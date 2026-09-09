# Grok Q2 — leftover "why not", memory, skills, gstack, toolkit, ink

**Date:** 2026-09-09 (GitHub API + READMEs fetched this turn)
**Constraint:** Baton collapses to ~5–6k LOC Python core (learned local-fleet router + Governor + Grimdex). ADOPTS tools. Prior picks: Herdr, Archon, firstmate/gnhf/quota-axi/treehouse, Ringer + no-mistakes, Superpowers.

Stars / `pushed_at` are from `api.github.com` on 2026-09-09.

---

## 1. "Why not" — five leftovers

### deepseek-ai/deepseek-harness — SKIP (do not reconsider)

| | |
|---|---|
| What | Full agent OS: "everything is a plugin" on the Cordis kernel. Models, tools, skills, sessions, sandboxes, loops, UI are all plugins. `npx @deepseek-ai/dsh web` → `http://127.0.0.1:3080`. Python SDK exists (`DeepSeekHarness`, `provider="deepseek-official"`). |
| Stats | **216,354 ★**, MIT, TypeScript, created 2026-08-13, **pushed 2026-09-08**. Issues/PRs **disabled**. Developer preview; README screams breaking changes. |
| Why not | This is a competing **session runtime + web UI**, not a library Baton can adopt. Herdr already is the mux. Claude Code / Codex / Grok Build already are the workers. A Cordis plugin ecosystem would become a third OS. Default models are DeepSeek-official (`deepseek-v4-flash`); local LM Studio is an afterthought, not the product. Viral star count (216k in ~4 weeks) is not maturity. |
| Reconsider if | DeepSeek ships a **thin Cordis plugin** that wraps Baton's router as a model provider *and* Kevin wants a DeepSeek-native worker. Even then: study the plugin ABI, do not replace Herdr. |

### earendil-works/pi  AND  can1357/oh-my-pi — SKIP both (same lineage; omp is the fork)

**Relationship:** **Same lineage, not the same product.** oh-my-pi's README, line 1 of the fork note: *"Fork of Pi by @mariozechner"*. Pi (Mario Zechner / Earendil) is the **minimal** TypeScript harness (`pi-ai` + `pi-agent-core` + `pi-coding-agent` + `pi-tui`). omp (Can Bölük) is a **batteries-included hard fork**: ~80k LoC Rust N-API core, 31 tools, LSP, DAP, hashline edits, in-process ripgrep/bash. OpenClaw embeds Pi's `createAgentSession()` — it does not shell out to the Pi CLI. Kevin already runs OpenClaw + Hermes on the Omarchy laptops, so **Pi is already in the fleet as someone else's runtime**.

| | Pi (`earendil-works/pi`) | oh-my-pi (`can1357/oh-my-pi`) |
|---|---|---|
| Stars / push | **103,182 ★**, MIT, TS, pushed 2026-09-08 | **30,217 ★**, MIT, TS+Rust, pushed 2026-09-09, **2,520 open issues** |
| Job | Minimal canvas. 4 tools by default (read/write/edit/bash). Embeddable SDK. | Full coding agent with the IDE wired in. `curl -fsSL https://omp.sh/install \| sh` |
| Fits Baton? | No. Would be a 4th worker CLI. Already underneath OpenClaw. | No. Competing worker vs Claude Code / Grok / Codex. Kitchen-sink. |

**Steal, don't install:** omp's **hashline** edit format (claimed −61% tokens on Grok 4 Fast) and in-process grep. Those are ideas for a worker, not a Baton-core dependency. Do not run `omp` as the factory OS.

### pingdotgg/t3code (Theo) — SKIP (do not reconsider)

