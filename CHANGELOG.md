# Changelog

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
