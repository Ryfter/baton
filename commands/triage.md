---
description: Triage an issue or task into a structured classification (type, priority, estimate, risk, recommended pipeline + model) by routing through the fleet. Haiku preferred; escalates to Sonnet on low confidence / high risk.
argument-hint: "[--url <github-issue-url>] [--file <path>] [--json] [<text>]"
---

# /baton:triage

Classify a task. Routes through `Select-Capability -Capability triage` (Haiku
preferred via the fleet's usage_class path) and escalates to Sonnet when the
first pass is low-confidence, high-risk, or ambiguous. Recommend-only: it
classifies and recommends a pipeline/worker; it does NOT dispatch the work.

## Steps

1. **Parse `$ARGUMENTS`.** Recognize `--url <github-issue-url>`, `--file <path>`,
   `--json`, and otherwise treat the remaining text as the inline task. Exactly
   one input source; if none or more than one, print usage and stop.

2. **Dispatch** (map `--url U` to `-Url U`, `--file F` to `-File F`, inline text
   to `-Text`, `--json` to `-Json`):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-triage.ps1" <MAPPED-ARGS>
   ```

   - default: echo the YAML triage block verbatim.
   - `--json`: emit the triage JSON.

3. **Summarize for the user** in 2-4 plain-language bullets: the type + priority,
   the recommended worker/pipeline, the confidence (and whether it escalated to
   Sonnet), and the next action. Do not act on the recommendation — Kevin decides
   whether to start the work.
