# Changelog

## [2.9.0] — 2026-08-05

**`edit` now takes `--title`, so a rename and a re-describe are one call (AGT-232).** The house
convention is that a ticket's title becomes `TEAM-N (Type): <action>` once its id is known — which
means the rename always happens *after* create, usually in the same breath as filling in the body. The
CLI made that two commands: `edit ISSUE-N` accepted `--desc`/`--desc-file` only, so `edit --title` died
on `Unknown flag(s) for edit: --title` (hit for real on AGT-230) and the caller had to know that a
separate `retitle` verb existed. The admin endpoint's `PATCH /api/v1/admin/linear_issues/{id}` has
accepted `title` and `desc` together since AGT-216; the CLI, which is what actually files the tickets,
could not.

- **`linear edit ISSUE-N [--title "New title"] [--desc "body" | --desc-file PATH|-]`** — either flag,
  or both in one call. At least one is required; `--title` composes with the `--desc-file -` heredoc
  path exactly as `--desc` does.
- **Still posts NO comment**, for the same reason a description replace doesn't: a title is the
  ticket's "now", not how it got here.
- **Reports title old → new, then the description char delta, then ONE URL**, so a two-field edit reads
  as one change rather than two.
- **Two mutations, applied title-first — the same order the admin endpoint's PATCH runs them**, since
  there is one client by design. Blank values are therefore rejected in the CLI *before* either fires:
  a `--title ""` caught only by the client would abort after the description had already been replaced,
  leaving a half-applied edit.
- **`Linear::Client#retitle` now refuses an empty or whitespace-only title** before the issue lookup,
  mirroring `#edit_description`'s empty-body guard and for the same reason — a blank title means a
  `--title ""` or a shell expansion that produced nothing, never "blank this ticket", and Linear itself
  accepts it and leaves an unidentifiable row on the board. **No host-visible HTTP change:** the admin
  endpoint already filters blank titles with `.present?`, so the guard only newly binds the CLI. The
  endpoint's request/response contract is untouched, so `openapi-admin.yaml` does not move.
- **`retitle` / `rename` are unchanged and stay** — the single-purpose verb for a title-only rename
  (it has existed since v1.0.0; the gap AGT-232 filed was `edit --title`, not the mutation, which is
  why no new GraphQL was needed here).

## [2.8.2] — 2026-08-04

**One serializer, two queries, and only one of them selected `state.type` (AGT-230).** `#search` asked
Linear for `state { name type }`; `#list` asked for `state { name }`. A caller picks between the two by
whether it has a search term and then flattens whichever it got through a single serializer — trader-ai's
`Api::V1::Admin::LinearIssuesController#issue_row` reads `state.type` for both branches — so
`GET /api/v1/admin/linear_issues` returned a real `state_type` under `?q=<term>` and **always `null`**
under `?status=` / `?label=`. Same documented field, same code path, value decided by which sibling ran,
and no way for a consumer to tell "this issue has no workflow type" from "you used the other branch".
The endpoint's own controller test could not catch it: the fake client's `list` fixture supplied a
`state.type` the real query never asked for, so the fixture was more generous than the client.

- **`#list` now selects `state { name type }`**, so both branches populate `state_type`. Found while
  fixing AGT-224 and deliberately left out of that release to keep the diff to the truncation bug.
- **The parity is pinned, not just the field.** A test asserts `#list` and `#search` select the same
  `state` sub-selection, because adding a field to one sibling alone is exactly how this recurred.
- **Host-visible:** the admin endpoint's list branch changes `state_type` from `null` to the real
  workflow type (`backlog` / `unstarted` / `started` / `completed` / `canceled`) — which is what its
  openapi contract already documented, so the response now matches the spec rather than the spec moving.
  `state_type` stays nullable (a node with no `state` still yields `null`). `exe/linear`'s `list`
  renderer prints `state.name` only, so CLI output is unchanged.

## [2.8.1] — 2026-08-04

**The stale-checkout warning offered bundler a remedy bundler would undo (AGT-222).** Found while
dogfooding v2.8.0 across all four surfaces. A `Gemfile` pinned by tag produces a bundler checkout that
*does* carry the repo's tags — the v2.8.0 assumption that such a copy is tagless held for one bundle
layout and not the other — so a trader-ai pin left a release behind would correctly be reported as
stale, and then told to `cd` into `…/bundler/gems/linear-cli-<sha>` and `git checkout` the new tag.
That directory is bundler's: it re-clones it from `Gemfile.lock`, so the next `bundle install` undoes
the checkout and the lock disagrees with the tree in the meantime. A remedy the managing tool will
clobber is worse than no remedy.