| | |
|---|---|
| What | **"Agent harness control surface."** Node WebSocket server wraps *existing* CLIs (Claude Code, Codex, Cursor, Grok Build, OpenCode, Antigravity) and serves web + Electron + iOS/Android. BYO-subscription. `npx t3`. Latest release **v0.0.40** (2026-09-08). |
| Stats | **22,121 ★**, MIT, TypeScript, 3,770 commits, pushed **2026-09-09**, 1,512 open issues. Contributions "not actively accepted." |
| Why not | This is Herdr's job: mux sessions over the worker CLIs Kevin already authenticates. Adding T3 Code = a **third cockpit** (Herdr + GitHub Projects + T3). Mobile remote-control is the one unique surface, but Kevin already has Tailscale onto the factory host. Theo's AGENTS.md is a good *ethos* read, not a stack component. |
| Reconsider if | Herdr dies or refuses Grok Build / Codex. Then T3 is the strongest open BYO-subscription cockpit. Until then: skip. |

### KunAgent/Kun — SKIP (license is the blocker; confirm PolyForm NC)

| | |
|---|---|
| What | Local-first **Electron workbench + TUI**, one `kun serve` runtime. Code mode + Design canvas + Work mode (docs/PDF/pptx). TypeScript. `npm run dev` / `kun`. |
| Stats | **6,298 ★**, created 2026-05-21, pushed 2026-09-09. License field on GitHub is `"Other"` / `NOASSERTION`. README + `package.json` both say **`PolyForm-Noncommercial-1.0.0`**. Confirmed against [polyformproject.org/licenses/noncommercial/1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0). |
| Practical impact | Personal hobby / research / private study is a **permitted purpose**. **"Commercial use, distribution, SaaS/hosting, resale, or integration into a commercial product requires separate written authorization."** Using Kun as Baton's workbench while shipping paid software, consulting, or any "anticipated commercial application" is **out of license**. Forking it into the Baton repo is integration. Even a personal factory that produces commercial products is the grey zone the license is written to catch. CLA required for PRs. |
| Why not | (1) License poison next to MIT/Apache stack. (2) Electron GUI duplicates Herdr. (3) Not a library — it is an OS. Name collision with Kun Chen's `/kun` skill (different person). |

Do not confuse with `kunchenguid/kun` (skill pack, §3).

### coleam00/ai-software-factory — CORRECT TO **ADD (patterns + Archon consumer, not a second OS)**

Prior "why not" was wrong. This is not a competing factory. It is **the overnight skin on the Archon pick already made**.

| | |
|---|---|
| What | GitHub issue in → gated merge out. `MISSION.md` (product + **out-of-scope list**), `harness/END-TO-END.md` (2–5 user journeys), `.factory/holdout/HOLDOUT.md` (hidden eval). All AI steps are Archon workflows (`archon-triage`, `archon-ship`, `archon-lifecycle`, `archon-verify-runtime`, `archon-merge-queue`, `archon-deploy`). Python `factory/consumer.py` is a thin invoker. Scheduler: `python factory/consumer.py tick` + `.factory/loop.sh` every 5 min. |
| Stats | **199 ★**, **no LICENSE file**, Python, created **2026-09-01**, pushed **2026-09-09**. Alpha. README: SDLC pack still lives on Archon branch `cleanup/sdlc-workflows-only`, **not merged upstream**; "still needs a live end-to-end run." |
| Why ADD | This is the missing *operating model* for the Archon DAG: mission drift-check, holdout, consumer CLI, "leave scheduling off until one lap is watched." That is exactly the overnight loop Baton was going to hand-roll. |
| How to adopt | Steal the three files + `consumer.py` *ideas*. Pin Archon's SDLC pack the same way (`pack.json`). **Do not vendor the repo** until it has a license. Do not run a second DAG beside Baton's Archon install. Installer: `python ~/ai-software-factory/bin/factory.py init` from the *application* repo — only after license is MIT/Apache. |

**Reconsider:** yes, immediately, as the Archon factory template. Wait on copying code.

---

## 2. LMCache — does it ever figure in?

