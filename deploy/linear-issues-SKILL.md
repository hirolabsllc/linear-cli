---
name: linear-issues
category: productivity
description: Read and write Linear issues with the `linear` CLI. Use when asked to search Linear, read a Linear issue, create or update a ticket, move its status, or comment on it. Defaults to $LINEAR_DEFAULT_TEAM; pass --team KEY to target another team.
---

<!-- Install onto an agent profile with: <agent> -p <profile> skills install <raw-url> --name linear-issues --category productivity -y
     The `category: productivity` placement matters — the agent discovers ticketing skills by listing that category (skills_list "productivity"). -->


# Linear Issues

Work Linear tickets directly with the **`linear`** CLI (the standalone `linear_cli` tool installed on
this box). It already knows this workspace's teams, workflow states, and conventions — you never
resolve team-ids or state-ids by hand, and there is no API key to manage (the CLI reads it from the
environment).

The default team for `create` / `list` is **`$LINEAR_DEFAULT_TEAM`**. To target another team, add
`--team KEY` (e.g. `--team ENG`). Every other command takes an issue id (e.g. `ENG-123`) and resolves
its team automatically.

## Golden rule: search before you create

Always `linear search "<keywords>"` first — it returns relevance-ranked matches across ALL states
(including Done/Canceled, flagged ⟲). On a true match, reopen / comment / relate instead of filing a
duplicate. Only create when nothing matches.

## Commands

```bash
# Search (dedup) — run BEFORE create
linear search "profit lock ratio"

# Read one issue (parent / sub-issues / relations / description)
linear view ENG-123

# Create (defaults to $LINEAR_DEFAULT_TEAM). Labels auto-create. Link deps at create time.
linear create "Build the thing" --label Bug --priority high --desc "what + why"
linear create "Cross-team note" --team OPS --label Feature      # file under another team

# Comment
linear comment ENG-123 "Working on this now — first pass pushed."

# Lifecycle transitions (by name — no state-ids needed)
linear start  ENG-123 --session "what I'm doing"   # → In Progress
linear review ENG-123 --sha <git-sha>              # → In Review (+ clickable commit link)
linear close  ENG-123 --comment "verified"         # → Done
linear cancel ENG-123 --comment "duplicate of ENG-9"

# Relations / hierarchy
linear relate ENG-1 ENG-2 --type duplicate         # related|blocks|blocked-by|duplicate|similar
linear parent ENG-2 ENG-1                           # make ENG-2 a sub-issue of epic ENG-1

# Labels / list
linear label ENG-123 Ops
linear list --status in_progress                   # $LINEAR_DEFAULT_TEAM by default; add --team KEY
```

Run `linear` with no arguments for the full command list.

## Workflow

1. **Search first** to avoid duplicates.
2. **Create** under the default team unless the user clearly means another team — then `--team KEY`.
3. Use `start` / `review` / `close` / `cancel` to move status (named transitions; no ids).
4. After any change, **report the returned identifier and URL** back to the user.
5. If `linear` prints an error, **surface the exact message** — don't guess flags or silently retry a
   different command. A missing key prints a clear `LINEAR_API_KEY not set` hint.

## Notes

- `linear` runs the standalone `linear_cli` gem and reads `LINEAR_API_KEY` + `LINEAR_DEFAULT_TEAM`
  from the environment (or a `.env` in the working directory when `dotenv` is available).
