# Baton stack decision — consolidated, 2026-09-08

**Three independent passes, merged:**
- **GLM 5.3 Flash** — text-only synthesis from training knowledge ($0.003). Raw: `baton-stack-glm-2026-09-08.md`.
- **grok-4.6 (high), Job A** — live web research, ~30 harness/orchestrator repos, same-day GitHub star/commit counts. Raw: `baton-stack-grokA-2026-09-08.md`.
- **grok-4.6 (high), Job B** — live web research, ~30 memory/validation/converter/PII repos. Raw: `baton-stack-grokB-2026-09-08.md`.
- Plus ~12 Claude WebFetch spot-checks.

**How grok was run** (the fix): `grok -p` forces a single model turn, so it can't research. Bare `grok` needs a TTY. Solution — drive it through **Herdr**:
`herdr pane split/workspace create → herdr agent start <name> --kind grok --pane <id> → herdr agent prompt <name> "<brief… write report to /path.md>" --wait → read the file`.
This works for any of Herdr's 22 agent kinds and is itself a finding (see §7).

**Grok's passes were materially better than GLM's** — correct current star counts, license flags (Marker weights = OpenRAIL-M >$5M; harness-mem = BUSL; KunAgent = PolyForm Noncommercial), org-transition watch items (Presidio moved Microsoft→data-privacy-stack), and it caught a star-farmed repo (ECC's "254k stars"). Where they disagree, grok wins unless noted.

---

## 1. What every pass agrees on (high confidence)

| | Verdict |
|---|---|
| **Learned local-fleet router** (benchmark Firefly/wraith2, route on measured per-task score) | **KEEP-BUILD.** Nothing else does it. The reason Baton exists. |
| **Governor** (hard spend caps, 5-hr windows, `:11` anchor, conserve mode, dispatch gating) | **KEEP-BUILD.** quota-axi *reports*; it does not *enforce*. |
| **Grimdex** (git-backed, model-agnostic decision/lessons KB) | **KEEP-BUILD.** No candidate is a git-backed decision ledger with promotion rules. |
| **Herdr** as the terminal substrate / multiplexer | **KEEP.** 36.7k★. Do not add a second mux (agent-deck, AgentsMesh, octoally, Claude Squad all → SKIP). |
| **Run multiple workers, always** — Claude Code + Codex + Grok + OpenCode/OpenRouter + LM Studio locals | **Required.** "One harness is an assistant; the factory is a router." A single-harness shop kills the cost bet. |
| **Archon** (23.4k★, TS/Bun YAML workflow engine: phases, bash gates, human-approval loops, worktrees) | **REPLACE** Baton's PowerShell phase/job DAG. *But* the SDLC workflow pack (`archon-ship`/`archon-lifecycle`/…) lives on branch `cleanup/sdlc-workflows-only` and **is not merged upstream** — pin or vendor it. Adopt the engine + pack, NOT the Slack/web-dashboard product. |
| **Ringer** (Python swarm verifier: cheap workers in parallel, executed `check` = exit 0, retry-once, `runs.jsonl` eval DB, Ringside HUD) | **ADD.** This *is* the "checking work is critical" layer. Feeds pass rates into Baton's router (local-fleet scores stay Baton-owned). PolyForm Shield license — pin a commit, don't rely on self-update in the factory path. |
| **no-mistakes** (git-push proxy → disposable worktree → review/test/lint → PR) | **ADD.** Pre-merge gate. *Different stage* from Ringer (worker artifact vs branch). Same author as quota-axi. |
| **Omnigent** (9.8k★ alpha meta-harness, policy engine w/ spend caps, multi-device) | **NOT the OS.** Optional ADD *later* as an interactive cockpit if you want phone/browser attach to live sessions. Telemetry on by default. Does not score local boxes. |
| **gastown** (18k★ Go: Mayor, Beads ledger, convoys, merge queue, Witness/Deacon watchdogs) | **SKIP as primary** — adopting it = becoming Gas Town (Beads replaces GitHub, tmux replaces Herdr, Mayor replaces the router). **Steal patterns:** escalation routing, merge queue, capacity governor, health watchdogs. |
| **ruflo** (71.7k★ TS, ex-claude-flow: swarms, 100+ agents, federation+PII, cost-tracker) | **ADD as a Claude Code plugin pack** — `ruflo-core` + `ruflo-swarm` + `ruflo-cost-tracker` only. NOT a second OS alongside Omnigent. Skip the 35-plugin marketplace. |
| **Superpowers** as the concept→plan→TDD methodology | **ADD (keep).** Do NOT also run spec-kit or OpenSpec — one SDD religion. |
| **Doc converters** | pdf-inspector (10–50 ms text/scanned router) → **Docling** (default: PDF/Office/HTML/EPUB/email) → **Pandoc** (already-structured / output formats). MarkItDown = shelf fallback. **Marker/MinerU = GPU-only on the 4090/5090**, not the Mac Mini path. |
| **Presidio** (local PII analyzer/anonymizer) | **ADD.** Runs after conversion, before any non-local model or cloud memory sees the text. Fail-closed for tax/medical/real-email. |
| **Token tracking** | CodexBar (Mac HUD) + Win-CodexBar (Windows boxes) + ccusage (Claude CLI) = **human dashboards, keep**. **quota-axi** = the machine probe the Governor reads. Governor still enforces. |
| **Agent nav tools** | **ADD:** `cocoindex-code` (AST code search, ~70% token saving), `Ix` (`ix map/explain/trace/impact` structural graph), `archify` (typed-IR → deterministic architecture/sequence diagrams for concept docs). |
| **`projectmem`** (799★ MIT, local MCP: records attempts/fixes, warns before repeating a failed approach) | **ADD.** This is Baton `/remember`+`/recall` as a maintained tool. |
| **coleam00/ai-software-factory** (GitHub-issue-in → gated-PR-out, `tick` scheduler, all steps = Archon workflows) | **ADD** as the overnight/dark-factory loop — once Archon's SDLC pack is pinned. |

**SKIP (noise / redundant / license / immature):** KunAgent/Kun (PolyForm Noncommercial), affaan-m/ECC (star-farm), Citadel *as an OS* (but copy its Request/Run/Evidence/**Needs You**/Resume state machine), agent-deck / AgentsMesh / octoally (Herdr covers), Evener/serf / pi / command-code / oh-my-pi (more workers — you don't need a 7th), block/buzz (agent comms bus, not the bottleneck), spec-kit / OpenSpec (one SDD only), letta / letta-code / letta-obsidian (wrong layer — a harness, not a KB), supermemory / agentmemory / OB1 / hindsight (crowded, cloud-shaped), hound (seeking a maintainer), harness-mem (BUSL-1.1), sharedcontext / cachezero (stalled), Understand-Anything / code-review-graph (second graph-UI tax), Forward-Future/loopy, LMCache (until locals move to vLLM), superfile, honestsoul/generative_ai_project.

**New candidates grok surfaced (evaluate, not urgent):**
- **Untrivial/agent-orchestrator** (11k★ Go, ex-Composio) — the strongest *open* Devboard-style fleet IDE. The GUI option if you refuse Omnigent and want more than GitHub Projects.
- **builderz-labs/mission-control** (6k★ TS) — self-hosted control plane that operates **OpenClaw + Claude Code + Codex** and tracks spend. Best off-the-shelf cockpit *for your Omarchy/Hermes/OpenClaw boxes*.
- **HarnessRouter** (661★, "Unified Harness Protocol") — one API in front of Codex/Claude/Hermes/Pi. A later adapter for Baton's thin runner, not a blocker.
- **NVIDIA-NeMo/Switchyard** (2.8k★) — OpenAI/Anthropic-compat model-router proxy. Optional Governor sibling *in front of token APIs only*; does not dispatch CLIs or score local boxes.

---

## 2. Where the passes genuinely disagree — you decide

| # | Fork | grok A | grok B | GLM | Lean |
|---|---|---|---|---|---|
| 1 | **Lead orchestrator** | Claude Code for plan/review | **Grok Build** lead (token discipline, paid plan), Opus only for viability debate / hard review | Claude Code primary | **Grok Build lead** — matches your stated "Grok is lead"; Opus as consultant only. |
| 2 | **Does Baton keep a `go` / Conductor front door?** | Yes — `baton go` stays as "describe an outcome"; Archon replaces the DAG underneath | (n/a) | Yes | **Keep `baton go`** as the thin front door; Archon is the engine beneath it. |
| 3 | **caura — adopt the service now?** | (n/a) | Stack A includes it; own "next actions" say **defer** until an OpenWiki-visualizer spike proves the UI isn't enough | Cherry-pick UI only | **Defer.** Spike OpenWiki first; adopt caura only if you still want the dashboard. |
| 4 | **GUI beyond GitHub Projects?** | agent-orchestrator or mission-control if you want one; else GitHub + Herdr is enough | — | octoally/agent-deck (both SKIP) | **Build the GitHub Projects table** (~200 lines: task × assigned LLM × queue depth × parked-on-human). devboardai ($24) + mission-control as UX references. |
| 5 | **Omnigent ever?** | Optional later cockpit | — | Pilot a week | **Park it.** Not load-bearing. Re-evaluate after the core ships one PR. |

---

## 3. Recommended stack (the convergence)

```
COORDINATION   GitHub Issues + Projects  (system of record)
                 └ Baton projects a table view: task | LLM | queue | PARKED-ON-HUMAN | failed
                 └ steal Citadel's Request/Run/Evidence/Needs-You/Resume states
                 (UX refs only: devboardai $24, builderz/mission-control for the OpenClaw boxes)

FRONT DOOR     `baton go "<outcome>"`  →  Superpowers concept→plan  →  human review

ORCHESTRATOR   Grok Build (lead)  ·  Opus only for viability debate + load-bearing review

WORKFLOW DAG   Archon YAML workflows (pin cleanup/sdlc-workflows-only)
                 └ overnight: coleam00/ai-software-factory `tick`

CREW / SUBSTRATE   Herdr — one workspace per worker (your preference)
                     driver: workspace create → agent start --kind <k> → agent prompt --wait → read file
                     workers: Claude Code · Codex · Grok · OpenCode/OpenRouter · LM Studio locals

VERIFICATION   Ringer (swarm: exit-0 is truth, Ringside HUD, feeds router)
                 → no-mistakes (pre-merge gate)
                 → deepsec (security lane, --max-cost-usd, not default CI)
                 → frontier review on load-bearing diffs

ROUTING/COST   Baton router (learned local-fleet scores)  ← KEEP-BUILD
                 Baton Governor (enforce caps/windows)     ← KEEP-BUILD
                 reads quota-axi  ·  LiteLLM = provider plumbing + key vault (fixes the leaked key)
                 CodexBar / Win-CodexBar / ccusage = human HUDs

MEMORY         Grimdex (canonical decisions/lessons)                    ← KEEP-BUILD
                 Grimlore  = the wiki shape (GRIMLORE.md / OKF v0.2)
                   written & claims-checked by  OpenWiki  (--update in CI, telemetry off)
                 projectmem = local "this fix already failed" precheck
                 (later, optional) caura self-hosted = fleet recall + dashboard
                 tools: cocoindex-code (AST search) · Ix (structural map) · archify (diagrams)

DOCS + PII     pdf-inspector → Docling → Pandoc   (Marker/MinerU = GPU-only on 4090/5090)
                 → Presidio (local) anonymize before any non-local egress
```

**Plugin/skill packs (cheap ADDs on the workers):** `wshobson/agents`, `coleam00/skills` (PIV/worktree meta-skills), `ruflo-core`+`swarm`+`cost-tracker`.

### The Baton that remains (~5–6k, per the 2026-09-07 audit)
Thin runner (argv/engine templates per worker + Tailscale LM Studio endpoints) · the learned router · the Governor · the Grimdex loop · the GitHub Projects projection. **Everything else is DROP or ADOPT.** Use `prime-radiant-inc/greenfield` the day the pwsh tree is cut, to generate the spec of "what Baton must still do."

---

## 4. Sequencing (unchanged from the audit — all passes agree)

1. **This week (hours):** claude-code-router + Claude Code subagent model-tiering; measure the window relief. Buy devboardai ($24), use it a day for the UX.
2. **Weeks 1–2:** Herdr + the `workspace/agent` driver + Ringer on ONE real project. Prove one PR ships end-to-end: cheap workers implement, executed checks gate, a premium model reviews.
3. **Weeks 3–4:** add Archon for the DAG (pin the SDLC branch) *or* keep a ~300-line Baton conductor — decide from step 2's pain. Port the learned router. Spike OpenWiki as the Grimlore engine. **Freeze `scripts/`.**
4. **Week 5+:** overnight loop (`ai-software-factory` tick). Decide caura. Re-evaluate Omnigent.

---

## 5. Risks (merged)

1. **Adoption-mania on one-maintainer / in-flux tools.** Ringer, no-mistakes, quota-axi, gnhf, firstmate are solo repos; Archon just rewrote itself and its factory pack isn't merged; ruflo churns. **Mitigation:** pin exact commits, vendor the small ones, cap the bet — if any two stall, Baton-core absorbs that layer.
2. **Two things want to own "run the phases"** — Archon's DAG and any crew loop. Decide which is subordinate before week 3.
3. **Losing the differentiator while assembling.** The pull of devboard dashboards / ruflo swarms / caura graphs is toward a pretty cockpit — the exact ambition that made Baton unfinishable. **Rule:** no new UI / harness / memory system until the router + Governor + Grimdex loop run one real PR on adopted plumbing.
4. **grok is not a viable *headless* fleet member without Herdr.** `grok -p` = one turn; bare grok needs a TTY. The Herdr `agent` path works — but any plan that routes real work to headless grok *outside Herdr* silently no-ops.
5. **The leaked OpenRouter key** — still `ps`-visible in Cursor Helper's env on the Mac. **Rotate it.** Then move keys behind LiteLLM so no agent process holds one.
6. **License footguns:** KunAgent (PolyForm Noncommercial), harness-mem (BUSL-1.1), Marker weights (OpenRAIL-M >$5M), Ringer (PolyForm Shield — can't ship a competing hosted Ringside). All fine for personal use; flagged so a future "productize" decision doesn't trip.

---

## 6. Punch list — still needs you

- [ ] **Confirm Grok Build as lead orchestrator** (Opus consultant only). *(Fork #1)*
- [ ] **Keep `baton go` as the front door** with Archon underneath — yes? *(Fork #2)*
- [ ] **Adopt Archon now** (pin `cleanup/sdlc-workflows-only`) vs keep a thin Baton conductor for another cycle.
- [ ] **Defer caura** until the OpenWiki spike — agree?
- [ ] **Build the GitHub Projects table view** as the coordination surface (not gastown, not a GUI app) — agree?
- [ ] **Is the learned-local-fleet router worth the rewrite**, or is "LiteLLM: prefer GLM, fall back to Opus" + measured spot-checks enough for now?
- [ ] Buy devboardai ($24) as a UX reference — yes/no.
- [ ] **Rotate the OpenRouter key** — when.

---

## 7. Bonus finding — Herdr *is* Baton's crew layer

The driver that made grok work headless —
`herdr workspace create → herdr agent start <name> --kind <k> --pane <id> → herdr agent prompt <name> "…write report to FILE" --wait → read FILE` —
is a working, headless dispatcher for **all 22 agent kinds Herdr knows** (`claude codex gemini grok hermes agy cursor kiro copilot kimi opencode droid amp …`), each in its own workspace, with lifecycle states (`idle/working/blocked/done`) and output capture over the socket API.

That is exactly what `fleet-executor-lib` (2,512 LOC of flaky PowerShell) tries to do. **Strong signal for the stack decision: Herdr's `agent` API replaces Baton's crew-dispatch layer outright** — Baton keeps only the routing *policy* (which kind, which model, cost gate) and calls Herdr to execute.

*Tonight's fleet spend: GLM ~$0.003; grok — 3 jobs on grok-4.6-high (probe ~87k tokens; A+B larger), against your Grok Build plan quota.*