**What it is:** a **KV-cache management layer for vLLM / SGLang**, not a general LLM cache and not an LM Studio plugin. It extracts transformer KV tensors out of GPU HBM, stores them in a tiered hierarchy (GPU → CPU RAM → disk → remote), and **reuses them across requests, sessions, and engine processes**. Two integration modes: in-process `LMCacheConnectorV1` inside vLLM, and multi-process `lmcache server` that several vLLM instances share. Paper (arXiv:2510.09665): up to ~15× throughput on multi-round QA / long-doc workloads vs vLLM alone. **11,708 ★**, Apache-2.0, Python, pushed 2026-09-09.

It does **not** cache "chat history" or embeddings. It caches the *attention KV* of a *specific model checkpoint* so the next request with the same prefix skips prefill.

**Exact condition Kevin would want it — all of these at once:**

1. **Leave LM Studio** on the 4090 and/or 5090 for **vLLM or SGLang** serving of one (or two) long-lived chat/instruct weights.
2. **Many concurrent agents** hit **that same model** with a **large shared prefix** (identical system prompt + tool schemas + Grimdex briefing, or the same RAG corpus). Prefix reuse across *different* models is worthless — KV is weight-specific.
3. Prefill is the bottleneck: long context, multi-turn agent loops, TTFT hurting the Governor's latency budget.
4. Optionally: **cross-GPU KV share** (4090 prefill → 5090 decode, or both serving the same weights) via the MP `lmcache server`. Tailscale-between-boxes KV is possible but the win is local NVLink/PCIe, not a 1 Gbps mesh.

**That condition is unlikely for a personal factory.** The fleet is heterogeneous (4090 / 5090 / 2070S / Mac Mini 24 GB / Pi), routed by *measured quality per task type*, not one hot model. LM Studio is llama.cpp-family OpenAI-compat, not vLLM paged attention. Switching the whole fleet to vLLM just to unlock LMCache is a serving-stack rewrite, not a cache add-on. **Verdict: does not figure. Revisit only if a 4090/5090 box is dedicated to one vLLM model serving ≥5 concurrent agents with a >8k shared prefix.**

Until then, cheaper prefix wins: keep system prompts short, let LM Studio's own prompt cache do per-process reuse, put durable memory in files (Grimdex / projectmem), not in GPU KV.

---

## 3. Skills roundup

### kunchenguid/kun — INSTALL (consult skill only)

