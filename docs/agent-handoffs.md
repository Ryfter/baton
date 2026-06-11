# Agent handoffs — shared core + what's intentionally model-specific

This project (**Baton** — https://github.com/Ryfter/baton) is worked by multiple AI
agents. To stay consistent **and** let each
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
`docs/roadmap.md` (status), and use the shared knowledge base (`Ryfter/grimdex-know`, the
private data repo — see the Grimdex split section below).

## Shared core — identical expectations for EVERY agent
1. **Orient first:** read `docs/next-session.md` + `docs/roadmap.md`.
2. **Decision capture:** when you make a significant architectural/scope/approach
   decision, record it via the file-based intake (canonical rule in `CLAUDE.md`).
   Records live in the `Ryfter/grimdex-know` repo (`projects/<id>/decisions/`).
3. **965-byte shell-argument ceiling:** never pass a long string (commit message,
   prompt, file body) as one shell argument — write it to a file and read it.
   Prefer small, separate commands over long `&&` chains.
4. **Shipping:** per-item branch → hard merge gate (`scripts/fleet-orchestrate.ps1`)
   → master. Keep master green. Gated merges auto-append `Closes #N`.
5. **Backup standing order:** push everything to GitHub (private) so a new PC can
   roll — including the `Ryfter/grimdex-know` base. Don't ask; just do it.
6. **Knowledge is model-agnostic** (`Ryfter/grimdex-know`): keep `universal/` +
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
paths, no secrets, noreply author). **Now PUBLIC (Kevin flipped it 2026-06-11) and available
at https://github.com/Ryfter/Grimdex (MIT).** Audit findings: `projects/grimdex/go-public-audit.md`
in the KB.
⚠️ If any agent has a stale remote pointing at `github.com/Ryfter/Grimdex.git` for the KB,
fix it to `grimdex-know` — the old redirect died when the engine repo took the name.

**For any agent working in the KB:** the KB you read/write is the private **`Ryfter/grimdex-know`**
(via the `~/.claude/knowledge` junction). Tag what you write as ENGINE (→ public `Ryfter/Grimdex`,
keep it free of personal content + hardcoded local paths) or DATA (→ private grimdex-know).
Decision records (like this) and project tiers are DATA. Engine changes are made in the Grimdex
home thread, then synced to the public repo. Decision: `d037-grimdex-goes-public-as-engine.md`;
historical plan (now executed via rename): `docs/go-public-hardening.md`. His knowledge stays
backed up in private `Ryfter/grimdex-know` (with the `pre-split-backup` tag preserving pre-split history).

## Baton rebrand + plugin packaging (2026-06-11, decision d038) — EXECUTED

The project was fully rebranded **coding-agent-orchestrator → Baton** ("Pass the
baton. Conduct the fleet.") and packaged as a Claude Code plugin. What every agent
must know:

- **Repo:** `Ryfter/baton` (GitHub rename; old URLs redirect). Local working dir:
  **`D:\Dev\baton`** (renamed from `D:\Dev\coding-agent-orchestrator`).
- **Install (Claude Code):** `claude plugin marketplace add Ryfter/baton` +
  `claude plugin install baton@ryfter`. The repo is its own marketplace
  (`.claude-plugin/plugin.json` + `marketplace.json`).
- **Commands are namespaced:** every slash command is now `/baton:<name>`
  (`/baton:fleet`, `/baton:route`, `/baton:job-start`, …). Flat `/fleet`-style
  copies in `~/.claude/commands` are removed by bootstrap — don't reference them.
- **KB tier renamed:** decision records + project knowledge now live under
  `projects/baton/` in `Ryfter/grimdex-know` (all d-records moved as git renames).
- **Env var:** `BATON_REPO_ROOT` is the preferred repo-root override
  (`CAO_REPO_ROOT` still honored as legacy). Default project id in scripts: `baton`.
- **octo** is a recommended companion plugin, NOT a hard plugin dependency
  (cross-marketplace dependency resolution is unreliable).
- **Phase 2 — EXECUTED (2026-06-11):** hooks ship with the plugin (`hooks/hooks.json`),
  including `log-tool-call` PostToolUse and `baton-init` SessionStart; all mutable state
  (jobs, runs, ensembles, ideas, current-job.json, routing-journal.jsonl,
  model-routing-log.md, fleet.yaml, tools.yaml, prime-hours.yaml, logs/) now lives under
  `BATON_HOME` (default `~/.baton`; env-overridable; NOT `${CLAUDE_PLUGIN_DATA}` — state
  must stay readable by every agent). One-time marker-gated migration from `~/.claude/`
  runs on first `baton-init`. KB, cost ledger, and deployed `~/.claude/scripts/` unchanged.
  `kb-autoindex` stays a user-settings hook. Statusline stays bootstrap-managed.
- **Phase 3 — EXECUTED (2026-06-11):** Python MCP server `baton` ships as `baton_mcp`
  (FastMCP stdio, 8 tools: `baton_capabilities`, `baton_route`, `baton_kb_search`,
  `baton_job_status`, `baton_job_list`, `baton_fleet_list`, `baton_fleet_doctor`,
  `baton_fleet_test`). Bundled in the plugin via `.mcp.json` — auto-registered in every
  Claude Code session. Codex and Cursor registration documented in README. All tools read
  the same `BATON_HOME`; bridge shims into existing PS libs via `scripts/mcp-bridge.ps1`.