- **A bundler-managed checkout is now told to bump the pin** — "bump the linear_cli tag to vX.Y.Z in
  your Gemfile, then `bundle update linear_cli`" — recognised by bundler's documented install layout
  (`…/bundler/gems/<name>-<shortsha>`). The staleness is still reported, because a lagging pin is
  exactly surface 1's drift; only the fix line changes.
- No change to the other shapes: a detached HEAD is still told to move the pin to the new tag, a branch
  checkout to fast-forward.

## [2.8.0] — 2026-08-04

**A gem tag reaches FOUR checkouts, and a stale one said nothing (AGT-222).** Tagging this gem ships it
nowhere. Four independent checkouts run it — trader-ai's bundle, the shared main checkout, the agent-ops
box at `/opt/linear-cli`, and the plain clone at `~/Developer/linear-cli` — and only two were written
down anywhere. The fourth is the one that matters most and was documented in no repo at all: cerails'
`bin/linear` `exec`s that **working tree** directly, because cerails' app Ruby is 3.2.2 against this
gem's `>= 3.4` floor, so it deliberately does not vendor the gem and has no Gemfile entry, no bundle and
no deploy step. The working tree is production for another team.

Both of its failure modes were silent, and both were measured. **Stale:** while shipping AGT-217 the
clone sat one commit behind `origin/main`, so ORC's `bin/linear` kept returning comments newest-first
*after* v2.6.0 was tagged and every other surface had updated — no version banner, no drift warning,
nothing to notice. **Dirty:** a half-finished edit in that tree is executed live by another team with no
deploy gate in between. Same shape as AKA-193 and AGT-218 (a box four releases and 45 days behind), on
the one surface neither covered.

- **The CLI now says so, on stderr, before it runs the command.** `LinearCli::Checkout` compares the
  checkout `exe/linear` was loaded from against the newest `vX.Y.Z` tag that checkout knows about, and
  reports uncommitted changes under `lib/`/`exe/`. The fix line matches the checkout's shape — a
  detached HEAD is a pinned box, so it is told to move the pin rather than to fast-forward. Advisory
  only: it never blocks the command, and a missing git, an odd checkout or an unparseable version is
  swallowed rather than allowed to take ticketing down.
- **It lives in the gem, so every shim inherits it.** `exe/linear` calls it, not each host's
  `bin/linear` — the shims stay thin. Not on `require "linear_cli"`, so a host app driving
  `Linear::Client` from a web request (trader-ai's admin endpoint) never shells out to git mid-request.
- **Local-only, no network, ~10–20 ms** — one or two `git` invocations against a 200 ms+ API round-trip,
  no credentials, nothing that can hang. It therefore cannot see a tag a checkout has never fetched;
  that is closed from the other end by the release recipe, which fast-forwards the plain clone in the
  same breath as `git push`. A cached `git ls-remote` would close it for a box nobody fetches (AGT-220).
- **Deliberately silent where a warning would be noise, and never misdirecting.** A packaged
  `gem install` has no `.git`, and a checkout with no release tags has nothing to be measured against.
  Bundler's vendored copy carries a permanently modified `linear_cli.gemspec` (bundler rewrites it in
  place), which is why only `lib/`/`exe/` count as dirty — crying wolf on every `bin/linear` in
  trader-ai would train the eye past the one line that matters. When a `Gemfile` pin genuinely is
  behind, the remedy offered is to bump the pin and `bundle update`, never a `git checkout` inside a
  directory bundler re-clones from `Gemfile.lock`. Linked worktrees are exempt from the dirty half,
  since uncommitted work is a dev worktree's normal state.
  `LINEAR_CLI_SKIP_CHECKOUT_CHECK=1` opts out entirely.
- **All four surfaces are now documented in one place** — README, "Releasing — a tag does not ship
  itself", with the propagation command for each. trader-ai's and cerails' own rules point at it.

## [2.7.0] — 2026-08-04

