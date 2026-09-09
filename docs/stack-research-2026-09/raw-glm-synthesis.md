# Baton Stack Decision Report

**Verdict framework applied from the shared context. Token discipline honored: no web fetches; training knowledge + your notes only.**

---

## 1. Repo-by-Repo Verdicts

### Core Baton layer

| Repo | Verdict | Why |
|---|---|---|
| **Ryfter/baton** | **KEEP-BUILD** | Collapse to ~5–6k LOC: learned local-fleet router + Governor (spend caps, quota windows) + Grimdex loop. Everything else gets adopted. This is the differentiated bet; nothing else benchmarks *your* LM Studio boxes. |
| **Ryfter/Grimdex** | **KEEP-BUILD** | GitHub-backed, model-agnostic decision/lessons KB is genuinely unique. Don't replace with Letta/supermemory — those are session-memory tools, not decision-ledgers. |
| **Grimlore** | **KEEP-BUILD** (borrow shape from OpenWiki) | The "why/who/landscape" layer is yours. Steal OpenWiki's structure (auto-generated wiki pages per topic, agent-writable) as the *format*, not the product. |
| **kunchenguid/firstmate** | **REPLACE** (replaces fleet-executor-lib + coordination-lib) | Crew dispatch, liaison layer, captain/first-mate seating — polished where Baton's is pwsh glue. **Maturity risk: one maintainer (Kun), effectively personal tooling.** Decide the shell-out direction before committing. |
| **kunchenguid/treehouse** | **REPLACE** (replaces worktree pooling, :3000 collision handling) | Worktree pool + per-task isolation solved. Same one-maintainer risk. |
| **kunchenguid/gnhf** | **REPLACE** (replaces dark-factory-lib overnight loop) | One-commit-per-iteration overnight loop with rollback/exit summary is exactly your dark-factory-lib. Same risk profile. |
| **kunchenguid/quota-axi** | **REPLACE** (replaces quota-lib/usage-probe-lib) | Quota probing seam. Note: it *reports* quota; your Governor *enforces* budget — keep the Governor. |
| **kunchenguid/no-mistakes** | **REPLACE** (replaces verification-lib runner + mechanical gate-lib) | Test-gate hooks + review panel. Strong in a thin category. Same maintainer risk. |
| **kunchenguid/kun** | **SKIP** | Another solo-maintainer meta-harness; overlaps firstmate/Omnigent. Piling three unfinished harnesses on Baton helps nobody. |
| **omnigent-ai/omnigent** | **ADD** (multi-host runtime/conductor cockpit) | Closest thing to your parked Fleet-Conductor vision: multi-harness abstraction, hosts, policies, multi-device — fits your Tailscale fleet. **Maturity risk: alpha.** Pilot it for a week as the cockpit layer; don't build on it as foundation yet. |
| **coleam00/Archon** | **SKIP** (adopt the *idea*) | Just archived Python v1, rewrote in TS — in flux. But steal the lesson: declarative YAML DAG as source of truth beats imperative hooks. If you want Archon-the-product, wait 90 days. |
| **obra/superpowers** | **ADD** (concept→spec→plan flow) | You already use it; it's the right tool for the "idea → researched concept doc → reviewed plan" front door. Mature, actively maintained. |
| **gastownhall/gastown** | **SKIP** | Direct analog to Baton but a different architecture; mining it for ideas costs tokens you don't have. One look at its routing/dispatch docs, then move on. |
| **ruvnet/ruflo** | **SKIP** | Swarm meta-harness that overlaps Omnigent + firstmate. Adopting both ruflo AND Omnigent is redundant. Pick one cockpit; Omnigent fits your fleet better. |
| **Herdr** (already in use) | **KEEP** | Rust, agent-state-aware, SSH remote — this is your session-manager layer across machines. It's already earning its keep. |

### Harnesses / orchestrators

