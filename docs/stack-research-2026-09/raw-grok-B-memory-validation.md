# Job B — Memory / Validation / Doc-converters / PII / Support

**Assessor:** Grok 4.6  
**Date:** 2026-09-08  
**Scope:** one fetch per repo; starred repos deep-dived; rest classified from README + GitHub metadata.  
**Baton irreducibles (do not replace):** (1) cost-optimal routing that *learns from measured scores of the private local fleet*; (2) Grimdex decisions/lessons KB + Grimlore context layer.

Stars / last push are as of 2026-09-08/09 via `gh api`.

---

## How to read this

Each repo gets **one** verdict:

| Verdict | Meaning |
|---|---|
| **REPLACE** | Adopt this instead of a homemade Baton piece. Name what it replaces. |
| **ADD** | New capability worth bringing in. Name where it plugs in. |
| **KEEP-BUILD** | Baton already does this uniquely / better. Do not adopt. |
| **SKIP** | Noise, redundant with a better pick, immature, abandoned, or wrong layer. |

---

## Direct answers to the five key questions

### 1. Memory: replace, complement, or cherry-pick?

| System | Call vs Grimdex | Call vs Grimlore |
|---|---|---|
| **OpenWiki** | Complement. Do not replace Grimdex. | **This is how Grimlore should work.** Adopt OpenWiki as the *writer/maintainer* of Grimlore-shaped wikis (Markdown + OKF v0.2 + Grounded Claims + graph visualizer). Keep Grimlore's authoring rules (`GRIMLORE.md`, `x-grimdex`) as the schema OpenWiki is instructed to obey. |
| **Caura** | Complement. Do not replace Grimdex. | Complement / cherry-pick. Caura is *fleet runtime memory* (write → recall → compound, trust tiers, MCP, UI). Grimlore is a *compiled, git-backed wiki*. Use Caura for cross-agent operational recall and the dashboard Kevin wants; never let Caura's pgvector store become the source of truth for decisions. |
| **Letta / letta-code** | Do not replace. | Do not replace. Letta is a *stateful agent harness* (MemGPT lineage), not a knowledge base. Optional later as a personal always-on agent; not the factory memory plane. |
| **Supermemory** | Do not replace. | Skip for Baton core. Strong product memory API; overlaps Caura if Caura is chosen; cloud-first personality fights the local/GitHub-backed bet. |
| **Karpathy LLM Wiki gist** | n/a | **Design pattern, not a product.** OpenWiki is the production implementation of this pattern. Grimlore should keep: immutable sources, LLM-owned wiki, schema file, ingest/query/lint, `index.md` + `log.md`. |

**Clear call:** Grimdex stays. Grimlore stays as the *what* (git markdown wiki + OKF). OpenWiki becomes the *how* (agent that writes and claims-checks it). Caura is the *fleet working memory + UI*, sitting beside both, never above them.

### 2. Validation: Ringer vs no-mistakes vs deepsec?

**Both Ringer and no-mistakes, at different stages. Deepsec is a third, expensive, security-only lane.**

| Stage | Tool | What "done" means |
|---|---|---|
| Swarm / implementation | **Ringer** | Worker's artifact is executed (`check` exit 0). Agent "done" is not evidence. Ringside is the live HUD. |
| Pre-merge / PR | **no-mistakes** | `git push no-mistakes` → isolated worktree → review/test/docs/lint → only then origin + PR. Human stays on findings. |
| Periodic / high-value security | **deepsec** | Agent-powered vuln hunt. Can cost thousands on a large repo. Not a default pre-merge gate. |
| Semantic review (optional) | Superpowers `requesting-code-review` + Ringer's "orchestrator still reviews PASS diffs" | Executed checks catch laziness, not subtle wrongness. Keep a human/frontier review on load-bearing diffs. |

Ringer's own README is explicit: a green check is not proof of semantic correctness; orchestrator patch review stays mandatory. That matches Baton's Governor + Plan Gate posture.

### 3. Local doc-converter stack (2–3 tools)

**Pick: pdf-inspector (router) + Docling (default converter) + Pandoc (interchange). Optional GPU fallback: Marker or MinerU on the 4090/5090 boxes only.**

