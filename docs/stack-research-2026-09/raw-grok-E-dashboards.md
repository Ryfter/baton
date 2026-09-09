# Dashboard / board research — slot 1 vs slot 2

**Date:** 2026-09-09  
**Question:** which of these seven repos is a coordination board (slot 1), which is observability (slot 2), and does any of them kill the GitHub Issues/Projects + ~200-line Baton table-view plan?

**Baton context used:** 5–6k-line Python core that *adopts* tools; GitHub Issues/Projects as system-of-record; table columns `task | assigned LLM | model tier | queue | Needs-You | Failed | Done`; private LM Studio fleet on a Tailscale mesh (Mac Mini + 3 Windows/WSL GPU boxes + Omarchy laptops + Pi + webhost); Governor + LiteLLM already own routing/spend; `devboardai.com` ($24 Mac app) is UX study only.

**Sources:** GitHub API metadata + READMEs + (for AO) `docs/architecture.md` + `docs/STATUS.md` + aoagents.dev agent-adapter/privacy docs; Helicone self-host + OpenLLMetry + proxy-vs-async docs; squan.dev; Sophylabs/devboardai.com pages to disambiguate the intern repo.

---

## Verdict snapshot

| Repo | Slot | Fleet-aware? | $0 self-host? | Verdict |
|---|---|---|---|---|
| `web-werkstatt/session-pilot` | **2** (strong) + weak 1 | Multi-*harness session import*, not Tailscale fleet | Yes, Docker; **Postgres required for Sessions** | **STUDY-ONLY** (optionally ADD later as a session/cost cockpit) |
| `tarvitave/squan` | **both**, as its *own* orchestrator | Single-machine Electron; Ollama yes; not mesh | Yes (OSS binary / Docker); needs provider API keys | **SKIP** |
| `DanWahlin/agent-mission-control` | **2**, Copilot-only | Single machine, `~/.copilot/` | Yes, local Tauri app | **STUDY-ONLY** (HUD UX) |
| `Untrivial-ai/agent-orchestrator` | **1** (the real board) + weak 2 | Multi-*harness* on **one machine**; mobile over LAN/Tailscale; cloud workers are **private/paid**; GitHub *issue* mirroring **not shipped** | Yes for local OSS; hosted cloud is paid | **STUDY-ONLY** for UX; do **not** REPLACE Projects as SoR |
| `burrthemenace/devboardAI` | **neither** | n/a | No — Firebase Auth + Firestore | **SKIP** (name collision; intern homework) |
| `Helicone/helicone` | **2** | LLM-HTTP fleet, not coding-agent fleet | Yes, heavy Docker (Postgres+ClickHouse+MinIO) | **ADD later as async sidecar only** — never as gateway |
| `disler/claude-code-hooks-multi-agent-observability` | **2**, Claude Code only | Multi-Claude-session; not Grok/Codex/LM Studio | Yes (Bun+SQLite); optional paid APIs for TTS/summarize | **STUDY-ONLY** (steal the event-bus pattern) |

**None of these kill the GitHub Projects table-view plan.** AO is the only one that *could*, and it currently does not use GitHub Issues as a live tracker.

---

## 1. `web-werkstatt/session-pilot`

https://github.com/web-werkstatt/session-pilot · https://session-pilot.com

### What it actually is
A **self-hosted Flask cockpit** over *local* AI-coding session files. It imports and normalizes JSONL/session stores from **Claude Code, Codex CLI, Gemini CLI, OpenCode, and Kilo**, then adds cost dashboards, a live 5h-window usage monitor (P90 limits, burn rate), session replay with markdown/tool results, plan import from `~/.claude/plans/`, project auto-discovery, Docker container status, and a code-quality scanner.

It also ships a small **agent-task API** (`create → pull → finish → verify → close`, token-gated `/api/agent-tasks/*`, CLI `scripts/claude_task.py`). That is a personal workflow overlay, not a live “which LLM has GitHub issue #N” board.

### Facts
| | |
|---|---|
| Language | Python (Flask, 37 blueprints, 50+ services) |
| License | MIT |
| Stars | **1** |
| Last push | **2026-04-18** (~5 months stale as of this report) |
| Maintainer | **Single:** `JosephKisler` / `web-werkstatt` (448/448 commits) |
| Commits | 448 |