| Repo | Verdict | Why |
|---|---|---|
| **Claude Code** | **PRIMARY HARNESS** | Best-in-class subagent model routing (cheap workers, expensive orchestrator), native GitHub integration, superpowers ecosystem, your existing competence. Standardize here. |
| **Codex CLI / Copilot / Cursor / Gemini** | **KEEP as secondary workers** | Run 1–2 secondary harnesses via Omnigent/firstmate's harness abstraction — for cross-checking and provider-quota arbitrage, not as primary. |
| **wshobson/agents** | **ADD** (subagent definition library) | Curated Claude Code subagent personas; cheap to adopt, plugs straight into the primary harness. |
| **Chachamaru127/claude-code-harness** | **SKIP** | Solo-maintainer wrapper around Claude Code; Claude Code + superpowers already covers it. |
| **Chachamaru127/harness-mem** | **SKIP** | Session memory; Grimdex covers the durable layer, claude-mem covers session layer if needed. |
| **affaan-m/ECC** | **SKIP** | Harness perf optimization — micro-optimization before the macro rewrite is done. Revisit later. |
| **ai-genius-automations/octoally** | **SKIP** | Basic dashboard; your GitHub Projects + dashboard/ (keep+freeze, 8.7k LOC Python) covers observability better. |
| **Untrivial-ai/agent-orchestrator** | **UNKNOWN-need-web** | Not in training data with confidence. |
| **ComposioHQ/agent-orchestrator** | **SKIP** | Tutorial-grade orchestration content; nothing Baton needs. |
| **jonwiggins/optio** | **UNKNOWN-need-web** | |
| **AgentsMesh/AgentsMesh** | **SKIP** | Another parallel-session manager; Herdr + firstmate cover this. |
| **asheshgoplani/agent-deck** | **SKIP** | Dashboard clone; GitHub Projects table view is your spec. |
| **pixel-agents-hq/pixel-agents** | **UNKNOWN-need-web** | |
| **builderz-labs/mission-control** | **UNKNOWN-need-web** | |
| **prime-radiant-inc/serf** | **ADD** (pattern study) | "Boiled-down version of what you want" — read its architecture for the minimal-loop pattern; likely SKIP as a dependency. |
| **prime-radiant-inc/iterative-development, engineering-notebook, greenfield, evener, books-for-bots** | **SKIP** (as deps) / **ADD** (as reading) | Skills/playbook repos — mine for the concept-doc and iteration flow, don't install. |
| **deepseek-ai/deepseek-harness** | **UNKNOWN-need-web** | |
| **CommandCodeAI/command-code** | **UNKNOWN-need-web** | |
| **can1357/oh-my-pi** | **UNKNOWN-need-web** | |
| **HarnessRouter/harnessrouter** | **UNKNOWN-need-web** — name suggests routing across harnesses; if it routes Claude-Code-shaped traffic across providers, it competes with claude-code-router. Check. |
| **NVIDIA-NeMo/Switchyard** | **UNKNOWN-need-web** | |
| **Factory-AI/factory** | **SKIP** | Commercial enterprise platform; not your stack. |
| **vercel-labs/skills** | **ADD** (maybe) | Skill packaging format is becoming a standard; cheap to align with. |
| **xai-org/grok-build** | **UNKNOWN-need-web** | |
| **ship-harness, t3code, earendil-works/pi, KunAgent/Kun(+UI)** | **SKIP** | More solo-maintainer harnesses in an already-saturated category. You need ONE harness, not seven. |
| **KunAgent/Kun** | **SKIP** | "Sounds like what I've been building" is a trap signal — adopting it abandons your differentiated router. |
| **coleam00/adversarial-dev** | **ADD** (pattern) | Multi-model adversarial debate for the viability/consult step of your concept flow. Implement as an orchestrator prompt pattern (2–3 models critique the concept doc), not a dependency. |
| **coleam00/skills** | **ADD** | Dark-factory skill system — directly relevant to your overnight loop; cheap to adopt into superpowers. |
| **mattpocock/skills** | **ADD** (selective) | Good TS/quality skills if you ship TS. |

### Spec-driven dev

