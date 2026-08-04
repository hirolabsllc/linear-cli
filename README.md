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

linear comment        ENG-12 "QA passed"         # or: --body-file notes.md / --body-file - (STDIN)
linear comments       ENG-12                      # list comment ids
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

## License

MIT — see [LICENSE](LICENSE).