### Slot
**Primarily slot 2.** Cost, tokens, 5h session blocks, tool-usage ranking, session replay, OTLP receiver for Claude Code telemetry (`CLAUDE_CODE_ENABLE_TELEMETRY=1` → `http://localhost:5055`).

**Weak slot 1:** Plans board + agent-task lifecycle. It does *not* show queue position, assigned model tier, or park-for-human against GitHub Issues. Status of plans is inferred from file age / session activity, not from a live worker fleet.

Kevin’s “looks a lot like I was thinking” is fair **as a cockpit over work already done**, not as the coordination SoR.

### Fleet-aware?
**No.** It reads local disk (`~/.claude/`, Codex/Gemini stores, a configured `DASHBOARD_PROJECTS_DIR`). Multi-account on one host, yes. It will not see LM Studio on the 4090 box, Hermes/OpenClaw on Omarchy, or Grok CLI unless those write a supported session format on a filesystem this app can mount. You *could* run the Docker container on the Mini and bind-mount several `~/.claude` trees over Tailscale/SSHFS; that is still “import local logs,” not a live fleet board.

### $0 self-host?
**Yes, with Postgres.**

```bash
git clone https://github.com/web-werkstatt/session-pilot.git
cd session-pilot
cp .env.example .env
# set DASHBOARD_PROJECTS_DIR, DB_*, DASHBOARD_PORT (default 5055)
docker compose up -d
# http://localhost:5055
```

Bare metal: `./setup.sh` or `pip3 install -r requirements.txt && python3 app.py`.

**Dependencies:**
- **Required:** Python 3.9+
- **Required for Sessions feature:** PostgreSQL 14+ (without it, “everything works except Sessions”)
- Optional: Docker socket (container dashboard), Gitea token, ripgrep
- No Supabase, no cloud SaaS. No API keys needed to *read* local Claude/Codex files.
- OTel path is optional; without it, usage monitor estimates limits from JSONL P90.

### Verdict
**STUDY-ONLY** (keep the tab; do not stand it up as infra). Closest match to “a cockpit over my sessions and spend,” but 1 star, last push April, Postgres for the only feature Baton actually wants, and it does not assign work. If Kevin later wants session *replay* of Claude/Codex/Gemini on the Mini, **ADD** then — as a reader, not as the board.

---

## 2. `tarvitave/squan` + squan.dev

https://github.com/tarvitave/squan · https://squan.dev/

### What it actually is
A **desktop multi-agent command center** (Electron 33 + React 19 + Express + SQLite cache). It is **its own agent runtime**: 53 built-in tools, MCP, isolated git worktrees, a 5-column kanban (`Open → In Progress → PR Review → Landed → Cancelled`), agent chat, cost dashboard, and a 17-platform messaging gateway (Telegram/Discord/Slack/…). State lives in `.squan/` markdown in the repo. Models: Anthropic, OpenAI, Gemini, **Ollama / any OpenAI-compatible endpoint**.

This is not a view over Claude Code / Codex / Baton. It *spawns its own agents*.

### Facts
| | |
|---|---|
| Language | TypeScript |
| License | Apache-2.0 |
| Stars | **7** |
| Last push | **2026-05-25** (~3.5 months stale; site still advertises v2.8.4) |
| Maintainers | Small. Owner `tarvitave` (Colin Wynd per README, 3 commits). Primary coder `renoschubert` (177). `yochum` 4. Effectively one-person product with a helper. |
| Commits | 185 |

### Slot
**Both — of Squan’s own world.** Kanban = slot 1. Cost/events/metrics = slot 2. Neither is Baton’s world: tasks are `.squan/board/*.md`, not GitHub Issues; workers are Squan child processes, not Claude/Codex/Grok/LM Studio harnesses.

### Fleet-aware?
**No.** One Electron app (or one Docker web deploy) on one machine. Ollama is “local model on this box,” not “route this task to the 5090 over Tailscale.” Messaging gateway is remote *control*, not remote *workers*.

### $0 self-host?
**Yes, OSS.**