| Repo | Verdict | Why |
|---|---|---|
| **github/spec-kit** | **ADD** | GitHub-native spec workflow fits "everything coordinated via GitHub." Backs your concept-doc → tasks pipeline. |
| **Fission-AI/OpenSpec** | **SKIP** | Redundant with spec-kit + superpowers specs dir. Pick one spec system; spec-kit wins on GitHub integration. |
| **planforge.software** | **SKIP** | Traditional PM tool; GitHub Projects is your board. |

### Memory

| Repo | Verdict | Why |
|---|---|---|
| **letta-ai/letta (+letta-code, letta-obsidian)** | **SKIP** | Serious project, but it's an agent-memory *server* — heavyweight, and it competes with Grimdex's role. Your KB is GitHub-backed files; Letta is a database. Different philosophy. |
| **supermemoryai/supermemory** | **SKIP** | Hosted/consumer memory API; wrong shape for a private dark factory. |
| **thedotmack/claude-mem** | **ADD** (session layer only) | Compresses Claude Code session history into searchable memory. Pairs *under* Grimdex (session recall vs. decision ledger). |
| **riponcm/projectmem, rohitg00/agentmemory, agent0ai/dox, TencentDB-Agent-Memory, cachezero, hindsight, sharedcontext, Eversmile12** | **SKIP** | Crowded field of small memory tools; Grimdex + claude-mem + git history is enough. More memory systems = more drift. |
| **caura-ai/caura** (ex-memClaw) | **ADD** (UI patterns only) | You love the UI — steal its visualization patterns for the Baton dashboard. Don't replace Grimlore with it; it's a memory product, Grimlore is a context/landscape layer. **Maturity: young.** |
| **langchain-ai/openwiki** | **ADD** (as Grimlore's blueprint) | Auto-generated, agent-writable wiki is exactly the Grimlore shape. Adopt the format; keep Grimlore as the owner. |
| **Karpathy memory gist** | **ADD** (read) | Design guidance, not a dependency. |
| **NateBJones-Projects/ringer** | **UNKNOWN-need-web** — you flag it as critical work-checking; I can't verify. **Priority web check.** If it does independent verification of agent output, it slots into the validation stack beside no-mistakes. |
| **NateBJones-Projects/OB1** | **UNKNOWN-need-web** | |

### Routing / cost / quota

| Repo | Verdict | Why |
|---|---|---|
| **LiteLLM Router** | **REPLACE** (replaces provider plumbing inside the router) | Production gateway: fallbacks, budgets, cost-based routing across 100+ providers. Baton's router becomes a *policy layer on top of LiteLLM*, not an HTTP client. |
| **claude-code-router** | **ADD** | Routes Claude Code's model tiers to GLM/local models — kills coordination overhead on your Anthropic window. One config file. Do this *this week*. |
| **RouteLLM** | **SKIP** (now) | Research-grade; LiteLLM + your measured-fleet router beats it for your use case. |
| **duolahypercho/codex-router** | **SKIP** | Narrow; LiteLLM covers it. |
| **steipete/CodexBar + Win-CodexBar + ccusage** | **KEEP** | Already installed, zero-cost observability of quota burn. Feeds the Governor's inputs. |
| **LMCache** | **SKIP** | KV-cache layer for vLLM-class serving; LM Studio boxes don't benefit. Revisit only if you move to vLLM/SGLang. |
| **unsloth** (installed) | **KEEP** | Fine for local fine-tuning later; orthogonal to routing. |

### Validation / security / review

| Repo | Verdict | Why |
|---|---|---|
| **vercel-labs/deepsec** | **ADD** | Security scanning gate in the ship pipeline — cheap, plugs into no-mistakes' gate hooks. |
| **scabench-org/hound** | **UNKNOWN-need-web** | |
| **tirth8205/code-review-graph** | **SKIP** | Code-graph review tools are immature; the harness's own review + no-mistakes gates suffice. |
| **cocoindex-io/cocoindex-code / cocoindex** | **SKIP** | Embedded code search index — nice, but harnesses already grep/read well at your repo sizes. |
| **ix-infrastructure/Ix** | **UNKNOWN-need-web** | |
| **presidio** | **ADD** | PII redaction (see §2). |
| **MinerU** | **SKIP** | Docling is better and you already prefer it. |
| **Understand-Anything** | **SKIP** | Grimlore's job, and OpenWiki's format is a better blueprint. |
| **tt-a1i/archify** | **UNKNOWN-need-web** | |
| **Panniantong/Agent-Reach** | **SKIP** | Web-perception agent; your research step is one-fetch-per-repo, not ambient browsing. |
| **GEPA** (link was a dup of Agent-Reach) | **SKIP** | Prompt-optimizer research; not load-bearing for you now. |
| **Forward-Future/loopy** | **SKIP** | Another agent-loop; gnhf + firstmate own this. |
| **yorukot/superfile** | **SKIP** | Nice TUI file manager; irrelevant to the factory. |
| **ayghri/i-have-adhd** | **UNKNOWN-need-web** — if it's an async question-queue for humans, it maps to your "park waiting on Kevin" board; GitHub Projects does that natively. |
| **steipete/agent-scripts** | **UNKNOWN-need-web** | |
| **SethGammon/Citadel** | **UNKNOWN-need-web** — you say it resembles Grimdex/Baton infra; check before duplicating. |
| **agentsmd/agents.md** | **ADD** | AGENTS.md is the emerging inter-harness convention; every worker agent should read one. Trivial cost. |
| **honestsoul/generative_ai_project** | **SKIP** | Generic project scaffold; your repo structure is already better. |
| **ai-boost/awesome-harness-engineering, andyrewlee/awesome-agent-orchestrators, Sumanth077/ai-engineering-toolkit** | **ADD** (as reading lists) | Curated indexes — skim once for patterns, never as dependencies. |
| **garrytan/gstack** | **UNKNOWN-need-web** | |

### Doc converters

| Repo | Verdict | Why |
|---|---|---|
| **docling** | **PRIMARY** | Best PDF/Office→Markdown quality; you already prefer it. |
| **microsoft/markitdown** | **ADD** | Fast, good for Office docs / bulk cheap conversion where docling is overkill. |
| **datalab-to/marker** | **SKIP** | Overlaps docling; pick one heavy converter. |
| **firecrawl/pdf-inspector** | **ADD** (niche) | Fast PDF inspection when you only need to peek, not convert. |
| **jgm/pandoc** | **ADD** | Universal format glue (docx↔md↔html) for the concept-doc pipeline. |

### Token tracking
**CodexBar / Win-CodexBar / ccusage — KEEP.** Already in use; wire ccusage output into the Governor as a spend input.

---

## 2. Recommended Sub-Stacks

**MEMORY:** Grimdex (decisions/lessons, GitHub-backed, KEEP-BUILD) + **claude-mem** (session recall under it) + **OpenWiki format** as Grimlore's page structure + **caura's UI patterns** for visualization. No memory server (Letta/supermemory). One write path: agents append records via a single `baton kb` command → git commit.

**VALIDATION:** **no-mistakes** (test gates + review panel) + **deepsec** (security gate) + GitHub CI as the final arbiter + **ringer** *pending web verification* (if it independently checks work, it becomes the "second opinion" gate in the ship pipeline). Adversarial-dev pattern (2–3 model debate) gates the *concept* stage, not the code stage.

**LOCAL DOC-CONVERTER:** **docling** (primary) + **markitdown** (bulk/cheap) + **pandoc** (format glue). Drop marker, MinerU.

**PII:** **Microsoft Presidio** as a pre-flight gate — every prompt/context payload leaving a home box to a frontier API passes a redaction step; local-fleet traffic skips it (stays on-box, which is the whole point of the local fleet). Plus: **rotate the OPENROUTER_API_KEY now** — it's exposed in Cursor Helper's process env on your Mac; stop passing keys via MCP env, use a keyring or a local proxy (LiteLLM gateway holds keys, agents hold none).

---

## 3. Stack Options

### Stack A — "Thin Brain on Adopted Plumbing" (RECOMMENDED)
**Baton-core (router + Governor + Grimdex loop, ~5–6k Python) + Claude Code (primary harness) + firstmate/treehouse/gnhf/quota-axi/no-mistakes (dispatch/worktrees/overnight/quota/gates) + LiteLLM (provider plumbing) + claude-code-router (window protection) + GitHub Projects (all coordination, boards, parked-items, LLM-assignment table) + docling/markitdown/pandoc + Presidio.**
- *Tradeoffs:* Fastest path to the dark factory; deletes ~25k LOC of pwsh; every coordination feature you described maps to a GitHub Projects view you configure, not code you write. Risks: dependence on Kun's five one-maintainer tools (mitigate: pin versions, they're small enough to fork), and the rewrite-disruption cost.