| Job | Tool | Why |
|---|---|---|
| PDF triage (text vs scanned vs mixed), <200 ms | **pdf-inspector** | Cheap routing so you do not OCR 54% of PDFs that already have a text layer. |
| Default convert: PDF, DOCX, PPTX, XLSX, HTML, EPUB, email, images | **Docling** | Kevin's lead pick, and it earns it: MIT, LF AI, IBM origin, local, MCP + API server, unified `DoclingDocument`, agent skills. |
| HTML / Markdown / Office interchange, already-clean markup | **Pandoc** | 15+ years, GPL, no ML, deterministic. Use when the file is already structured. |
| Lightweight Office/simple PDF fallback | MarkItDown (keep on the shelf, not the default) | Huge, simple, LLM-oriented Markdown. Weaker layout/tables than Docling. |
| Hard scanned / math / Chinese / GPU | Marker *or* MinerU on Firefly/wraith2 — **not** the default path | Marker wins olmocr-bench vs Docling on PDFs; MinerU is the GPU tank. Both are heavier and have license/ops cost. |

Do **not** run all five converters. Route: `pdf-inspector` → (text PDF or Office/HTML) Docling or Pandoc → (scanned/math, GPU available) Marker/MinerU.

### 4. PII: Presidio as a local preprocessing gate?

**Yes. Local-only is feasible. Put it after conversion, before any non-local model sees the text.**

Pipeline:

```
raw file
  → Docling / Pandoc / pdf-inspector
  → Presidio analyzer (local spaCy/regex/checksum recognizers)
  → if destination is local LM Studio: pass through, optionally flag
  → if destination is Claude/Codex/Grok/OpenRouter/Caura-cloud: anonymize
  → then OpenWiki ingest / Caura write / swarm spec
```

- Runs fully local (pip or Docker). No cloud. Python 3, MIT.
- Do **not** treat Caura's built-in `contains_pii` flag as the only gate — that fires *on write into Caura*, after the text may already have been sent to Caura's enrichment LLM.
- Presidio does not guarantee 100% recall. Fail closed for high-risk docs (tax, medical, real email): local models only, or human review of the analyzer hits.
- Org note: repo moved Microsoft → `data-privacy-stack`. Still actively pushed (2026-09-08). Transition is a watch item, not a skip.

### 5. Token tracking: CodexBar / ccusage vs quota-axi?

**Keep all three, in different seats. Do not standardize on CodexBar as the factory probe.**

| Seat | Tool | Role |
|---|---|---|
| Human HUD (Mac) | **CodexBar** | Menu-bar limits / reset countdowns. Already used. Keep. |
| Human HUD (Windows 4090/5090 boxes) | **Win-CodexBar** | Same idea, tray app. Keep. |
| Claude Code cost CLI | **ccusage** | `npx ccusage` session/daily/monthly from local JSONL. Keep. |
| Machine-readable fleet probe | **quota-axi** (`kunchenguid/quota-axi`) | This is what Baton's Governor should *read*. Reports quota; does not enforce budget. |
| Enforcement | **Baton Governor (KEEP-BUILD)** | Hard spend caps, 5-hour windows, `:11` anchoring, conserve mode, dispatch gating. quota-axi does not replace this. |

CodexBar is a dashboard for Kevin. quota-axi is a library for the router. Mixing them is how the homemade quota probe stays alive.

---

## Recommended stacks (this slice)

Primary coding harness for *this* slice of the factory (concept → plan → verified ship): **Superpowers as the methodology, on one lead harness (Claude Code or Grok Build), with Ringer as the cheap-worker swarm.** Do not run Superpowers + Spec Kit + OpenSpec together.

### Stack A — recommended (memory + validation + docs)

**OpenWiki (Grimlore engine) + Grimdex (KEEP) + Caura self-hosted (fleet UI/runtime memory) + Ringer (executed swarm checks) + no-mistakes (pre-merge) + Docling + pdf-inspector + Pandoc + Presidio + Superpowers + quota-axi/CodexBar.**

Why: matches Kevin's words. OpenWiki *is* the Grimlore shape (self-maintaining wiki, claims, visualizer, OKF v0.2). Caura is the UI/fleet-memory layer he said he wants Baton to reach. Ringer is the work-checking layer he called critical. Docling is his converter pick. Presidio is the local PII gate. Superpowers is the concept→plan flow already in the vision.

Tradeoffs: Caura is a real service (Postgres + pgvector + Redis + Docker). OpenWiki generation costs tokens (mitigate with LM Studio / OpenAI-compatible provider, or host-driven Codex/Claude/Grok integrations). Ringer is young (created 2026-07, 282★, PolyForm Shield). Two validation tools (Ringer + no-mistakes) is the right split, not duplication.

