# linear_cli

Standalone, project-agnostic **Linear** ticketing. One gem ships **both**:

- **`Linear::Client`** — the single Ruby place all Linear GraphQL + lifecycle conventions live
  (multi-team, dedup search, relations, parent/sub-issue, state transitions, label auto-create,
  rate-limit backoff). Pure `net/http` + `json` — no Rails, no other runtime deps.
- **`linear`** — a thin CLI over that client (`exe/linear`).

It is configured by **environment only**, so any project can drive the *same* tool against the *same*
Linear workspace with zero app coupling.

## Install

Git-source gem, pinned by tag (no private gem server):

```ruby
# Gemfile
gem "linear_cli", git: "git@github.com:hirolabsllc/linear-cli", tag: "v1.0.0"
```

Or install the CLI standalone from a checkout:

```bash
git clone git@github.com:hirolabsllc/linear-cli
cd linear-cli
gem build linear_cli.gemspec && gem install ./linear_cli-1.0.0.gem
# `linear` is now on PATH (wherever RubyGems installs executables)
```

Ruby **3.4.9** is pinned via `.ruby-version` (rbenv auto-selects it in the repo dir).

## Configuration (env only)

| Variable | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | yes | Linear personal API key — get one at <https://linear.app/settings/api> |
| `LINEAR_DEFAULT_TEAM` | no | Default team key for `create` / `list` (e.g. `ENG`). A per-command `--team KEY` always wins. With neither set, `create` / `list` raise a clear error. |

