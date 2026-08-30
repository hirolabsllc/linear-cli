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
| `LINEAR_CLI_DEPLOY_REPOS` | no | Which repos `review` may describe as deploying: `owner/name[=Platform]`, comma-separated (e.g. `octocat/hello-world=Kamal`). **No default** — unset or empty means nothing deploys, and `review` emits no deploy clause. Per-call, `--deploy` / `--no-deploy` override it. |

If the `dotenv` gem is available, a `.env` in the working directory is auto-loaded (so it "just
works" inside a project checkout). On servers, export the vars directly.

## CLI usage

```bash
linear search "<keywords>"                       # dedup search (ALL states) — run BEFORE create
linear create "Title" --team ENG --label Bug --priority high --desc "body"
linear start  ENG-12 --session "my session"      # → In Progress
linear review ENG-12 --sha <sha>                 # → In Review (+ commit link, if it can be proven)
linear review ENG-12 --sha <sha> --repo owner/name   # …when the commit lives in ANOTHER repo
linear close  ENG-12 --comment "verified"        # → Done
linear close  ENG-12 --comment-file -            # …closing writeup from STDIN (heredoc-safe)
linear cancel ENG-12 --comment-file notes.md     # cancel/reopen take the same pair
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

**`review` and `commit` claim only what git can show.** Both used to build the commit link from the
cwd's `origin` whether or not the SHA was in that repo, and `review` ended every comment with a
hardcoded `Merged to main: … — deploy in progress`. Since `bin/linear` reaches most callers
as a shim inside one app, a session shipping another repo's ticket stood in that app's checkout and
got all three claims wrong at once — measured five times, on tickets whose work was an open PR in a
repo with no deploy pipeline (AGT-212). Now:

| Clause | Emitted when |
|---|---|
| the commit **link** | the ref resolves to a commit **in this checkout** (so this checkout's `origin` is its repo), or `--repo owner/name` names it. Otherwise the SHA goes out **bare** with a stderr line saying why — a 404 on a permanent audit trail is worse than no link. |
| **"Merged to main"** | the SHA is an ancestor of origin's default branch. An open PR reads `Pushed for review (not on main yet)`, an unpushed commit `Commit under review (not pushed)`, an unknown SHA `Commit under review`. Override with `--merged` / `--not-merged`. |
| **"… deploy in progress"** | the resolved repo is in `$LINEAR_CLI_DEPLOY_REPOS` **and** the commit is on main — a deploy follows a merge, not a ticket moving to In Review. Override with `--deploy` / `--no-deploy`. |

Remote-tracking refs can be stale, which only ever makes the merge claim *under*-shoot; that is the
safe direction for the sentence a reader uses to decide whether work shipped. `commit` follows the
same repo rule and also takes `--repo`; it asserts nothing about merging or deploying.

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

**Never edit your main clone in place** — work in a `git worktree`. Several concurrent agent sessions
may share one clone, and a caller can be `exec`ing its working tree live (see *Releasing* below), so an
uncommitted edit there is not a work in progress: it is a deploy.

```bash
git -C <clone> fetch origin main
git -C <clone> worktree add -b <topic> /tmp/linear-cli-<topic> origin/main
```

## Releasing — a tag does not ship itself

`git tag` publishes nothing. Each checkout that runs this gem carries its own staleness, and a release
is not done until every one of them has moved (AGT-222). In practice the gem gets consumed in four
different shapes, and only two of them have anything that would catch a missed update:

| Shape | How it updates | Fails loudly? |
|---|---|---|
| **a bundled pin** — the gem pinned by tag in an app's `Gemfile` | bump the tag → `bundle update linear_cli` → commit + push → whatever deploys that app | yes — the lock and the deploy |
| **a shared clone** — one checkout several people or concurrent agent sessions run from | `git fetch origin main && git merge --ff-only origin/main` | no |
| **a pinned checkout** — a detached `HEAD` held at a tag on a server | `git fetch --tags --prune origin && git checkout --detach vX.Y.Z` | yes — the pin is explicit |
| **a raw working-tree `exec`** — a `bin/linear` shim that runs `exe/linear` straight out of a clone | `git fetch --tags origin && git merge --ff-only origin/main` | **no** |

**The last shape is the one that bites, because it has no Gemfile, no bundle and no deploy step.** An
app whose own Ruby is below this gem's `>= 3.4` floor cannot vendor the gem at all, so instead of
depending on it, it shims out to a clone and runs `exe/linear` there under its own Ruby (point
`LINEAR_CLI_DIR` at that clone to move it). That makes the clone's **working tree** production for
whoever shims into it: **stale means they run old code, dirty means they run your half-finished edit**
— with no PR, no lockfile and no deploy log anywhere to say so. AGT-217 measured exactly that, with a
clone one commit behind `origin/main` still returning comments newest-first long after the fix was
tagged and every other consumer had moved.

```bash
bundle exec rake test                                       # green first
$EDITOR lib/linear_cli/version.rb CHANGELOG.md              # bump + describe
git commit -am "<summary> (TEAM-N)"
git tag vX.Y.Z && git push origin main vX.Y.Z

# then move every consumer. Do the raw-`exec` clones in the same breath as the push:
# they are the ones with no deploy gate to catch the omission later.
git -C <clone> fetch --tags origin
git -C <clone> merge --ff-only origin/main
```

Keep the list of *your* consumers — the actual paths, hosts and owners — with your deployment
config, not here. What belongs in this README is the shape of the problem, and the fact that the
CLI now reports its own staleness so a forgotten checkout says so out loud.

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

- It **cannot see a tag the checkout has never fetched.** For a clone a release was tagged from, that
  is a non-issue — a worktree shares the clone's ref store, so the tag exists there the instant it is
  cut — and a pinned checkout's update recipe opens with `fetch --tags` anyway. Closing it for a box
  nobody ever fetches needs a cached `git ls-remote`; see AGT-220.
- **Under bundler** it never cries wolf and never misdirects. Bundler's vendored checkout carries a
  permanently modified `linear_cli.gemspec` — bundler rewrites it in place — which is why only `lib/`
  and `exe/` count as dirty. And when the `Gemfile` pin genuinely *is* behind, the fix offered is to
  bump the pin and `bundle update`, never a `git checkout` inside a directory bundler re-clones from
  `Gemfile.lock` (which the next `bundle install` would undo, desyncing the lock).
- Only **linked worktrees** are exempt from the dirty half — uncommitted work is a dev worktree's normal
  state, whereas in a shared clone it is live for every caller.

Silence it with `LINEAR_CLI_SKIP_CHECKOUT_CHECK=1` (a box held back on purpose, or a caller that parses
stderr).

## License

MIT — see [LICENSE](LICENSE).