**Primary harness:** Superpowers-on-Grok (lead) / Claude Code (orchestrator when needed). Run **more than one harness as workers** (Codex, Grok, OpenCode+OpenRouter) *through Ringer*, not as three competing orchestrators.

### Stack B — conservative (no Caura ops)

**Grimdex + OpenWiki + projectmem (local session memory) + Ringer + no-mistakes + Docling + pdf-inspector + Presidio + Superpowers.**

Why: if Caura's Docker/Postgres footprint is too much this quarter. projectmem is the closest local-first "don't repeat yesterday's failed fix" layer (the Baton `/remember`/`/recall` shape). You lose Caura's UI, trust tiers, Interviewer, and fleet compounding.

Tradeoff: Kevin does not get "Baton at Caura UI level." Revisit Caura once the 5–6k core exists.

### Stack C — do not pick as memory plane

**Letta-code as the stateful harness + Letta Cloud for memory.** This replaces the coding harness rather than plugging into Baton. Letta V1 server is archived; current source is `letta-code` (recent rewrite). Wrong layer for Grimdex/Grimlore. Optional later as a personal always-on agent on the Mac Mini, not the factory.

---

## Maturity risk (explicit)

| Repo | Risk |
|---|---|
| **ringer** | Young (2026-07), 282★, ~101 commits, one-product shop (Nate Jones / LEJ). PolyForm Shield — fine for personal use, cannot ship a competing hosted Ringside. **Adopt anyway** for the executed-check invariant; pin a commit; do not depend on self-update in the factory path. |
| **caura** | Rename from MemClaw, v2 embedding-dimension migration, Docker multi-service. Production claim at eToro. Apache-2.0, actively pushed. **Ops risk, not abandonment risk.** Self-host; do not use managed caura.ai as the brain. |
| **openwiki** | New (2026-06) but LangChain-org, 16k★, MIT, TypeScript, CI, OKF. Telemetry on by default (`OPENWIKI_TELEMETRY_DISABLED=1`). Host-driven integrations are the right cost path. **Low org risk, young-product risk.** |
| **letta / letta-code** | `letta` repo is now a landing page; V1 archived. Real code in `letta-code` (3.3k commits, 3.2k★). Recently rewritten harness. `letta-obsidian` last push 2026-02. **Rewrite risk.** |
| **no-mistakes** | 8.3k★, Go, active, same author as quota-axi. Young (2026-04) but dogfooded hard. **Acceptable.** |
| **deepsec** | vercel-labs, 7.9k★, Apache-2.0. Cost can be thousands/run. Labs, not a promised SLA. **Use with `--max-cost-usd`.** |
| **hound** | Looking for a new maintainer. Last push 2026-07. Optimized for small/smart-contract codebases. **Skip.** |
| **presidio** | Mature (2018), org transition Microsoft → data-privacy-stack. Watch the transition; tool itself is the standard. |
| **marker** | Apache-2.0 *code*; **model weights OpenRAIL-M** (commercial restriction above $5M). Fine for personal use. Heavier GPU path. |
| **MinerU** | Custom license (moved off AGPL to Apache-based custom). Heavy. Optional GPU only. |
| **harness-mem** | BUSL-1.1. **License skip.** |
| **spec-kit** | GitHub 1.0.0, 134k★. Overlaps Superpowers. Don't run two SDD religions. |
| **Understand-Anything** | 82k★ viral graph UI. Overlaps OpenWiki visualizer + Ix. |

---

## Verdict list

### Deep-dive

#### NateBJones-Projects/ringer — **ADD**
**Work-checking layer for swarm implementation. Replaces homemade "agent said done" verification, not Grimdex.** Parallel workers (Codex / Grok / OpenCode+OpenRouter), executed `check` commands, one retry with failure context, Ringside HUD, local `runs.jsonl` scoreboard, worktrees. Directly serves Kevin's "this is all for checking work." Plug in: Baton/Ringer manifest per swarm; Ringside as the live dashboard; feed pass rates into Baton's router (local-fleet scores still stay Baton-owned). Maturity: young, PolyForm Shield. Pin it.

