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

---

## 2026-09-08 evening — deep-dives (Kun-stack run, follow-ups, devboardai)

Two more grok-4.6 passes (raws: `raw-grok-C-kun-stack-run.md`, `raw-grok-D-followups.md`),
run via the Herdr `agent` driver, each in its own workspace.

### A. The Kun stack, as an actual run

The 4 Kun tools + no-mistakes are **not a 5-deep stack** — 3 layers + 1 sibling:
`firstmate` (crew: decompose, pick model, supervise, PR) → uses `treehouse` (leases a pooled
worktree) + Herdr (the tab) + `no-mistakes` (its OWN disposable worktree: review→test→docs→
lint→origin→PR→CI). `gnhf` is a sibling overnight loop that calls **none** of the others and
opens **no PR** (you wake to a branch + `notes.md`, then push it through the gate).

`baton go "add rate-limit middleware…"` → firstmate intake (1 expensive turn, reads
`quota-axi` once, judges "1 ship task not a fan-out") → `treehouse get --lease` → `fm-spawn.sh`
→ Herdr tab → `codex exec -m gpt-5.4` medium effort → worker `git push no-mistakes` → daemon
gate → `gh pr create` → firstmate watcher wakes → you say "merge it" → `gh-axi pr merge` →
`treehouse return`. **6 human gates** (install consent · project-mode+merge-autonomy ·
dispatch tie-break · mid-task judgment · no-mistakes findings · merge); `+yolo` removes some.

**Three facts that matter:**
- **firstmate is macOS/Linux** — but Kevin has WSL on all Windows boxes and the Mac Mini is
  the primary dev box, so this is not a blocker. Windows/WSL + Omarchy boxes = LM Studio
  model servers + optional `gnhf`/worker runners over Tailscale; Mac Mini drives firstmate+Herdr.
- **quota-axi sees ZERO local models** (Claude/Codex/Cursor/Copilot/Grok/Kimi/Z.AI/Alibaba/
  OpenCode/agy only). Its `spendPriority` = subscription-forfeiture, not quality-per-dollar.
  Adopt it as-is and you route as if the 4090/5090 don't exist. Baton's router calls quota-axi
  for cloud seats, then **overlays measured local scores**.
- **firstmate = a workflow religion + bash** (76k-char `AGENTS.md`, 1,182 open issues, 3 months
  old). Pin SHAs, vendor the `bin/` scripts you call. Telemetry: `gnhf` + `no-mistakes` phone
  home by default (`GNHF_TELEMETRY=0`, `NO_MISTAKES_TELEMETRY=0`; `go install` builds clean).

**The seam:** Baton-core = Governor + learned local router + Grimdex ingest, sitting **in
front of** `fm-spawn.sh`, pre-resolving harness/model/effort and passing them in. It must NOT
fork firstmate's watcher or reimplement no-mistakes' pipeline. *"If the core is expected to
also be the crew supervisor, you'd be reimplementing firstmate and shouldn't bother adopting
it."*

### B. Follow-up verdicts

