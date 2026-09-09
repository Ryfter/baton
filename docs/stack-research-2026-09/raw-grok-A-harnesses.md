# Job A — Coding harnesses / orchestrators / meta-harnesses

**Date:** 2026-09-08
**Scope:** Baton stack decision — what to adopt vs keep-build vs skip.
**Method:** One fetch per repo (GitHub page or API About). Deep-dive READMEs for the six starred items; About/description only for the rest. Star counts from `api.github.com` the same day.

**Irreducible Baton (do not give away):**
1. Cost-optimal routing that **learns from measured benchmarks of the private local fleet** (LM Studio boxes Firefly, wraith2, …) with frontier fallback.
2. Grimdex + Grimlore (model-agnostic, GitHub-backed operating memory).

Everything else in the ~60k-LOC PowerShell factory is a candidate to collapse.

---

## Answers to the five key questions

### 1. Primary coding harness / runtime — Omnigent vs Baton-thin-on-Herdr

**Pick: Baton as a thin runner on Herdr. Do not make Omnigent the primary OS.**

Head-to-head:

| | Omnigent | Baton-thin-on-Herdr |
|---|---|---|
| What it is | Alpha Python meta-harness: one session layer over Claude Code, Codex, Cursor, OpenCode, Hermes, Pi, Grok Build, Devin; phone/desktop collab; policies; cloud sandboxes | Keep native worker CLIs. Herdr (already in use) is the mux. Baton is router + KB + Governor that *spawns* those CLIs |
| Stars / maturity | 9,790 ★, Apache-2.0, **explicit alpha badge**, 1,314 open issues, created 2026-06-11 | Herdr is already running on the fleet. Baton core is the thing being shrunk to ~5–6k LOC |
| Local-fleet routing | Any-model credentials (API / subscription / gateway / Ollama). **No measured local-box quality routing** | This is Baton's unique bet |
| GitHub Projects as board | Own sessions UI, not GitHub Projects | Baton keeps GitHub as the coordination substrate |
| Risk of adopting as OS | Swallows identity into someone else's alpha runtime; telemetry on by default; desktop/phone product is a different job than "dark factory" | Lowest lock-in. Worker CLIs stay swappable. Herdr already owned |

Omnigent is a **cockpit for interactive multi-harness sessions**, not a cost-learning factory. Polly (their example orchestrator) is closer, but it is an example agent inside Omnigent, not the product. Using Omnigent as primary would re-implement Baton *inside* an alpha framework that does not benchmark Firefly/wraith2.

**Primary coding *worker* to standardize on:** **Claude Code** for plan/review (and for Archon YAML nodes). **Always run more than one worker:** Codex + Grok Build as cheap implementers, OpenCode/OpenRouter as the universal cheap lane, LM Studio locals via Baton's router. That split *is* the factory. A single-harness shop (Omnigent-only, or Claude-only) kills the cost bet.

### 2. Is ruflo worth adding as the swarm layer?

**ADD, but as a Claude Code plugin — not as a second OS.** Do not run ruflo *and* Omnigent as competing meta-harnesses.

Ruflo (71,687 ★, MIT, formerly Claude Flow) is a Claude Code / Codex **nervous system**: 100+ agents, swarm topologies, vector memory, 35 plugins, MCP, federation, cost-tracker plugin, claimed “smart routing.” Kevin asked to pull it in; standalone is fine. It overlaps Omnigent on the *word* “meta-harness” but not the job: Omnigent = session runtime over many CLIs; ruflo = plugin/MCP/swarm layer *inside* Claude Code.

It does **not** replace Baton's local-fleet measured routing. Its routing is agent/task routing plus multi-provider failover, not “cheapest model that passed this task type on Firefly.” Kitchen-sink risk is real (314 MCP tools advertised, 955 open issues, one-maintainer-shaped). Install `ruflo-core` + `ruflo-swarm` + `ruflo-cost-tracker` only; skip the neural-trader / IoT / arena plugins.

### 3. Does Archon's YAML-DAG replace Baton's PowerShell phase/job glue?

**Yes — REPLACE the pwsh phase/job DAG with Archon workflows. Do not adopt Archon as the whole factory OS.**

