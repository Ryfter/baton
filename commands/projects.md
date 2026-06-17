---
description: Sync Triage classification to GitHub — labels (classify) + Project v2 fields (decide). Dry-run by default.
argument-hint: "[init|sync] --owner @me --project N [--apply] [--reclassify] [--classify] [--json]"
---

# /baton:projects

Pulls open issues, classifies the untriaged ones through the Triage Agent, and writes
the result back as **labels** (`type:`/`area:`/`risk:`/`estimate:`/`route:`) and
**Project v2 fields** (`Priority`, `Status`). Dry-run by default — nothing is written
until you re-run with `--apply`. All GitHub operations go through `gh`.

## Steps

1. Run the runner with the user's arguments:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-projects.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `init --owner @me --title "Baton Board"` — one-time: create the Project + ensure the Priority field.
   - `sync --owner @me --project 7` — dry-run: print the planned label/field writes and the would-be classifier per untriaged issue (zero token spend).
   - `sync --owner @me --project 7 --apply` — classify untriaged issues (governed routing) and write labels + fields.
   - `--reclassify` re-runs triage on already-typed issues; `--classify` classifies during dry-run; `--json` emits the raw plan.

3. Summarize the plan/results in plain language: which issues got which labels/fields,
   which were skipped (already correct), and which worker classified them.
