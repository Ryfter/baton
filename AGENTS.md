# AGENTS.md — Codex handoff for Baton

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

## Codex-specific
- **Role: primary autonomous implementer** (decision d009). As an agentic file-editing CLI, you implement backlog items end-to-end and take them through the hard merge gate to master.
- Tests before merging: `python -m pytest kb dashboard -q` and the PowerShell suites at `scripts/test-*.ps1`.
- Status: Plans 1–11 shipped (v1.1.0), backlog #16–#26 cleared. The Gemini dashboard redesign has since been reviewed and merged (its branch tip is an ancestor of `master`); current release state lives in `docs/roadmap.md` + `docs/releases/`.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/baton/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
- Grimdex engine is open source: <https://github.com/Ryfter/Grimdex>.
<!-- grimdex:end -->

<!-- grimlore:start -->
# Grimlore — context layer (read when why/who/landscape matters)

WHY / WHO / durable context → **Grimlore** at `D:\Dev\Grimlore`.
Baton landscape (watched repos, keep-vs-adopt):
`D:\Dev\Grimlore\projects\baton\BATON.md` then `index.md`.

- Authoring: `D:\Dev\Grimlore\GRIMLORE.md` (OKF v0.2 + `x-grimdex`).
- Do not copy Source cards into this repo. Reference the path or
  `x-grimdex.repo`.
- Decisions still go to Grimdex, not Grimlore.
<!-- grimlore:end -->

## Project command center (from any agent)

Baton's project registry and front door are harness-neutral. From Codex (or
any agent), reach the same engine directly:

- Roster: `pwsh -NoProfile -File scripts/fleet-project.ps1 list --json`
- Start a project by name: `pwsh -NoProfile -File scripts/fleet-go.ps1 --project <slug> --goal "<goal>"`

Active-session detection and resume pointers use a neutral marker contract
under `$BATON_HOME/sessions/` (`{agent,session_id,cwd,started_at}`). The
Claude adapter (SessionStart/SessionEnd hooks) and the portable `baton session`
adapter ship now. Codex, Grok, or another controller can participate with:
`baton session start|refresh|stop -Agent <label> -SessionId <id> -Cwd <path>`.

Fleet health (model-agnostic):
- `fleet doctor --live` — harness-neutral way to verify a box's roster actually answers (canary round-trip per enabled provider), not just that the binaries are installed.
- `/baton:go --execute` — agentic labor lands in an isolated worktree (branch `baton/run-<id>`, proof-by-diff, acceptance-gated); the branch is always left for the human to merge.
