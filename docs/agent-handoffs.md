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
| Grok (`grok` CLI) | `GROK.md` (Grok-specific role); also loads `AGENTS.md` / `CLAUDE.md` via Grok project-rules discovery, and `.grok/rules/*.md` |
| GitHub Copilot | `.github/copilot-instructions.md` (add when adopted) |

Every agent should also read `docs/next-session.md` (the operating loop) and
`docs/roadmap.md` (status), and use the shared knowledge base (`Ryfter/grimdex-know`, the
private data repo — see the Grimdex split section below).

> **ACTIVE WORK QUEUE (2026-07-04):** seven spec'd-and-planned work packages are
> staged for any agent to pick up. Start at
> `docs/superpowers/plans/2026-07-04-backlog-execution-handoff.md` — it carries the
> package table, dependency/parallelization rules, the per-package execution
> protocol, and the binding house-rules digest. Claim a package by setting its
> Status cell to `IN PROGRESS (<agent>, <date>)` and committing that edit on your
> feature branch. Merges remain Kevin's word, always.

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

8. **Credentials live in the environment, never in a registry file.** An
   authenticated `kind: http` row names the *variable* (`api_key_env`), and the
   transport fails loudly rather than falling back to an anonymous request. See
   `docs/authenticated-instruments.md`. Corollary for prepaid providers
   (OpenRouter is the first): the spend ceiling is set on the vendor's key as
   well as in fleet policy — a Baton bug must not be able to drain a balance.

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
- **`GROK.md` — Grok = plan once-over peer + second implementer** (decision d080).
  Claude conducts; Codex + Grok review plans via `plan-review`. Fleet headless:
  `grok -p` / `--prompt-file` / `--always-approve`. Register with `agentic: true`
  (platform `grok` is outside d078's auto-infer set). Grimdex pointer stanza is
  maintained by `grimdex wire-project` alongside CLAUDE/AGENTS/GEMINI.

  `agentic` is one of two edit-eligibility fields on a fleet row; the other is
  `diff_apply` (decision d103, `feat/diff-apply-worker-path`). Where `agentic: true`
  claims a provider has its own filesystem harness (a CLI that opens and saves files
  itself), `diff_apply: true` opts a text-only transport (`kind: http` /
  `kind: stdio-json`) into a different mechanism entirely: Baton reads the files,
  the model returns SEARCH/REPLACE edit blocks as text, and Baton applies them. The
  scope oracle and the frozen verification contract are unchanged and remain the
  sole authorities either way — diff-apply only changes who holds the pen, not who
  judges the result. See `docs/diff-apply.md` for the full opt-in and grammar.

- **Usage probes** (`usage_policy.probe_transport`, #173) decide whether a row's
  soft caps are enforceable or decorative. A probe is resolved by transport NAME,
  observes only, and fails soft — except identity, which fails closed: without
  `usage_policy.probe_provider` the transport does not run rather than guess which
  account it is querying. Rows can bind to a model-scoped sub-quota via
  `usage_policy.scope_id`; a bound id absent from a response falls back to the
  plan-wide window, never to "unlimited," because the set of windows is
  plan-dependent and shrinks when a plan is downgraded. On Windows, `codexbar-cli`
  is the recommended (and for some providers the only) way to read remaining plan
  allowance. See `docs/usage-probes.md`.

## Drift policy
- Change a **shared** rule → change it **here** only; the model files don't repeat
  it, so they can't drift.
- Add a **model-specific** item → put it in that model's file **and** list it in the
  registry above, so every divergence is intentional and visible.

## Grimdex ecosystem — the three-layer boundary (2026-08-14, `grimdex:d018` + `grimdex:d019`)

**Authoritative for every agent on this project.** Full brief:
`D:\Dev\Grimdex-engine\docs\2026-08-14-grimdex-ecosystem-architecture.md`. Baton's own half:
[`ecosystem-boundaries.md`](ecosystem-boundaries.md). Grimlore design draft:
`D:\Dev\Grimdex-engine\docs\2026-08-14-grimlore-spec.md`.

> **The Law:** Bloat is the enemy of Grimdex. Context is the purpose of Grimlore. Execution is
> the purpose of Baton.

- **Grimdex** governs **how** coding work is done (rules, conventions, lessons, verification and
  security expectations, disciplined promotion). Smallest, most aggressively trimmed layer.
- **Grimlore** remembers **why / who / context** (rationale, history, environment, hardware,
  organization, audience, models, research). Format is **OKF v0.2** (`grimdex:d021`). Repo
  `Ryfter/Grimlore` (**private**, `D:\Dev\Grimlore`) stood up 2026-08-15 (`grimdex-d026`).
  Baton's landscape lives at `D:\Dev\Grimlore\projects\baton\` — start at `BATON.md`,
  then `index.md`. Reach it by **file path** (same as Grimdex). No indexer, no MCP,
  no assumption that every dispatch has Grimlore loaded. Isolation enforcement is
  still unchosen: load this bundle + `universal/` only.
- **Grimdex Baton** (this project) decides **what happens next and when**, then executes.
- **Grimdex-Know** is **not a layer** — it is the name of the private personalized Grimdex
  instance (`Ryfter/grimdex-know`, mounted at `D:\Dev\Grimdex`). Never diagram it as a peer.

**Routing rule when you're unsure where something goes:** changes *how* work is done → Grimdex;
explains *why/who/context* → Grimlore; makes something *happen* → Baton. *Grimdex prescribes. Grimlore
explains. Baton acts.*

**Prohibitions that bind Baton specifically:** do not let Baton become the permanent home for
durable rules or long-term context just because it discovers them during execution; do not turn
Grimlore into an execution engine; do not collapse Grimlore context into Grimdex merely because it's
useful.

**Discarded — do not reintroduce unless explicitly asked:** Open Brain / AWS is not part of this
architecture branch. Do not let it shape designs, diagrams, or proposals.

**Naming:** the context layer is **Grimlore** — Kevin renamed it from the brief's "Grimdex Wiki"
(2026-08-14), spending the name Grimdex had already reserved for a general second-brain KB. It is a
*sibling* of Grimdex, not a component of it: `Grimdex` (rules) / `Grimlore` (context) / `Baton`
(action). "Grimdex Baton" is still a working name — do not rename anything unless explicitly asked.

**Layer inventory** — Grimdex: conventions · lessons · rules · schemas · gates · standards ·
validation · security guidance · project rules → universal rules. Grimlore: design · rationale ·
history · environment · user · company · audience · hardware · models · research · project
knowledge. Baton: orchestrate · execute · route · build · test · verify · deploy · agents ·
models · workflows.

**A layer is defined by the question it answers, not the nouns it touches.** *models* span all
three: **what it is** (roster, availability, characteristics) → Grimlore; **the rules for using
it** (spend ceilings, permitted tier per stakes, what may never leave the box) → Grimdex; **how
to use it** (selection, routing, flags, retries) → Baton. Likewise *gates/validation* are
Grimdex's (defines the standard) while *test/verify* are Baton's (runs it). And *project rules →
universal rules* is both two content types and the gate between them.

⚠️ **Grimdex writes the spend rule; Baton enforces it.** The usage governor, cost meter,
pre-flight quota probe, depth policy, and `max_cost_tier` ceiling are runtime machinery and
**stay in Baton** — nothing here moves to Grimdex. Grimdex owns the constraint, not the meter.

⚠️ **Baton's fleet config is ground truth for quota numbers (`grimdex:d022`).** Quota policy is
deliberately duplicated — documented in Grimlore (with reasoning), ruled in Grimdex, enforced
here. The halves are bound by a shared `policy_id` and reconciled by the weekly KB audit. **The
values in `~/.baton/fleet.yaml` are the ones that actually govern behavior**, so when a soft cap
or usage policy changes here, the paired Grimlore concept and Grimdex rule are stale until
updated. Do not treat a prose copy as authoritative for a number.

⚠️ **"Rules layer" is Grimdex's position, not its contents.** Inside it are the decisions,
lessons, and artifacts that **back the rules up** — not a flat list of rules. A decision record's
*Rationale* (the why behind a **rule**) is Grimdex's; the why behind the **work** — purpose,
audience, environment — is Grimlore's. Do not start filing d-records into Grimlore.

**Grimlore's format is settled — OKF v0.2** (`grimdex:d021`): markdown + YAML frontmatter in bundles, with
standard provenance/trust/staleness fields. Spec:
<https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md>

**Left open on purpose (do not silently settle):** how Baton reaches Grimlore context (direct query
vs. a shared context-loading mechanism); how project isolation is enforced; retrieval mechanism;
rule-family organization inside Grimdex. All mechanism — the format question is closed.

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
- `/baton:usage` shows a Copilot Credits panel (d079) when the `gh-copilot` fleet row has a `budget`; needs `gh` token `user` scope (`gh auth refresh -h github.com -s user`).
- **Direct-model commands (#2, v1.15.0):** `/baton:codex|grok|gemini|agy "<prompt>" [--tier <name>|all]` → `scripts/fleet-ask.ps1` → `Invoke-Fleet` (journaled + metered). Per-model tokens land as a trailing `tok:N(exact|estimate)` field on the fleet journal line (observe-only). Tiers = flat `tier_<name>` fleet.yaml keys → `{{tier_args}}`.
- **Memory layer — claude-mem REMOVED (2026-08-21, d126):** the `claude-mem@thedotmack`
  plugin is gone (it began soliciting $30/mo). Do **not** reinstall it or write to
  `~/.claude-mem`. Memory is now the two free systems already in place: Claude Code's
  native file-based auto-memory (`~/.claude/projects/<sanitized-cwd>/memory/`, index in
  `MEMORY.md`) for per-project facts, and the **Grimdex KB**
  (`~/.claude/knowledge/projects/baton/`, repo `Ryfter/grimdex-know`) for decisions,
  design notes, and the append-only `compact-state-log.md`. The KB is the cross-agent
  tier — Codex/Gemini/Grok read it; the auto-memory dir is Claude-local and NOT
  GitHub-backed, so anything that must survive a dead drive or be seen by another model
  goes in the KB. Removal order matters if it ever reappears: uninstall the plugin
  *before* killing its daemons, or the SessionStart/UserPromptSubmit hooks respawn them.
- **Ox Alpha = `opencode/big-pickle` (OpenCode Zen, free until ~2026-08-27):** stealth
  model served under a codename; it is absent from the catalog under any "ox" name.
  Zero credentials needed, accepts stdin, 1M context. **ZDR is NOT in effect** — the
  provider retains prompts; keep private-repo and Grimdex KB contents off this path.
  Measured behavior (2026-08-21): it ignores "do not use tools" and goes agentic, and
  failed to produce a terse structured verdict twice in ~25min where codex/grok/fable
  each finished quickly. Seat it on bulk code-gen behind a review gate; do **not** claim
  `review` / `plan-review` / `judge` / `extract-json` capabilities for it.