- **What:** One `/kun` skill. Thin wrapper; fetches living `ENTRY.md` / `TOOLS.md` / `OPINIONS.md` / `VOICE.md` from `raw.githubusercontent.com` (updated daily from Kun Chen's X/Substack/YouTube). "Think like this principal engineer."
- **Harness:** Cross-harness via `npx skills add kunchenguid/kun -g`. Works anywhere skills.sh works (Claude Code, Grok Build, Codex, …).
- **Stats:** **257 ★**, created **2026-09-06**, no license, no PRs accepted (it's his KB).
- **Overlap:** Complementary to firstmate/gnhf/quota-axi/treehouse (those are *tools*; this is *judgment/voice*). Different person from KunAgent/Kun.
- **Call:** **INSTALL globally.** Invoke explicitly (`/kun how would you…`), do not auto-trigger on every coding task.

```sh
npx skills add kunchenguid/kun -g
```

### coleam00/skills — CHERRY-PICK one; SKIP the rest

- **What:** 33 skills around **prime → plan → implement → validate → review → commit → PR**, plus worktrees, meta-skills, `build-dark-factory`. MIT. ~4,200 tokens of always-on descriptions if you install the whole plugin.
- **Harness:** Claude Code plugin (`/plugin marketplace add coleam00/skills` then `/plugin install skills@cole-medin`) or `npx skills add coleam00/skills`. 75+ agents via the CLI.
- **Stats:** **492 ★**, MIT, Python+md, pushed 2026-08-26.
- **Overlap:** Superpowers already owns TDD / plans / worktrees / subagent-driven-dev / review. firstmate/treehouse already owns worktrees. Archon + ai-software-factory already own the dark-factory loop.
- **Call:** **SKIP the plugin.** Copy **only** `build-dark-factory` as a reference when wiring Archon's factory files. Do not install `worktree-*` (treehouse) or `piv-*` (Superpowers).

### superdesigndev/superdesign-skill — SKIP

- **What:** Design-judgment skill that drives **`@superdesign/cli`** + superdesign.dev canvas (login required). UI / decks / graphics.
- **Harness:** `npx skills add superdesigndev/superdesign-skill` (70+ agents) or Claude plugin `/plugin install superdesign@superdesign`.
- **Stats:** **526 ★**, MIT, pushed 2026-08-21.
- **Why skip:** Not zero-cost. `superdesign login` is a hosted design agent. Frontend-design skill already covers taste-in-prompt. Do not add a SaaS canvas to a $0 factory.

### mattpocock/skills — CHERRY-PICK two; SKIP the rest

- **What:** Small composable skills. Unique: **grill** (relentless interview) + **shared language** (`CONTEXT.md` + ADRs). Also `/tdd`, `/implement`, `/to-spec`, `/code-review`, `/wayfinder`.
- **Harness:** Claude official marketplace `claude plugins install mattpocock-skills` **or** `npx skills add mattpocock/skills` (pick skills; include `setup-matt-pocock-skills`). Do **not** do both (duplicates).
- **Stats:** **257,016 ★**, MIT, pushed 2026-09-04. (Star count is marketplace-viral; treat as popular, not as 257k-LOC software.)
- **Overlap:** Superpowers `brainstorming` ≈ `grill-me`; Superpowers `tdd` / `requesting-code-review` / `writing-plans` ≈ Matt's tdd/code-review/to-spec. Matt's **domain model / CONTEXT.md** is the piece Superpowers does not have.
- **Call:** **INSTALL only** `grill-with-docs` and `domain-modeling` (plus `setup-matt-pocock-skills` once per repo). SKIP tdd/implement/review/wayfinder.

```sh
npx skills add mattpocock/skills --skill grill-with-docs domain-modeling setup-matt-pocock-skills
```

### gastownhall/gastown (bundled skills) — SKIP

- **What:** Gas Town is a **Go multi-agent workspace manager** (Mayor, rigs, polecats, Beads ledger, Dolt). **18k ★**, MIT, pushed 2026-09-03. Bundled Claude skills under `.claude/skills/`: **`crew-commit`**, **`ghi-list`**, **`pr-list`**, **`pr-sheriff`**. They are Gas Town internals (commit/list/sheriff against Beads + `gt` CLI), not portable methodology.
- **Overlap:** firstmate/treehouse already cover crew/worktrees. GitHub Projects is the board (Beads is a competing ledger — prior audit already rejected switching).
- **Call:** **SKIP the skills and the runtime.** Do not install Gas Town.

### obra/superpowers — INSTALL (already picked; keep as the methodology backbone)

- **What:** Mandatory workflow: brainstorm → worktree → plan → TDD → subagent-driven-dev → review → finish branch. Skills listed in README: `brainstorming`, `writing-plans`, `executing-plans`, `dispatching-parallel-agents`, `subagent-driven-development`, `test-driven-development`, `systematic-debugging`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`, `using-git-worktrees`, `finishing-a-development-branch`, `writing-skills`, `using-superpowers`.
- **Harness:** First-class on **Claude Code, Codex, Cursor, Grok Build, OpenCode, Pi, Hermes**, plus Copilot/Gemini/Kimi/Devin/Factory. Install **per harness**.
- **Stats:** **283,410 ★**, MIT, pushed 2026-09-08.
- **Call:** **INSTALL on every worker Kevin actually runs.**

```sh
# Claude Code
/plugin install superpowers@claude-plugins-official
# Grok Build
grok plugin install superpowers@xai-official --trust
# Codex: /plugins → Superpowers
# Hermes
hermes plugins install obra/superpowers --enable
```

Set `SUPERPOWERS_DISABLE_TELEMETRY=1` (logo-fetch telemetry is on by default).

### Recommended skill set (no duplication)

| Slot | Skill | Where | Why this one |
|---|---|---|---|
| Methodology (mandatory) | **obra/superpowers** (full) | Claude Code, Grok Build, Codex, Hermes | Already picked. Owns TDD/plan/review/worktrees. |
| Align + glossary | **mattpocock `grill-with-docs` + `domain-modeling`** | Same harnesses, via `npx skills` | CONTEXT.md/ADR layer Superpowers lacks. |
| Consult | **kunchenguid `/kun`** | Global, invoke-on-demand | Living principal-engineer voice; does not fight Superpowers. |
| Factory template (read, don't auto-trigger) | **coleam00 `build-dark-factory`** as a *doc* next to Archon | Human + Archon wiring session | Patterns for MISSION.md / holdout. Not a runtime. |

**Do not install:** Cole's 33-skill plugin, Matt's full set, Superdesign, Gas Town skills, gstack wholesale (§5).

---

## 4. ZERO-COST memory — architecture ($0/month)

Hard constraints honored: no SaaS, no hosted vector DB, no extra paid tokens for memory generation. Local LM Studio inference is free. Grimdex already covers durable *decisions*.

### 4a. Operational recall — pick **projectmem** (in-repo files, not the Pi)

| Option | Verdict |
|---|---|
| **projectmem** (riponcm/projectmem, **799 ★**, MIT, Python, v0.3.2, pushed 2026-09-07) | **PICK.** Typed events (issue / attempt / fix / decision / note) in `.projectmem/events.jsonl`. Distilled `summary.md` is what the agent reads (~800–1,500 tokens via MCP `get_summary()`, never the raw log). **Pre-commit warning** (`pjm precheck`) is the unique "don't repeat yesterday's failed fix" gate. 100% local, no telemetry. One MCP server for every repo since 0.3.0. |
| SQLite file on the Pi | Worse. You'd reimplement typed events, distillation, and the pre-commit hook. Network hop for a 2k-token summary is slower than a git-tracked file next to the code. Use the Pi for the *index* (§4c), not for operational memory. |
| Just git | Git records *what changed*. It does not record "tried JWT middleware, failed, do not retry." That is why projectmem exists. Grimdex is the decision layer; projectmem is the attempt/failure layer. |

```bash
pip install -U projectmem
cd /path/to/baton && pjm init
# MCP once, all projects:
#   command: $(which python)
#   args: ["-m", "projectmem.mcp_server"]
pjm doctor --fix
```

Commit distilled files (`summary.md`, `PROJECT_MAP.md`, `AI_INSTRUCTIONS.md`). Keep `events.jsonl` gitignored if the raw log is noisy; or commit it — it's plaintext. Baton's existing `remember` / `recall` commands can stay as a thin wrapper that shells to `pjm` so the factory doesn't grow a second event schema.

**Token spend on generation:** zero extra. The agent logs events with MCP tools during work it was already doing. Distillation is local Python, not an LLM call.

### 4b. Grimlore wiki — OpenWiki *can* hit LM Studio; still too heavy as the default

**Yes, OpenWiki speaks LM Studio** via the `openai-compatible` provider (documented in langchain-ai/openwiki README, **16,282 ★**, MIT, pushed 2026-09-08):

```bash
# Mac Mini, LM Studio Developer → Local Server on :1234
export OPENWIKI_PROVIDER=openai-compatible
export OPENAI_COMPATIBLE_API_KEY=lm-studio          # required by the client; LM Studio ignores it
export OPENAI_COMPATIBLE_BASE_URL=http://127.0.0.1:1234/v1
export OPENWIKI_MODEL_ID='<id from GET /v1/models>'  # must be a tool-calling chat model
export OPENWIKI_TELEMETRY_DISABLED=1
# if the local server is stream-only:
# export OPENWIKI_OPENAI_COMPATIBLE_STREAMING=true

npm install -g openwiki
cd /path/to/repo && openwiki --init     # writes openwiki/ as git-owned markdown
```

**Why it's still too heavy for Grimlore as default:**
- Generation is a **Deep Agents multi-turn tool loop per page** (begin → plan → next_page → submit_page → finish). A local 7–32B will burn hours of GPU and still stall if it can't emit tools. OpenWiki's own Ollama note: *"Local models must support tool calling — a model that cannot emit them will stall."*
- Visualizer pulls mermaid/graph libs from a **public CDN** (needs net; not a cost, but not air-gapped).
- Personal-wiki connectors want Tavily (`TAVILY_API_KEY`) for web-search — that *is* paid. Skip connectors.
- Coding-agent integration (`openwiki integrations install claude`) uses the *host's* model — that spends Claude/Codex quota, which Kevin does not want for wiki generation.

**Zero-cost fallback (recommended default):** **Karpathy-wiki pattern.**

- Wiki lives as ordinary markdown in the knowledge repo: `grimlore/{why,who,landscape}/*.md`.
- Written by the **same agent session already running** (Superpowers plan/review, or a `/kun` consult) — no separate generation job, no extra tokens beyond work Kevin was doing.
- Human edits in **Obsidian** pointed at that git folder (local app, $0). Optional publish: `git clone --depth 1` on the webhost as a static tree, or Obsidian Sync is paid — don't use it.
- OpenWiki is **opt-in later** for a single code repo that has a strong local tool-calling model loaded and a night to spare. Not the Grimlore backbone.

### 4c. Semantic search — nomic-embed-text-v1.5 + sqlite-vec

| Piece | Pick | Why |
|---|---|---|
| Embedding model | **nomic-embed-text-v1.5** GGUF (~84 MB Q4_K_M, 768-d, 8192 ctx, Matryoshka-truncatable to 256-d) | Small enough for the Pi *or* a side-load on Mac Mini LM Studio (`/v1/embeddings`). Better long-doc recall than all-MiniLM-L6-v2 (384-d, 256 tok). Apache-2.0. |
| Fallback tiny | all-MiniLM-L6-v2 (22M, 36 MB) | Only if the Pi chokes on nomic. |
| Index | **sqlite-vec** (`asg017/sqlite-vec`, **8,091 ★**, Apache-2.0/MIT, pure C, **runs on Raspberry Pi**, <1 MB extension) | File-based. No FAISS native-build pain on ARM. No numpy service to keep alive. SQL + KNN. Brute-force is fine under ~500k vectors (Grimdex will be thousands, not millions). |
| Do not use | FAISS (native build, not a file you scp to the webhost), Chroma (daemon), Pinecone/Weaviate hosted. |

Index **files**, not chat: Grimdex `decisions/*.md`, projectmem `summary.md`, Grimlore wiki `*.md`. Embed on the Mac Mini (LM Studio embeddings endpoint or `sqlite-lembed` with the GGUF). Copy `kb.sqlite` to the Pi.

If Baton's existing `kb-index` / `kb-search` can be pointed at a local embedding endpoint, **use that** and only swap the backend to sqlite-vec. Don't grow a second indexer.

### 4d. Where each piece runs — $0/month

```
┌──────────── git (knowledge repo, already pushed) ─────────────┐
│ Grimdex decisions/*.md                                        │
│ Grimlore {why,who,landscape}/*.md   ← agent-written markdown  │
│ projectmem distilled summary.md / PROJECT_MAP.md              │
└───────────────────────────────────────────────────────────────┘
         ▲ clone/pull                         ▲ clone/pull
┌────────┴────────┐                  ┌────────┴─────────┐
│ Mac Mini 24GB   │  embeddings      │ Raspberry Pi     │
│ LM Studio :1234 │ ───────────────► │ sqlite-vec       │
│  - chat models  │  nightly index   │ kb.sqlite        │
│  - nomic-embed  │    scp/rsync     │ tiny HTTP search │
│ projectmem MCP  │                  │ (python -m http  │
│ (stdio, local)  │                  │  or caddy file)  │
│ OpenWiki opt-in │                  └────────┬─────────┘
└─────────────────┘                           │ Tailscale
                                     ┌────────┴─────────┐
                                     │ shared webhost   │
                                     │ static md tree   │
                                     │ + optional copy  │
                                     │ of kb.sqlite     │
                                     │ (read-only)      │
                                     └──────────────────┘
Workers (4090/5090/2070S, Omarchy): read git; call projectmem MCP
on the Mac (or locally if the repo is checked out). No extra $ .
```

| Item | $/month |
|---|---|
| projectmem, sqlite-vec, nomic GGUF, Obsidian, git, Tailscale, Pi, webhost, LM Studio | **$0** (hardware Kevin already owns) |
| OpenWiki default-on telemetry | off via `OPENWIKI_TELEMETRY_DISABLED=1` |
| Superpowers logo telemetry | off via `SUPERPOWERS_DISABLE_TELEMETRY=1` |
| **Total** | **$0** |

Nightly on Mac Mini (launchd / cron, already-on box):

```bash
# 1. pull KB
cd ~/knowledge && git pull --ff-only
# 2. embed changed .md → kb.sqlite (local nomic via LM Studio /v1/embeddings)
python3 ~/baton/scripts/kb_index.py --root ~/knowledge --db /tmp/kb.sqlite \
  --embed-url http://127.0.0.1:1234/v1/embeddings --model nomic-embed-text-v1.5
# 3. ship index to Pi
scp /tmp/kb.sqlite pi:~/kb/kb.sqlite
```

---

## 5. garrytan/gstack — SKIP / study-only

| | |
|---|---|
| What | Garry Tan (YC CEO) open-sourced his Claude Code setup: **23 specialist slash-commands + 8 power tools** (office-hours, plan-ceo/eng/design-review, /review, /qa with a real browser, /ship, /cso OWASP+STRIDE, /learn, …). Turns one session into a "virtual engineering team." |
| Language | TypeScript + Bun. Skills are Markdown. Setup writes into `~/.claude/skills/gstack`. |
| Stats | **132,164 ★**, MIT, created 2026-03-11, pushed **2026-09-08**, **19,779 forks**, **869 open issues**. Mature-as-a-skill-pack, productized (Aside browser, GBrain, iOS QA daemon, telemetry-opt-in). |
| Problem it solves | Opinionated sprint process for a founder shipping product UI with Claude Code, 10–15 parallel Conductor sessions, browser QA. |

**SKIP wholesale.** Reasons, given current picks:

1. **Superpowers already is the methodology.** Installing gstack beside it is two mandatory workflows fighting (gstack SessionStart auto-update hook + Superpowers bootstrap).
2. **Token bomb.** 23 skills of frontmatter on every Claude session. gstack even ships `gstack-context-bill` because this is a known cost.
3. **Claude-first.** `./setup --host` covers Codex/Cursor/OpenCode/Hermes/OpenClaw, but the depth (browser, verify-gate, Aside) is Claude Code on macOS. Kevin's factory is multi-worker + Windows boxes.
4. **GBrain is not $0.** `/setup-gbrain` paths are Supabase (hosted) or PGLite (local but another datastore next to Grimdex). Memory is already Grimdex + projectmem.
5. **Browser QA** overlaps Playwright skill + Ringer/no-mistakes. Don't add Aside + bundled Chromium + ML prompt-injection sidecar.

**Study-only (read, don't install):** `/office-hours` six forcing questions, `/cso` confidence-gated security review, `/qa` "eyes on staging → atomic fix → regression test." Fold any of those *ideas* into Superpowers/Ringer, not as 132k-star tooling.

```text
# do not run
git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack && ./setup
```

---

## 6. Sumanth077/ai-engineering-toolkit — genuine gaps only

Curated list, **3,386 ★**, MIT, last push **2026-05-11** (stale-ish). Categories: vector DBs, orchestration, RAG, eval, scraping, agent frameworks, fine-tune, inference, safety, local serving, structured generation.

Already covered by Baton picks / this report: LangChain/LlamaIndex/CrewAI/AutoGen (skip — Archon is the DAG), Ollama/LM Studio/vLLM/llama.cpp (fleet), Firecrawl/Playwright (already in skills), Mem0 (paid/not local), Superpowers/skills, FAISS listed but sqlite-vec is the right local choice.

**Genuine gaps (not restatements):**

1. **Structured generation for local models** — `Outlines` (Apache-2.0, constrained decoding) or `Instructor`. Baton's Governor/router will need schema-valid JSON from LM Studio models that otherwise drift. This is a library in the Python core, not a product.
2. **OpenAI-compat gateway in front of the heterogeneous fleet** — `LiteLLM` (MIT) or equivalent. One URL, many backends (4090 vLLM later, Mac Mini LM Studio, 2070S). Only if Baton's homemade router is still doing ad-hoc base_url switching after the 5–6k collapse. Don't add it *and* keep a custom router.
3. **Prompt-injection / tool-abuse tests** — `Garak` (MIT). One-shot red-team of agent tools and the Herdr session boundary. Not a runtime dependency.
4. **Doc ingest for Grimlore** — `Docling` (MIT) if the wiki must absorb PDFs/DOCX. Skip if Grimlore stays markdown-only.
5. **Self-hosted traces (optional)** — Phoenix or Langfuse OSS. Only if Governor debugging needs request traces. Default: stay on files + git. Not required to ship.

Not gaps: SkyPilot (Kevin has a home fleet, not cloud GPUs), unsloth/Axolotl (no training mandate), Dify/Langflow (UI builders), Guardrails-as-a-platform.

---

## 7. vadimdemedes/ink — do not build a bespoke TUI; if a CLI, Python

| | |
|---|---|
| What | React renderer for interactive CLIs (Flexbox in the terminal). **39,837 ★**, MIT, TypeScript, pushed 2026-09-08. Used by many Node CLIs. |
| Maturity | High. Wrong language for Baton's core. |

**Does Baton need a bespoke TUI?** **No.**

- Session UI: **Herdr** (already picked).
- Board: **GitHub Projects**.
- Workflow UI: **Archon** (and Ringside if that's in the validation path).
- Worker TUIs: Claude Code / Grok Build / Codex / Hermes already are TUIs.
- Overnight factory: `archon-lifecycle` + `consumer.py tick` — headless.

A fourth interactive surface is how the 60k-LOC factory happened.

**If a thin status/control CLI is wanted** (`baton status`, `baton halt`, `baton who-is-on-fire`):

- **Python + Typer + Rich**, same language as the 5–6k core. One `pip` extra, no Node toolchain on the Windows boxes / Pi.
- **Not ink.** Ink means a Node package, React mental model, and a second runtime beside the Python router/Governor. The split is not "worth it" for a status table.
- **Not Textual** unless someone is sitting in a dashboard all day. Textual is a full TUI app; Rich print/live tables are enough. Gas Town's `gt feed` / `gt dashboard` are the cautionary tale of growing a monitoring product.

**Recommendation:** **no TUI project.** Ship `baton` as a Typer CLI with Rich output, commands that shell to `gh`, `pjm`, and Archon's `consumer.py`. Ink is a study-only curiosity.

---

## Scoreboard

| Item | Verdict |
|---|---|
| deepseek-harness | SKIP |
| Pi | SKIP (already inside OpenClaw) |
| oh-my-pi | SKIP (fork of Pi; competing worker) |
| t3code | SKIP (Herdr's job) |
| KunAgent/Kun | SKIP (PolyForm NC) |
| coleam00/ai-software-factory | **ADD patterns** (Archon factory skin; wait for a license before vendoring) |
| LMCache | SKIP unless fleet moves to vLLM + shared prefix |
| Superpowers | INSTALL (all workers) |
| /kun skill | INSTALL (on-demand) |
| Matt grill-with-docs + domain-modeling | INSTALL |
| Cole skills / Superdesign / Gas Town skills / gstack | SKIP (gstack = study-only) |
| Memory | projectmem + git wiki + nomic + sqlite-vec = **$0** |
| OpenWiki | LM Studio: yes. Default: no (too heavy). Opt-in later. |
| ink TUI | NO. Python Typer/Rich if any CLI. |
