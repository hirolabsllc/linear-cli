---
name: linear-issues
description: Read and write Linear issues with the `linear` CLI. Use when asked to search Linear, read a Linear issue, create or update a ticket, move its status, or comment on it. The agent-ops team is AGT (the default); pass --team for another team (AKA = trader-ai app, ORC = orcaru).
---

# Linear Issues

Work Linear tickets directly with the **`linear`** CLI (the shared `hgl_linear` tool installed on this
box). It already knows this workspace's teams, workflow states, and conventions — you never resolve
team-ids or state-ids by hand, and there is no API key to manage (the CLI reads it from box config).

The default team is **AGT** (agent-ops). For another team, add `--team KEY` to `create`/`list`
(e.g. `--team AKA` for the trader-ai app, `--team ORC` for orcaru). Every other command takes an issue
id (`AGT-123`, `AKA-45`, …) and resolves its team automatically.

## Golden rule: search before you create

Always `linear search "<keywords>"` first — it returns relevance-ranked matches across ALL states
(including Done/Canceled, flagged ⟲). On a true match, reopen / comment / relate instead of filing a
duplicate. Only create when nothing matches.

## Commands

```bash
# Search (dedup) — run BEFORE create
linear search "profit lock ratio"

# Read one issue (parent / sub-issues / relations / description)
linear view AGT-123

# Create (defaults to team AGT). Labels auto-create. Link deps at create time.
linear create "Build the thing" --label Bug --priority high --desc "what + why"
linear create "Cross-team note" --team AKA --label Feature      # file under another team

# Comment
linear comment AGT-123 "Working on this now — first pass pushed."

# Lifecycle transitions (by name — no state-ids needed)
linear start  AGT-123 --session "what I'm doing"   # → In Progress
linear review AGT-123 --sha <git-sha>              # → In Review (+ clickable commit link)
linear close  AGT-123 --comment "verified"         # → Done
linear cancel AGT-123 --comment "duplicate of AGT-9"

# Relations / hierarchy
linear relate AGT-1 AGT-2 --type duplicate         # related|blocks|blocked-by|duplicate|similar
linear parent AGT-2 AGT-1                           # make AGT-2 a sub-issue of epic AGT-1

# Labels / list
linear label AGT-123 Ops
linear list --status in_progress                   # team AGT by default; add --team KEY
```

Run `linear` with no arguments for the full command list.

## Workflow

1. **Search first** to avoid duplicates.
2. **Create** under AGT (the default) unless the user clearly means another team — then `--team KEY`.
3. Use `start` / `review` / `close` / `cancel` to move status (named transitions; no ids).
4. After any change, **report the returned identifier and URL** back to the user.
5. If `linear` prints an error, **surface the exact message** — don't guess flags or silently retry a
   different command. A missing key prints a clear `LINEAR_API_KEY not set` hint.

## Notes

- `linear` runs the standalone `hgl_linear` gem (rbenv Ruby 3.4.9) and reads `LINEAR_API_KEY` +
  `LINEAR_DEFAULT_TEAM` from box config — there is **no** dependency on the trader-ai app or its `.env`,
  and **no** Python `linear_api.py` anymore. If you find references to `linear_api.py` or `--team-key`/
  `--state-id` in old notes, ignore them and use the `linear` commands above.
