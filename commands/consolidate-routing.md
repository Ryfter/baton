---
description: Review recent model-routing journal entries, propose updates to the catalog (`knowledge/universal/routing.md`), and on approval archive the consolidated entries. Run periodically (weekly to monthly) or when you suspect routing defaults need tuning.
argument-hint: (no arguments)
---

# /baton:consolidate-routing

You are running the routing consolidation flow. Your job is to:

1. Read recent observations.
2. Detect patterns (model X failed N times on Y, model Z costs $W on average).
3. Propose specific catalog edits.
4. Get user approval.
5. Apply the edits, archive the consolidated entries.

## Steps

### 1. Read the inputs

- Read `~/.claude/model-routing-log.md` (the journal).
- Find the most recent archive marker line (a line of the form
  `<!-- archived through: YYYY-MM-DDTHH:MM:SS -->`). Entries below it are
  "since-last-consolidation." If no marker exists, treat all entries as new.
- Read `~/.claude/knowledge/universal/routing.md` (the catalog — migrated from `~/.claude/model-routing.md` in Plan 3). If the new path is missing, fall back to the legacy path and surface a warning.
- Read `~/.claude-octopus/results/` (if it exists) — list the most recent run
  directories to cross-reference patterns.

### 2. Analyze

Group journal entries by model. For each model with ≥3 entries since last
consolidation, compute:

- **Success rate** (hook lines: exit:0 vs non-zero).
- **Avg cost** (otel lines: $ amount).
- **Avg elapsed time** (hook lines: Ns).
- **Qualitative tone** (note lines: any words like "nailed", "bailed", "ugly",
  "matched style" — pull verbatim).

Identify:

- Models with notable success or failure patterns (e.g. devstral:24b failed
  4/5 multi-file refactors).
- Models with cost surprises (e.g. claude-opus averaged $0.42/run, 5× others).
- Models with consistent qualitative praise or complaint.

### 3. Propose catalog updates

Present a numbered list of proposed edits to `~/.claude/knowledge/universal/routing.md`.
Each proposal must be specific:

> 1. In `## Routing heuristics`, change "Single-file refactor in a known
>    language: `local-coder` lane (devstral or qwen3-coder-30b)" to
>    "...prefer qwen3-coder-30b; devstral failed 4 of 5 refactors in May
>    (see archive)."

### 4. Get user approval

For each proposed edit, ask: keep, modify, or skip. Apply approved edits using
the Edit tool.

### 5. Archive

After edits are applied, append an archive marker to the journal:

```
<!-- archived through: <ISO-timestamp-of-newest-consolidated-entry> -->
```

Then move all entries above the new marker (since the previous marker) to
`~/.claude/model-routing-log-archive-YYYY-MM.md`, appending if the archive
file exists.

### 6. Summarize

Report to the user: how many entries consolidated, how many catalog edits
applied, where the archive landed.

## Arguments

(none)