#### caura-ai/caura — **ADD** (complement; cherry-pick UI + fleet memory)
**Does not replace Grimdex or Grimlore.** Governed shared memory for multi-agent fleets: MCP (`caura_write`/`recall`/`evolve`), trust tiers, knowledge graph, contradiction supersession, PII *flagging*, OpenClaw plugin, Interviewer (harvests Claude/Cursor transcripts), Broker (local redaction before anything leaves the machine), Skill Factory. Kevin wants "Baton at that UI level" — that is the dashboard/recall surface, not the git-backed decision log. Self-host (Docker, local embedder, no phone-home). Do not make Caura the source of truth; write Grimdex decisions *into* Caura as `decision` memories if useful, but the file in GitHub remains canonical. **Cherry-pick if not adopting whole:** Interviewer, Broker redaction posture, Skills Inbox UI ideas.

#### langchain-ai/openwiki — **ADD** (Grimlore engine)
**This is the Grimlore implementation, not a Grimdex replacement.** CLI that writes a linked Markdown wiki, Grounded Claims with versioned source evidence (`repo://file#L40-L82`), OKF v0.2 (Grimlore already authors OKF v0.2), graph visualizer, self-update via GHA, coding-agent integrations (Codex, Claude Code, OpenCode, Cursor), OpenAI-compatible / LM Studio provider. Personal mode exists but **code mode is the Grimlore path.** Instruct OpenWiki via `openwiki/INSTRUCTIONS.md` to obey `GRIMLORE.md`. Disable telemetry. Use `--update` in CI so the wiki does not rot.

#### docling-project/docling — **ADD** (lead local converter)
**Replaces any homemade doc→markdown path.** MIT, local, PDF layout/tables/formulas, DOCX/PPTX/XLSX/HTML/EPUB/email/images/ODF, MCP + `docling-serve`, agent skills. Default converter after pdf-inspector routing. IBM/LF AI — mature.