Archon (23,406 ★, MIT, TypeScript/Bun) is “Dockerfiles for AI coding”: YAML workflows with AI nodes, bash gates, human-approval loops, isolated git worktrees, 19 bundled SDLC workflows (`archon-ship`, `archon-lifecycle`, `archon-verify-runtime`, …). That is exactly the homemade PowerShell glue. Companion `ai-software-factory` (199 ★, brand-new 2026-09-01) is the overnight loop: GitHub issue in → gated merge out, scheduled `tick`.

Caveats (maturity): Python v1 is archived (`archive/v1-task-management-rag`); current default branch is `dev`; factory's SDLC pack still lives on `cleanup/sdlc-workflows-only` and **is not merged upstream yet**; default assistant is Claude Code (Codex and Pi are supported). Worth adopting *the workflow engine + SDLC pack*, not the Slack/Telegram/web-dashboard product, until that pack lands on main.

### 4. Does anything already do GitHub Projects + LLM-task table + park-for-human?

**No. KEEP-BUILD that substrate.** Closest cousins, none of which are GitHub Projects:

- **DevboardAI** — the UX Kevin pointed at. Local Kanban (Backlog / In Progress / QA / Done / Failed), Value Mode (Haiku vs Opus), worktrees, retry. **Mac-only, $24 closed-source, not GitHub.** Use as the *picture* of the board, not the board.
- **Gas Town** — closest *factory analog* (Mayor, rigs, convoys, dashboard, park via escalation). Work lives in **Beads**, not GitHub Projects.
- **Untrivial `agent-orchestrator`** (ex-ComposioHQ, 11,113 ★) — fleet IDE: plan, spawn, CI fixes, merge conflicts, reviews. Own UI.
- **builderz mission-control** (6,194 ★) — self-hosted control plane: dispatch, review, **track spend**, OpenClaw + Claude Code + Codex. Own UI. Relevant because Kevin already runs OpenClaw/Hermes on Omarchy boxes.

Baton should keep GitHub Issues/Projects as the system of record and *project* a table view (which LLM, queue depth, parked-on-human) onto it. Do not switch the ledger to Beads or a local Kanban.

### 5. Maturity / maintainer risk (deep-dive picks)

| Pick | Stars | Risk |
|---|---:|---|
| **omnigent-ai/omnigent** | 9,790 | **Alpha** (badge). 1,314 open issues. Created Jun 2026. Productizing desktop/phone/collab. Telemetry on by default. Do not bet the factory on it. |
| **coleam00/Archon** | 23,406 | **Recently rewritten** Python→TypeScript. Default branch `dev`. v1 archived. SDLC factory pack not merged. Cole Medek is a known builder; community is large; treat as 1.0-in-progress. |
| **ruvnet/ruflo** | 71,687 | **One-maintainer kitchen sink** (rUv). 7,417 commits, 955 issues, formerly claude-flow. High visibility, high surface area. Plugin-subset adoption is the safe mode. |
| **gastownhall/gastown** | 17,975 | **Steve Yegge / Beads stack.** 7,770 commits, Go, heavy original ontology (Mayor/Polecats/Rigs/Witness/Deacon). Created Dec 2025, moving fast. Adopting = converting Baton into Gas Town, not shrinking Baton. |
| **prime-radiant-inc/serf** | 132 | **Renamed to `evener`.** GitHub redirects. Fork of Kilroy. 13,280 commits / 132 ★ is a tell (imported history, little adoption). Coding-*agent* hub, not an orchestrator of other agents. |
| **DevboardAI** | n/a (closed) | **Mac-only indie app**, $24 lifetime. Fine as UX reference. Not a substrate. No GitHub Projects, no Windows 4090/5090 boxes, no local LM Studio. |

---

## Deep-dive verdicts

### omnigent-ai/omnigent — **ADD** (cockpit only, not OS)

Open-source meta-harness: common session layer over Claude Code, Codex, Cursor, OpenCode, Hermes, Pi, Grok Build, Devin; policies; sandboxes; terminal/browser/phone/macOS desktop. 9,790 ★, Apache-2.0, Python, **alpha**, 3,453 commits, 1,314 open issues. **Do not REPLACE Baton with it.** Optional ADD later if Kevin wants one interactive UI that can attach to a live Claude *and* a live Codex session from a phone — that is a cockpit, not the factory. Does not learn local-fleet scores.

### coleam00/Archon — **REPLACE** (PowerShell phase/job DAG + worktree runner)

