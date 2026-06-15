# Changelog

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