```bash
# binary (easiest)
# https://squan.dev/download  — signed Win/macOS

# from source
git clone https://github.com/tarvitave/squan.git
cd squan && npm install && npm start   # server :3001, UI in Electron

# docker web
cp .env.example .env   # ANTHROPIC_API_KEY / OPENAI_API_KEY
docker-compose up -d   # http://localhost:80
```

Hosted deps: none required. SQLite (`file:./squansq.db`). Cloud model spend is on you. JWT_SECRET defaults to `squansq-dev-secret`.

### Verdict
**SKIP.** Competing orchestrator with 7 stars and a stale tree. Adopting it would replace Baton’s dispatch model, not sit beside GitHub Projects. Kanban screenshots are fine as UX study; the paid Mac app (`devboardai.com`) already covers that.

---

## 3. `DanWahlin/agent-mission-control`

https://github.com/DanWahlin/agent-mission-control · https://danwahlin.github.io/agent-mission-control

### What it actually is
A **Tauri 2 + Phaser 4 “mission map” HUD** that tails **GitHub Copilot CLI / Copilot App** session state under `~/.copilot/session-state/`. Live sectors for edits/reads/commands/hooks/sub-agents/skills/MCP, token totals, history/daily debrief, and an analytics chat over *local* indexed Copilot usage. Looks like a NASA console. Copilot-only.

Architecture is actually clean: `AgentProvider` trait + `CopilotProvider` impl — a second provider *could* be written, but only Copilot ships.

### Facts
| | |
|---|---|
| Language | Rust (Tauri) + TypeScript/Phaser |
| License | MIT |
| Stars | **47** |
| Last push | **2026-08-11** (alive) |
| Maintainer | **Single:** Dan Wahlin (122/122) |
| Commits | 122 |

### Slot
**Slot 2 only**, and only for Copilot. Not a queue, not assignment, not park-for-human. The “Attention Center” surfaces provider/schema problems, not “Needs-You on issue #N.”

### Fleet-aware?
**No.** One Mac/Win/Linux desktop reading one home directory. No Tailscale, no other harnesses.

### $0 self-host?
**Yes.** Unsigned GitHub Release builds, or:

```bash
git clone https://github.com/DanWahlin/agent-mission-control.git
cd agent-mission-control
npm install
npm start          # Tauri dev
# releases: https://github.com/DanWahlin/agent-mission-control/releases
```

No cloud. Analytics chat is local. Not code-signed (quarantine/SmartScreen dance).

### Verdict
**STUDY-ONLY.** Kevin is right that it LOOKS cool — steal HUD ideas (focus mode, sectors, quiet-unless-actionable attention). Do not install it as fleet infra; Copilot is not the fleet.

---

## 4. `Untrivial-ai/agent-orchestrator` (AO)

https://github.com/Untrivial-ai/agent-orchestrator · https://useao.dev / https://aoagents.dev

**This is the one to go deep on.**

### What it actually is
A **local desktop supervisor for coding-agent CLIs**. Go daemon + Electron/React UI + optional `ao` CLI + Expo mobile. Each **worker** = one task + one harness + one git worktree/branch. A project **orchestrator** agent plans and spawns workers. Live Kanban columns derived from session + PR + CI + review facts:

- **Working**
- **Needs you** (blocked, missing input, failed CI, requested changes, lost signal)
- **In review**
- **Ready to merge** (merged kept until archived)

That column set is almost exactly Kevin’s table (`Needs-You | Failed | Done`), with PR/CI folded in.

It launches **your already-installed CLIs**. It does not bundle credentials. It does not sit in front of LM Studio.

### Facts
| | |
|---|---|
| Language | **Go** (daemon) + TypeScript (Electron) |
| License | Apache-2.0 |
| Stars | **11,123** |
| Forks | 1,569 |
| Last push | **2026-09-09 07:00 UTC** (today; 2,644 commits) |
| Maintainers | **Org, not single-maintainer.** Top: `harshitsinghbhandari` 444, `AgentWrapper` 244, `illegalcall` 214, `suraj-markup` 172, `ashish921998` 161 |
| Open issues | 701 (noisy; product is shipping nightly) |

### Slot
**Slot 1 — the only real coordination board in this set.**