YAML workflow engine for AI coding: deterministic phases, bash validation gates, human-approval loops, isolated worktrees, 19 bundled SDLC workflows, CLI + web builder. 23,406 ★, MIT, TypeScript/Bun, default branch `dev`, Python v1 archived. **This is the replacement for Baton's homemade phase glue.** Adopt workflows + `archon-ship` / `archon-lifecycle`; do not move the ledger off GitHub or throw away the Governor.

### ruvnet/ruflo — **ADD** (Claude Code swarm/memory plugins)

Agent meta-harness around Claude Code/Codex: swarms, 100+ agents, HNSW memory, federation, cost tracker, multi-provider. 71,687 ★, MIT, TypeScript, formerly Claude Flow. **ADD as a plugin pack on Claude workers**, standalone as Kevin asked. Not the primary runtime. Overlaps Omnigent in marketing, not in layer. Do not also install the full 35-plugin marketplace.

### gastownhall/gastown — **SKIP** as primary; **ADD** only as a studied analog

Multi-agent workspace manager: Town → Rigs (projects) → Polecats (workers) + Mayor coordinator; git-backed hooks; Beads ledger; tmux; convoy tracking; Witness/Deacon health; Refinery merge queue; web dashboard. 17,975 ★, MIT, Go, 7,770 commits. Kevin is right that it is a **direct analog** to Baton — which is why adopting it *replaces Baton wholesale* (Beads instead of GitHub Projects, tmux instead of Herdr, Mayor instead of Baton router). Steal patterns (escalation, merge queue, capacity governor). Do not migrate the factory onto it.

### prime-radiant-inc/serf → **evener** — **SKIP**

`/serf` redirects to `prime-radiant-inc/evener`: a Go coding agent with `evener hub` web UI and TUI, native tool-calling across OpenAI/Anthropic/Google/Ollama. 132 ★, MIT, 13k commits (Kilroy fork history). This is **another worker CLI**, not a boiled-down Baton. Kevin already has Claude Code, Codex, Grok, Copilot, Cursor, Kiro. Adding Evener as “the” harness duplicates workers and still leaves routing/KB unsolved.

### DevboardAI (devboardai.com/#orchestrator) — **SKIP** as substrate; **ADD** as UX reference

Local-first macOS Kanban orchestrator: NL → sprint → parallel Claude Code / Codex / Kimi in worktrees, Value Mode (Haiku vs Opus), retry with QA, five columns including Failed. $24 once, 7-day trial, Mac-only. **This is the board Kevin described**, except it is not GitHub, not multi-OS, not local-fleet, not Copilot/Grok/Gemini/Cursor. Copy the columns and the “which model is on this card” table into Baton's GitHub Projects view. Do not buy it as the factory.

---

## Quick-classify verdicts

### coleam00/ai-software-factory — **ADD** (overnight loop on top of Archon)

GitHub-issue-in / gated-PR-out dark factory. 199 ★, created 2026-09-01, 167 commits. All AI steps are Archon SDLC workflows; this repo is installer + `MISSION.md` + holdout + `tick` scheduler. **ADD as the overnight loop** once Archon's SDLC pack is pinned. Not a harness. Status: pack not merged upstream; they tell you to watch one issue before enabling the schedule.

### coleam00/skills — **ADD** (PIV / worktree / meta-skills)

“The agent skills I actually use”: PIV loop, planning, worktrees, AI-layer meta-skills. 492 ★, MIT, Python, Aug 2026. Feeds Archon (`archon-piv-loop` exists). Cheap ADD into worker skill dirs. Overlaps obra/superpowers on concept→plan; keep both if they don't collide.

### coleam00/adversarial-dev — **ADD** (quality gate pattern)

GAN-inspired generator vs adversarial evaluator, Claude Agent SDK + Codex SDK. 131 ★, last push the day it was created (2026-03-29) — **immature**. The *pattern* is already an Archon bundled workflow (`archon-adversarial-dev`). Steal the idea; don't vendor the repo.

### affaan-m/ECC — **SKIP**

“Harness performance optimization” (skills, instincts, memory, security) for Claude Code/Codex/OpenCode/Cursor. **254,343 ★ / 38k forks on a Jan 2026 repo is not a credible popularity signal** (star-farm shape). Don't let the number drive adoption. Revisit only if a trusted eval shows real harness gains.

