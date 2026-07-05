# AGENTS.md — Codex handoff for Baton

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

## Codex-specific
- **Role: primary autonomous implementer** (decision d009). As an agentic file-editing CLI, you implement backlog items end-to-end and take them through the hard merge gate to master.
- Tests before merging: `python -m pytest kb dashboard -q` and the PowerShell suites at `scripts/test-*.ps1`.
- Status: Plans 1–11 shipped (v1.1.0), backlog #16–#26 cleared. An unreviewed Gemini dashboard redesign waits on branch `gemini/dashboard-redesign`.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/baton/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
- Grimdex engine is open source: <https://github.com/Ryfter/Grimdex>.
<!-- grimdex:end -->

## Project command center (from any agent)

Baton's project registry and front door are harness-neutral. From Codex (or
any agent), reach the same engine directly:

- Roster: `pwsh -NoProfile -File scripts/fleet-project.ps1 list --json`
- Start a project by name: `pwsh -NoProfile -File scripts/fleet-go.ps1 --project <slug> --goal "<goal>"`

Active-session detection and resume pointers use a neutral marker contract
under `$BATON_HOME/sessions/` (`{agent,session_id,cwd,started_at}`). The
Claude adapter (SessionStart/SessionEnd hooks) ships now; a Codex lifecycle
adapter writing the same marker shape is the documented follow-on.
