# hgl_linear

Standalone, project-agnostic **Linear** ticketing for Hiro Labs. One gem ships **both**:

- **`Linear::Client`** — the single Ruby place all Linear GraphQL + lifecycle conventions live
  (multi-team, dedup search, relations, parent/sub-issue, state transitions, label auto-create,
  rate-limit backoff). Pure `net/http` + `json` — no Rails, no other runtime deps.
- **`linear`** — a thin CLI over that client (`exe/linear`).

It is configured by **environment only**, so every project — the trader-ai app, the agent-ops Hermes
bot, Orcaru — drives the *same* tool against the *same* Linear workspace with zero app coupling.

## Why this exists

The implementation was extracted from the trader-ai app (`lib/linear/client.rb` + `bin/linear`) so
agent-ops is no longer coupled to that app to file/track Linear issues. trader-ai now consumes this
gem; the Hermes bot and Orcaru install the `linear` CLI directly. (Epic AGT-43.)

## Install

Git-source gem, pinned by tag (no private gem server):

```ruby
# Gemfile
gem "hgl_linear", git: "git@github.com:hirolabsllc/linear-cli", tag: "v1.0.0"
```

Or install the CLI standalone from a checkout:

```bash
git clone git@github.com:hirolabsllc/linear-cli
cd linear-cli
gem build hgl_linear.gemspec && gem install ./hgl_linear-1.0.0.gem
# `linear` is now on PATH (wherever RubyGems installs executables)
```

Ruby **3.4.9** is pinned via `.ruby-version` (rbenv auto-selects it in the repo dir).

## Configuration (env only)

| Variable | Required | Purpose |
|---|---|---|
| `LINEAR_API_KEY` | yes | Linear personal API key — get one at <https://linear.app/settings/api> |
| `LINEAR_DEFAULT_TEAM` | no | Default team key for `create` / `list` (e.g. `AGT`, `ORC`, `AKA`). A per-command `--team KEY` always wins. |

If the `dotenv` gem is available, a `.env` in the working directory is auto-loaded (so it "just
works" inside a project checkout). On servers / the agent-ops box, export the vars directly.

## CLI usage

```bash
linear search "<keywords>"                       # dedup search (ALL states) — run BEFORE create
linear create "Title" --team AGT --label Bug --priority high --desc "body"
linear start  AGT-12 --session "my session"      # → In Progress
linear review AGT-12 --sha <sha>                 # → In Review (+ clickable commit link)
linear close  AGT-12 --comment "verified"        # → Done
linear view   AGT-12                             # parent / sub-issues / relations
linear list   --status in_progress --team AGT
```

Every command except `create` / `list` takes an issue id (`AKA-N`, `AGT-N`, …) and resolves its team
automatically — no `--team` needed. Run `linear` with no args for the full command list.

## Library usage

```ruby
require "hgl_linear"

client = Linear::Client.new(team_key: "AGT")       # or Linear::Client.new for the default
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