#### data-privacy-stack/presidio — **ADD** (PII gate)
**New capability Baton does not uniquely own.** Local analyzer + anonymizer + image redactor + structured. Plug in as preprocessing before non-local models and before Caura enrichment. Not a replacement for publishing-guard (that's git/history); this is *content* leaving the machine.

#### letta-ai/letta — **SKIP** (as memory plane)
Landing page. V1 server archived. Not the thing to install.

#### letta-ai/letta-code — **SKIP** (for factory memory); optional later as a personal harness
Stateful agent harness with MemFS (git-tracked memory blocks), dreaming, skills, subagents, channels. Recently rewritten. Competes with Claude Code / Grok / Superpowers as a *harness*, not with Grimdex. Do not adopt as Baton memory. Revisit only if Kevin wants an always-on personal agent on the Mac Mini.

#### letta-ai/letta-obsidian — **SKIP**
Vault-sync plugin. Last push 2026-02. Stale relative to letta-code rewrite. If a wiki viewer is needed, Obsidian-on-OpenWiki-markdown is enough (Karpathy's own setup).

---

### Quick-classify — Memory

#### supermemoryai/supermemory — **SKIP**
29k★, #1 on LongMemEval/LoCoMo marketing, local binary exists. Product memory/RAG/profiles/connectors. Overlaps Caura; cloud-shaped; not git-backed decisions. If Caura is too heavy *and* projectmem is too small, this is the fallback — not the first pick.

#### riponcm/projectmem — **ADD** (session / "don't repeat failed fixes")
Local-first MCP memory for coding agents: records issues, attempts, fixes, decisions; warns before repeating a failed approach. 799★, MIT, arXiv, Windows watcher. **This is Baton `/remember`+`/recall` as a maintained tool.** Complements Grimdex (operational attempt log vs durable law). Use in Stack B; even in Stack A it can sit under Caura as the cheap local precheck.

#### rohitg00/agentmemory — **SKIP**
28k★ viral "persistent memory for coding agents," Karpathy-wiki implementation on `iii` engine. Overlaps OpenWiki (wiki) + Caura/projectmem (memory). 579 open issues. Too much product, not enough unique Baton fit.

#### agent0ai/dox — **ADD** (pattern, not a runtime)
Tiny AGENTS.md hierarchy: walk docs before edit, update after. No install. **Lift the idea into OpenWiki/Grimlore conventions** (local `AGENTS.md` already exists in Baton). Don't add a competing framework.

#### Eversmile12/sharedcontext — **SKIP**
50★, last push 2026-02, Arweave-synced encrypted MCP memory. Stalled. Wrong persistence model (Arweave vs GitHub).

#### swarajbachu/cachezero — **SKIP**
19★, last push 2026-04. Karpathy-wiki bookmark toy. OpenWiki covers this.

#### NateBJones-Projects/OB1 — **SKIP**
4.6k★ "Open Brain" — personal thinking DB + Slack capture + MCP. 45-minute DIY infra. Overlaps Caura personal/fleet memory and OpenWiki personal mode. Not coding-factory memory. License NOASSERTION. Skip unless Kevin wants a *life* brain separate from Baton.

#### ai-genius-automations/hindsight — **SKIP**
2★ fork/mirror of Vectorize Hindsight (the real project is `vectorize-io/hindsight`). Cloud agent-memory SaaS. Wrong repo, wrong layer.

#### Chachamaru127/harness-mem — **SKIP**
37★ local SQLite continuity between Claude/Codex. **BUSL-1.1.** projectmem covers the need with MIT.

#### cocoindex-io/cocoindex — **ADD** (later; incremental corpus indexing)
11k★ Rust incremental engine: code, Slack, PDFs, meetings → fresh agent context, only the delta reprocessed. Plug in if Grimlore/OpenWiki ingest of large messy corpora becomes a bottleneck. Not week-one.

#### cocoindex-io/cocoindex-code — **ADD**
2.7k★ AST-based embedded code search CLI + MCP. "70% token saving." Plug in as an agent tool for code navigation, alongside or instead of naive grep. Complements OpenWiki (wiki is compiled understanding; this is live AST search).

#### gist:karpathy/llm-wiki — **ADD** (design law for Grimlore)
Not a repo to install. The pattern: immutable `raw/` sources, LLM-owned `wiki/`, schema file, ingest/query/lint, `index.md` + `log.md`, Obsidian as IDE. OpenWiki is the maintained implementation (plus Grounded Claims, which the gist lacks). **Copy the invariants into `GRIMLORE.md`; do not build a third wiki engine.**

---

### Quick-classify — Validation / review

#### kunchenguid/no-mistakes — **ADD** (pre-merge gate)
**Replaces homemade PR-quality gates.** `git push no-mistakes` → disposable worktree → AI validation pipeline → origin + PR. Agent-agnostic (claude, codex, grok, opencode, copilot, …). Complements Ringer: Ringer verifies *worker artifacts during the swarm*; no-mistakes verifies *the branch before it becomes a PR*. Same author as quota-axi — stack coherence.

#### scabench-org/hound — **SKIP**
813★ graph-driven security auditor. Maintainer explicitly looking for a replacement. Last push 2026-07. Tuned for small/smart-contract repos. deepsec is the security pick.

#### tirth8205/code-review-graph — **SKIP** (redundant)
31k★ local-first code intelligence graph for cheaper reviews. Real product, but Ix (structural map) + OpenWiki (compiled wiki) + cocoindex-code (AST search) cover the need. Don't add a fourth graph.

#### vercel-labs/deepsec — **ADD** (security lane, not default CI)
Agent-powered vuln scanner, resumable, `--max-cost-usd`, `process --diff` for PRs. Plug in: scheduled or on high-risk repos; never unbounded. Complements Ringer/no-mistakes (those check "does it work / is the PR clean"; this checks "is it exploitable").

---

### Quick-classify — Doc converters (local only)

#### microsoft/markitdown — **SKIP** as default; **shelf** as lightweight fallback
181k★, simple Office/PDF/HTML → Markdown. Weaker layout/tables than Docling. Useful as a no-GPU, no-model, "just give me text" fallback. Azure CU/Doc Intel paths are **not** local — ignore those.

#### datalab-to/marker — **SKIP** as default; **optional GPU** for hard PDFs
39k★, best-in-class PDF→MD/JSON on olmocr-bench (balanced 76.0 vs Docling 50.3 in *their* table — treat as vendor bench). Model-weight license is OpenRAIL-M. Needs vLLM/llama.cpp. Use on 4090/5090 only when pdf-inspector says scanned/math and Docling quality is not enough.

#### firecrawl/pdf-inspector — **ADD** (router)
18k★ Rust. Classifies text vs scanned vs mixed in 10–50 ms, extracts text-layer Markdown without OCR. **First hop in the converter pipeline.** Prevents sending born-digital PDFs into MinerU/Marker.

#### jgm/pandoc — **ADD**
46k★, the interchange tool. HTML↔MD↔DOCX, no ML. Use for already-structured files and for producing concept-doc formats Kevin will actually read.

#### opendatalab/MinerU — **SKIP** as default; **optional GPU**
79k★, VLM+OCR, 109 languages, native DOCX/PPTX/XLSX, MCP. Custom license, heavy, Chinese-lab ops. Keep as the "nuclear" parser on a GPU box for scanned scientific PDFs Docling/Marker both fail. Not the Mac Mini path.

---

### Quick-classify — Spec-driven

#### github/spec-kit — **SKIP**
134k★ GitHub SDD toolkit, now 1.0.0. Overlaps Superpowers (brainstorm → plan → execute). Kevin already pointed at Superpowers for concept→plan. Running both splits the religion.

#### Fission-AI/OpenSpec — **SKIP** (unless Superpowers is rejected)
67k★ SDD, brownfield-friendly, `/opsx:propose`. Good product. Superpowers is the one already in the vision and installed across Grok/Claude/Codex/Hermes. One SDD system.

#### obra/superpowers — **ADD** (concept → plan → TDD execute)
283k★. Brainstorming → design chunks → implementation plan → worktrees → subagent TDD → review → finish branch. Native Grok Build / Claude / Codex / Hermes / OpenCode plugins. **This is the methodology layer for the vision's "fully-featured concept doc."** Plug in as mandatory skills on the lead harness. Do not reimplement as PowerShell.

---

### Quick-classify — Codebase understanding

#### ix-infrastructure/Ix — **ADD**
874★, Apache-2.0, active. Persistent system graph: `ix map` / `explain` / `trace` / `impact`, MCP. Complements OpenWiki (wiki is prose+claims; Ix is queryable structure). Small enough to try.

#### Egonex-AI/Understand-Anything — **SKIP**
82k★ interactive knowledge graph. Viral overlap with OpenWiki visualizer + Ix. Don't pay the second graph-UI tax.

#### tt-a1i/archify — **ADD** (concept-doc diagrams)
54k★ agent skill: typed JSON IR → deterministic HTML/SVG architecture/sequence/data-flow diagrams, before/after diffs. Plug into Superpowers brainstorming / OpenWiki pages so concept docs are readable. Not a memory system.

---

### Quick-classify — Token tracking

#### steipete/CodexBar — **ADD** (keep; human HUD on Mac)
21k★ menu bar, 69 providers, reset countdowns, privacy-first (reuses existing sessions). Kevin already uses it. Keep.

#### nesszer/Win-CodexBar — **ADD** (keep; human HUD on Windows boxes)
1k★ Tauri port, 56 providers, winget. Needed because the factory has Windows 4090/5090 machines. Keep.

#### ccusage/ccusage — **ADD** (keep; Claude Code CLI)
18k★. Local JSONL cost/usage for Claude Code. Keep as the Claude-specific CLI. Not the fleet probe.

**quota-axi (already in Baton's adopt list, not in this fetch list):** **REPLACE homemade usage-probe-lib.** Reports quota for the Governor; does not enforce. CodexBar/ccusage stay as human-facing; quota-axi is what dispatch reads.

---

### Quick-classify — Misc

#### LMCache/LMCache — **SKIP** (for now)
11k★ KV-cache layer for vLLM. Only relevant if Baton starts serving local models as a *shared inference cluster* with prefix reuse. Not memory, not validation. Revisit if Firefly/wraith2 move from LM Studio chat to vLLM.

#### Forward-Future/loopy — **SKIP**
3.1k★ library of agent loops + skill. Last meaningful push 2026-07. Interesting playbook catalog; Superpowers + Ringer already encode "try, check, retry, stop." Don't add another methodology pack.

#### unslothai/unsloth — **KEEP-BUILD** (already installed; out of this slice)
75k★ local fine-tune/UI. Useful for the local fleet later (task-type adapters). Not a Baton memory/validation/doc tool. Leave installed; don't weave into the 5–6k core.

---

## Recommended MEMORY stack

```
GitHub (source of truth)
  ├─ Grimdex          KEEP-BUILD   decisions, lessons, laws
  └─ Grimlore wiki    KEEP as schema; WRITE via OpenWiki
         ▲
         │ openwiki --update / host-driven Codex|Claude|Grok
         │ Grounded Claims + OKF v0.2 + visualize
         │
Caura (self-hosted, optional in Stack A)
  ├─ fleet runtime recall (MCP)
  ├─ UI / dashboard Kevin asked for
  ├─ Interviewer (harvest Claude/Cursor/Hermes transcripts)
  └─ never canonical for decisions

projectmem (Stack B, or under Caura)
  └─ local "this fix already failed" precheck  ≈ Baton /remember

cocoindex-code
  └─ AST search tool for agents

Ix
  └─ persistent structural map (impact/trace)
```

**Do not:** replace Grimdex with Caura/Letta/Supermemory.  
**Do not:** hand-write Grimlore if OpenWiki will maintain it.  
**Do:** put `OPENWIKI_TELEMETRY_DISABLED=1`, Caura `IS_STANDALONE` + local embedder, and Presidio in front of any cloud-bound write.

---

## Recommended VALIDATION stack

```
implement (cheap workers)
  → Ringer          executed checks, Ringside HUD, retry-once, eval log
                    (feeds pass rates; does NOT replace local-fleet routing)

pre-merge
  → no-mistakes     git-push proxy, worktree pipeline, PR open
                    Superpowers requesting-code-review still runs inside

security (scheduled / high-risk / --diff on sensitive PRs)
  → deepsec         cap with --max-cost-usd; not default CI

semantic / load-bearing diffs
  → frontier orchestrator review   Ringer PASS ≠ correct
```

Ringer is the work-checking layer. no-mistakes is the ship-checking layer. deepsec is the attacker-checking layer. All three can coexist without overlapping jobs.

---

## Recommended LOCAL DOC-CONVERTER + PII stack

```
file in
  ├─ PDF?  → pdf-inspector
  │            ├─ text/mixed high-confidence → Docling (or Pandoc if already clean)
  │            └─ scanned / math / low-confidence
  │                 ├─ CPU / Mac Mini → Docling OCR
  │                 └─ 4090/5090     → Marker or MinerU (optional)
  ├─ Office (docx/pptx/xlsx/odt) → Docling
  ├─ HTML / MD / already-structured → Pandoc
  └─ simple fallback → MarkItDown

then
  → Presidio (local) anonymize if destination is non-local
  → OpenWiki ingest / Caura write / swarm spec
```

**Two-to-three tools in daily use:** pdf-inspector + Docling + Pandoc.  
**Presidio is the fourth, always-on for egress.**  
**Marker/MinerU are GPU spares, not defaults.**

---

## Primary coding harness (this slice's call)

- **Standardize methodology on Superpowers** (already multi-harness: Grok, Claude, Codex, Hermes, OpenCode).
- **Lead orchestrator:** Grok Build (token discipline + already paid plan) with Claude/Opus only for the viability debate / hard review, matching Kevin's "Grok is lead, Opus only if truly needed."
- **Run more than one harness as workers, not as competing conductors:** Codex + Grok + OpenCode/OpenRouter **through Ringer**.
- **Do not** also run Spec Kit and OpenSpec.
- **Do not** make Letta-code the factory harness.

---

## What Baton should still KEEP-BUILD (this slice)

1. **Governor** — quota-axi reports; Governor enforces. CodexBar does not gate dispatch.
2. **Local-fleet routing on measured scores** — Ringer's `models --explore` is a cousin (OpenRouter catalog + executed pass rates) but does not benchmark Firefly/wraith2. Keep that bet in Baton. Optionally *ingest* Ringer JSONL as one more signal.
3. **Grimdex** — nothing in this list is a git-backed, model-agnostic decision/lessons KB with promotion rules. Caura's `decision` type is a runtime echo, not a replacement.

---

## Suggested next actions (not started)

1. Spike OpenWiki on one Baton-adjacent repo with LM Studio provider + `INSTRUCTIONS.md` pointing at Grimlore schema. Judge the visualizer vs Caura UI honestly.
2. Run Ringer `demo` + one real swarm with executed checks; install Ringside. Confirm Grok engine block.
3. Put Presidio + pdf-inspector + Docling on the Mac Mini as a local convert/redact service bound on Tailscale, not localhost-only.
4. Defer Caura self-host until spike (1) says the OpenWiki visualizer is not enough UI. If it isn't, Caura is the dashboard; OpenWiki stays the wiki.
5. Keep CodexBar / Win-CodexBar / ccusage; wire quota-axi into Governor; delete homemade usage-probe-lib when that lands.
)