### Stack B — "Omnigent Cockpit + Baton Router"
**Omnigent as the multi-host runtime/cockpit across the Tailscale fleet + Baton-core (router/Governor/Grimdex only) + Claude Code + no-mistakes + same memory/converter stack.**
- *Tradeoffs:* Best long-term fit for the multi-machine, multi-harness vision (Hermes/OpenClaw boxes, Mac Mini, 4090/5090) and the harness abstraction is exactly your "route any task to any agent" goal. Risks: **Omnigent is alpha** — building the factory on it now means riding someone else's breaking changes. Do this as a 1-week pilot *in parallel* with Stack A; promote Omnigent when it survives a week of real overnight runs.

### Stack C — "Assemble, Retire Baton" (fallback)
**Herdr + Claude Code subagent model-tiering + claude-code-router + aider architect/editor + LiteLLM + no-mistakes + a 200-line AGENTS.md encoding cost policy.**
- *Tradeoffs:* ~2 days, zero maintenance, proves how much of the pain is free. Loses the learned local-fleet router, hard spend Governor, and the KB loop — i.e., loses the differentiated bet. Run this as your **Option-0 measurement week** before committing to A; it's also your permanent fallback if the rewrite stalls.

**Primary harness: Claude Code. Run exactly one primary + up to two secondary harnesses (Codex CLI, Copilot) behind firstmate/Omnigent's harness abstraction** — secondaries exist for quota arbitrage and cross-checking, not for a second coordination stack. More than two harnesses = coordination overhead eats the cost savings.

