# Baton — rebrand & packaging (plugin + MCP) design

**Date:** 2026-06-11
**Status:** approved-pending-review
**Scope:** full rebrand of `coding-agent-orchestrator` → **Baton**, conversion to the
Claude Code plugin architecture, and an MCP adapter as the cross-tool fallback
(Codex, Cursor, anything MCP-capable).

## Identity

- **Name:** Baton. The conductor's baton — Claude conducts, and work is handed to
  each agent by *passing the baton*.
- **Tagline:** *Pass the baton. Conduct the fleet.*
- **Invoker:** plugin name `baton` → all commands surface as `/baton:<command>`
  (`/baton:fleet`, `/baton:route`, `/baton:job-start`, …). The prefix is hardcoded
  to the plugin `name` field, so the plugin MUST be named `baton`.
- **Repo:** `Ryfter/coding-agent-orchestrator` → `Ryfter/baton` (GitHub rename;
  old URLs redirect).
- **MCP surface (Phase 3):** server `baton`, tools `baton_route`, `baton_fleet`,
  `baton_kb_search`, `baton_job_status`, …

### Rebrand boundaries

| Surface | Action |
|---|---|
| README, plugin manifest, dashboard branding, CLAUDE.md / AGENTS.md / GEMINI.md, docs/agent-handoffs.md, docs/next-session.md | rename to Baton |
| GitHub repo name | `gh repo rename baton` |
| KB project dir `~/.claude/knowledge/projects/coding-agent-orchestrator/` | move → `projects/baton/`; update MEMORY.md pointer + any registry refs |
| Grimdex tier `projects/coding-agent-orchestrator/` | move → `projects/baton/`; update CLAUDE.md ref |
| Historical artifacts (release notes, decision records, compact-log entries, past specs/plans) | keep old name — they are history, not identity |
| Local folder `D:\Dev\coding-agent-orchestrator` → `D:\Dev\baton` | LAST step (breaks the live session cwd); migrate auto-memory dir `D--Dev-coding-agent-orchestrator` → `D--Dev-baton` at the same time |

## Architecture: three phases

### Phase 1 — Plugin shell (the invoker)

Make the repo an installable Claude Code plugin and its own marketplace.

- `.claude-plugin/plugin.json` — `name: "baton"`, displayName "Baton", version
  (sync with release tags), description, author, repository, license, keywords,
  plus explicit `"hooks": "./hooks/hooks.json"` once Phase 2 lands.
- `.claude-plugin/marketplace.json` — marketplace `ryfter`, owner Kevin Rank,
  single plugin entry `baton` with a relative source. One repo = plugin AND
  marketplace (verified supported).
- Existing root `commands/` (26 commands) and `agents/` are auto-discovered.
  (`commands/` is legacy-but-supported; migrating to `skills/` is a later,
  optional cleanup — not in scope.)
- Install flow: `claude plugin marketplace add Ryfter/baton` →
  `claude plugin install baton@ryfter`.
- Bootstrap step 5 (flat copy into `~/.claude/commands/`) is replaced by the
  plugin install; bootstrap additionally deletes previously deployed flat copies
  so `/fleet` and `/baton:fleet` don't coexist.
- **octo:** documented as a recommended companion, NOT a hard `dependencies`
  entry — octo installs from a different marketplace and a hard dependency
  can't be resolved reliably across marketplace scopes. Revisit if plugin
  dependency resolution gains cross-marketplace support.

### Phase 2 — Full plugin conversion

- **Hooks:** move decision-detect (Stop), run-feed (PostToolUse), and the
  SessionStart seeding into `hooks/hooks.json`, declared from plugin.json.
  Hooks invoke `pwsh` scripts via `"${CLAUDE_PLUGIN_ROOT}/scripts/…"`.
  **Exception — statusline:** plugins cannot provide a statusline; the
  statusline-feed stays a bootstrap-written user setting.
- **State root:** introduce a single resolver in the shared lib:
  `Get-BatonHome` = `$env:BATON_HOME`, default `~/.baton/`. Jobs, runs,
  journal, cost ledger, routing journal move there.
  **Deliberately NOT `${CLAUDE_PLUGIN_DATA}`:** that path is Claude-only and
  id-mangled; Baton's state must stay directly readable by Codex/Gemini and
  the Phase-3 MCP server per the model-agnostic north star. The plugin's own
  hooks/scripts read the same `BATON_HOME`.
  Migration: one-time move from `~/.claude/{jobs,runs,…}` with a marker file;
  `~/.claude/knowledge` does NOT move (cross-project, repo-backed, shared).
- **Config seeds:** `fleet.yaml`, `tools.yaml`, `prime-hours.yaml` ship as
  defaults in the plugin; a SessionStart hook copies them into `BATON_HOME` on
  first run (replaces bootstrap's Copy-WithPrompt).
- **Bootstrap shrinks** to: prerequisites check + marketplace add + plugin
  install + statusline setting + state migration. Everything else is plugin
  lifecycle.
- Python dashboard/kb stays a separately launched component (`/baton:dashboard`
  style command); plugins can't serve a web UI.

### Phase 3 — MCP adapter (cross-tool fallback)

- Python MCP server (`kb/` is already Python) exposing the core capabilities as
  tools — `baton_route`, `baton_fleet_*`, `baton_kb_search`, `baton_job_*` —
  by shelling into the existing `.ps1` libs (thin adapter, no logic fork).
- Bundled in the plugin via `.mcp.json` at plugin root (auto-registers for
  Claude when the plugin is enabled); for Codex: `codex mcp add baton -- …`;
  Cursor/others: standard MCP config.
- Codex remains a fleet implementer regardless — AGENTS.md already carries the
  instruction layer; the MCP server adds *capability* access (route/kb/jobs)
  from non-Claude conductors.
- Server reads the same `BATON_HOME` state — one state model, three surfaces
  (plugin commands, hooks, MCP tools).

## Sequencing & risk

1. **Phase R (rebrand)** and **Phase 1 (plugin shell)** land together this
   session — Phase 1 is a strict subset of Phase 2, nothing throwaway.
   Local-folder move is the final step of Phase R.
2. **Phase 2** next: the state re-root is the bulk of the effort (every script
   touches `$HOME/.claude/…`) — mechanical but pervasive; full test suite
   (30 PS suites + 176 Python tests) gates it.
3. **Phase 3** after Phase 2 stabilizes, since the MCP server wants the final
   state root.

**Risks:** state migration breaking in-flight jobs (mitigate: marker + idempotent
move + tests); plugin install replacing flat commands mid-transition (mitigate:
bootstrap cleanup step); rename breaking external links (GitHub auto-redirects;
KB/Grimdex moves are same-machine).

**Out of scope:** migrating `commands/` → `skills/`; auto-served dashboard;
publishing to third-party marketplaces; bash ports of the PowerShell core.

## Verification

- `/baton:fleet doctor`, `/baton:route`, `/baton:job-status` work from a clean
  `claude plugin install`.
- Old flat `/fleet` etc. no longer resolve after bootstrap cleanup.
- Full PS + Python test suites green after each phase.
- Phase 3: `codex mcp add` session can call `baton_route` end-to-end.