### ai-genius-automations/octoally — **SKIP**

Claude Code session dashboard. 100 ★, last push Jul 2026. Redundant with Herdr + GitHub + (optionally) Omnigent/mission-control.

### CommandCodeAI/command-code — **SKIP**

“Best coding agent for open models.” 3,899 ★, language null, 272 open issues, created 2017 (repurposed org). Another worker CLI. Don't add a seventh coding agent.

### can1357/oh-my-pi — **SKIP** as primary worker

Coding agent with the IDE wired in (pi-family). 30,212 ★, MIT, TypeScript, **2,520 open issues**. Popular TUI/IDE hybrid. Not the factory. Don't standardize on it.

### HarnessRouter/harnessrouter — **ADD** (thin adapter, later)

Self-hosted Unified Harness Protocol: one API in front of Codex, Claude Code, Hermes, Pi, DSH. 661 ★, Apache-2.0, Python, created Aug 2026. This is the *interface* Baton's thin runner might speak instead of N argv templates. Young. Watch; don't block on it.

### NVIDIA-NeMo/Switchyard — **ADD** (model-router sidecar, not agent-router)

OpenAI/Anthropic-compatible proxy that routes across models/providers for cost/perf. 2,784 ★, Apache-2.0, NVIDIA. Useful in front of **token APIs**. Does **not** dispatch coding-agent CLIs and does **not** score LM Studio boxes. Optional Governor sibling, not a harness.

### Factory-AI/factory — **SKIP**

Commercial “Agent-Native Software Development.” 16 ★, no license, language null. Not a usable OSS factory.

### earendil-works/pi — **SKIP** as primary; optional cheap worker

Mario Zechner's AI agent toolkit (LLM API + agent loop + TUI + coding CLI). **103,166 ★**, MIT. Excellent *library* others wrap (oh-my-pi, Omnigent's `pi` harness). Don't make Pi the Baton worker standard; Claude/Codex/Grok already cover that. Fine as an Omnigent/Archon backend if those tools need it.

### KunAgent/Kun — **SKIP** as OS (license + wrong layer)

Local-first GUI+TUI agent workspace (Code / Design / Work). 6,298 ★, TypeScript/Electron, **PolyForm Noncommercial 1.0.0**. Looks like “what I've been trying to build” *as a desktop product*, not as a dark factory. Noncommercial license is a footgun if any of this ever leaves personal use. Doesn't do GitHub Projects or local-fleet routing.

### KunAgent/KunUIExtend — **SKIP**

Empty stub. 0 ★, 1 byte, created and last-pushed the same day.

### Untrivial-ai/agent-orchestrator (ComposioHQ/agent-orchestrator redirects here) — **ADD** (fleet IDE candidate)

Agent IDE: plan, spawn fleets, CI fixes, merge conflicts, reviews; Claude Code + Codex + worktrees. **11,113 ★**, Apache-2.0, Go. This is the strongest *open* Devboard-like fleet UI. Still not GitHub Projects. Consider as the dashboard if Kevin wants a GUI and refuses Omnigent; otherwise GitHub + Herdr is enough.

### builderz-labs/mission-control — **ADD** (OpenClaw/Hermes control plane)

Self-hosted control plane: dispatch, review runs, **track spend**, operate **OpenClaw**, Claude Code, Codex. 6,194 ★, MIT, TypeScript. Kevin already runs Hermes+OpenClaw on two Omarchy boxes. This is the best off-the-shelf cockpit *for those boxes*. Does not replace Baton routing.

### AgentsMesh/AgentsMesh — **SKIP** (overlaps Gas Town + Herdr)

“Run a hundred AI coding agents across your own machines.” 2,343 ★, Go, other/unclear license, last push Aug 2026. Real fleet-across-machines pitch, but Gas Town is more mature and Herdr already muxes. Don't take a third factory OS.

### asheshgoplani/agent-deck — **SKIP**

TUI session manager for Claude/Gemini/OpenCode/Codex. 853 ★, Go, tmux. **Herdr already does this** (agent-state-aware multiplexer). Don't dual-mux.

### jonwiggins/optio — **SKIP**

Workflow orchestration for agent swarms, task → merged PR. 1,045 ★, TypeScript, last push Aug 2026. Redundant with Archon + factory.