Weak slot 2: Chat conversations persist usage/compaction; there is no fleet-wide token/latency/tool-trace product, and AO “does not intercept, store, or forward what [agents] send to their own providers” (privacy policy). Ringside/Helicone/session-pilot still own traces.

### Is it fleet-aware? Multi-machine? Beyond Claude + Codex?

**Multi-harness: yes. Multi-machine worker fleet: no (OSS). GitHub-Issues SoR: not shipped.**

**Harnesses (26 worker adapters compiled into the daemon), from current docs:**  
`claude-code`, `codex`, `opencode`, **`grok`**, `cursor`, `qwen`, `copilot`, `kimi`, `muse`, `droid`, `amp`, **`agy`**, `crush`, `aider`, `goose`, `auggie`, `continue`, `devin`, `cline`, `kiro`, `kilocode`, `vibe`, `pi`, `kimchi`, `prime-agent`, `autohand`.

Chat/ACP (structured, not just TUI): Codex, Claude Code, OpenCode, Droid, plus STATUS.md also lists Cursor, Kimchi, Kimi, Pi, OMP. Grok is a **TUI harness + experimental reviewer**, not a first-class Chat driver.

**What “fleet” means here:** many *CLI harnesses on the machine that runs the daemon*. Isolation = git worktrees, not GPU boxes.

