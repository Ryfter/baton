# AGENTS.md — Codex handoff for coding-agent-orchestrator

You're picking up Kevin's personal LLM-fleet orchestrator (Approach C: the agent *is* the orchestrator — no daemon). Orient before acting:

1. **Read `docs/next-session.md`** — the operating loop (how to use the orchestrator on its own backlog).
2. **Read `docs/roadmap.md`** — status: Plans 1–11 shipped, **v1.1.0**, the post-Plan-8 backlog (#16–#26) is cleared. Full batch writeup: `docs/releases/2026-06-04-backlog-clearance.md`.
3. **Read `CLAUDE.md`** — its **decision-capture rule applies to you too.** When you make a significant architectural/scope/approach decision, capture it via the file-based intake (`Add-DecisionRecordFromFile`). Records live at `~/.claude/knowledge/projects/coding-agent-orchestrator/decisions/` (d001–d013 so far; not yet version-controlled).

## How work ships
- Per-item branch → hard merge gate (`scripts/fleet-orchestrate.ps1`) → master. Keep master green. Gated merges now auto-append `Closes #N`.
- Tests: `python -m pytest kb dashboard -q`; PowerShell suites at `scripts/test-*.ps1`.
- Fleet/provider config: `references/fleet.yaml`; deployed runtime at `~/.claude/`.

## Hard constraints
- **965-byte shell-argument ceiling.** Never pass a long string (commit message, prompt, file body) as a single shell argument — it silently fails/gets lost. Write it to a file and have the command read it (`git commit -F <file>`). Prefer many small, separate commands over long `&&` chains.

## Open threads
- `docs/roadmap.md` "Parked" + the release notes list what's left (wire `decision-detect` Stop hook; cross-project consolidation; decision feedback).
- An **unreviewed Gemini dashboard redesign** is on branch `gemini/dashboard-redesign` (not merged).
- `~/.claude/knowledge/` (decisions, KB, guidance) is **not backed up** — flagged for the owner.