**Sequencing:** Week 0 = Stack C knobs (measure). Week 1–4 = strangler to Stack A (linear `baton go`, prove one real PR, port behind event log, freeze pwsh). Week 5+ = Omnigent pilot → promote to Stack B if it holds.

---

## 4. Three Biggest Risks in Kevin's Current Lean

1. **Adoption-mania on one-maintainer alpha tools.** firstmate/treehouse/gnhf/quota-axi/no-mistakes are all Kun's personal repos; Omnigent is alpha; Archon just rewrote itself. You'd be swapping "my unfinished 60k pwsh" for *five* someone-else's-unfinished-things. Mitigation: pin/fork each, and cap the bet — if any two of the five stall, Baton-core absorbs that layer rather than you hunting a sixth tool.

2. **The architecture question nobody answered: who owns the loop?** Does Baton shell out to firstmate, or does firstmate's liaison call Baton? Every stack above silently assumes an answer. Decide this *before* the strangler week-1 build, or you'll build both halves and discover they fight over the event log.

3. **Losing the differentiated bet while assembling.** The gravitational pull of devboardai-style dashboards, ruflo swarms, and caura UIs is toward building a pretty cockpit — the exact ambition that made Baton unfinishable. The router that learns from *your* LM Studio fleet and the Grimdex KB are the only defensible IP here. Rule: no new UI, no new harness, no new memory system until the router + Governor + KB loop run one real PR end-to-end on adopted plumbing. Also: rotate that leaked OpenRouter key today.