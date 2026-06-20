# AGENTS.md — Codex handoff for Baton

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

## Codex-specific
- **Role: primary autonomous implementer** (decision d009). As an agentic file-editing CLI, you implement backlog items end-to-end and take them through the hard merge gate to master.
- Tests before merging: `python -m pytest kb dashboard -q` and the PowerShell suites at `scripts/test-*.ps1`.
- Status: Baton v1.2.0 shipped (Conductor + Memory Bridge stable). Current next build target is Sprint 6 — Worker Adapter. An unreviewed Gemini dashboard redesign waits on branch `gemini/dashboard-redesign`.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/baton/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
- Grimdex engine is open source: <https://github.com/Ryfter/Grimdex>.
<!-- grimdex:end -->