**`list` silently truncated every result at 50 rows (AGT-224).** The query passed no `first:` and never
read `pageInfo`, so Linear applied its default page size and handed back 50 nodes — with no error, no
marker on the response and nothing short to notice. A truncated lane was byte-for-byte indistinguishable
from a lane that is genuinely 50 long, which is why this shipped and stayed unnoticed: the defect was
invisible in the only thing a caller looked at. `linear list --status in_progress` on team AKA reported
**In Progress 28 / In Review 70 as 15 / 35** (measured 2026-08-04) — 48 of 98 issues gone. `orderBy:
createdAt` compounded it: the surviving 50 were the **oldest**, so what fell off the end was the newest,
most actionable work.

It was not a CLI nit. `/board` derives its lane counts, `free_slots` and every invariant check from these
text dumps, so a third of the review backlog was invisible on the one screen meant to show it, and
Invariant 1 (`In Progress` ⇔ a live session) could only check the tickets it could see. The admission-halt
verdict happened to survive — 35 and 70 are both far over a cap of 10 — but that was luck, not
correctness.

- **`list` now pages the connection to exhaustion**, `MAX_PAGE_SIZE` (250) at a time, following
  `pageInfo.endCursor` until `hasNextPage` is false. A blank `endCursor` ends the walk, so a
  `hasNextPage` with nothing to follow cannot re-request page one in a loop.
- **`--label` is filtered by Linear, not in Ruby over a page already discarded.** This was the
  compounding half of the bug and strictly the worse one: `--status backlog --label Bug` did not return
  the Bug-labelled Backlog issues, it returned the Bug-labelled ones *among the oldest 50* — **19 rows
  when the truth was 54**. That count is plausible, and adding a filter is exactly when a caller stops
  expecting a big number, so there was nothing to notice at all. `labels: { name: { eqIgnoreCase: } }`
  matches an issue carrying some label of that name; verified against a multi-labelled issue and against
  the old client-side predicate over a fully-paginated set (identical rows).
- **A ceiling that announces itself.** `Linear::Client::MAX_LIST_PAGES` (40 → 10,000 issues, against
  1,597 in the largest team here) bounds a pathological query. Reaching it prints a `list TRUNCATED …
  INCOMPLETE` warning to **stderr** and returns what it has. Silent truncation is the actual defect; a
  wrong count that announces itself is recoverable, one that doesn't is not.
- **New `limit:` / `--limit N`** — caps the rows *and* stops the walk as soon as it has them, so ten rows
  cost one request asking for ten rather than seven full pages thrown away. It is never a default: an
  omitted `--limit` means everything. Because both filters are now Linear's, a `--limit` row count is
  exact, which post-filtering could not be. A non-numeric or non-positive `--limit` aborts rather than
  coercing to 0 and printing "No issues found." — the same silent wrong answer in miniature.
- **The row format is unchanged, byte for byte.** `.claude/skills/board/collect.py` and the skills parse
  these dumps line-by-line, so this is a completeness fix and nothing else: the first 50 rows of the new
  output diff clean against 2.6.0's entire output, and the 98/314/54 totals were cross-checked against
  raw paginated GraphQL.
- **Thirteen tests pin the request, not just the result** — an explicit `first:`, a followed cursor, the
  ceiling warning, the server-side label filter, and the `limit:` short-circuit. Ten of them fail against
  2.6.0. Asserting only on returned rows is what let a 50-row cap look correct.

## [2.6.0] — 2026-07-30

**`Linear::Client#comments` returned the reverse of what it documented (AGT-217).** The method promised
"oldest-first (the order Linear returns)" and returned **newest-first** — so `.last`, the natural way to
ask *what did the most recent comment say*, handed back the **oldest** comment. Nothing raised and
nothing looked wrong; a caller checking "is my comment the most recent one" just silently read a stale
sibling. It bit the 2.5.0/AGT-216 verification directly: a check asserting the newest comment was the
digest it had just posted read a **36-minute-old** comment and reported the wrong timestamp. Both halves
of the drift were unguarded — no test asserted ordering, which is exactly how the doc and the behaviour
could disagree for two releases unnoticed.

- **`comments` now really is oldest-first** — `.first` is the oldest comment, `.last` is the newest, and
  `linear comments ISSUE-N` / `linear view ISSUE-N` print threads in the order they happened.
