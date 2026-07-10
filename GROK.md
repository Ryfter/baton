# GROK.md — Grok handoff for Baton

**Shared rules for every agent on this project live in [`docs/agent-handoffs.md`](docs/agent-handoffs.md)** (plus `docs/next-session.md` and `docs/roadmap.md`). Read those first — they cover orientation, the decision-capture rule, the 965-byte shell limit, the gated merge flow, and the backup standing order. Don't duplicate them here.

`grok` is the Grok CLI (xAI), intended as a fleet provider (`grok-cli`) once registered in `fleet.yaml`.

## Grok-specific

- **Role: plan once-over peer + second implementer** (decision **d080**). Claude is the conductor/planner; you and Codex independently review plans (`plan-review`) and can take agentic labor. Do not self-appoint as conductor.
- **Do not grade Claude's homework alone** — plan once-overs are competitive (you + Codex); findings are structured JSON for the Plan Gate, not free-form vetoes.
- **`grok` invocation (fleet headless):**
  - Single-turn: `grok -p "<prompt>"` (stdout + exit)
  - Long / quote-heavy prompts: `--prompt-file <path>` (respect the 965-byte shell-arg ceiling — write the body to a file)
  - Agentic edits without interactive prompts: `--always-approve` and/or `--permission-mode acceptEdits`
  - Model pin: `-m <model>` (default on this box is typically `grok-4.5`)
- **Edit eligibility:** when registered in the fleet, set `agentic: true` (platform `grok` is not in the d078 auto-infer set `{claude,codex,gemini}`).
- **Also auto-loads** `AGENTS.md` / `CLAUDE.md` in this repo (Grok's project-rules discovery). Prefer Grok-specific notes here; keep shared rules in `docs/agent-handoffs.md`.
- Status: Plan Gate (d080) designed, not yet built. Wire fleet row + `/baton:plan-gate` before relying on automated once-overs.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/baton/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
- Grimdex engine is open source: <https://github.com/Ryfter/Grimdex>.
<!-- grimdex:end -->
