# Agent handoffs — shared core + what's intentionally model-specific

This project is worked by multiple AI agents. To stay consistent **and** let each
model play to its strengths, the rules split into a **shared core** (identical for
every agent, documented here once) and **model-specific** notes (in each model's
own instruction file). This doc is the source of truth and the anti-drift registry.

## Which file each tool reads
| Tool / model | Instruction file it auto-loads |
|---|---|
| Claude Code (Claude) | `CLAUDE.md` |
| Codex / ChatGPT (codex CLI) | `AGENTS.md` |
| Gemini / Antigravity (`agy`) | `GEMINI.md` |
| GitHub Copilot | `.github/copilot-instructions.md` (add when adopted) |
| Grok / others / future tools | their own convention — mirror the shared core below |

Every agent should also read `docs/next-session.md` (the operating loop) and
`docs/roadmap.md` (status), and use the shared knowledge base (`Ryfter/knowledge`).

## Shared core — identical expectations for EVERY agent
1. **Orient first:** read `docs/next-session.md` + `docs/roadmap.md`.
2. **Decision capture:** when you make a significant architectural/scope/approach
   decision, record it via the file-based intake (canonical rule in `CLAUDE.md`).
   Records live in the `Ryfter/knowledge` repo (`projects/<id>/decisions/`).
3. **965-byte shell-argument ceiling:** never pass a long string (commit message,
   prompt, file body) as one shell argument — write it to a file and read it.
   Prefer small, separate commands over long `&&` chains.
4. **Shipping:** per-item branch → hard merge gate (`scripts/fleet-orchestrate.ps1`)
   → master. Keep master green. Gated merges auto-append `Closes #N`.
5. **Backup standing order:** push everything to GitHub (private) so a new PC can
   roll — including the `Ryfter/knowledge` base. Don't ask; just do it.
6. **Knowledge is model-agnostic** (`Ryfter/knowledge`): keep `universal/` +
   `projects/` tool-neutral; isolate tool config under `config/` (decision d014).
7. **Task-group closeout & compaction:** at the end of any task group (a finished
   plan / sprint / milestone) — or proactively whenever context grows long — FIRST
   save everything (every significant decision recorded with reasons + alternatives,
   code committed, pushed to GitHub, memory + these handoff docs updated), state the
   checklist explicitly, THEN prompt the human to compact the conversation. Save
   before compacting, always. Canonical copy: `~/.claude/rules/task-group-closeout.md`.

Shared rules live HERE. Model files should **reference** this section, not re-copy
it — re-copying is how drift starts.

## Model-specific registry (what each file adds, and why)
- **`CLAUDE.md` — Claude = orchestrator / conductor.** Full superpowers + skills;
  drives the fleet concurrently and synthesizes; consults Codex when stuck. Canonical
  home of the decision-capture rule.
- **`AGENTS.md` — Codex = primary autonomous implementer.** Agentic file-editing
  CLI; implements items end-to-end through the gated flow (decision d009).
- **`GEMINI.md` — Gemini/`agy` = design & interface reviewer** (decisions d009/d010).
  Plus `agy` CLI quirks: `agy --print "<prompt>"` needs the prompt as the argument
  (≤965 bytes; it rejects stdin); pass `--add-dir <dir>` for context and
  `--dangerously-skip-permissions` to let it edit — large inline prompts hang.

## Drift policy
- Change a **shared** rule → change it **here** only; the model files don't repeat
  it, so they can't drift.
- Add a **model-specific** item → put it in that model's file **and** list it in the
  registry above, so every divergence is intentional and visible.