### pixel-agents-hq/pixel-agents — **SKIP**

“Pixel office.” 9,213 ★, MIT. Novelty office-of-agents UX, not a factory substrate.

### block/buzz — **SKIP**

Block's “hive mind communication platform.” 32,416 ★, Rust, Apache-2.0, custom property **maturity: prototype**, 3,513 open issues. Agent comms bus. Not the coding factory. Revisit only if multi-agent chat between boxes becomes the bottleneck (it isn't yet).

### wshobson/agents — **ADD** (plugin/skill pack)

Multi-harness plugin marketplace for Claude Code, Codex, Cursor, OpenCode, Copilot, Antigravity. **39,506 ★**, MIT. Cheap ADD: install the subset that matches Kevin's worker CLIs. Not a runtime.

### Chachamaru127/claude-code-harness — **SKIP**

Claude-Code-only Plan→Work→Review cycle. 3,101 ★, Shell. Superpowers + Archon already cover this. Claude-only is the wrong constraint.

### deepseek-ai/deepseek-harness — **ADD** (optional cheap worker lane)

Official DeepSeek harness, “everything is a plugin” (DSH). **216,326 ★** (treat the count as marketing, not a quality score), MIT, TypeScript, created Aug 2026, issues/PRs disabled. If Kevin wants a first-party cheap Chinese-model worker, this is the lane; HarnessRouter already lists DSH. Not primary.

### SethGammon/Citadel — **SKIP** as OS; steal the “Needs You / Resume” states

Operating layer for Claude Code + Codex: persistent project memory, intent routing, safety hooks, cost telemetry, parallel fleets, `/do` entry point. 919 ★, MIT, 630 commits. Kevin is right that it *sounds* like Grimdex/Baton infra. Difference: Citadel is a **plugin operating layer inside one repo**, with honest-to-a-fault evals that *do not* claim savings. Baton's KB is already GitHub-backed and model-agnostic. Don't install a second operating layer. Copy the public state machine (Request / Run / Evidence / **Needs You** / Resume) onto the GitHub park-for-human column.

### prime-radiant-inc/iterative-development — **SKIP**

Claude Code methodology plugin (walking skeleton, audited sprints). 179 ★, last push Jun 2026. Overlaps Archon PIV + superpowers.

### prime-radiant-inc/engineering-notebook — **ADD** (optional journal)

Ingests Claude Code + Codex transcripts → daily summaries + web UI. 331 ★, Apache-2.0, last push Jun 2026. Nice sidecar for Grimlore; not load-bearing. Don't block the collapse on it.

### prime-radiant-inc/greenfield — **ADD** (one-shot when rewriting)

Claude Code plugin: reverse-engineer behavioral specs + test vectors from a codebase so a fresh team can reimplement. 275 ★, Apache-2.0. Useful the day Baton's 60k LOC pwsh is replaced — generate the spec of *what Baton must still do*. Not a harness.

### prime-radiant-inc/books-for-bots — **SKIP**

EPUB → navigable Markdown for LLM agents. 142 ★, Rust. Converter, not factory. Out of this slice.

### honestsoul/generative_ai_project — **SKIP**

Generic gen-AI app template. 1,047 ★. Not a harness.

### andyrewlee/awesome-agent-orchestrators — **SKIP** (index)

1,834 ★. Names already covered: Gas Town, Archon, ruflo, agent-orchestrator, optio, AgentsMesh. No new must-pull from the About.

### ai-boost/awesome-harness-engineering — **SKIP** (index)

4,070 ★. Pattern catalog (memory, MCP, permissions, evals). Useful reading later; not a pick.

---

## Stack recommendations

### Stack A — recommended (collapse Baton, don't replace it)

**Baton core (router + Grimdex/Grimlore + spend Governor) + Herdr mux + Claude Code (plan/review) + Codex/Grok/OpenCode (implement) + Archon YAML SDLC + GitHub Projects board + ruflo plugins on Claude + superpowers for concept→plan.**

