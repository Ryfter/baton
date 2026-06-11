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

## Grimdex knowledge base — go-public engine/data split (2026-06-10, decision d037)

The knowledge base (historically `Ryfter/knowledge`, since renamed `Ryfter/Grimdex`) is being
prepared for open-source release as an **engine/data split** — this is cross-cutting context
for EVERY agent touching it:

- **Public `Ryfter/Grimdex` = the ENGINE** (tool/framework): `scripts/` (setup, wire, sweep,
  schedule, console libs + tests), `setup.ps1`, the `GRIMDEX.md` convention, `docs/`,
  `.github/`, tool-wiring files, + an empty `universal/` skeleton + a few curated exemplar
  records. MIT. (`config/` is **DATA**, not engine — it holds Kevin's tool-config backups
  with local paths; the public repo ships `config/` as an empty template. Per the Task 1 audit.)
- **Private `Ryfter/grimdex-know` = the DATA** (accumulated knowledge): `universal/` content +
  ALL `projects/` tiers + `config/`. Stays private; remains the knowledge backup. The
  `~/.claude/knowledge` junction repoints here post-split.

**Ownership (Grimdex decision d003):** Grimdex-side execution — the Grimdex audit, the split
itself, the Grimdex README — runs from the **Grimdex home thread** (sessions in
`D:\Dev\Grimdex`); this project's thread owns only the orchestrator repo's own audit + README.
Cross-thread decisions flow as context syncs; cross-thread operations don't.

**Status: the SPLIT IS EXECUTED (2026-06-10, Grimdex d004 — via rename, not migration).**
The combined private repo was renamed `Ryfter/Grimdex` → **`Ryfter/grimdex-know`** (data +
full history + `pre-split-backup` tag; the `D:\Dev\Grimdex` working dir, the
`~/.claude/knowledge` junction, and the scheduled routines are all UNCHANGED — only the
remote URL changed, already updated in the shared tree). A NEW public-destined
**`Ryfter/Grimdex`** = the engine, rebuilt from zero history (1 commit, audited: no data
paths, no secrets, noreply author), currently still PRIVATE — **the visibility flip is
Kevin's manual action.** Audit findings: `projects/grimdex/go-public-audit.md` in the KB.
⚠️ If any agent has a stale remote pointing at `github.com/Ryfter/Grimdex.git` for the KB,
fix it to `grimdex-know` — the old redirect died when the engine repo took the name.

**For any agent working in the KB:** tag what you write as ENGINE (→ public, keep it free of
personal content + hardcoded local paths) or DATA (→ private). Decision records (like this)
and project tiers are DATA. Do **not** change repo visibility or rewrite history piecemeal.
Plan: `docs/go-public-hardening.md` (Task 2). Decision: `d037-grimdex-goes-public-as-engine.md`.
Until the split runs, his knowledge stays backed up in the current private `Ryfter/Grimdex`.