**What it is not:**
- Not a Tailscale mesh scheduler. Daemon **primary bind is `127.0.0.1`** (load-bearing rule). Opt-in second listener `0.0.0.0:3011` is **Connect Mobile** (bearer password, plaintext LAN; privacy docs explicitly say Tailscale is fine *for the phone to reach the daemon*). Mobile is a thin renderer, not a remote worker pool.
- Not LM Studio / local OpenAI-compatible model servers. AO will not assign “run this on the 4090 box.” Those boxes are invisible unless a *harness CLI* on the AO machine happens to call them.
- Not Baton’s learned router. AO picks a harness + that harness’s own model setting.
- **GitHub tracker lane is a stub.** `docs/STATUS.md`: “GitHub tracker adapter exists, but there is no daemon observer loop or agent-lifecycle→issue mirroring yet, so the tracker does nothing at runtime (#112).” SCM observer *does* watch PRs/CI/reviews and nudge the owning agent. Issues/Projects are **not** AO’s SoR. AO’s SoR is **SQLite under `~/.ao`**.
- **Cloud workers are not in the public repo.** `docs/cloud-development.md`: public product stays local; `private/ao-cloud` submodule is the hosted control plane (Docker sandbox locally; NodeOps hosted still in progress). Design-partner pricing on the site is **$500–2,000/mo**. Do not treat “Desktop, web, mobile, and cloud agents” in the GitHub description as OSS multi-machine.

Anonymous telemetry: privacy-preserving usage, plus **GitHub org/user owner segment** (personal-repo owner username is “not anonymous”). Local app works without an AO account.

### $0 self-host?
**Yes, for the OSS desktop.**

```bash
# canonical: desktop app (owns the daemon)
# macOS arm64
# https://github.com/Untrivial-ai/agent-orchestrator/releases/latest/download/agent-orchestrator-darwin-arm64.dmg
# also: darwin-x64.dmg, win32-x64.exe, linux AppImage/deb/rpm

brew install agentwrapper/tap/agent-orchestrator   # advertised on aoagents.dev

# from source (dev)
git clone https://github.com/Untrivial-ai/agent-orchestrator.git
cd agent-orchestrator
# see docs/development.md — Nix flake + Go + npm
```

Prereqs: Git, `gh` for GitHub projects, at least one harness CLI, **tmux** on macOS/Linux for TUI.

No Postgres/Supabase. SQLite in `~/.ao`. No required cloud. Hosted AO cloud = paid/private.

### Verdict
**STUDY-ONLY for the board UX; do not REPLACE the Projects plan.**

AO is the strongest open “fleet IDE” if “fleet” = “many coding CLIs on the Mini.” It is the right screenshot to steal for columns (Needs you / Working / In review / Ready to merge) and for “failed CI routes back to the agent that owns the branch.”

It is the **wrong SoR** for Baton: it will not see the 4090/5090/2070S LM Studio servers, it will not honor the Governor, and it will not write queue/assignee onto GitHub Issues (#112 unshipped). Standing it up as the board creates a second source of truth next to Projects.

Optional later **ADD** (narrow): run AO *only* on the Mini as a launcher/HUD for Claude Code + Codex + Grok CLI worktrees, while GitHub Projects remains the cross-fleet queue including local-model workers. That is extra surface, not a replacement for 200 lines.

---

## 5. `burrthemenace/devboardAI` (GitHub) vs `devboardai.com`

https://github.com/burrthemenace/devboardAI

### What it actually is
**An internship homework repo.** README: intern Burhan Haider, Zynvex Solutions, “Frontend Dev,” Module 1 (Jul 20–26 2026): Next.js 14 App Router + Tailwind + **Firebase Auth + Firestore**, login/register, navbar, empty dashboard placeholder. Module 2 (kanban) is listed as not done. **2 commits. 5 KB. 0 stars.**

This is **not** pre-release of the paid Mac app.

### Related to `devboardai.com`?
**No.** Name collision only.

| | GitHub `burrthemenace/devboardAI` | `devboardai.com` (Sophylabs) |
|---|---|---|
| What | Next.js + Firebase student dashboard | Closed Electron Mac orchestrator |
| Agents | None | Claude Code, Codex, Kimi only |
| License | **None** | Paid, **$24** lifetime (site FAQ; Sophylabs case study also quotes $74 — treat the site price as current, the case study as older marketing) |
| OSS? | Public source, no LICENSE file → not safely reusable | Closed |
| Last push | 2026-07-26 | Commercial product |

### Facts
| | |
|---|---|
| Language | TypeScript |
| License | **none** |
| Stars | **0** |
| Last push | 2026-07-26 |
| Maintainer | **Single:** `burrthemenace` (2 commits) |

### Slot
**Neither.** Generic CRUD kanban homework. No LLM assignment, no traces.

### Fleet-aware / $0
Firebase Auth + Firestore = **hosted paid dependency** (Spark free tier, not local). Not a fleet tool.

### Verdict
**SKIP.** Confirmed: looks “pre-release” because Module 1 is a stub, not because it is the Sophylabs app. Do not confuse with the $24 Mac UX study already on the plan.

---

## 6. `Helicone/helicone`

https://github.com/Helicone/helicone · https://docs.helicone.ai

### What it actually is
YC W23 **LLM observability platform + AI Gateway**. Request logs, cost, latency, sessions/traces, playground, prompt versioning. Two integration modes:

1. **Proxy / AI Gateway** — change `baseURL` to Helicone; they forward to the provider. Gets caching, retries, rate limits, fallbacks.
2. **Async / OpenLLMetry** — log *after* the call; Helicone is **not** on the critical path.

Self-host stack (docs): Web (Next.js), Jawn (API), Postgres, ClickHouse, MinIO. Older compose used Supabase; current **all-in-one image bundles Postgres + ClickHouse + MinIO**. **Jawn no longer proxies** (`/v1/gateway/*` removed); a self-hosted gateway is a *separate* deploy.

### Facts
| | |
|---|---|
| Language | TypeScript |
| License | Apache-2.0 |
| Stars | **6,137** |
| Last push | **2026-08-31** |
| Maintainers | Company. Top: `chitalian` 2314, `colegottdank` 836, `ScottMktn` 491, … |
| Commits | 5,484 |

### Slot
**Slot 2 only.** Dashboards are request/trace/cost, not task queues.

### Fleet-aware?
**At the HTTP-LLM hop, yes** — any worker whose OpenAI-compatible calls you instrument can show up, including (via LiteLLM) local endpoints.

**At the coding-agent hop, no.** Claude Code / Codex / Grok CLI tool traces do not appear unless those CLIs’ *provider HTTP* is wrapped. LM Studio is not in the OpenLLMetry supported-provider list (OpenAI, Anthropic, Azure, Cohere, Bedrock, Google). Practical path for Kevin: **LiteLLM already in front of the fleet → Helicone callback**, not Helicone-in-front-of-LM-Studio.

### $0 self-host? Gateway vs Governor?

**Self-host is $0 OSS, but heavy.** Hosted free tier is 10k req/month then paid — ignore hosted.

```bash
# lightest local
docker pull helicone/helicone-all-in-one:latest
docker run -d --name helicone \
  -p 3000:3000 -p 8585:8585 -p 9080:9080 \
  -v helicone-postgres:/var/lib/postgresql/data \
  -v helicone-clickhouse:/var/lib/clickhouse \
  -v helicone-minio:/data \
  helicone/helicone-all-in-one:latest
# UI: http://localhost:3000  (signup; no email — must SQL-verify)
# without volumes, restart WIPES data

# compose (repo)
git clone https://github.com/Helicone/helicone.git
cd docker && cp .env.example .env && ./helicone-compose.sh helicone up
```

**Callouts:**
- Ports: 3000 web, 8585 Jawn, 9080 MinIO; internally 5432 Postgres, 8123 ClickHouse.
- No mailer: `UPDATE "user" SET "emailVerified" = true …` via `docker exec`.
- Org membership is a manual SQL insert on first run.
- 8585 proxy auth is weak; firewall it.
- Helm/enterprise chart is sales-gated (`enterprise@helicone.ai`).

**Does it fight LiteLLM / the Governor?**

| Mode | Conflict? |
|---|---|
| **Helicone AI Gateway as `baseURL`** | **YES. Do not do this.** Duplicate routing, fallbacks, retries, rate limits. Governor would no longer see true spend/shape; LiteLLM would be bypassed or double-wrapped. Self-host Jawn *cannot* even proxy anymore without a separate gateway binary. |
| **Async OpenLLMetry** (`pip install helicone-async` / `npm i @helicone/async`) | **No.** Off critical path. Does not route. |
| **LiteLLM callback** (`litellm.success_callback = ["helicone"]` or `HELICONE_API_BASE` pointing at self-host) | **No.** LiteLLM still calls LM Studio / providers; Governor still meters; Helicone only records. This is the only mode that fits Baton. |

Point the callback at the self-host Jawn, not `https://api.helicone.ai`, if staying $0 and private.

### Verdict
**ADD later, async-only, and only once LiteLLM is the real hop for local+cloud calls.** Do not stand the ClickHouse pile up now just to have a dashboard. Never put Helicone in front of the fleet.

---

## 7. `disler/claude-code-hooks-multi-agent-observability`

https://github.com/disler/claude-code-hooks-multi-agent-observability

### What it actually is
IndyDevDan’s **Claude Code hook → HTTP POST → Bun/SQLite → Vue 3 WebSocket timeline**. Captures all 12 Claude Code hook events (Pre/PostToolUse, SubagentStart/Stop, PermissionRequest, SessionStart/End, PreCompact, …). Multi-session swim lanes, live pulse chart, optional LLM summarization of events.

Data flow: `Claude Agents → hook scripts (uv/Python) → POST /events → Bun → SQLite WAL → WS → Vue :5173`.

### Facts
| | |
|---|---|
| Language | Python (hooks) + TypeScript (Bun server, Vue client) |
| License | **none** (no LICENSE file) — treat as “ask before adopting code” |
| Stars | **1,533** |
| Last push | **2026-02-08** (~7 months stale) |
| Maintainer | **Single:** `disler` (16 commits) |
| Forks | 385 (popular tutorial, thin commit history) |

### Slot
**Slot 2, Claude Code only, as shipped.** Excellent *tool-call* debugger for CC swarms. Not a coordination board (no queue/assignee/Needs-You over GitHub).

### Fleet-aware? Generalize to Grok / Codex / local workers?

**As a product: no.** Hooks are Claude Code’s `settings.json` contract. Codex/Grok/LM Studio do not fire those events.

**As a pattern: yes.** The payload is a JSON POST:

```bash
curl -X POST http://localhost:4000/events \
  -H "Content-Type: application/json" \
  -d '{"source_app":"test","session_id":"test-123","hook_event_type":"PreToolUse","payload":{"tool_name":"Bash"}}'
```

Anything Baton/Grok/Codex/local can POST that shape to. Generalizing means **writing emitters**, not installing this repo on the 4090 box and expecting traces.

Multi-machine: several Claude Code checkouts can POST to one server if they can reach `:4000` (Tailscale). Still Claude-only until emitters exist.

### $0 self-host?
**Yes for the core.**

```bash
git clone https://github.com/disler/claude-code-hooks-multi-agent-observability.git
cd claude-code-hooks-multi-agent-observability
just install && just start
# server :4000  client :5173
cp -R .claude /path/to/project/   # then set source-app in settings.json
```

**Optional paid (not required for traces):** `ANTHROPIC_API_KEY` (event `--summarize`), `OPENAI_API_KEY`, `ELEVENLABS_API_KEY` (TTS), `FIRECRAWL_API_KEY`. Bun + SQLite on disk; no Postgres/Supabase.

### Verdict
**STUDY-ONLY.** Steal `send_event.py` + the 12-event taxonomy if Baton ever grows a harness-agnostic event bus. Do not make this *the* slot-2 install — it is Claude-only, unlicensed, and 7 months stale. Baton already has Superpowers/Ringer hooks on the Claude side; copying this wholesale would duplicate that.

---

## Cross-cutting answers

### 1. Does any of these kill the GitHub Projects table-view plan?

**No. Keep GitHub Issues/Projects as SoR and write the ~200-line table view.**

Reasons, bluntly:

- **AO** is the only board that looks like the plan (Needs you / Working / In review / Ready to merge, per-card agent). Its SoR is `~/.ao` SQLite. Issue mirroring is explicitly **not shipped** (`STATUS.md` #112). It cannot represent “this ticket is on the 5090 via LM Studio at tier local-cheap.”
- **Session-pilot / Squan / AMC / Helicone / disler** are cockpits, runtimes, or tracers. They complement a queue; they are not a queue over GitHub.
- **`burrthemenace/devboardAI`** is unrelated intern code.
- Kevin already decided `devboardai.com` is UX study, not infra. Nothing here is a better SoR than Issues for a mesh of mixed harnesses + local model servers.

Complement, don’t replace: AO/session-pilot/AMC inform **column UX**; Helicone/disler inform **trace UX**.

### 2. Best slot-1 pick if Kevin wants a real UI instead of a raw Projects board — worth it vs 200 lines?

**Best UI in the set: Agent Orchestrator.**  
**Worth replacing 200 lines? No.**  
**Worth studying for 2 hours? Yes.**

| If the board must… | AO | 200-line Projects view |
|---|---|---|
| Be the SoR for mixed Claude/Codex/Grok **and** LM Studio/OpenClaw workers | No | **Yes** (you define columns) |
| Honor Governor / learned router / model tier | No | **Yes** |
| Spawn Claude/Codex/Grok into worktrees and bounce CI back to the owner | **Yes** (best in class) | No (out of scope) |
| Run $0 on the Mini today | Yes (desktop) | Yes (`gh` + a thin HTML/table) |
| Stay ~200 lines in Baton | No (Go daemon + Electron is a product) | **Yes** |

Install AO **as a UX study** (same bucket as the $24 Mac app), screenshot the Kanban, then encode those columns onto GitHub Projects. Only ADD AO as a *launcher* later if the pain is “babysitting Claude/Codex/Grok TUIs,” which is a different slot than “who has which ticket.”

Session-pilot is the wrong slot-1 substitute (it’s a diary). Squan is a wrong-runtime substitute.

### 3. Best slot-2 pick: $0 self-host, fleet-wide, no gateway fight

**There is no perfect fit.** Closest *product* vs closest *pattern*:

**Product (LLM HTTP spend/latency, fleet-wide if LiteLLM is the hop):**  
**Helicone self-host + LiteLLM success callback / OpenLLMetry async.** Not the gateway. This is the only item that can see Mini + 4090 + 5090 + 2070S **as model endpoints** without stealing routing from the Governor.

**Pattern (tool-call traces per coding agent):**  
**disler’s POST `/events` bus**, with Baton-written emitters from Claude hooks, Codex, Grok, and local workers. The Vue app is optional; SQLite+WS is the idea. Session-pilot is the better *reader* for Claude/Codex/Gemini JSONL already on disk (post-hoc, not live).

What does **not** satisfy the constraint:

- Helicone **gateway** — fights Governor.
- disler **as installed** — Claude-only.
- AMC — Copilot-only.
- Session-pilot — not live traces; Postgres; stale; no LM Studio.
- AO — refuses to intercept provider HTTP.

### 4. Combined recommendation — stand up vs skip

**Stand up now**
1. **Keep / build the 200-line GitHub Projects table view.** None of these replace it.
2. **Optional 30-minute AO desktop install on the Mini** as UX study only (same class as `devboardai.com`). Do not point the fleet at it. Do not make `~/.ao` the SoR.

```text
# AO UX study (Mini)
# download darwin-arm64.dmg from
# https://github.com/Untrivial-ai/agent-orchestrator/releases/latest
# open a throwaway repo, spawn one claude-code and one grok worker, screenshot Kanban
```

**Stand up later (only if a real pain shows up)**
3. **Slot 2 HTTP traces:** Helicone all-in-one **with volumes**, LiteLLM `success_callback=["helicone"]`, `HELICONE_API_BASE=http://<mini>:8585`. Firewall 8585 to Tailscale. Never change provider `baseURL` to Helicone.
4. **Slot 2 session replay (Claude/Codex/Gemini on the Mini):** session-pilot Docker *if* Kevin actually misses “what happened last Tuesday.” Budget Postgres.

**Do not stand up**
- `tarvitave/squan` — competing runtime, 7 stars, stale.
- `burrthemenace/devboardAI` — intern Firebase app, unrelated to the $24 product.
- `DanWahlin/agent-mission-control` as infra — Copilot HUD; screenshot only.
- `disler/...observability` as the fleet dashboard — Claude-only, no license, stale. Copy the event schema if Baton grows emitters.
- Helicone **gateway** / hosted Helicone — duplicate router + data leaves the mesh.
- AO **cloud** / design-partner — paid, private submodule, still not LM Studio.

**If Baton grows dashboards in-tree (fits the “5–6k Python adopts tools” doctrine)**  
- Slot 1: GitHub Projects GraphQL → one HTML table (the 200 lines).  
- Slot 2: append JSONL events from the Governor (already sees tokens/latency per call) + optional `POST` from harness hooks; render with something tiny (or Ringside). That beats adopting ClickHouse or an Electron daemon.

---

## Install cheat-sheet (copy-paste)

```bash
# --- AO (UX study, Mini) ---
# https://github.com/Untrivial-ai/agent-orchestrator/releases/latest

# --- session-pilot (only if you want session replay) ---
git clone https://github.com/web-werkstatt/session-pilot.git
cd session-pilot && cp .env.example .env && docker compose up -d
# http://localhost:5055   needs Postgres (compose provides it)

# --- Helicone async sidecar (later; NOT gateway) ---
docker pull helicone/helicone-all-in-one:latest
docker run -d --name helicone \
  -p 3000:3000 -p 8585:8585 -p 9080:9080 \
  -v helicone-postgres:/var/lib/postgresql/data \
  -v helicone-clickhouse:/var/lib/clickhouse \
  -v helicone-minio:/data \
  helicone/helicone-all-in-one:latest
# then in LiteLLM: litellm.success_callback = ["helicone"]
# HELICONE_API_BASE=http://<mini-tailscale>:8585
# do NOT set OpenAI baseURL to Helicone

# --- disler (pattern only) ---
git clone https://github.com/disler/claude-code-hooks-multi-agent-observability.git
cd claude-code-hooks-multi-agent-observability && just start
# POST http://localhost:4000/events
```

---

## One-line each

- **session-pilot** — STUDY: local Claude/Codex/Gemini cockpit + cost; Postgres; stale; not the queue.  
- **squan** — SKIP: own agent runtime pretending to be a board.  
- **agent-mission-control** — STUDY: beautiful Copilot-only HUD.  
- **agent-orchestrator** — STUDY (best slot-1 UI); local multi-harness, not Tailscale/LM Studio; don’t replace Projects.  
- **burrthemenace/devboardAI** — SKIP: intern Firebase homework, not the $24 app.  
- **helicone** — ADD later, **async/LiteLLM callback only**; gateway fights the Governor.  
- **disler observability** — STUDY: Claude hook event bus; generalize the POST, don’t install as fleet obs.
