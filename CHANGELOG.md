# Changelog

## [2.4.0] — 2026-07-30

**`edit` — replace an issue's description in place (AGT-216).** The CLI could only ever APPEND to a
ticket's body: `--desc` / `--desc-file` existed on `create` alone, `set` covered
priority/assignee/estimate/due/label, and there was no `edit`. So an agent told to keep a ticket's
description current had no way to do it and had to post a comment instead — which makes the newest
COMMENT the state of the world rather than the description. That made the ticket contract's
load-bearing rule — *description = now, edited in place; comments = how it got here* — unimplementable
for **every** ticket, and blocked any board/status ticket that rewrites its body each tick.

- **`linear edit ISSUE-N --desc "body" | --desc-file PATH|-`** replaces the whole description and
  **posts no comment** as a side effect. `--description` / `--description-file` are accepted aliases,
  and `edit-desc` is an alias for the command (disambiguating it from the existing `comment-edit`).
  `--desc-file -` reads STDIN, so the AGT-201 single-quoted-heredoc idiom works here too — the robust
  path for a body with code fences / backticks / `$VAR` / `\`:

  ```sh
  linear edit ISSUE-N --desc-file - <<'MD'
  ## Now
  | lane | wip | cap |
  MD
  ```
- **Flags only — no positional body.** A whole-body replace is destructive, so it must be explicit;
  there is no `edit ISSUE-N "body"` form to fat-finger.
- **An empty or whitespace-only body is refused, not applied.** An empty body means a heredoc produced
  nothing or a `--desc-file` was empty — never "blank this ticket". The guard lives in
  `Linear::Client#edit_description`, so every host inherits it (the CLI *and* the admin HTTP endpoint),
  and a description replace is otherwise unrecoverable.
- The CLI prints the **char delta** (`description replaced (9070 → 359 chars)`) so an accidental
  clobber is visible at a glance, and `#edit_description` returns the previous body
  (`{ old_description:, issue: }`) so a host can report or stash it.
- Implementation rides the existing `#update_issue` mutation path — one new field on
  `IssueUpdateInput`, no new plumbing, and it inherits that method's success check.
- **Gotcha, measured live:** unlike a comment body, a description does **not** round-trip
  byte-for-byte — Linear canonicalizes description markdown server-side (`|---|` → `| -- |`, a `-`
  bullet → `*`, trailing newline stripped). Content is untouched (backticks, `$(…)`, `$VAR`,
  backslashes, quotes all survive verbatim) and the normalization is idempotent, so never verify a
  write by comparing bytes.
- New `test/cli/edit_desc_test.rb` (STDIN / inline / aliases / **no comment posted** / char delta /
  usage + typo-flag guards) plus client-level tests for the single-field mutation, the empty-body
  refusal, and the GraphQL-variable round trip. Both `cli/*_test.rb` files now `load exe/linear` only
  when it isn't already loaded, so the suite no longer warns about re-initialized constants.

## [2.3.0] — 2026-07-11

**Rich multi-line Markdown comment bodies — STDIN input + `--` end-of-options (AGT-201).** Filing a
rich Linear comment via `bin/linear comment ISSUE-N "<body>"` mangled the body before the gem ever saw
it: inside bash double quotes, code-fence/inline **backticks** run as command substitution, `$VAR` /
`$(…)` expand, and `\` is eaten — so a body with headings + fenced code + `$`/`\` came out corrupted
(and a body starting with `---` was rejected outright as a flag). The GraphQL layer was already correct
(bodies travel as escaped **variables**, never string-interpolated into the query), so the fix is in
how the CLI READS the body:

- **`--body-file -` reads STDIN.** `read_body_file` now treats `-` as standard input, so a caller can
  pipe a **single-quoted heredoc** — which suppresses ALL shell expansion — and the body reaches the
  gem byte-for-byte:

  ```sh
  linear comment ISSUE-N --body-file - <<'MD'
  ## Heading — inline `code`, $VARS, $(cmd) and C:\paths all survive verbatim
  MD
  ```

  Shared by `comment`, `comment-edit`, and `create --desc-file`, so all three gain STDIN input.
- **POSIX `--` end-of-options separator** on `comment` / `comment-edit`: everything after a bare `--`
  is the body, so a positional body that itself starts with `--` (e.g. a `---` horizontal rule) is no
  longer misread as an unknown flag. A genuine typo'd flag (`--show`) *before* `--` is still rejected —
  the AGT-83 unknown-flag guard is preserved.
- Usage/help updated to surface `--body-file -` (with the single-quoted-heredoc idiom) as the robust
  path for complex bodies.
- `exe/linear`'s command dispatch is wrapped in `run(argv)` with a guarded autorun
  (`LINEAR_CLI_SKIP_MAIN=1`) so the CLI helpers are unit-testable without a network round-trip. New
  `test/cli/comment_body_test.rb` (STDIN read / `--` separator / preserved typo-guard) plus a
  client-level nasty-body → GraphQL-variable JSON round-trip test.

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
