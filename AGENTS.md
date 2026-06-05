# AGENTS.md — Codex handoff for coding-agent-orchestrator

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

## Codex-specific
- **Role: primary autonomous implementer** (decision d009). As an agentic file-editing CLI, you implement backlog items end-to-end and take them through the hard merge gate to master.
- Tests before merging: `python -m pytest kb dashboard -q` and the PowerShell suites at `scripts/test-*.ps1`.
- Status: Plans 1–11 shipped (v1.1.0), backlog #16–#26 cleared. An unreviewed Gemini dashboard redesign waits on branch `gemini/dashboard-redesign`.