- **The direction is sorted client-side, because Linear's API cannot express it.** `PaginationOrderBy`
  offers only `createdAt` / `updatedAt` and no direction — a `PaginationSortOrder` enum exists in the
  schema but is not an argument on the `comments` connection, and both `orderBy` values return
  descending (measured 2026-07-30). The query still passes **`orderBy: createdAt` explicitly** to pin the
  sort *field*, so editing an old comment can't reshuffle the list the way an implicit `updatedAt`
  default would; the sort supplies the direction. It sorts on the timestamp rather than `.reverse`-ing
  the response, so the contract holds whatever order the server returns — relying on that implicit
  default is what let doc and behaviour drift apart in the first place. Ties break on `id`, since Ruby's
  `sort_by` is not stable.
- **The query now asks for a full 250-comment page** (Linear's maximum — 251 is an *Argument Validation
  Error*) instead of letting Linear default to 50. Sorting a truncated **newest-50** window ascending
  would make `.first` silently mean "50th-newest" rather than "oldest" — the same species of
  quietly-wrong answer as the bug being fixed. `Linear::Client::MAX_PAGE_SIZE` is public.
- **Five tests pin the ordering**, all of which fail against the previous behaviour: the fixtures are
  newest-first (the order Linear actually sends) rather than pre-sorted, which is the flaw that let the
  original tests pass while the contract was inverted.
- No caller inverted: the two display paths (`comments`, `view`) read better oldest-first, the
  `comment-edit` / `comment-delete` guard matches by id, and `comment-edit` / `comment-delete` take an
  explicit comment id. No consumer in the host app calls `#comments`.

## [2.5.0] — 2026-07-30

**`edit` now says when a description replace deleted a screenshot (AGT-219).** A ticket's screenshots
live INSIDE its description — `create --image` uploads each one and embeds `![name](assetUrl)` in the
body, because Linear has no separate attachment field the CLI writes to. So the `edit` command added in
2.4.0 could silently delete a bug's only repro image: it replaces the whole body, and the loss showed up
as nothing but a smaller char delta. That quietly defeats the evidence rule the images are there for
(AGT-66 — report, repro and QA screenshots belong ON the ticket, enforced on `create`/`comment` by a
host-side pre-tool hook that correctly does *not* guard `edit`).

- **`edit` prints a stderr warning naming each dropped image** when the new body no longer references an
  image the old one did:

  ```
  AGT-219: description replaced (183 → 42 chars)
    ! dropped 2 embedded image(s) — the replaced description carried screenshots this body does not (AGT-66: evidence belongs on the ticket)
      - https://uploads.linear.app/…
      - https://uploads.linear.app/…
      those asset URLs are still live — re-embed as ![name](url) in the new body, or add fresh evidence with: linear attach AGT-219 PATH
  ```

  The listed URLs are the recovery path: the asset stays hosted after the description stops referencing
  it, so re-embedding needs no re-upload.
- **Warn, don't block — deliberately.** A whole-body replace *is* `edit`'s contract, so the fix makes the
  loss legible rather than impossible. It does not raise, does not prompt, does not re-append the old
  `**Screenshots**` block (magic, and wrong when the caller means to replace everything), and it still
  applies the replace in full — `edit` has to stay non-interactive because a board/status ticket's tick
  calls it unattended.
- **Per-reference diff, not "old had images, new has none".** Dropping 2 of 3 screenshots warns about
  exactly those 2 and stays quiet about the one still embedded — the coarse check misses that case
  entirely and can't honestly report a count.
- `Linear::Client#edit_description` returns the new **`dropped_images:`** key (alongside
  `old_description:` / `issue:`), computed from the body it already fetched — **no extra network call**.
  Detection lives in the client so every host inherits the fact (the CLI *and* the admin HTTP endpoint);
  rendering it to stderr is the CLI's job.
- New public **`Linear::Client.image_refs(markdown)`** → the deduped list of image references in a body:
  every markdown image `![alt](url)` plus any bare `https://uploads.linear.app/…` URL (an uploaded file
  linked rather than embedded — also evidence). Pure string work, so two bodies can be diffed offline.
- Warning goes to **stderr**, so stdout stays parseable; stdout is flushed first so the warning can't
  surface above the `description replaced` line it annotates when the output is piped.
- Tests: 5 CLI cases in `test/cli/edit_desc_test.rb` (warns + names each URL · silent when neither body
  has images · silent when the new body keeps them · partial-loss counts only what was dropped · the
  warning neither blocks the replace nor prompts) driving the **real** `#edit_description` with only its
  two network calls stubbed, plus 5 client cases for the diff and `image_refs` itself.

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
