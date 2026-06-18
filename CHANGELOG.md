# Changelog

## [2.2.0] — 2026-06-18

**`priority` command + a general field setter (AGT-84).** The CLI could edit only an issue's title
(`retitle`) and lifecycle state (`start`/`review`/`close`/`cancel`/`reopen`) — there was no command to
change priority or any other field, so bumping a ticket's priority meant dropping to a raw
`issueUpdate(input:{priority:N})` mutation, which defeats the shared CLI (hit live bumping AKA-260
High→Urgent). Adds:

- **`Linear::Client#set_priority` / `#set` / `#update_issue`.** `set_priority(id, word)` changes priority
  by word (urgent|high|medium|low|none) and reports the human-readable old→new (mirrors `retitle`).
  `set(id, priority:/assignee:/estimate:/due:/label:)` is a general field setter that resolves the
  human inputs and applies priority/assignee/estimate/due in a SINGLE `issueUpdate`, merging any labels
  via `add_labels` (existing preserved). `update_issue(id, input)` is the low-level `issueUpdate`
  wrapper (resolution-free) reusable by any host (e.g. the admin `LinearIssuesController`). Pure inputs
  (priority word, estimate, due format) are validated **before** any network call, so a bad value never
  half-applies. New helpers `#priority_int` (strict word→int, unlike the medium-defaulting
  `#priority_value` used by `create`), `#viewer_id`, `#user_id_for_email`, `#assignee_id_for`.
- **CLI `priority` (alias `prio`) and `set` subcommands.** `priority ISSUE-N high` prints old→new;
  `set ISSUE-N [--priority X] [--assignee me|email] [--estimate N] [--due YYYY-MM-DD] [--label NAME]`
  changes any subset of fields in one call and prints each change. An empty `--due` clears the due date;
  unknown flags are rejected. `priority` delegates to `set`.

## [2.1.0] — 2026-06-17

**Comment edit/delete + file-based bodies + unknown-flag guard (AGT-83).** A stray comment posted by a
fat-fingered flag (`comment ISSUE-N --show`) used to be un-removable from the CLI, and multi-line
markdown bodies with backticks/parens broke under bash command substitution. Adds:

- **`Linear::Client#comments` / `#update_comment` / `#delete_comment`** — list an issue's comments
  (id + timestamp + author + body), edit a comment body (`commentUpdate`), and delete a comment
  (`commentDelete`). Reusable by any host (e.g. the admin `LinearIssuesController`).
- **CLI `comments` / `comment-edit` / `comment-delete` subcommands.** `comments ISSUE-N` lists comment
  ids; `comment-edit ISSUE-N <id> "new body"` and `comment-delete ISSUE-N <id>` edit/remove one. Both
  guard that the comment actually belongs to ISSUE-N (a typo'd id / wrong issue aborts with a hint).
  `view ISSUE-N` now also lists comment ids for discoverability.
- **File-based bodies** (borrowed from schpet/linear-cli) — `create --desc-file PATH`
  (alias `--description-file`) and `comment` / `comment-edit --body-file PATH` read the body from a
  file instead of a shell arg, sidestepping shell-escaping/quoting bugs with multi-line markdown.
- **Unknown-flag rejection** on `create` / `comment` / `comment-edit` / `comment-delete`: an
  unrecognized `--flag` now aborts with a clear error instead of being silently swallowed (or, for
  `comment`, posted as the body) — the fat-finger that motivated this ticket can no longer create junk.

## [2.0.1] — 2026-06-15

**Resilience — transient state-transition failures now self-heal (AKA-491).** A single transient blip
on the first lifecycle transition (e.g. `linear start AGT-52`) used to fail hard with
`INVALID_INPUT: Discrepancy between issue team and state, cycle or project.` and — because Linear
flags that error `userError: true` — print the misleading "this workspace hit a Linear plan limit"
hint, which once pushed a whole session onto an SSH/box-CLI fallback. Fixes:

- **`Linear::Client#transition` re-resolves + retries a stale team↔state map.** The discrepancy is the
  symptom of a wrong-team workflow-state id (a transient/partial `find_issue` returning the issue
  without its `team` node falls back to the *default* team's states). It is now surfaced as the
  distinct, retryable `StaleStateError` (a subclass of `ApiError`); `transition` busts the team +
  workflow-state caches, re-fetches the issue, and retries up to `MAX_TRANSIENT_ATTEMPTS` (3) with a
  short backoff. Only a *persistent* mismatch escapes — wrapped as a clear `ApiError`, never silent.
- **Transport-layer retry for network blips + 5xx.** `#graphql` now retries `Net::OpenTimeout` /
  `Net::ReadTimeout` / `Errno::ECONNRESET` / SSL / EOF errors and HTTP 5xx responses up to
  `MAX_ATTEMPTS` with exponential backoff, then surfaces a clear `ApiError`. Genuine client errors
  (4xx, bad field, `404` not-found, `403` perms) and real usage/plan caps (`USAGE_LIMIT_EXCEEDED`)
  still **fail fast** — never retried.
- **Opt-in diagnostics.** Set `LINEAR_DEBUG=1` to log the resolved team + state id at transition time
  and any self-healing retry to stderr.

## [2.0.0] — 2026-06-15

**Breaking — gem renamed.** The gem is now project-agnostic. The Ruby API is unchanged
(`Linear::Client` and the `linear` CLI behave identically), but the package and namespace changed:

- Gem name `hgl_linear` → **`linear_cli`**; module `HglLinear` → **`LinearCli`**. Consumers must
  update `gem "hgl_linear"` → `gem "linear_cli"` and `require "hgl_linear"` → `require "linear_cli"`
  (and `Gem.bin_path("hgl_linear", "linear")` → `Gem.bin_path("linear_cli", "linear")`).
- Removed the hardcoded `DEFAULT_TEAM_KEY = "AKA"` default team. `Linear::Client` now reads
  `LINEAR_DEFAULT_TEAM` with **no fallback**; `create` / `list` raise a clear `ConfigError` when no
  team is configured (pass `--team KEY` or set `LINEAR_DEFAULT_TEAM`). Identifier-based commands are
  unaffected (they resolve the team from the issue id).
- Removed project-specific references from docs, comments, and tests.

`v1.0.0` (the `hgl_linear` release) remains available by tag for anything still pinned to it.

## [1.0.0] — 2026-06-14

Initial release. A standalone, project-agnostic gem (`Linear::Client` library + `linear` CLI) so any
project can share one Linear tool.

- `Linear::Client` library: multi-team resolution, full-text dedup search, create with dependency
  links (parent / blocks / blocked-by / related), label auto-create, lifecycle state transitions
  (todo / in_progress / in_review / done / canceled), reopen, relations, parent/sub-issue, file
  upload (GraphQL half), and rate-limit/usage-limit handling with exponential backoff.
- `linear` CLI (`exe/linear`) over the client: `search`, `create`, `view`, `url`, `list`, `start`,
  `review`, `commit`, `comment`, `attach`, `label`, `retitle`, `reopen`, `relate`, `unrelate`,
  `parent`, `close`, `cancel`. Self-names from `$PROGRAM_NAME` so it reads correctly as `linear` or a
  host `bin/linear` shim.
- Config is env-only: `LINEAR_API_KEY` + `LINEAR_DEFAULT_TEAM`. Optional `.env` auto-load via dotenv.
- Lifted unit tests (no network) run on plain Minitest; CI on Ruby 3.4.9.
