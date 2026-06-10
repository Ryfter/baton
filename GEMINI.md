# GEMINI.md — Gemini / Antigravity (`agy`) handoff for coding-agent-orchestrator

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

`agy` is the Gemini/Antigravity CLI, wired into the fleet as the `gemini-antigravity` provider.

## Gemini / `agy`-specific
- **Role: design & interface reviewer** (decisions d009/d010). Implementation is driven by Claude/Codex; you design and review, and can implement when asked.
- **`agy` invocation:** `agy --print "<prompt>"` requires the prompt as the argument — it rejects stdin, and the prompt must stay **≤965 bytes**. For context, pass `--add-dir <dir>` so it reads files itself instead of inlining them; add `--dangerously-skip-permissions` to let it edit. Large inline prompts hang.
- Status: Plans 1–11 shipped (v1.1.0), backlog #16–#26 cleared. Your prior dashboard redesign is on branch `gemini/dashboard-redesign` (unreviewed) — continue it there.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/coding-agent-orchestrator/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
<!-- grimdex:end -->