- **Primary coding harness:** Claude Code (worker), dispatched by Baton, living in Herdr panes.
- **More than one worker:** yes — required. Codex + Grok Build as flat-rate implementers; OpenCode/OpenRouter as the penny lane; LM Studio locals via the router that actually measures them.
- **Harness/runtime:** Herdr (already owned). Not Omnigent.
- **Orchestrator:** Baton `go` / Conductor remains the “describe an outcome” front door; Archon workflows replace the pwsh phase DAG underneath.
- **Memory:** Grimdex + Grimlore (keep). Optional ruflo-rag-memory only inside Claude sessions, never as the system of record.
- **Validation:** Archon bash gates + existing executed-check discipline (Ringer-style: exit code is truth). Factory `MISSION.md` / holdout from ai-software-factory.
- **Overnight loop:** `ai-software-factory` `tick` once the SDLC pack is pinned — or a 40-line Baton wrapper around `archon-lifecycle`.
- **Dashboard:** GitHub Projects (Status / Roadmap / table of LLM assignment + queue + parked-on-human). Optional: mission-control on the Omarchy/OpenClaw boxes; DevboardAI as a Mac Mini toy for UX, not as the ledger.
- **Converters:** greenfield plugin the day the pwsh tree is cut down.

**Why this stack:** it is the only one that preserves the two irreducible bets, kills the SIGABRT pwsh surface, uses a maintained YAML workflow engine for the glue, and does not donate the factory to an alpha meta-OS. GitHub stays the board Kevin actually wants.

**Tradeoffs:** you still have to *build* the GitHub Projects LLM-table view (nobody ships it). Archon's SDLC pack is mid-merge. You operate N worker CLIs (that is the point, but it is ops). Ruflo can sprawl if you install more than three plugins.

### Stack B — Gas Town as the factory OS (do not pick unless Kevin wants to abandon GitHub Projects)

**Gas Town (Mayor/Rigs/Polecats/Beads/dashboard) + Claude/Codex/Copilot/Gemini workers + Baton Governor as a sidecar + Grimdex still on GitHub.**

**Why someone would pick it:** it is the most complete open analog of “dark factory across many projects,” with health watchdogs, merge queue, scheduler, and a live dashboard. 18k ★, real Go engineering.

**Why not:** Beads *is* the ledger — that fights “everything coordinated via GitHub.” Ontology tax (Mayor, Polecats, Witness, Deacon, Refinery, Wasteland) is a second career. tmux vs Herdr. Local-fleet routing still wouldn't exist; you'd bolt Baton's router on the side and now you have two orchestrators.

### Stack C — Omnigent + ruflo + Archon (maximum adoption, maximum overlap)

**Omnigent as session OS + ruflo swarm inside Claude + Archon workflows + GitHub still for issues.**

**Why someone would pick it:** one window over every CLI, including Grok Build and Devin; phone access; policies/spend caps; ruflo for swarms; Archon for DAG.

**Why not:** two meta-harnesses plus a workflow engine plus Baton is four orchestrators. Omnigent is **alpha**. Telemetry on. Does not score Firefly/wraith2. Herdr becomes redundant. Highest chance of spending the next quarter integrating other people's roadmaps.

---

## Primary-harness pick (single sentence)

**Standardize on Claude Code as the default coding worker, run it (and Codex/Grok/OpenCode/locals) under a thin Baton runner inside Herdr — not Omnigent, not Gas Town, not Evener — and REPLACE Baton's PowerShell DAG with Archon YAML workflows while KEEP-BUILDing GitHub Projects as the board and the local-fleet router as the differentiator.**

Run more than one worker: **yes, always.** One harness is an assistant. The factory is a router.

---

## What Baton still has to build (this slice)

1. **Thin runner** — argv/engine templates for Claude Code, Codex, Grok, OpenCode, Copilot, Cursor, Kiro, plus LM Studio OpenAI-compat endpoints on Tailscale names. (HarnessRouter UHP is a later adapter, not a blocker.)
2. **Governor** — spend caps, quota, which worker may run. (Switchyard optional in front of token APIs only.)
3. **GitHub Projects table** — columns: task, assigned LLM/engine, queue position, state (running / queued / **parked-on-human** / failed). DevboardAI is the mock; GitHub is the store.
4. **Archon pack pin** — wait for or vendor `cleanup/sdlc-workflows-only`; do not wait forever. One `archon-lifecycle` dogfood on a real Baton issue before enabling `tick`.
5. **Do not build:** another session mux (Herdr exists), another swarm OS (ruflo plugins), another coding agent (Evener/Pi/Command Code), another local Kanban (DevboardAI).
