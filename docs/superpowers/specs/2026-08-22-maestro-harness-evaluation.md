# Maestro harness evaluation — Kevin's AI Dev Harness stars + Baton fit

**Date:** 2026-08-22  
**Source list:** [github.com/stars/Ryfter/lists/ai-dev-harness](https://github.com/stars/Ryfter/lists/ai-dev-harness)  
**Context:** Maestro (Baton) is the conductor; we need a **runtime + agent CLI** layer that is not Cursor IDE.

---

## The stack (recommended)

| Layer | Tool | Role |
|---|---|---|
| **Conductor** | **Baton Maestro** (building) | Admit/fire jobs, parallel cap, project registry, cockpit dashboard |
| **Runtime** | **[Herdr](https://herdr.dev/)** | Persistent agent panes, blocked/idle detection, socket API — agents survive laptop close |
| **Agentic labor** | **Codex CLI + Grok CLI** | File edits without Cursor IDE; already in `~/.baton/overnight/fleet.yaml` |
| **Bulk free labor** | **openrouter-ox-alpha** | Promo window; diff_apply path for non-agentic edits |
| **Orchestration seat** | **cursor-agent** (optional) | Only when you want Cursor models headless — not the IDE |

**Cursor IDE** is optional front-end. Your pain (no right-click paste, vendor lock-in) is IDE-level — Herdr + terminal CLIs sidestep it.

---

## Your stars list — quick read

| Repo | Stars | Verdict for Kevin |
|---|---|---|
| **[Herdr](https://github.com/herdrdev/herdr)** | new | **Try first.** tmux-for-agents + `agent wait --until blocked`. Fits Maestro fan-out. |
| **[Omnigent](https://github.com/omnigent-ai/omnigent)** | 9k | Meta-harness — swap Claude/Codex/Cursor without rewrite. Watch; may overlap Baton. |
| **[agent-orchestrator](https://github.com/Untrivial-ai/agent-orchestrator)** | 9k | Fleet IDE — closest commercial shape to Maestro cockpit. Borrow UX ideas. |
| **[OctoAlly](https://github.com/ai-genius-automations/octoally)** | 100 | **Already using** — cockpit grid inspiration (slice 4). |
| **[Archon](https://github.com/coleam00/Archon)** | 23k | Harness *builder* — deterministic recipes. Good for one-shot install docs. |
| **[ECC](https://github.com/affaan-m/everything-claude-code)** | 242k | Skills/instincts — you already run superpowers/skills; keep mining ECC patterns. |
| **[claude-code-harness](https://github.com/Chachamaru127/claude-code-harness)** | 3k | Plan→Work→Review in Go — aligns with Conductor loop; reference for gate design. |
| **[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)** | 182k | Plugin everything — overkill unless you standardize on DeepSeek tooling. |
| **[ruflo](https://github.com/ruvnet/ruflo)** | 69k | Multi-agent swarms — heavy; Maestro already fans out via fleet-go. |
| **[wshobson/agents](https://github.com/wshobson/agents)** | 39k | Plugin marketplace — useful skill snippets, not a runtime. |
| **[adversarial-dev](https://github.com/coleam00/adversarial-dev)** | 128 | Generator vs evaluator GAN pattern — good for acceptance gate experiments. |

---

## Herdr — worth it?

**Yes, as the runtime layer beneath Maestro** — not as a replacement for Baton.

What Herdr fixes that Cursor does not:

- Agents keep running when you detach / close the terminal client
- **`blocked` vs `working` vs `idle`** — Maestro can poll `herdr agent list` instead of guessing from logs
- **`herdr agent prompt <target> "<text>" --wait`** — programmatic fan-out without Cursor UI
- Supports **codex, grok, cursor-agent, claude, opencode** as pane kinds out of the box
- Normal terminal paste (⌘V / middle-click) — no IDE paste bugs

What Herdr does **not** replace:

- Project registry, stakes, parallel cap, window budget — that's **Maestro**
- Plan gate, acceptance gate, worktrees — that's **Conductor / fleet-go**

**Pilot:** install Herdr on Mac mini, one workspace per Maestro project, wire `maestro-fire` optional path to `herdr agent start` + prompt instead of inline `fleet-go` for long runs.

---

## Maestro fixes shipped this session (slice 5)

Root causes found:

1. **`Start-Job` dropped `OPENROUTER_API_KEY`** → parallel fires failed in ~2s → false `waiting-quota`
2. **`waiting-quota` never requeued** → board stuck forever after one bad tick
3. **`ensure-conductors` placeholders ate parallel slots** → zero admits (fixed earlier)
4. **Stale overnight goals** cluttered the board

Fixes in `feat/maestro-front-door-slice1`:

- `Import-MaestroEnv` — load `.openrouter.env` in every runspace
- `ForEach-Object -Parallel` replaces `Start-Job` in `maestro-fire.ps1`
- `Test-MaestroInstrumentReady` — don't claim ox-alpha without API key
- `maestro-reconcile.ps1` — requeue waiting-quota, fold shipped goals
- `maestro-tick.ps1` — reconcile → admit → fire

---

## Next Baton moves

1. **Herdr integration spike** — `scripts/maestro-herdr.ps1` start/wait/prompt wrapper
2. **Default Maestro labor to grok-cli/codex** for `--stakes high` (agentic), ox-alpha for bulk
3. **Choices queue** (conductor-choices-queue plan) — unblock `needs-you` without Kevin hunting panes
4. **launchd plist** install for `maestro-watch` on Mac mini

---

## Cursor paste workaround (until you leave)

- Use **Terminal / iTerm / Herdr pane** for agent sessions — standard paste works
- In Cursor: **⌘V** or **Edit → Paste** (context menu paste is a known Electron gap on some builds)
- For Maestro compose: use dashboard at `:8765` or `curl` POST `/maestro/jobs`
