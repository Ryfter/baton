---
description: Conductor needs-you queue — present admitted choices one project at a time; Kevin answers via option id or free text.
argument-hint: "[brief|next|answer|list|draft|admit|reject] [...]"
---

# /baton:choices

Factory-level queue for blocking product decisions. Orchestrators draft cards;
Conductors admit them; Kevin sees only admitted cards, one project at a time.
Every card lives as `$BATON_HOME/choices/ch-<id>.json` — no parallel markdown
queues.

## Mouth flow (Kevin-facing)

When presenting overnight or multi-project decisions:

1. Run **`brief`** — builds the per-project writeup, refreshes project order,
   and resets the cursor to the first admitted card.

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-choices.ps1" brief
   ```

2. Run **`next`** — show the current admitted card (id, question, options,
   recommendation, evidence).

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-choices.ps1" next
   ```

3. When Kevin replies, map his pick to **`answer <id> <option_id>`** (or
   `--text "..."` for free-form). Always cite the `ch-` id from the card.

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-choices.ps1" answer ch-abc123 opt-b
   # or: ... answer ch-abc123 --text "ship option B with a follow-up PR"
   ```

4. After each answer, run **`next`** again until the current project has no
   admitted cards, then advance to the next project in order.

## Other subcommands

- **`list [--project <slug>] [--status admitted]`** — inspect the queue.
- **`draft ...`** — Orchestrator creates a `draft` card (not Kevin-visible).
- **`admit <id> [--priority P0]`** — Conductor promotes draft → admitted.
- **`reject <id>`** — Conductor clears a card without Kevin's answer.

Add `--json` to any subcommand for machine-readable output.

## Rules

- No card in chat without a `ch-` id.
- Kevin's answer must go through `answer` — never hand-edit status in the file.
- Stay on one project until its admitted queue is clear before moving on.
