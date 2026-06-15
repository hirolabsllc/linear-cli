# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require "json"

# Shared Linear GraphQL client — multi-team, default team configurable.
#
# This is the ONE place the Linear GraphQL operations + conventions live. It ships in the standalone
# `linear_cli` gem so every surface drives this same class and the logic is never duplicated:
#   * the `linear` CLI (the gem's `exe/linear`) — arg-parse + stdout only.
#   * a host app's HTTP endpoint (e.g. an admin controller) — lets external agents that run OUTSIDE a
#     checkout file/update tickets with the same conventions.
#
# Pure Net::HTTP + JSON — it MUST NOT require Rails (or anything beyond stdlib) to boot, so the CLI
# loads it standalone. It reads `LINEAR_API_KEY` from ENV and raises typed errors (nested under
# {Linear::Client}); presentation concerns — `exit 1` / `$stderr` / stdout formatting — belong to the
# CLI layer, JSON rendering + HTTP status mapping to a host controller layer.
module Linear
  class Client
    ENDPOINT = URI("https://api.linear.app/graphql")

    # --- typed errors --------------------------------------------------------
    # Callers rescue these instead of the client calling `exit`/`abort`.
    class Error < StandardError; end
    class ConfigError < Error; end   # LINEAR_API_KEY missing → CLI exit 1 / controller 503
    class ApiError < Error; end      # Linear GraphQL returned errors / unexpected shape → 502
    class NotFound < Error; end      # issue identifier not found → 404
    class InvalidInput < Error; end  # bad caller input (unknown relation type / state) → 422
    # ApiError refinements so callers can branch on the failure mode. Both subclass ApiError, so the
    # controller's `rescue_from ApiError` still maps them to 502 (no HTTP-contract change) while the
    # CLI prints a mode-specific hint.
    class RateLimited < ApiError; end  # HTTP 429 / extensions.code == "RATELIMITED" — retried w/ backoff, then surfaced
    class UsageLimited < ApiError; end # terminal extensions.userError == true (e.g. USAGE_LIMIT_EXCEEDED) — NEVER retried
    # A team↔state discrepancy ("Discrepancy between issue team and state, cycle or project"). Linear
    # returns it as an INVALID_INPUT with userError:true, so it WOULD otherwise be classified as a
    # terminal UsageLimited — but it is the symptom of a stale/cross-team workflow-state map (a state id
    # from the wrong team), which is RETRYABLE once the team→state map is re-resolved. {#transition}
    # rescues this, busts the team/state caches, re-resolves, and retries; only a persistent one escapes
    # (as a wrapped ApiError). A single transient blip must never again silently push a session onto an
    # SSH/box-CLI fallback (AKA-491).
    class StaleStateError < ApiError; end

    # Canonical Linear label colors used when auto-creating a missing label.
    LABEL_COLORS = {
      "bug"            => "#eb5757",
      "feature"        => "#5e6ad2",
      "infrastructure" => "#26b5ce",
      "ops"            => "#f2c94c"
    }.freeze

    PRIORITY_MAP   = { "urgent" => 1, "high" => 2, "medium" => 3, "low" => 4, "no" => 0 }.freeze
    PRIORITY_LABEL = { 0 => "No priority", 1 => "Urgent", 2 => "High", 3 => "Medium", 4 => "Low" }.freeze

    # Linear's IssueRelationType enum. "blocked-by" is a CLI/API convenience that swaps direction.
    RELATION_TYPES = %w[related duplicate blocks similar].freeze

    # Rate-limit retry policy. Total attempts including the first try (so MAX_ATTEMPTS = 4 ⇒ ≤3 retries).
    # Exponential backoff is used only when Linear gives no explicit reset/retry header; every sleep is
    # capped at MAX_BACKOFF so a far-future reset header can't wedge the CLI.
    MAX_ATTEMPTS = 4
    BASE_BACKOFF = 0.5
    MAX_BACKOFF  = 30.0

    # Transient-failure retry policy for the state-map re-resolution in {#transition}. Kept separate
    # from the rate-limit budget so a stale-state retry can't consume (or be starved by) the 429 budget.
    # MAX_TRANSIENT_ATTEMPTS = 3 ⇒ the first try + up to 2 re-resolved retries.
    MAX_TRANSIENT_ATTEMPTS = 3
    TRANSIENT_BACKOFF      = 0.3

    # Net::HTTP transport exceptions that mean "the round-trip itself blipped — retry it", not a real
    # API failure. Retried at the transport layer ({#graphql}) up to MAX_ATTEMPTS, then surfaced as
    # ApiError. A 5xx HTTP status is treated the same way.
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
      EOFError, SocketError, IOError, OpenSSL::SSL::SSLError
    ].freeze

    # Linear's message for a wrong-team workflow-state id (a stale/cross-team state map). Matched
    # case-insensitively against the surfaced error so a real plan/usage cap (USAGE_LIMIT_EXCEEDED) is
    # NOT mistaken for it — see {StaleStateError}.
    STALE_STATE_PATTERN = /discrepancy between issue team and state/i

    attr_reader :team_key

    # The default team comes from LINEAR_DEFAULT_TEAM (or an explicit `team_key:`). There is no
    # hardcoded fallback — create/list with no team configured raise a clear ConfigError (see
    # {#team_id_for}); identifier-based commands resolve the team from the issue id and need none.
    def initialize(api_key: ENV["LINEAR_API_KEY"], team_key: ENV["LINEAR_DEFAULT_TEAM"])
      @api_key  = api_key
      key       = team_key.to_s.strip
      @team_key = key.empty? ? nil : key
    end

    def configured?
      !@api_key.to_s.strip.empty?
    end

    # --- core transport ------------------------------------------------------

    # Run a GraphQL query/mutation and return the `data` hash. Raises:
    #   * ConfigError  — LINEAR_API_KEY missing.
    #   * UsageLimited — a terminal GraphQL error with extensions.userError == true (e.g. the free-plan
    #                    active-issue cap, USAGE_LIMIT_EXCEEDED). Surfaces Linear's
    #                    extensions.userPresentableMessage + code, and is NEVER retried.
    #   * RateLimited  — HTTP 429 / extensions.code == "RATELIMITED", surfaced only after exhausting
    #                    MAX_ATTEMPTS retries (exponential backoff honoring Retry-After /
    #                    x-ratelimit-*-reset headers).
    #   * ApiError     — any other GraphQL error, a non-JSON body, or a non-2xx HTTP status.
    #
    # The message is built from extensions.userPresentableMessage (falling back to the raw `message`)
    # prefixed with extensions.code, so the real cause surfaces instead of a bare "usage limit exceeded".
    def graphql(query, variables = {})
      raise ConfigError, "LINEAR_API_KEY not set. Add it to .env — get one at linear.app/settings/api" unless configured?

      attempt = 0
      loop do
        attempt += 1
        begin
          res = perform_request(query, variables)
        rescue *NETWORK_ERRORS => e
          # A transport blip (timeout / reset / SSL). Re-sending the same request is the right move —
          # back off and retry, then surface a clear ApiError rather than crashing with a raw exception.
          raise ApiError, "Linear request failed after #{attempt} attempt(s): #{e.class}: #{e.message}" if attempt >= MAX_ATTEMPTS

          backoff_pause(exponential_backoff(attempt))
          next
        end

        status = res.code.to_i
        body   = parse_json(res.body)
        errors = body.is_a?(Hash) ? body["errors"] : nil

        if errors.is_a?(Array) && !errors.empty?
          primary    = primary_error(errors)
          code       = primary.dig("extensions", "code").to_s
          user_error = primary.dig("extensions", "userError") == true
          message    = error_message(errors)

          if rate_limited?(status, code)
            raise RateLimited, message if attempt >= MAX_ATTEMPTS

            backoff_pause(retry_delay(res, attempt))
            next
          end
          # A team↔state discrepancy is a stale/cross-team state-map symptom, NOT a terminal plan limit
          # — even though Linear flags it userError:true. Surface it as the distinct, retryable
          # StaleStateError so {#transition} re-resolves + retries (and the CLI never prints the
          # misleading "plan limit" hint that once pushed a session onto an SSH fallback — AKA-491).
          raise StaleStateError, message if stale_state_error?(code, message)
          # Other terminal user errors (the free-plan issue cap, etc.) are the caller's to resolve.
          raise UsageLimited, message if user_error

          raise ApiError, message
        end

        # A bare 429 (or a 429 with a non-JSON body) is still rate limiting — back off and retry.
        if status == 429
          raise RateLimited, "Linear rate limit exceeded (HTTP 429)" if attempt >= MAX_ATTEMPTS

          backoff_pause(retry_delay(res, attempt))
          next
        end

        # 5xx is a transient server-side blip — retry the round-trip before giving up.
        if status >= 500
          raise ApiError, "Linear returned HTTP #{status} after #{attempt} attempt(s): #{truncate(res.body)}" if attempt >= MAX_ATTEMPTS

          backoff_pause(exponential_backoff(attempt))
          next
        end

        raise ApiError, "Linear returned a non-JSON response (HTTP #{status}): #{truncate(res.body)}" unless body.is_a?(Hash)
        # Remaining 4xx (400/401/403/404/422 …) are genuine client errors — fail fast, never retry.
        raise ApiError, "Linear returned HTTP #{status}: #{truncate(res.body)}" if status >= 400

        return body["data"]
      end
    end

    # --- team / workflow states / labels (memoized within an instance) -------

    # All teams in the workspace ({ id, key }), fetched once per client. The workspace may be
    # multi-team; every team is resolved by KEY against this live list, so no team key is ever
    # hardcoded.
    def teams
      @teams ||= graphql("query { teams { nodes { id key } } }").dig("teams", "nodes") || []
    end

    # Resolve a team key (e.g. "ENG") to its Linear id. Raises ConfigError when no team is configured
    # (no LINEAR_DEFAULT_TEAM and no --team), or ApiError if the workspace has no such team.
    def team_id_for(key)
      key = key.to_s.strip
      if key.empty?
        raise ConfigError, "No Linear team specified. Set LINEAR_DEFAULT_TEAM or pass a team key (e.g. --team ENG)."
      end

      team = teams.find { |t| t["key"] == key }
      raise ApiError, "Team #{key} not found in Linear workspace" unless team

      team["id"]
    end

    # The client's default team — used by create/list when no explicit team is passed.
    def team_id
      @team_id ||= team_id_for(team_key)
    end

    # Workflow states for a given team id, memoized per team. A close/transition on an issue must
    # resolve THAT issue's team's "Done" state, not the default team's — so this is keyed by the
    # ISSUE's team.
    def workflow_states_for(t_id)
      (@workflow_states_by_team ||= {})[t_id] ||= begin
        data = graphql(<<~GQL, { teamId: t_id })
          query($teamId: ID!) {
            workflowStates(filter: { team: { id: { eq: $teamId } } }) {
              nodes { id name type }
            }
          }
        GQL
        data.dig("workflowStates", "nodes") || []
      end
    end

    # Workflow states for the client's default team (callers with no specific issue/team in hand).
    def workflow_states
      workflow_states_for(team_id)
    end

    # All labels visible to the team: workspace-level (shared) + this team's own. Linear's default
    # workspace ships Bug/Feature/Improvement at the workspace level, so a team-only filter misses
    # them — fetch everything and match by name.
    def labels
      data = graphql("query { issueLabels { nodes { id name } } }")
      data.dig("issueLabels", "nodes") || []
    end

    # Resolve a label name to its id, creating it at the workspace level if missing. Case-insensitive;
    # new labels are Title-cased with a canonical color when known. Returns the label id (or nil).
    def find_or_create_label(name)
      existing = labels.find { |l| l["name"].downcase == name.downcase }
      return existing["id"] if existing

      color = LABEL_COLORS[name.downcase] || "#95a2b3"
      display = name.downcase.split(/[\s_-]+/).map(&:capitalize).join(" ")
      data = graphql(<<~GQL, { name: display, color: color })
        mutation($name: String!, $color: String!) {
          issueLabelCreate(input: { name: $name, color: $color }) {
            success
            issueLabel { id name }
          }
        }
      GQL
      data.dig("issueLabelCreate", "issueLabel", "id")
    end

    def priority_value(name)
      PRIORITY_MAP[name.to_s.downcase] || 3
    end

    def priority_label(value)
      PRIORITY_LABEL[value] || "?"
    end

    # --- issue lookup --------------------------------------------------------

    # Full issue node (incl. parent/children/relations/description), or nil if not found.
    def find_issue(identifier)
      data = graphql(<<~GQL, { id: identifier })
        query($id: String!) {
          issue(id: $id) {
            id identifier title url priority
            team { id key }
            state { name type }
            assignee { name }
            labels { nodes { name } }
            parent { identifier }
            children { nodes { identifier } }
            relations { nodes { type relatedIssue { identifier } } }
            inverseRelations { nodes { type issue { identifier } } }
            description
          }
        }
      GQL
      data["issue"]
    end

    # Resolve an issue, raising NotFound when absent (used by mutating operations).
    def find_issue!(identifier)
      find_issue(identifier) || raise(NotFound, "Issue #{identifier} not found")
    end

    # --- create --------------------------------------------------------------

    # Create an issue. `description` is the FINAL body string — the caller embeds any screenshot
    # markdown (a local-file concern that lives in the CLI). Dependency refs are resolved leniently:
    # an unknown ref is reported as `ok: false` in `:links` rather than raising, so a bad link never
    # discards an otherwise-good issue. Returns { issue:, links: [{kind:, ref:, identifier:, ok:}] }.
    def create(title:, label: nil, priority: "medium", description: nil, team: nil,
               parent: nil, blocks: [], blocked_by: [], related: [])
      input = { title: title, teamId: team_id_for(team || team_key), priority: priority_value(priority) }
      input[:description] = description if description && !description.empty?
      if label
        label_id = find_or_create_label(label)
        input[:labelIds] = [label_id] if label_id
      end

      data = graphql(<<~GQL, { input: input })
        mutation($input: IssueCreateInput!) {
          issueCreate(input: $input) {
            success
            issue { id identifier title url }
          }
        }
      GQL
      issue = data.dig("issueCreate", "issue")
      raise ApiError, "Linear refused the issue create" unless issue

      links = []
      new_id = issue["id"]

      if parent
        p = find_issue(parent)
        links << link_result("parent", parent, p, p && set_parent(new_id, p["id"]))
      end
      # NEW blocks X ⇒ relation "NEW blocks X"
      Array(blocks).each do |ref|
        t = find_issue(ref)
        links << link_result("blocks", ref, t, t && create_relation(new_id, t["id"], "blocks"))
      end
      # NEW blocked by X ⇒ relation "X blocks NEW"
      Array(blocked_by).each do |ref|
        t = find_issue(ref)
        links << link_result("blocked_by", ref, t, t && create_relation(t["id"], new_id, "blocks"))
      end
      Array(related).each do |ref|
        t = find_issue(ref)
        links << link_result("related", ref, t, t && create_relation(new_id, t["id"], "related"))
      end

      { issue: issue, links: links }
    end

    # --- title / comment / labels -------------------------------------------

    def retitle(identifier, new_title)
      issue = find_issue!(identifier)
      old_title = issue["title"]
      data = graphql(<<~GQL, { id: issue["id"], title: new_title })
        mutation($id: String!, $title: String!) {
          issueUpdate(id: $id, input: { title: $title }) {
            success
            issue { identifier title url }
          }
        }
      GQL
      { old_title: old_title, issue: data.dig("issueUpdate", "issue") }
    end

    # Add a comment to an issue (resolves the identifier first). Returns the issue identifier.
    def comment(identifier, body)
      issue = find_issue!(identifier)
      add_comment(issue["id"], body)
      issue["identifier"]
    end

    # Low-level: add a comment to an already-resolved issue id (no extra lookup).
    def add_comment(issue_id, body)
      graphql(<<~GQL, { issueId: issue_id, body: body })
        mutation($issueId: String!, $body: String!) {
          commentCreate(input: { issueId: $issueId, body: $body }) { success }
        }
      GQL
    end

    # Add one or more labels to an issue, preserving existing labels (idempotent — Linear de-dupes by
    # id). Missing labels auto-create. Returns { identifier:, labels: }.
    def add_labels(identifier, names)
      names = Array(names).map(&:to_s).reject { |n| n.strip.empty? }
      raise InvalidInput, "No label name given" if names.empty?

      issue = find_issue!(identifier)
      label_ids = names.map do |n|
        find_or_create_label(n) || raise(ApiError, "Could not resolve or create label '#{n}'")
      end
      existing = graphql(<<~GQL, { id: issue["id"] }).dig("issue", "labels", "nodes")&.map { |l| l["id"] } || []
        query($id: String!) { issue(id: $id) { labels { nodes { id } } } }
      GQL
      ids = (existing + label_ids).uniq

      graphql(<<~GQL, { id: issue["id"], labelIds: ids })
        mutation($id: String!, $labelIds: [String!]!) {
          issueUpdate(id: $id, input: { labelIds: $labelIds }) { success }
        }
      GQL
      { identifier: issue["identifier"], labels: names }
    end

    # --- state transitions ---------------------------------------------------

    # Move an issue to a lifecycle state (:todo/:in_progress/:in_review/:done/:canceled), optionally
    # posting a comment in the same call. Returns { issue:, from: }.
    def transition(identifier, target, comment: nil)
      attempt = 0
      begin
        attempt += 1
        # Re-fetch the issue each attempt: a transient partial response can return it without a `team`
        # node, which would otherwise fall back to the DEFAULT team's states (the cross-team state-map
        # bug behind AKA-491). A fresh fetch on retry repopulates the team.
        issue = find_issue!(identifier)
        # Resolve the target state from the ISSUE's OWN team, not the client default — so closing an
        # issue targets its own team's "Done" (cross-team state ids don't apply).
        issue_team_id  = issue.dig("team", "id")
        issue_team_key = issue.dig("team", "key") || team_key
        states = issue_team_id ? workflow_states_for(issue_team_id) : workflow_states
        state  = find_state(target, states: states, team_label: issue_team_key)
        debug_log { "transition #{identifier} → #{target}: team=#{issue_team_key}(#{issue_team_id}) state=#{state['name']}(#{state['id']}) attempt=#{attempt}" }
        data = graphql(<<~GQL, { id: issue["id"], stateId: state["id"] })
          mutation($id: String!, $stateId: String!) {
            issueUpdate(id: $id, input: { stateId: $stateId }) {
              success
              issue { identifier title state { name } url }
            }
          }
        GQL
        add_comment(issue["id"], comment) if comment && !comment.to_s.empty?
        { issue: data.dig("issueUpdate", "issue"), from: issue.dig("state", "name") }
      rescue StaleStateError => e
        # A wrong-team state id slipped through (stale/partial team↔state resolution). Bust the team +
        # workflow-state caches and re-resolve from scratch, then retry. Only a persistent discrepancy
        # escapes — wrapped as a clear ApiError so it still fails (loudly), never silently.
        if attempt >= MAX_TRANSIENT_ATTEMPTS
          raise ApiError, "Linear team/state map still mismatched after #{attempt} re-resolved attempt(s): #{e.message}"
        end

        reset_team_state_cache!
        debug_log { "transition #{identifier}: stale team/state map (#{e.message}) — re-resolving, retry #{attempt + 1}/#{MAX_TRANSIENT_ATTEMPTS}" }
        backoff_pause(TRANSIENT_BACKOFF * attempt)
        retry
      end
    end

    # Move a Done/Canceled (or any) issue back to Todo (default) or In Progress — a recurrence of
    # already-closed work, keeping the original history. Returns { identifier:, from:, to: }.
    def reopen(identifier, to_progress: false, comment: nil)
      res = transition(identifier, to_progress ? :in_progress : :todo, comment: comment)
      { identifier: res[:issue]["identifier"], from: res[:from], to: res[:issue].dig("state", "name") }
    end

    # --- relations & parent --------------------------------------------------

    # Create a real Linear relation. `type` reads in the canonical direction "issueId <type>
    # relatedIssueId" (e.g. blocks). Returns the GraphQL `success` boolean.
    def create_relation(issue_id, related_id, type)
      data = graphql(<<~GQL, { issueId: issue_id, relatedIssueId: related_id, type: type })
        mutation($issueId: String!, $relatedIssueId: String!, $type: IssueRelationType!) {
          issueRelationCreate(input: { issueId: $issueId, relatedIssueId: $relatedIssueId, type: $type }) {
            success
          }
        }
      GQL
      data.dig("issueRelationCreate", "success")
    end

    # Make `child` a sub-issue of `parent` (Linear's native epic hierarchy). Returns `success`.
    def set_parent(child_id, parent_id)
      data = graphql(<<~GQL, { id: child_id, parentId: parent_id })
        mutation($id: String!, $parentId: String!) {
          issueUpdate(id: $id, input: { parentId: $parentId }) { success }
        }
      GQL
      data.dig("issueUpdate", "success")
    end

    # Higher-level relate-by-identifier. Validates the type FIRST (no network on a bad type), then
    # resolves both issues. "blocked-by" swaps direction. Returns { a:, b:, type: }.
    def relate(a_ident, b_ident, type: "related")
      type = type.to_s.downcase
      unless RELATION_TYPES.include?(type) || type == "blocked-by"
        raise InvalidInput, "Unknown relation type #{type.inspect}; use related | blocks | blocked-by | duplicate | similar"
      end

      a = find_issue!(a_ident)
      b = find_issue!(b_ident)
      ok =
        if type == "blocked-by"
          create_relation(b["id"], a["id"], "blocks")
        else
          create_relation(a["id"], b["id"], type)
        end
      raise ApiError, "Failed to create relation between #{a_ident} and #{b_ident}" unless ok

      { a: a["identifier"], b: b["identifier"], type: type }
    end

    # Make CHILD a sub-issue of PARENT by identifier. Returns { child:, parent: }.
    def set_parent_by_identifier(child_ident, parent_ident)
      c = find_issue!(child_ident)
      p = find_issue!(parent_ident)
      raise ApiError, "Failed to set #{parent_ident} as parent of #{child_ident}" unless set_parent(c["id"], p["id"])

      { child: c["identifier"], parent: p["identifier"] }
    end

    # Remove any relation(s) between two issues (both directions). Returns the number removed.
    def unrelate(a_ident, b_ident)
      a = find_issue!(a_ident)
      b = find_issue!(b_ident)
      data = graphql(<<~GQL, { id: a["id"] })
        query($id: String!) {
          issue(id: $id) {
            relations        { nodes { id relatedIssue { id } } }
            inverseRelations { nodes { id issue { id } } }
          }
        }
      GQL
      ids  = (data.dig("issue", "relations", "nodes") || []).select { |r| r.dig("relatedIssue", "id") == b["id"] }.map { |r| r["id"] }
      ids += (data.dig("issue", "inverseRelations", "nodes") || []).select { |r| r.dig("issue", "id") == b["id"] }.map { |r| r["id"] }
      ids.each do |rid|
        graphql(<<~GQL, { id: rid })
          mutation($id: String!) { issueRelationDelete(id: $id) { success } }
        GQL
      end
      ids.length
    end

    # --- search / list -------------------------------------------------------

    # Full-text dedup search — relevance-ranked across title + description, ALL states
    # (Done/Canceled included) so reopen/link candidates surface. Returns issue nodes.
    def search(term, limit: 10)
      data = graphql(<<~GQL, { term: term, first: limit })
        query($term: String!, $first: Int!) {
          searchIssues(term: $term, first: $first) {
            nodes {
              identifier title priority url
              state { name type }
              labels { nodes { name } }
            }
          }
        }
      GQL
      data.dig("searchIssues", "nodes") || []
    end

    # List team issues, optionally filtered by lifecycle status and/or label name. Returns nodes.
    def list(status: nil, label: nil, team: nil)
      filter = { team: { id: { eq: team_id_for(team || team_key) } } }
      if status
        type = case status.to_s.downcase
               when "todo"                      then "unstarted"
               when "in_progress", "inprogress" then "started"
               when "done"                      then "completed"
               else status.to_s
               end
        filter[:state] = { type: { eq: type } }
      end

      data = graphql(<<~GQL, { filter: filter })
        query($filter: IssueFilter!) {
          issues(filter: $filter, orderBy: createdAt) {
            nodes {
              identifier title priority url
              state { name }
              labels { nodes { name } }
            }
          }
        }
      GQL
      issues = data.dig("issues", "nodes") || []
      if label
        issues = issues.select { |i| i.dig("labels", "nodes")&.any? { |l| l["name"].downcase == label.downcase } }
      end
      issues
    end

    # --- file upload (GraphQL half only) ------------------------------------

    # GraphQL half of an image upload (CLI screenshot helpers). Returns the `uploadFile` node
    # `{ uploadUrl, assetUrl, headers }`. The byte PUT stays in the CLI (local-file I/O), so no
    # GraphQL lives outside this class.
    def request_file_upload(content_type:, filename:, size:)
      data = graphql(<<~GQL, { contentType: content_type, filename: filename, size: size })
        mutation($contentType: String!, $filename: String!, $size: Int!) {
          fileUpload(contentType: $contentType, filename: $filename, size: $size) {
            success
            uploadFile { uploadUrl assetUrl headers { key value } }
          }
        }
      GQL
      data.dig("fileUpload", "uploadFile")
    end

    private

    def link_result(kind, ref, issue_node, ok)
      { kind: kind, ref: ref, identifier: issue_node && issue_node["identifier"], ok: !!ok }
    end

    # Resolve a target lifecycle symbol to its workflow-state node, mirroring the by-name/by-type
    # heuristics the CLI used (Linear has two "started" states — In Progress and In Review).
    def find_state(target, states: workflow_states, team_label: team_key)
      state =
        case target.to_sym
        when :in_progress
          states.find { |s| s["name"].casecmp?("In Progress") } ||
            states.find { |s| s["type"] == "started" && s["name"].downcase.include?("progress") } ||
            states.find { |s| s["type"] == "started" }
        when :in_review
          states.find { |s| s["name"].casecmp?("In Review") } ||
            states.find { |s| s["type"] == "started" && s["name"].downcase.include?("review") }
        when :done
          states.find { |s| s["type"] == "completed" } ||
            states.find { |s| s["name"].downcase.include?("done") }
        when :canceled
          states.find { |s| s["type"] == "canceled" } ||
            states.find { |s| s["name"].downcase.include?("cancel") }
        when :todo
          states.find { |s| s["name"].casecmp?("Todo") } ||
            states.find { |s| s["type"] == "unstarted" } ||
            states.find { |s| s["type"] == "backlog" }
        else
          raise InvalidInput, "Unknown target state #{target.inspect}"
        end
      state || raise(InvalidInput, "No '#{target}' state found in the #{team_label} workflow")
    end

    # --- transport internals (split out so retry/backoff is unit-testable) --

    # The single HTTP round-trip. Returns the raw Net::HTTPResponse (tests stub this to feed canned
    # 429/usage-limit responses). Kept tiny + Rails-free.
    def perform_request(query, variables)
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      req = Net::HTTP::Post.new(ENDPOINT.path, {
        "Content-Type" => "application/json",
        "Authorization" => @api_key
      })
      req.body = JSON.generate({ query: query, variables: utf8(variables) })
      http.request(req)
    end

    def parse_json(str)
      JSON.parse(str)
    rescue JSON::ParserError
      nil
    end

    # A 429 status or an explicit RATELIMITED GraphQL code means "retry after backing off".
    def rate_limited?(status, code)
      status == 429 || code.to_s.casecmp?("RATELIMITED")
    end

    # A team↔state discrepancy (INVALID_INPUT whose message names the team/state mismatch). Retryable
    # by re-resolving the state map — distinguished from a real plan/usage cap, which never matches the
    # pattern. The code check is best-effort (some discrepancies omit it), so the message pattern is
    # authoritative.
    def stale_state_error?(code, message)
      return false if message.to_s.empty?
      return false unless STALE_STATE_PATTERN.match?(message.to_s)

      code.to_s.empty? || code.casecmp?("INVALID_INPUT")
    end

    # Drop the per-instance team / workflow-state memoization so the next resolve re-queries Linear.
    # Used by {#transition} when a stale state map produced a wrong-team state id.
    def reset_team_state_cache!
      @teams = nil
      @team_id = nil
      @workflow_states_by_team = nil
    end

    # Plain exponential backoff (no rate-limit headers in play) clamped to MAX_BACKOFF — used for the
    # network/5xx transport retries.
    def exponential_backoff(attempt)
      clamp_delay(BASE_BACKOFF * (2**(attempt - 1)))
    end

    # Opt-in diagnostic, off unless LINEAR_DEBUG is set — logs the resolved team + state id and any
    # self-healing retry so a future discrepancy is debuggable without re-instrumenting. The block form
    # avoids building the string when disabled. Goes to $stderr (the CLI's diagnostic stream); never
    # stdout, so it can't pollute machine-readable output.
    def debug_log
      return unless ENV["LINEAR_DEBUG"] && !ENV["LINEAR_DEBUG"].to_s.strip.empty?

      warn "[linear] #{yield}"
    rescue StandardError
      nil
    end

    # The error to base the surfaced message on: the first one carrying an extensions.code (Linear puts
    # the actionable detail there), else the first error.
    def primary_error(errors)
      errors.find { |e| e.is_a?(Hash) && e.dig("extensions", "code") } || errors.first || {}
    end

    # Build a human message from Linear's errors[]: prefer extensions.userPresentableMessage (the
    # upgrade/rate-limit copy) over the terse `message`, and prefix extensions.code when present.
    def error_message(errors)
      Array(errors).map do |e|
        ext  = (e.is_a?(Hash) && e["extensions"]) || {}
        text = ext["userPresentableMessage"].to_s.strip
        text = e["message"].to_s.strip if text.empty?
        code = ext["code"].to_s.strip
        code.empty? ? text : "#{code}: #{text}"
      end.reject(&:empty?).uniq.join(", ")
    end

    # Seconds to wait before the next attempt. Honor Linear's reset/retry headers when present, else
    # exponential backoff; always clamped to [0, MAX_BACKOFF].
    def retry_delay(res, attempt)
      header = header_delay(res)
      return clamp_delay(header) if header

      clamp_delay(BASE_BACKOFF * (2**(attempt - 1)))
    end

    # Extract a wait, in seconds, from Retry-After (seconds) or the x-ratelimit-*-reset headers
    # (Linear sends an epoch-ms timestamp ⇒ convert to seconds-from-now). Returns nil if none usable.
    def header_delay(res)
      retry_after = res["retry-after"].to_f
      return retry_after if retry_after.positive?

      reset = res["x-ratelimit-requests-reset"] || res["x-ratelimit-complexity-reset"]
      reset_f = reset.to_f
      return nil unless reset_f.positive?

      reset_seconds = reset_f > 1_000_000_000_000 ? reset_f / 1000.0 : reset_f
      delay = reset_seconds - Time.now.to_f
      delay.positive? ? delay : nil
    end

    def clamp_delay(seconds)
      [[seconds.to_f, 0.0].max, MAX_BACKOFF].min
    end

    # Indirection so tests can assert the backoff schedule without actually sleeping.
    def backoff_pause(seconds)
      sleep(seconds) if seconds.to_f.positive?
    end

    def truncate(str, max = 200)
      s = str.to_s
      s.length > max ? "#{s[0, max]}…" : s
    end

    # Recursively re-tag strings as UTF-8 so JSON.generate doesn't see BINARY-tagged bytes (shell
    # args / file reads can arrive ASCII-8BIT) — silences the json 2.x deprecation + avoids the
    # hard error coming in json 3.0.
    def utf8(obj)
      case obj
      when String then obj.dup.force_encoding("UTF-8")
      when Array  then obj.map { |e| utf8(e) }
      when Hash   then obj.transform_values { |v| utf8(v) }
      else obj
      end
    end
  end
end