| Item | Verdict |
|---|---|
| **deepseek-harness** | SKIP — competing session-runtime+web-UI on a plugin kernel; 216k★ in 4 weeks; issues disabled. |
| **Pi / oh-my-pi** | SKIP both — same lineage (omp = hard fork of Pi). Pi is *already in the fleet under OpenClaw*. Steal omp's `hashline` edit format for a worker; don't install. |
| **t3code** | SKIP — Node WS server wrapping the CLIs you have + web/mobile. Herdr's job. |
| **KunAgent/Kun** | SKIP — **PolyForm-Noncommercial-1.0.0**; integration into a commercial product needs written auth. Also an Electron OS duplicating Herdr. (≠ Kun Chen's `/kun`.) |
| **coleam00/ai-software-factory** | **ADD (patterns)** — reversal. It's the overnight operating skin on Archon (MISSION.md + out-of-scope + holdout + `consumer.py tick`). Steal the files; don't vendor (no LICENSE yet). |
| **LMCache** | SKIP — KV-cache for vLLM/SGLang only; not LM Studio, not general. Revisit only if a GPU box becomes a dedicated single-model vLLM server serving ≥5 concurrent agents with a >8k shared prefix. |
| **Skills set** | `superpowers` (full, every worker, `SUPERPOWERS_DISABLE_TELEMETRY=1`) + `mattpocock` `grill-with-docs`+`domain-modeling` only + `/kun` (on-demand) + `coleam00 build-dark-factory` as a *doc*. SKIP Cole's other 32, Superdesign, Gas Town skills, **gstack wholesale**. |
| **gstack** (garrytan) | SKIP wholesale — 23 always-on skills = token bomb, Claude-first, fights Superpowers, GBrain = Supabase/2nd datastore. Read `/office-hours`, `/cso`, `/qa` as ideas. |
| **ai-engineering-toolkit gaps** | **Outlines/Instructor** (constrained decoding so local models return schema-valid JSON for the router), **LiteLLM** (fleet gateway *if* the router still does ad-hoc base_url switching — not both), **Garak** (one-shot prompt-injection red-team). Docling only if Grimlore ingests PDFs; Phoenix/Langfuse only if Governor needs traces. |
| **ink CLI** | NO bespoke TUI. Herdr = session UI, Projects = board, Archon/Ringside = workflow UI, workers are TUIs. Thin `baton status`/`halt` = **Python Typer + Rich** (same language, no Node on Pi/WSL). Not ink, not Textual. |

### C. Zero-cost memory ($0/month) — hard constraint, resolved

- **Operational recall = `projectmem`** (MIT, local; `events.jsonl` → distilled `summary.md`
  the agent reads via MCP; `pjm precheck` pre-commit = "don't repeat the failed fix").
  Baton's `remember`/`recall` become a shell wrapper over `pjm`. Not a Pi service, not raw git.
- **Grimlore wiki = Karpathy-wiki pattern by default** — plain markdown in the knowledge repo,
  written by the agent session already running, edited in Obsidian on the git folder.
  **OpenWiki *can* run against LM Studio** (`OPENWIKI_PROVIDER=openai-compatible`,
  `OPENAI_COMPATIBLE_BASE_URL=http://127.0.0.1:1234/v1`, `OPENWIKI_TELEMETRY_DISABLED=1`) but
  its per-page Deep-Agents tool loop burns GPU-hours on a local 7–32B and stalls if the model
  can't emit tools — **opt-in later for one code repo**, not the backbone. Its connectors want
  a paid Tavily key — skip those.
- **Semantic search = `nomic-embed-text-v1.5` GGUF (~84 MB) + `sqlite-vec`** (pure C, runs on
  the Pi, no FAISS build pain). Index *files* (Grimdex decisions + projectmem summary +
  Grimlore md). Nightly on the Mac Mini: embed via LM Studio `/v1/embeddings` → `scp kb.sqlite pi:`
  → webhost gets a read-only copy. Point existing `kb-index`/`kb-search` at it; don't grow a
  second indexer.
- **Placement:** Mac Mini = LM Studio + projectmem MCP + nightly index (+ OpenWiki opt-in);
  Pi = sqlite-vec + tiny HTTP search; webhost = static md mirror + read-only `kb.sqlite`;
  workers read git + call projectmem over Tailscale. **Total $0/month.**

### D. devboardai vs GitHub Projects

devboardai ($24, closed, macOS, Claude Code/Codex/Kimi only) is an **execution engine with a
kanban bolted on** — the value is NL→sprint→parallel-worktree-agents→cards-auto-move-from-
agent-state→auto-QA→retry. GitHub Projects is a **passive tracker** (board/roadmap/table/
fields/automation) that dispatches nothing.

- **The board is redundant** with GitHub Projects — don't adopt devboardai for it.
- **Can't be infrastructure** — single-machine, closed, can't see the WSL boxes / LM Studio
  fleet / Grok-Copilot-Cursor-Kiro workers / Grimdex.
- **Buy it for $24 as a UX study** — the `Backlog → In Progress → QA → Done → Failed` column
  set (the "Failed" lane is worth copying) and how agent-state card movement reads. Then build
  the thin layer on GitHub Projects: fields (`assigned_worker`, `model_tier`, `queue_position`,
  `run_id`, `blocked_reason`), status set (Backlog→Queued→In Flight→In Review→**Needs You**→
  Failed→Done), Baton-core writing them via `gh` on dispatch (~200 lines). The task DAG view
  comes from Archon's own UI.
- If a GUI beyond raw Projects is wanted: **Untrivial/agent-orchestrator** (11k★ Go, open) or
  **builderz/mission-control** (6k★, drives OpenClaw) — fleet-aware, unlike devboardai.

### Updated punch list (supersedes §6 items where they overlap)
- [ ] Buy devboardai ($24) — **yes, as a UX study only**, not infrastructure.
- [ ] Confirm zero-cost memory arch (projectmem + Karpathy wiki + nomic/sqlite-vec on Pi).
- [ ] The 5 forks from §2 still stand; the cloud pass (2026-09-09 05:51 UTC) takes a swing at them.

---

## 2026-09-09 cloud pass

**Method:** no new model fleet spend — read the four committed docs + Kevin's two raw-notes files
(`How should I rearrange the stack.txt`, `Links-Harnesses and more.txt`) in full, then ran targeted
WebFetch checks (GitHub HTML pages; `api.github.com` returned 403 through this session's proxy, so
verification used the rendered repo pages instead) against the specific items §2 flagged as
uncertain. Thinking/research only — no code, no subagents, no PRs, per this pass's brief.

### A. The 5 forks — resolved or evidenced

**Fork 1 — Lead orchestrator (Claude Code vs Grok Build): still open, leaning Claude Code.**
No web evidence resolves a preference call, so this stays with Kevin. But two facts already in
`01-architecture-audit` and this doc's §7 push the lean toward **Claude Code as lead**, not Grok
Build: (a) grok is confirmed non-viable *headless* without the Herdr `agent` driver workaround
(`grok -p` = one turn, bare `grok` needs a TTY — risk #4 in §5); routing the lead role through a
provider that needs a workaround to run unattended is fragile. (b) Every other convergent finding
in this doc (Archon default assistant, ai-software-factory's `tick`, Superpowers' plugin surface)
treats Claude Code as the reference integration and Grok/Codex as one-of-several workers — going
against that grain adds integration tax for no demonstrated benefit. Grok Build's token-discipline
argument (grok A/B's rationale) is real but is a *cost* argument, not a *reliability* one — and the
Governor already exists to enforce cost discipline regardless of which model leads. **Recommend:
Claude Code lead, Grok Build as a first-class worker + the viability-debate consultant** (splits
the difference the grok passes wanted without betting the spine on grok's headless story).
**Still needs Kevin's yes/no** — this is a preference call about which subscription anchors the
factory, not a technical one.

**Fork 2 — Keep `baton go` front door: RESOLVED, yes.** All three original passes already agreed
(grok A, GLM, and the lean in §2 itself); nothing in this pass's research contradicts it. Archon
becomes the engine Nick `baton go` dispatches into, per §3. Closing this fork — no further debate
needed unless Kevin objects.

**Fork 3 — Adopt caura now vs defer: RESOLVED, defer — confirmed harder than assumed.**
WebFetch against `caura-ai/caura`'s current README confirms the self-host footprint is a real
production service, not a docker-compose toy: **Postgres 16+ with pgvector, Redis, a
`core-storage-api` service, and a `core-api` REST/MCP gateway** — four moving parts minimum, with
optional reader/writer splitting for scale. New and material: **Caura shipped a v2.0 that widened
embeddings from 768→1024 dimensions**, and the README calls the upgrade path explicitly
**destructive** — existing installs must opt in, snapshot the DB, and re-embed everything before
running v2 images. That's a second migration hazard on top of the ops footprint the original passes
already flagged. This raises, not lowers, the bar for adopting caura before the OpenWiki spike.
**Defer stands, with more confidence than 09-08.** Caura is still 491★, Apache-2.0, actively
committed (1,152 commits) — abandonment isn't the risk here, operational weight and a destructive
migration on a tool you haven't even piloted yet is.

**Fork 4 — Adopt Archon now vs keep thin conductor: RESOLVED, adopt now via the same pin
`coleam00/ai-software-factory` already uses.** The SDLC workflow pack is **still not merged to
Archon's `dev` (default) branch as of today** — `cleanup/sdlc-workflows-only` is a live branch,
last pushed *today* (2026-09-09), and `ai-software-factory`'s own README states plainly: *"the
default uses the workflow additions on Archon's `cleanup/sdlc-workflows-only` branch. They are not
merged upstream yet, and this integration still needs a live end-to-end run."* That confirms the
09-08 finding, not new — but it also surfaces the actual mitigation already in the wild:
`ai-software-factory`'s installer **pins a specific revision of that branch via `pack.json`**
rather than waiting for the merge. That's the same "pin exact commits" mitigation this doc's §5
Risk 1 already prescribes. **Verdict: don't wait for the merge — pin the same branch at a known-good
SHA (copy `ai-software-factory`'s pinned revision as the starting point, or re-pin after your own
smoke test) and start on it in Week 1.** Re-check merge status monthly; re-pin when it lands on
`dev`.

**Fork 5 — GitHub Projects table vs GUI: RESOLVED, GitHub Projects table.** Unchanged from §2/§3 —
no new evidence surfaced a reason to add a GUI before the core ships one PR. Still stands: build the
~200-line table (fields below), keep Untrivial/agent-orchestrator and builderz/mission-control as
GUI options to *reconsider*, not adopt, if the plain table proves insufficient after real use.

**Net:** 4 of 5 forks resolve to a concrete default action; only Fork 1 (lead orchestrator) is a
genuine preference call still needing Kevin's word — everything else can proceed on the
recommendations above without blocking on him.

### B. Week-1 plan — Herdr + driver + Ringer, one real PR

Goal restated from §4 step 2: prove cheap workers implement, executed checks gate, and a premium
model reviews — on ONE real Baton issue, end to end, before touching the pwsh core.

**Day 1 — stand up the driver and pick the target issue.**
1. Confirm Herdr is current: `herdr --version`; update if stale.
2. Pick the smallest currently-open, well-scoped issue from the 32 open issues in
   `01-architecture-audit-2026-09-07.md` §3 that is tagged CORE-trivial or FIXED-BY-ADOPTION-adjacent
   — good candidates: **#209** (docs task), **#178** (doctor check), **#183** (roster capability
   flag). Small, real, low-blast-radius — exactly what a first strangler PR should be.
3. Smoke-test the Herdr agent driver on that issue's repo:
   ```
   herdr workspace create baton-week1
   herdr agent start w1-worker --kind codex --pane <id>
   herdr agent prompt w1-worker "Read issue #<N> in Ryfter/baton. Implement it. Write your diff summary to /tmp/w1-report.md" --wait
   cat /tmp/w1-report.md
   ```
   This is the exact pattern this doc's §7 already validated for grok; repeat it for whichever
   worker (Codex, Grok, OpenCode) is cheapest today per quota-axi / CodexBar.

**Day 2 — add Ringer as the executed-check gate.**
4. Install pinned Ringer: `git clone` at a known commit (per Risk 1 — do not `go install @latest`
   in the factory path). Confirm `ringer demo` runs clean.
5. Write a one-swarm Ringer manifest for the picked issue: worker = whatever ran in step 3, `check`
   = the repo's actual test/lint command for the touched files (not a stub — exit 0 must mean
   something).
6. Run it: `ringer run --manifest <path>`; watch Ringside HUD; confirm `runs.jsonl` records a real
   pass/fail, not an agent's self-report.

**Day 3 — pre-merge gate + premium review, then ship.**
7. Push the worker's branch through `no-mistakes` (pinned commit, `NO_MISTAKES_TELEMETRY=0`):
   disposable worktree → test/lint/docs → only then `origin` + `gh pr create`.
8. Have Claude Code (Opus, per d111 seating) review the diff before merge — this is the "premium
   model reviews" leg; a script or a manual `/code-review` pass both satisfy it for week 1.
9. Merge. Record what broke, what the driver commands actually were (they will differ from the
   pseudocode above at least once), and how much of the ~6 human gates in §7's Kun-stack account
   showed up in practice.

**First concrete command to actually run** (this is the literal Week-1 first step — everything
above is sequencing around it):
```
herdr workspace create baton-week1 && herdr agent start w1-worker --kind codex --pane 1
```

**Exit criterion for Week 1:** one real PR, merged, where a cheap worker implemented, an executed
check (not a self-report) gated it, and a premium model reviewed it — with Herdr, Ringer, and
no-mistakes all pinned to known commits. Do not port any CORE pwsh lib yet; that's Week 3+ per §4.

### C. Migration-spec skeleton — what Baton-core must still contain

Full detail already exists in `01-architecture-audit-2026-09-07.md` (file-by-file CORE/ADOPT/DROP
buckets, the `baton` command surface, on-disk state layout, golden-path steps 1–7, the 32-issue
disposition table). This is the skeleton a real spec document should follow — not a rewrite of that
audit, a table of contents for turning it into `docs/superpowers/specs/2026-0X-XX-baton-core-migration.md`.

```
# Baton core migration spec (skeleton)

## 1. Scope
   - What ships: ~5-6k LOC Python core replacing 36,120 LOC pwsh
   - What does NOT ship: MCP server (dies), 54 of 56 command files (die),
     6 pwsh hooks (die — 7 pure-Python hooks survive as-is)

## 2. Command surface (verbatim from audit §2)
   baton go / status / fleet list|probe / route / jobs list|show|retry /
   decide / kb search / doctor

## 3. On-disk state (verbatim from audit §2)
   ~/.baton/config.toml, runs/<id>/{events.jsonl, plan.json, state/},
   decisions/, kb/
   -- event log (#206) is the foundation, not a feature; every other
      projection (status, dashboard/) reads it, nothing else is authoritative

## 4. DROP / ADOPT / KEEP map (per scripts/*.ps1 file)
   -- pull directly from audit §1 tables (CORE/ADOPT/DROP), unchanged --
   CORE (~13,500 LOC → ~5-6k Python):
     conductor-lib, maestro-lib, fleet-lib, window-budget-lib (Governor),
     window-service-lib, fleet-backlog, routing-lib, effective-cost-lib,
     officers-lib (Fable scheduler split, NOT wholesale), gate-lib (panel
     verdict logic split), verification-lib (contract carve-out),
     coordination-lib (claim/lock/liveness carve-out), dark-factory-lib
     (lane/standing-order config carve-out), decisions-lib, plan-gate-lib,
     project(s)-lib, job-lib, small glue cluster (~2,600 LOC)
   ADOPT (~8,700 LOC deleted via 5 external tools):
     fleet-executor-lib, diff-apply-lib → firstmate + treehouse
     usage-probe-lib, cursor-quota-lib, usage-classify-lib,
       copilot-credit-lib, usage-lib → quota-axi
     verification-lib (runner half), gate-lib (mechanical half) → no-mistakes
     dark-factory-lib (loop half) → gnhf
     coordination-lib (crew-fanout half) → firstmate
     heartbeat-lib → firstmate watchers
   DROP (~13,900 LOC deleted outright):
     officers-lib is NOT here (corrected from GLM's first pass — see audit
     A1); ship-report-lib, start-lib, optimize-prompt-lib, bootstrap.ps1,
     coach-lib, prompt-pool-lib, research-gate-lib, fleet-ensemble,
     the routing-learn/observe/calibrate cluster, otel/misc experiment
     cluster, mcp-bridge.ps1
   KEEP AS-IS (already Python, not pwsh):
     kb/ (1,734 LOC), dashboard/ (8,721 LOC, freeze — read-only projection
     once #206 lands)

## 5. Architecture decision this spec must open with
   -- the still-unanswered question from audit's bottom line: does `baton go`
      shell out to firstmate, or does firstmate's liaison call `baton`?
      Week-1 plan (§B above) answers this empirically: `baton`-side driver
      calls Herdr directly for week 1 (bypassing firstmate entirely) to
      prove the spine; firstmate integration is a Week 3+ decision made
      from that evidence, not guessed up front.

## 6. Issue disposition
   -- pull verbatim from audit §3's 32-issue table; re-triage only the ones
      whose status changed since 09-07 (none did — scripts/ is untouched
      as of this pass, confirmed via git log)

## 7. Sequencing
   -- this doc's §4, unchanged: Week 1 (Herdr+Ringer+no-mistakes, one PR,
      per §B above) → Weeks 3-4 (Archon pinned per Fork 4 above, port
      router, freeze scripts/) → Week 5+ (overnight loop, caura/Omnigent
      re-evaluation)
```

The one addition this pass makes to the audit's content: **§5 above should be the spec's opening
section, not an aside** — Week 1 is deliberately designed to answer "who owns the loop" with a
working PR instead of a whiteboard debate, and the spec should say so explicitly so nobody re-opens
that debate in the abstract during Week 3.

### D. New decisions this pass surfaces — still need Kevin

1. **Fork 1 (lead orchestrator) is the only fork left genuinely open.** This pass's lean is Claude
   Code lead / Grok Build as worker + viability consultant (reasoning in §A above) — needs Kevin's
   explicit yes/no, since it's a subscription/workflow preference, not something evidence settles.
2. **Which issue is the Week-1 target.** §B suggests #209, #178, or #183 as candidates (small,
   real, already triaged CORE-trivial in the audit) — Kevin should confirm or pick a different one;
   whichever it is should be genuinely useful, not a throwaway, since it's also the first real test
   of "does the strangler spine ship code."
3. **Whether to pin Archon's `cleanup/sdlc-workflows-only` at `ai-software-factory`'s existing
   pinned revision, or cut a fresh pin after Baton's own Week-1 smoke test.** Reusing
   `ai-software-factory`'s pin is faster; a fresh pin is safer if Baton's usage pattern diverges
   from theirs. Low stakes, but it's a concrete choice someone has to make before Week 3.
4. **Confirm the Fork-4 resolution itself (adopt Archon now via pin, don't wait for merge).** The
   evidence supports it, but "start depending on an unmerged branch of someone else's in-flux repo"
   is exactly the Risk 1 pattern this doc already flags — worth Kevin's explicit sign-off given it's
   the biggest structural bet in the Week 3+ plan.