If the `dotenv` gem is available, a `.env` in the working directory is auto-loaded (so it "just
works" inside a project checkout). On servers, export the vars directly.

## CLI usage

```bash
linear search "<keywords>"                       # dedup search (ALL states) — run BEFORE create
linear create "Title" --team ENG --label Bug --priority high --desc "body"
linear start  ENG-12 --session "my session"      # → In Progress
linear review ENG-12 --sha <sha>                 # → In Review (+ clickable commit link)
linear close  ENG-12 --comment "verified"        # → Done
linear view   ENG-12                             # parent / sub-issues / relations + comment ids
linear list   --status in_progress --team ENG     # EVERY match, paginated; --limit N caps it

linear edit   ENG-12 --desc-file board.md        # REPLACE the description in place (posts no comment)
linear edit   ENG-12 --title "ENG-12 (Bug): …" --desc-file board.md   # …and/or the title, in one call
linear retitle ENG-12 "ENG-12 (Bug): …"          # title only (alias: rename)

linear comment        ENG-12 "QA passed"         # or: --body-file notes.md / --body-file - (STDIN)
linear comments       ENG-12                      # WHOLE thread oldest-first, paginated; comment ids
linear comment-edit   ENG-12 <comment-id> "fix"   # or: --body-file notes.md / -
linear comment-delete ENG-12 <comment-id>         # remove a stray/mistaken comment
```

**`list` returns every match, not one page.** Linear's `issues` connection caps a query that omits
`first:` at **50 nodes** silently — no error, no marker — so `list` used to report a 98-issue lane as 50
and a truncated lane was indistinguishable from a short one. It now pages the connection to exhaustion,
and `--label` is filtered by Linear rather than applied to a page already thrown away (which is why
`--status backlog --label Bug` answered 19 when the truth was 54). Pass `--limit N` when you only want
the oldest N and would rather not page a whole team for them; without it you get everything. If the
10,000-issue safety ceiling is ever reached, `list` says so on **stderr** and labels the rows
`INCOMPLETE` — a short list is never returned in silence.

**`comments` and `view` return the whole thread, oldest-first.** The same cap bit comments one page
further out: the query asked for 250 and stopped there, and because Linear serves comments
**newest-first**, what fell off past 250 were the **oldest** ones — so `.first` quietly meant
"250th-newest". That is five days of a ticket commented on every half hour, not a hypothetical.
`comments` now pages to exhaustion behind the same ceiling and the same `INCOMPLETE` stderr warning as
`list`.

**`edit` vs `comment`** — an issue's *description* is **now** (the current state, rewritten in place);
its *comments* are **how it got here**. `edit` replaces the whole description and never posts a
comment, so a board/status ticket can keep its body current instead of burying the state in the newest
comment. It takes flags only (no positional body — a whole-body replace is destructive, so it must be
explicit) and refuses an empty body rather than blanking the ticket. Note that Linear canonicalizes
description markdown server-side (`|---|` → `| -- |`, `-` bullets → `*`), so don't verify a write by
byte-comparing what you sent; the content itself is preserved verbatim.

**`edit` warns when a replace drops a screenshot.** `create --image` embeds each uploaded screenshot in
the *description* (there is no separate attachment field), so replacing the whole body can delete a
ticket's only repro image. When the new body no longer references an image the old one did, `edit` prints
`! dropped N embedded image(s)` to **stderr** and lists the asset URLs — which are still live, so you can
re-embed one as `![name](url)` without re-uploading, or add fresh evidence with `linear attach`. It warns
rather than blocks: a whole-body replace is the command's contract, and `edit` stays non-interactive.

Multi-line markdown with backticks/`$`/`\` breaks under bash command substitution when passed as a
double-quoted arg, so `create` / `edit` accept `--desc-file PATH` and `comment` / `comment-edit` accept
`--body-file PATH` to read the body from a file. For a **rich body without a temp file**, use
`--body-file -` to read STDIN from a **single-quoted heredoc**, which suppresses all shell expansion so
backticks / `$` / `\` reach Linear verbatim:

```sh
linear comment ENG-12 --body-file - <<'MD'
## Heading — inline `code`, $VARS and C:\paths all survive
MD
```

A positional body that itself starts with `--` (e.g. a `---` horizontal rule) can be passed after a
POSIX `--` end-of-options separator: `linear comment ENG-12 -- "--- then the body"`. Unknown flags are
still rejected (a typo like `comment ENG-12 --show` errors instead of posting junk).

Every command except `create` / `list` takes an issue id (e.g. `ENG-12`) and resolves its team
automatically — no `--team` needed. Run `linear` with no args for the full command list.

## Library usage

```ruby
require "linear_cli"

client = Linear::Client.new(team_key: "ENG")       # or Linear::Client.new to use LINEAR_DEFAULT_TEAM
result = client.create(title: "Fix X", label: "Bug", priority: "high")
client.transition(result[:issue]["identifier"], :in_progress, comment: "picked up")
```

## Development

```bash
bundle install
bundle exec rake test     # Minitest, no network (GraphQL transport is stubbed)
```

CI runs the same on Ruby 3.4.9 (`.github/workflows/ci.yml`).

**Never edit `~/Developer/linear-cli` in place** — work in a `git worktree`. Three to six concurrent
Claude sessions share that clone, *and* another team executes its working tree live (surface 4 below),
so an uncommitted edit there is not a work in progress: it is a deploy.

```bash
git -C ~/Developer/linear-cli fetch origin main
git -C ~/Developer/linear-cli worktree add -b <topic> /tmp/linear-cli-<topic> origin/main
```

## Releasing — a tag does not ship itself

`git tag` publishes nothing. **Four independent checkouts run this gem**, each with its own staleness,
and a release is not done until all four have moved (AGT-222):

| # | Surface | Runs it | How it updates |
|---|---|---|---|
| 1 | trader-ai's bundle | team AKA + the app's admin endpoint | `Gemfile` tag → `bundle update linear_cli` → commit + push → Hatchbox deploy |
| 2 | the shared trader-ai main checkout | concurrent Claude sessions | `bin/refresh-shared-checkout` |
| 3 | `/opt/linear-cli` on `ops.hirolabs.com` | Hermes agents, via `/opt/agent-ops/bin/linear` | SSH as `root`, run git as `claude` so ownership survives (AGT-218) |
| 4 | `~/Developer/linear-cli` — the plain clone | **team ORC**: cerails' `bin/linear` execs this **working tree** | `git merge --ff-only origin/main` |

**Surface 4 has no Gemfile, no bundle and no deploy step.** cerails' app Ruby is 3.2.2, below this gem's
`>= 3.4` floor, so it deliberately does not vendor the gem and instead runs
`$HOME/Developer/linear-cli/exe/linear` directly under rbenv 3.4.9 (override with `LINEAR_CLI_DIR`).
The working tree *is* production for another team: **stale means ORC runs old code, dirty means ORC runs
your half-finished edit** — and neither used to say so. AGT-217 measured exactly that, with the clone one
commit behind `origin/main` still returning comments newest-first after the fix was tagged and every
other surface had moved.

```bash
bundle exec rake test                                       # green first
$EDITOR lib/linear_cli/version.rb CHANGELOG.md              # bump + describe
git commit -am "<summary> (TEAM-N)"
git tag vX.Y.Z && git push origin main vX.Y.Z

# 4 — do this in the same breath as the push; it is the surface with no deploy gate
git -C ~/Developer/linear-cli fetch --tags origin
git -C ~/Developer/linear-cli merge --ff-only origin/main

# 3 — the box fetches over https (public repo, no credential); run the git as `claude`
ssh root@ops.hirolabs.com \
  'sudo -u claude git -C /opt/linear-cli fetch --tags --prune origin &&
   sudo -u claude git -C /opt/linear-cli checkout --detach vX.Y.Z'

# 1 + 2 — in trader-ai: bump the Gemfile tag, bundle update linear_cli, push, then
bin/refresh-shared-checkout
```

### Staleness announces itself

Since v2.8.0 the CLI checks the checkout it was loaded from and prints to **stderr** — before running
the command, never blocking it — when that checkout is **behind the newest tag it knows about** or has
**uncommitted changes under `lib/` or `exe/`**:

```
  ! linear_cli 2.7.0 is behind v2.8.0 — this checkout is serving old code (AGT-222)
    fix: cd /Users/you/Developer/linear-cli && git fetch origin main && git merge --ff-only origin/main
```

It lives in the gem (`LinearCli::Checkout`, called from `exe/linear`), not in each host's `bin/linear`,
so every shim inherits it — the shims stay thin. The fix line matches the checkout's shape: a detached
HEAD is a pinned box, so it is told to move the pin to the new tag.

The check is **local-only and never touches the network**: one or two `git` invocations (~10–20 ms
against a 200 ms+ API round-trip), no credentials, nothing that can hang. Consequences of that choice:

- It **cannot see a tag the checkout has never fetched.** For surface 4 that is a non-issue — a release
  tagged from a worktree shares the clone's ref store, so the tag exists there the instant it is cut —
  and for surface 3 the update recipe opens with `fetch --tags`. Closing it for a box nobody ever
  fetches needs a cached `git ls-remote`; see AGT-220.
- On **surfaces 1 and 2** it never cries wolf and never misdirects. Bundler's vendored checkout carries
  a permanently modified `linear_cli.gemspec` — bundler rewrites it in place — which is why only `lib/`
  and `exe/` count as dirty. And when the `Gemfile` pin genuinely *is* behind, the fix offered is to
  bump the pin and `bundle update`, never a `git checkout` inside a directory bundler re-clones from
  `Gemfile.lock` (which the next `bundle install` would undo, desyncing the lock).
- Only **linked worktrees** are exempt from the dirty half — uncommitted work is a dev worktree's normal
  state, whereas in the main clone it is live for every caller.

Silence it with `LINEAR_CLI_SKIP_CHECKOUT_CHECK=1` (a box held back on purpose, or a caller that parses
stderr).

## License

MIT — see [LICENSE](LICENSE).
