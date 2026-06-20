# Next-session playbook

How to pick **Baton** back up and use it on its own backlog.

## ⚑ Active WIP branch — dashboard/docs refresh (2026-06-20)

The unmerged v1.2.0 docs refresh + dashboard operator-console restyle was preserved on branch `wip/dashboard-docs-refresh` (remote: `origin/wip/dashboard-docs-refresh`, checkpoint commit `cc909d6`). It is also recoverable from patch `D:\tmp\baton-wip-2026-06-20.patch` and stash `stash@{0}: baton WIP snapshot 2026-06-20 before sprint 6`.

Scope on that branch: v1.2.0 docs refresh (`README.md`, `docs/COMMANDS.md`, `docs/DECISIONS.md`, `docs/getting-started.md`, `docs/roadmap.md`, this file, AGENTS/GEMINI status text), dashboard template/CSS restyle, and state-path isolation hardening in `scripts/test-hook.ps1` / `scripts/test-otel-parser.ps1`.

Review status: affected tests passed before the branch commit (`python -m pytest dashboard -q` = 124 passed; `pwsh -NoProfile -File scripts\test-hook.ps1` passed; `pwsh -NoProfile -File scripts\test-otel-parser.ps1` passed). Do not merge that branch as-is. Must-fix items: `docs/COMMANDS.md` documents `/baton:recall "<task>"` but the command requires `-Text` or `-File`; it documents `/baton:remember ... --note` but the runner exposes `-Tags`/`-RefJob` and no `Note`; it documents `/baton:go ... --json` even though the slash wrapper advertises `--budget`/`--max-tier` and uses JSON internally. Also consolidate `dashboard/static/style.css`: it contains an earlier cinematic/glow theme later overridden by the "Baton operator console pass".

## ⚑ Baton v2 direction — 2026-06-16 (read FIRST)

**Strategic pivot (2026-06-15, ChatGPT brainstorm + design pass):** Baton v2 = **economic conductor for AI software development** — "spend intelligence like money." Research before building, estimate before spending, route to the cheapest capable worker, reach *acceptable* quality cheaply, spend premium intelligence on *polish/judgment*, track usage limits, distill lessons into memory. Crisp **"What Baton Is Not"** list (not an IDE / harness / memory DB / benchmark suite / project manager / dashboard) guards scope. **v2 EXTENDS v1, not a rebuild** (d046): fleet.yaml→Worker Registry, capability routing→Worker Router, cost cascade→Economic Policy + Acceptable/Polished gates, usage_class→Usage Governor seed. **Memory Adapter is Projectmem-style, not a hard dep** (d047). 7-sprint MVP order: Triage → Usage Governor → GitHub Projects sync → Research Gate → Memory Bridge → Worker Adapter → Acceptance/Polish gates. Full brief + clarifications in memory `project_baton_v2_direction` (d045-d047).

**Sprint 1 — Triage Agent: SHIPPED 2026-06-16** (PR #52 merged, plugin v1.2.0-rc.8, closed #51; decision d045). `/baton:triage [--url|--file|--json] [<text>]` classifies any issue/task into a structured object (type/priority/estimate/risk/research_required/recommended platform+model/pipeline/confidence/ambiguity) by routing through the EXISTING fleet — `Select-Capability -Capability triage`, Haiku preferred via two new pinned providers (`claude-haiku`/`claude-sonnet`, `stdin: true` for JSON-safe prompts), Sonnet escalation when confidence < 0.70 / risk high / ambiguity high. Deterministic fallback on no-candidates / non-zero-exit / unparseable-JSON. Files: `scripts/triage-lib.ps1` (Read-TriageInput, Build-TriagePrompt, Test-TriageEscalationNeeded, Get-TriageJsonBlock, Invoke-TriageAgent), `scripts/fleet-triage.ps1` (YAML default + `--json`), `commands/triage.md`, providers in `references/fleet.yaml`. 30-check suite (T1-T15 + T7d `$Input`-binding guard); full systems gate green except `test-hook.ps1`/`test-otel-parser.ps1` which **fail identically on master** (pre-existing, unrelated — pipe-field/otel-prefix, env-sensitive). Live Haiku smoke green through deployed scripts + live fleet.yaml. **Two build-time bugs caught + fixed:** `$Input` is a PowerShell automatic variable (read the param via `$PSBoundParameters['Input']`); `Select-Capability` returns `$null` not `@()` for empty (explicit null guard). **Plan bug fixed:** there is NO root `fleet.yaml` — the deployable seed is `references/fleet.yaml` (bootstrap copies it to BATON_HOME; `Initialize-BatonHome` SKIPS seeding when a live fleet.yaml exists, so new providers were hand-added to live `~/.baton/fleet.yaml`). Spec/plan: `docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md`, `docs/superpowers/plans/2026-06-15-triage-agent-sprint1.md`.

**Sprint 2 — Usage Governor: SHIPPED 2026-06-16** (PR #54 merged `17c96b7`, plugin v1.2.0-rc.9, closed #53; decision d048). `/baton:usage [status|lockout|limit|cooldown|clear|conserve|tick|forecast]` governs worker availability. **Event-sourced** `usage-journal.jsonl` under BATON_HOME (box-private — never the knowledge repo) is **folded** to five per-worker states (`available|limited|exhausted|cooling_down|waiting_for_reset`) with time-based auto-expiry, plus a **global `conserve_mode`** posture (`worker:"*"` event). Manual lockout/limit/cooldown/clear take reset ETAs (`+5h`/`+2d`/ISO-8601 → `ConvertTo-UsageInstant`), rendered as human ETAs. **Route-around-exhausted** is a filter inside `Select-Capability` (routing-lib.ps1): hard-stops excluded, `limited` down-ranked (×0.5) normally / hard-excluded under conserve, conserve forces economy ranking; **absent journal = no-op** (existing routing suites unperturbed). **Best-effort forecast** (`Get-UsageForecast`): linear run-rate over days-with-data, honest `insufficient_data`/`rate_only`/`ok` — never fabricates a `days_to_exhaustion` without a `budget` (optional per-worker fleet field; box-private, comment-only in the shared seed) + ≥2 days of ticks. Files: `scripts/usage-lib.ps1`, `scripts/fleet-usage.ps1`, `commands/usage.md`. 29-check suite (T1-T29; T29 = 0-count-tick guard, review nit N1). **cascade/dispatch suites hardened**: they reach `Select-Capability` indirectly with the default `-UsagePath`, so a live lockout/conserve could perturb them — pinned `BATON_HOME` to each suite's temp dir (proven green against a hostile journal with conserve-on + colliding lockouts). Adversarial final review: APPROVE, 0 blocking. Live smoke green through deployed scripts (real fleet read, `lockout --reset +3h`→`waiting_for_reset (in 2h 59m)`→`clear`). **PS lesson reused:** event param is `-Kind` (the JSON field is `event`) — `$Event` is a PowerShell automatic variable (sibling of S1's `$Input` trap). Spec/plan: `docs/superpowers/specs/2026-06-16-usage-governor-sprint2-design.md`, `docs/superpowers/plans/2026-06-16-usage-governor-sprint2.md`.

**Sprint 3 — GitHub Projects sync: SHIPPED 2026-06-16** (PR #56 merged `3e98af4`, plugin v1.2.0-rc.10, closed #55; decision d049). `/baton:projects [init|sync] --owner @me --project N [--apply|--reclassify|--classify|--json]` pulls open issues, classifies the untriaged ones through the **Sprint-1 Triage Agent**, and writes the result back as **labels** (`type:`/`area:`/`risk:`/`estimate:`/`route:` — classify) + **Project v2 single-select fields** (`Priority`, `Status` — decide). **Dry-run by default** (`--apply` to write); dry-run **spends zero tokens** and shows the would-be classifier per untriaged issue (a read-only `Select-Capability` peek). All GitHub ops go through **`gh` CLI** behind an injectable `[scriptblock]$GhInvoker` seam (default real gh; stubbed in tests → never touches a real repo/board/model). **Baton ensures structure via gh** — `gh project field-create` creates the `Priority` field (P0-P4) if absent (idempotent, mirrors the label-ensure idiom); `Status` ships by default on v2 boards. **Project creation is explicit** (`projects init` → `gh project create` + ensure Priority), never implicit in `sync` (a mistyped project number errors, never spawns a board). **Classification rides the Sprint-2 governed fleet** — `Invoke-TriageAgent` → `Select-Capability` inherits the route-around-exhausted + budget filter, so it prefers a budgeted/included worker and routes around it on exhaustion. **Fallbacks** write only `needs-triage`, never field decisions. Pure layer (`ConvertTo-SyncLabels`/`ConvertTo-SyncFieldValues`/`Get-IssueTriageState`/`Build-SyncPlan`) is gh-free and fully unit-tested; I/O layer (`Get-RepoIssues`/`Resolve-ProjectFields`/`Ensure-ProjectFields`/`Resolve-ProjectItems`/`Resolve-ProjectId`/`Test-GhAuth`/`Invoke-SyncPlan`, best-effort per issue) is stubbed. Files: `scripts/projects-lib.ps1`, `scripts/fleet-projects.ps1`, `commands/projects.md`. 39-check suite; **all emitted gh flags verified against live gh 2.86.0** (`item-edit --id/--project-id/--field-id/--single-select-option-id`, `item-add --owner/--url/--format`, `field-create --data-type/--name/--single-select-options`, `issue edit --add-label`, `project view --format json` → `.id`). Adversarial review APPROVE, 0 blocking. Live smoke green through deployed scripts (dry-run resolved real worker `claude-haiku`, zero mutating gh calls). **Build lesson reused:** the unary-comma array idiom (`,([object[]])`) protects only **direct-assignment** returns — at sites flowing into `@()`-wrappers or hashtable members (`ConvertTo-SyncLabels`, `existing_labels`) the comma nests the array and must be dropped (keep the `[string[]]` cast). Spec/plan: `docs/superpowers/specs/2026-06-16-github-projects-sync-sprint3-design.md`, `docs/superpowers/plans/2026-06-16-github-projects-sync-sprint3.md`.

**Sprint 4 — Research Gate: SHIPPED 2026-06-18** (PR #58 merged `3efd5a8`, plugin v1.2.0-rc.11, closed #57; decision d050). `/baton:research-gate (--text|--url|--file) [--deep] [--json] [--out]` emits a **build/adopt/adapt/inconclusive** verdict — the cheapest spend that prevents the most expensive waste (building what already exists; the Doc2MD trap). **Cheap-model floor + live-evidence grounding** ("cheap model + good context"): synthesis routes through `Select-Capability -Capability research` preferring Haiku, escalating to a champion (Sonnet) on low confidence / high risk / inconclusive — Triage's pattern. Evidence = local **tools.yaml registry** (catches "already wired") + the prior `/baton:research` **ensemble `synthesis.md`** (gather→decide split — the ensemble gathers, the gate decides) + **KB** hits + optional **`-Deep` live web/registry search**; default run is **offline, zero-network**. **Two injectable seams** (`-Searcher` evidence, `-Dispatcher` model) keep the **38-check suite hermetic** (no network/model/job-dir; child-process CLI test). **Wired to the job `research` phase** — active job → writes `phases/research/gate-<ts>.md`+`.json`; no job → stdout/`--out`. Recommend-only; `inconclusive` is the fallback. Files: `scripts/research-gate-lib.ps1` (pure: `Get-GateJsonBlock`/`ConvertTo-GateHashtable`/`Test-GateEscalationNeeded`/`New-GateFallback`/`Get-ToolsRegistrySummary`/`Get-EnsembleSynthesis`/`Build-GatePrompt`/`Format-GateMemo`; seamed: `Invoke-EvidenceSearch`/`Invoke-ResearchGate`), `scripts/fleet-research-gate.ps1`, `commands/research-gate.md`. `research` capability added to claude-haiku/claude-sonnet in **seed `references/fleet.yaml` AND live `~/.baton/fleet.yaml`** (capability tag only — box-private rule respected). My final adversarial review: APPROVE, 0 blocking (one cosmetic `--json --out` double-emit, not worth a fix). **Live smoke proved the entire thesis in one real call:** grounded in the registry, the gate caught `docling` was already wired for PDF/DOCX→markdown and recommended **ADOPT** over a redundant build (confidence 0.92), with the **haiku→sonnet escalation firing on live models**. Spec/plan: `docs/superpowers/specs/2026-06-18-research-gate-sprint4-design.md`, `docs/superpowers/plans/2026-06-18-research-gate-sprint4.md`.

**Conductor (`/baton:go`) capstone — SHIPPED 2026-06-19** (PR #59 squash `6e72c9b`, release **v1.2.0-rc2** "The Conductor release", plugin v1.2.0-rc.12; decisions d051-d053). The NL plan-then-execute front door now exists end-to-end. `/baton:go "<goal>"` → the engine asks a planner for a **task DAG**, walks it in **Kahn topological order**, and executes **full-auto**, stopping the walk for **exactly two** reasons (**guard-before-spawn**, structural): a **budget cap** or a **destructive `reversible:false`** task — everything else (ambiguity, forks, under-cap spend) is auto-guessed and logged, never prompted. Four artifacts land under box-private `$BATON_HOME/runs/go-<yyyy-MM-ddTHH-mm-ss>/`: `plan.json`, `events.jsonl`, `decisions.jsonl` (autonomous-guess ledger), `report.md` (plain-English). **Substrate = Style-A** (runs in this Claude session — the "not so smart" conductor tier is never blocked, so real-time chat always works) with a **file-based Style-B seam** so a future standalone broker + web cockpit can swap in without touching the engine (d051). Files: `scripts/conductor-lib.ps1` (New-RunId, Resolve-TaskOrder, the budget/destructive guards, event/decision factories + ledger writers, Build-PlannerPrompt, Invoke-PlanPhase, Invoke-TaskViaFleet, Complete-Run, Invoke-Conductor), `scripts/fleet-go.ps1` (CLI; env seams `BATON_GO_TEST_PLAN`/`BATON_GO_TEST_SPAWN` for hermetic child-process tests), `commands/go.md`. **59/59** conductor suite + **38/38** bootstrap, both green; final opus whole-branch review = **READY TO MERGE** (no Critical); deployed live + hermetic smoke green (status `completed`, all 4 files, run-id format correct). **Box-private:** `budget_cap` defaults to null in shared code (null cap = never interrupts on budget). **PS idioms reused:** event factory param is `$EventObj` (not `$Event`, the automatic var — sibling of S1 `$Input`/S2 `$Event` traps); `Resolve-TaskOrder` returns `,([array]$ordered)` (direct-assignment flatten). **Open follow-ups (non-blocking, from the final review):** (1) `Resolve-TaskOrder` reports **duplicate / self-dependency task ids** as a generic "cycle" — fails closed (`plan-invalid`, never executes) but deserves a precise error; (2) add direct `Invoke-Conductor` tests for the `failed` and `plan-invalid` status paths; (3) the budget guard is an **estimate gate, not a hard ceiling** (spec §6.2 v1 tradeoff — a mis-tagged cheap task can pass the cap). Spec/plan: `docs/superpowers/specs/2026-06-18-conductor-go-mode-design.md`, `docs/superpowers/plans/2026-06-18-conductor-go-mode.md`. Memory: `project_maestro_go_mode`.

**Sprint 5 — Memory Bridge: SHIPPED 2026-06-19** (PR #60 squash `2cb3f45`, plugin v1.2.0-rc.13; decision d054). Projectmem-style dev memory: an append-only box-private `$BATON_HOME/memory-journal.jsonl` of **problem→attempt→outcome** rows, queried *before* acting to warn when a new task matches a past attempt — especially a known-bad fix (memory-as-governance). Three surfaces: **`/baton:remember`** (capture), **`/baton:recall <task>`** (`--deep` adds semantic), **`/baton:memory-promote`** (`[<id|signature>]`). **Hybrid matching (d-mb-1):** a deterministic normalized **signature** (token-set key — lowercase, strip paths/line-nums/hex+uuid/digit-units, drop stopwords, sorted-distinct) token-overlap match is the hermetic backbone; **`-Deep` semantic KB recall** (`Invoke-KbSearch`) is advisory **discovery**. **Discover→crystallize ratchet (d-mb-2):** semantic proposes → operator/watch promote → deterministic key enforces (encodes Kevin's "AI discovers, I crystallize deterministic goals" style). **Two nomination paths, one visible write (d-mb-3):** `Get-PromotionCandidates` auto-**watches** (fail ≥N → avoid rule; win ≥N → prefer rule), or the operator **flags** `<id|signature>`; both run `Invoke-MemoryPromote` → `-Writer` Grimdex write → stamp source rows `promoted`. **Pluggable seams (d-mb-4, d047 honored):** `Invoke-MemorySource` `-Producer` (manual is v1's source; Conductor-ledger ingest deferred) + `-Writer` (default appends the box-private lessons file). Files: `scripts/memory-lib.ps1` (pure: `Get-MemorySignature`/`Read-MemoryJournal`/`Add-MemoryEvent`/`Find-MemoryMatches`/`Get-PromotionCandidates`/`Format-RecallReport`/`Format-PromotionMemo`; seamed: `Invoke-MemoryRecall`/`Invoke-MemorySource`/`Set-MemoryPromoted`/`Write-PromotionToGrimdex`/`Invoke-MemoryPromote`), `scripts/fleet-memory.ps1` (subcommands `remember|recall|promote`; CLI splat uses `$pArgs` not `$args`), `commands/{remember,recall,memory-promote}.md`. **33-check hermetic suite** (`BATON_HOME` + `BATON_MEM_LESSONS` temp redirect keeps the promote test off the real KB) + 2 bootstrap deploy asserts (39/39). **Opus final review = READY TO MERGE, 0 Critical / 0 Important.** Deployed live + hermetic smoke green (remember→recall warns "2 prior, 2 FAILED" + auto-surfaces candidate→watch lists→flag writes lessons + stamps 2 rows). **Build lesson reused/extended:** the unary-comma flatten idiom produces a **1-element wrapper on EMPTY collections** — Task 2 added an explicit empty guard before the comma-return in `Find-MemoryMatches`/`Get-PromotionCandidates` (Task 5 in `Invoke-MemorySource`). **Open follow-ups (non-blocking, from the final review):** (M1) `Write-PromotionToGrimdex` writes one box-private lessons file regardless of `scope`/kind — scope/kind-driven write-target routing (universal target / `decisions-lib.ps1`) deferred in the spec, plugs in behind `-Writer`; (M2) `Set-MemoryPromoted` rewrites rows with scrambled key order (cosmetic, round-trips fine); (M3) `recall --json` surface untested. Spec/plan: `docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md`, `docs/superpowers/plans/2026-06-19-memory-bridge.md`. Memory: `project_baton_v2_direction`.

**→ NEXT: Sprint 6 — Worker Adapter** (run one external worker through Baton routing) per the roadmap order — the sprint where `gh models run <model>` becomes a *budgeted* fleet worker, turning the GitHub allotment into a saturable labor pool the Usage Governor drives toward Kevin's **99.9%-monthly-utilization** target (Serf is one candidate adapter, not central). Then Sprint 7 (Acceptance/Polish gates). **Parallel optional tracks:** Conductor follow-ups / Style-B broker+cockpit; Memory Bridge follow-ups (M1 scope/kind write routing, Conductor-ledger auto-ingest, M2/M3). Each gets its own spec → plan → build. **Release note:** Sprint 5 is merged to master but **not yet in a tagged GitHub release** (last tag is v1.2.0-rc2); cutting rc3 (or folding Sprint 5 into a later milestone release) is a pending Kevin decision.

**Cleanup note:** the Conductor was built on the in-tree feature branch `conductor-go-mode` (squash-merged via PR #59; branch left on remote, not deleted — delete at will). SDD progress ledger + task briefs + the final-review package live under `.git/sdd/` (non-tracked, safe to ignore). Kevin's `dashboard/static/style.css` WIP remains uncommitted in the working tree (preserved across the branch round-trip + master sync, untouched).

## ⚑ Parked threads — 2026-06-10 (read first)

**Phase 2 shipped 2026-06-11** — state now at `$BATON_HOME` (default `~/.baton`); hooks ship with the plugin (`hooks/hooks.json`). **Phase 3 shipped 2026-06-11** — Python MCP server (`baton_mcp`, 8 tools) bundled in plugin via `.mcp.json`; Codex/Cursor registration documented in README.

**Slice B SHIPPED 2026-06-11** (PR #44 merged `a43ac1a`, plugin v1.2.0-rc.5, decision d041): `scripts/routing-cascade.ps1` — `Invoke-CapabilityCascade` drafts on the cheapest N draft-eligible candidates (new optional `role: draft|bulk|finisher` + `platform:` registry fields, explicit beats cost-tier inference, selector stays role-blind), short-circuits at judge score ≥0.9 (zero frontier spend; heuristic verdicts never short-circuit), else the cheapest finisher takes-and-extends the best draft through the Slice A rank gate. Six statuses; deferred/escalate salvage the best *usable* draft (review B1). `/baton:route --cascade`. 39-check suite; live local-only smoke verified (judge scoring + fallback + no-finisher observed on real models). NOTE: live `~/.baton/fleet.yaml` needed `general_capabilities:` added by hand (pre-routing migrated copy lacked it — seeds never overwrite); live registries are UNANNOTATED (inference covers them; add `role:`/`platform:` lines manually for cheap-paid drafters when wanted). Deferred review nit N2: gate-deferred attempts carry `grader=$null` (honest — nothing graded).

**Slice C SHIPPED 2026-06-11** (PR #46 merged `5ecf4f0`, plugin v1.2.0-rc.6, decision d042): cascade in the autonomous loop. Backlog items opt in additively: `cascade: true` + `output_file` = **full cascade** (winning text written to the file in the item worktree, normal merge gate judges it — a judge-scored ≥0.9 draft merges with ZERO frontier spend); `cascade: true` alone = **advisory** (new `Invoke-CapabilityCascade -NoFinisher` → `drafts-only` status; best usable local draft injected into the agentic implementer's prompt via `Get-AdvisoryPrompt`, fail-open to the plain prompt). Cascade items are never gated at the driver — their effective rank flows INTO the cascade whose finisher runs the Slice B gate; `finisher-deferred` → item `deferred`, re-drafts next run. **Concurrent driver got the Slice A parity it never had**: effective-rank ordering, unattended paid-peak gate, surge-scaled `-MaxParallel` (0 = unbounded back-compat; `Get-EffectiveMaxParallel`). **All deferrals now dep-block dependents in both drivers** (fixed a Slice A gap where a deferred prereq's dependents ran without its work). Cascade items run as child processes (`CascadeJobWorker`/`AdvisoryJobWorker`) — items draft in parallel; within-cascade parallel drafts stay future work, as does draft caching across runs. `run-backlog.ps1` gained `-MaxParallel` + a cascade-aware summary (winner + frontier-spend line). Gate: 11/11 suites; adversarial review SHIP (2 accepted NITs: advisory placeholder collision is cosmetic; the `output_file` traversal guard over-blocks in the safe direction). **Live-smoke catch → PR #47 (`25f705b`):** `fleet-orchestrate.ps1`/`fleet-backlog.ps1`/`run-backlog.ps1` were MISSING from the bootstrap manifest — stale June-1 copies sat in `~/.claude/scripts`, so production backlog runs used a pre-Slice-A driver; now deployed + test-asserted. Spec/plan: `docs/superpowers/specs/2026-06-11-cost-engine-slice-c-loop-cascade-design.md`, `docs/superpowers/plans/2026-06-11-cost-engine-slice-c-loop-cascade.md`.

**Models-as-Tools registry slice SHIPPED 2026-06-11** (PR #49 merged `9571f32` + shape-fix PR #50 `b4f8fb5`, plugin v1.2.0-rc.7, decision d044): local models are now declared specialists. **Capability claims** — a provider with `capabilities: [...]` in fleet.yaml is a candidate for ONLY those (judge, commit-msg, extract-json, ...); no field = blanket `general_capabilities` grant (frontier CLIs unchanged). **Judge by claim** — `Get-JudgeModel` resolves the judge via the `judge` claim (lm-studio-small/phi-4 live), killing the file-order auto-pick; fail-open fallback chain intact. **Context floors** (`capability_floors:` map; unknown context never disqualifies), **keep_list** globs (heretic teaching models — never culled, never claimed), **usage_class tight|broad** recorded + surfaced by doctor (`class` column) but NOT enforced (idle-gating = saturation slice). **`/baton:models` inventory** — probes LM Studio native `/api/v1/models` + ollama `/api/tags` per box (deduped by base_url, offline-tolerant), tags pins/claims/keep, recommend-only findings; live run: 77+5 models, 37 real recommendations (found the duplicate gpt-oss + llama-8B near-peer pile), snapshot at `~/.baton/model-inventory.json`. **Gauntlet scorecard import** — `Import-GauntletScorecard` (idempotent by run_id, model-id→provider mapping via pins) feeds a new Wg=0.75 gauntlet bucket in the quality blend; hand-made scorecards work until Gauntlet is built. **Selection modes** — `Select-Capability -SelectionMode economy|champion` (smallest-above-bar vs BoB-local). Live registry annotated (claims/context/usage_class + floors + keep_list). Live-smoke catch → PR #50: real LM Studio 0.3.x native shape differs from docs-derived fixture (`models`/`key`/`architecture`/quant-object/capabilities-object/`loaded_instances`) — normalizer now handles both. Spec/plan: `docs/superpowers/specs/2026-06-11-models-as-tools-registry-design.md`, `docs/superpowers/plans/2026-06-11-models-as-tools-registry.md`. **Still open from the vision** (memory `project_models_as_tools_vision`): idle VRAM saturation + broad-class enforcement, overnight battery scheduling (needs Gauntlet), pareto culling automation, BoB+large-context slots, judge-rubric calibration.

**⚠ JUDGE: degraded → RESTORED same-day (live-config only).** Two stacked causes found via live smoke: (1) the judge auto-pick (`Get-CheapestLocalModel`) takes the FIRST enabled local provider in file order — after d043 that was the often-offline laptop (`ollama-box2`), so the judge dialed a dead box; (2) the first replacement pin (`qwen3.5-9b`) is a REASONING model whose thinking preamble breaks the strict-JSON parse (LM Studio's native `/api/v1/models` flags this in its `capabilities` field). Fix applied to live `~/.baton/fleet.yaml`: `lm-studio-small` re-pinned to **`phi-4`** (non-reasoning, structured-output strong) and moved ABOVE `ollama-box2` so it is the judge's first-local pick. Verified live: real `llm-judge` verdicts in 2-3s with scores + reasons. **Remaining:** judge rubric is miscalibrated — graded a correct one-liner 0.50 ("doesn't create complete code structure") so the ≥0.9 short-circuit is still unreachable in practice. ~~(b) explicit judge claim~~ — DONE in the models-as-tools slice (d044): `Get-JudgeModel` resolves via the `judge` claim, file order no longer matters.

**⚠ VRAM HARD CONSTRAINT + live registry reconfig (Kevin, 2026-06-11; decision d043):** ONE model-serving process per box — Firefly has 32 GB VRAM and Ollama/LM Studio have NO cross-process arbiter, so concurrent big loads spill to system RAM (unacceptable). Live `~/.baton/fleet.yaml` now: **LM Studio primary** (`lm-studio` pinned `qwen/qwen3-coder-30b` ~17 GB; new same-server `lm-studio-small` pinned `qwen/qwen3.5-9b` ~6 GB for judge/utility — big+small INSIDE one server), `ollama-local` registered but `enabled: false` (flip flags together, never both true), `research_default` swapped to lm-studio. Explicit model pins everywhere — `auto` is banned. wraith2 (8 GB) is its own pool. This is the first concrete row of the cost/speed advisor's infra inventory.

**THE NEXT BUILD (pick one — each gets its own worktree-isolated session):**

1. **Cost/speed advisor** (parked thread 6 below): two dials (cost × speed) + an infra inventory; fast+cheap corner → recommend *expanding cheap capacity* (2nd $20 platform, add a PC) not deepening expensive; consumes the registry `platform` field. Needs its own spec → plan → build.
2. **Autonomous run-loop epic** (the headline goal): folder + GitHub repo → run until budget/goal. Slice C is its on-ramp — the loop now drafts cheap, finishes gated, and respects rank/peak/surge end-to-end.
3. **MCP ride-along whenever convenient**: `route-cascade` bridge op + `baton_route` cascade mode (out of B/C scope by design). Also still open: within-cascade parallel draft fan-out, draft caching across runs, stage-aware learning (journal `stage` → `Get-CapabilityQuality`).
2. **`/schedule` rank surfacing — NOT a loose end (no artifact yet).** Reconciled 2026-06-10: there is **no orchestrator `/schedule` skill** — the only `schedule.md` on the box is the `octo` marketplace plugin's, and native scheduling is Claude Code's own `ScheduleWakeup`/`CronCreate`. The Slice A spec's "`/schedule` carries a rank" was *aspirational*. So this is a **feature** (build an orchestrator `/schedule` skill that carries a rank → prime-hours gate decides allow/defer-to-off-peak), not a quick consumer-wiring. De-prioritized until/unless we want our own scheduling skill; the gate library is ready for it whenever.

**SHIPPED this spurt:**

0. **Cost-Optimization Engine — Slice A (time-awareness): SHIPPED** (merged `e584e7b`, 2026-06-10). New pure lib `scripts/prime-hours.ps1` — `Test-PrimeHoursGate -Rank -CostTier [-Now] [-ConfigPath] → @{decision;default;reason;window}` and `Get-CapacityProfile → @{concurrency_factor;surge;window}`, reading `~/.claude/prime-hours.yaml` (`-Now` injectable → clock-independent tests). Gate guards ONLY the paid tier in a `peak` window; rank policy 1=ask/run, 2=ask/defer, 3-5=defer, unranked=default_rank(3); reserved rows 0/6 (undocumented); fail-open on missing/garbage config/tz. `Get-CapacityProfile` → surge×factor (default 2) in a `surge` window. Wiring: routing paid-tier gate is **opt-in via `-Rank`** (sentinel `[int]::MinValue` → 32 original dispatch checks untouched); backlog `Get-EffectiveRanks` (min(own, transitive dependents) — prereqs inherit an urgent dependent's rank) + ascending dispatch + per-item gate (deferred → `Write-ItemLive -State deferred`, never silently dropped); bootstrap deploys lib+seed; `/baton:route --rank`. **Invariant held: rank ≠ tier** (the optimizer still picks the cheapest capable model; the gate only governs premium-spend-now). Gate: all 8 PS suites exit 0 + live deploy smoke; adversarial review SHIP (one clock-dependency BLOCK fixed: `-GateNow` injected in the routing gate tests, `532f156`). 7 TDD task commits `d9d7a11`→`16a3ef2` + the review fix. Spec/plan: `docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md`, `docs/superpowers/plans/2026-06-10-cost-optimization-engine-slice-a.md`.

   **Slice A deferred follow-ups (non-blocking nits from final review, tracked not done):**
   - **Capacity surge is computed but not consumed in the serial `Invoke-Backlog`** (`$cap = Get-CapacityProfile` is a dead assignment there) — the spec's "on surge raise max-parallel + drain deferred" belongs to the concurrent driver / Slice B/C. Wire it when the concurrent path lands, or drop the call until then.
   - **`$script:__lastGateDecision` module-scoped carry** in `routing-dispatch.ps1` is correct for serial dispatch but a latent race if surge ever drives parallel candidate dispatch — thread a local instead when that happens.
   - **Interactive rank-1 `ask` confirms AFTER the spend, not before** (`ask`→`run`→dispatch happens in the library; `/baton:route` only sees `gate='ask'` post-dispatch). Unattended semantics are correct; the "confirm before premium peak spend" promise in `route.md` is unenforceable for rank-1 through this channel. If true pre-spend confirmation is wanted, the gate must surface `ask` as a *non-dispatching* status the command layer resolves then re-dispatches — a design change, flag to Kevin.
   - Minor: `Test-InWindow` treats a window with only `start` OR only `end` as all-day; `concurrency_factor: 0` is falsy → silently 2.0. Both harmless with the seed config; one-time warn would be tidier.

2. **Grimdex — SHIPPED, SPLIT & PUBLIC.** The KB is the standalone **Grimdex** app at `D:\Dev\Grimdex`; `~/.claude/knowledge` is a directory junction → it. **Engine/data split executed 2026-06-10 (d037, via rename):** the private data repo is **`Ryfter/grimdex-know`** (all `universal/` + `projects/` + `config/`, full history, `pre-split-backup` tag — the junction's remote already points here); the **engine** is a fresh-history repo **`Ryfter/Grimdex`** (scripts + convention + skeleton + exemplars, MIT) that is **now PUBLIC** (https://github.com/Ryfter/Grimdex). Engine work happens in the Grimdex home thread; this repo's `CLAUDE.md` is wired with the `<!-- grimdex:start -->` pointer stanza. ⚠️ Any stale remote pointing at `Ryfter/Grimdex.git` for the *KB* must move to `grimdex-know`. Decisions **d032/d033** (standalone, tool-agnostic, file-first; graceful degradation). **Grimdex-side rules (its d002):** project-tier writes (d-records/guidance/ratings) go *direct* to `projects/<id>/`; cross-project/universal rule proposals go to `universal/promotions/<id>.md` (do NOT hand-edit `GRIMDEX.md`) — a **daily 5:30am sweep** auto-inscribes clean additions, defers conflicts to Kevin; **`git pull --rebase` before writing, push after** (shared repo). Naming family: Grimdex = coding now; **Grimlore** reserved for a future general "second-brain" KB.

3. **`/kb-audit` + rules-mirror.** **Rules-mirror: DONE** (Grimdex `dc3279e`, verified 2026-06-10) — the 3 global rules (context7, task-group-closeout, post-compact-state-report) are mirrored to Grimdex `universal/claude-rules/`, redeployed on fresh setup via `Sync-GrimdexRules` (`setup-lib.ps1`, called from `setup.ps1:31`, with live-vs-mirror drift warning + tests), committed and pushed. **The live backup-order gap is closed.** Remaining (Grimdex scope, not the orchestrator board): the broader **`/kb-audit`** read-only health sweep (6b–6d in the kickoff) — MEMORY pointers/wikilinks/decision-id/cross-project-contamination checks + `KB-AUDIT-LOG.md`. Grimdex's d002 promotions-inbox + 5:30am sweep already realizes the *consolidation* half.

**DESIGN SPURT — parked for spec (full detail in memory `project_fleet_conductor_design_spurt`):**

4. **Conductor operating model (decision d035).** Orchestrator = lightweight **async non-blocking message-broker** → 3rd north-star pillar **responsiveness**. 3 tiers + model stack: **Conductor** (1 global, command-control, Sonnet/Haiku) → **Orchestrator** (1 per project, the brains + interactive partner, Opus/Fable, Sonnet downshift for cost-mode) → **Fleet** (many, local/cheap, concurrent). Light = low *volume* (offload heavy work to background agents), not dumb.
5. **Cockpit dashboard (web-first per d019).** 3-pane: left gutter = projects (compressed) → optional grouped convos; center = conversation; right = artifacts (pending decisions, plan/spec files, todos) — a **renderer** over existing structured data. Top-left chrome: tools + **account (moved up)**. Surface priority: **web = default**; VS Code companion = low nice-to-have (rides Kiro/Cursor/clones); custom = eventual/very-low.
6. **Cost/speed advisor (Engine slice, after Slice A).** Two dials (cost × speed); the fast+cheap corner → advisor recommends **expanding cheap capacity** (a 2nd $20 platform e.g. Codex over Claude $20→$100; add/optimize a PC), not deepening expensive. Needs an infra inventory. **Orchestrator-specific** knowledge per **decision d034** (Grimdex holds only portable coding knowledge).

Also shipped earlier 2026-06-10: routing **Slice 4 calibration** (merged `b88b12b`, closes #36, d031); the post-compact-state-report rule relocated its per-project log into the KB.

## 0. Dashboard redesign — SHIPPED (2026-06-05)

The Gemini dashboard redesign is **merged to master**. Codex's audit
([`dashboard-redesign-audit.md`](dashboard-redesign-audit.md)) was resolved by
Claude — all 8 required fixes done, browser-verified — and written up in
[`dashboard-redesign-handoff.md`](dashboard-redesign-handoff.md). The dashboard
now has **zero external dependencies** (htmx/Chart.js vendored under
`dashboard/static/vendor/`, system fonts, inline favicon) so it renders fully
offline. Tests: `kb dashboard` 116 passed.

Open follow-up (optional, not blocking): capture a screenshot of an *active*
fleet run, and consider real browser-driven fleet controls (provider roster,
`/baton:fleet doctor`, `/baton:ensemble` launch, backlog approval) as a separate feature.

## 0b. Fleet Conductor — vision + Slice 1 SHIPPED (2026-06-06)

The orchestrator is evolving into a **Fleet Conductor**. North star (the *why*):
**autonomy** (stop forcing the human to press 1/2) + **legibility** (always show, in
plain English, what each agent is doing and why); interrupt only for real decisions.

Architecture (decisions in `Ryfter/grimdex-know/projects/baton/decisions/`):
- **d018 — conductor, not monolith:** stay a thin conductor; call out to best-of-breed
  harnesses (ruflo for swarm execution, the adversarial-dev Planner/Generator/Evaluator
  pattern for quality, GitHub for coordination) as uniform *callable capabilities*,
  extending the `fleet.yaml` registry pattern from models up to whole subsystems.
- **d019 — web dashboard is the primary surface;** pixel-agents sprites are an optional,
  themeable plugin. Surfaces (web / VS Code / Kiro / Copilot) are interchangeable
  renderers over one neutral "what's happening" feed.

Docs: concept `docs/superpowers/specs/2026-06-05-fleet-conductor-concept.md`;
Slice 1 spec `…/2026-06-05-legibility-dashboard-design.md`; plan
`docs/superpowers/plans/2026-06-06-legibility-dashboard.md`.

**Slice 1 — legibility dashboard: SHIPPED** (merged `0c0f274`). A file-based feed under
`$BATON_HOME/runs/` (default `~/.baton/runs/`) (`run.json` + `events.jsonl` + `index.json`) written by PowerShell
(`scripts/runs-lib.ps1`, the `run-feed.ps1` PostToolUse narration hook, and
`statusline-feed.ps1`) and read by the FastAPI dashboard: a **runs gutter** + **detail
pane** + **global strip** + a **needs-you** answer queue. Autonomy win shipped too: a
curated permission allowlist (`.claude/settings.json` read-only; project-scoped script
exec in `.claude/settings.local.json`). Gate: 143 Python tests + 3 PS suites + bootstrap
smoke all green.

**Deferred follow-ups (tracked, not done):**
- Stale-run auto-idle (spec §5) — a dead `running` producer shows 🟢 forever; needs a
  read-time `updated_at`-age check + fixture rework (deferred to avoid wall-clock test fragility).
- Styling/`frontend-design` pass for the gutter/detail/sprites (templates ship unstyled).
- Wire fleet dispatch to set/clear `$BATON_HOME/runs/current-run.json` per dispatched run so the
  hook narrates real fleet runs.

**SP2 — coordination backbone: SHIPPED** (merged `5027956`, 2026-06-07). GitHub Agent HQ
was verified first (decision **d020**): it's cloud-Copilot-only with no public API and
cannot orchestrate a local fleet, so we build the local backbone and ride GitHub artifacts
(Projects/issues/PRs); Agent HQ stays a *future* call-out per d018. Built: a fleet→runs
**bridge** (`scripts/fleet-runs-bridge.ps1`, `Publish-ItemRun`) wired into both backlog
drivers (parent-process, best-effort try/catch) so real dispatched agents now appear in the
legibility feed; a per-agent **assignment view** (`read_assignments` + `partials/assignments.html`)
with active/queued/**parked-for-human** lanes; and **current-run** wiring (`Set-CurrentRun`/
`Clear-CurrentRun` + `/baton:job-start`/`/baton:job-phase done`) so the conductor's own session narrates
in. Decision **d022** = wire the calls inside the existing markdown command PS blocks. Gate:
154 Python + 5 PowerShell suites + bootstrap smoke; adversarial review verdict SHIP.
Spec/plan: `docs/superpowers/specs/2026-06-06-sp2-coordination-backbone-design.md`,
`docs/superpowers/plans/2026-06-06-sp2-coordination-backbone.md`.

**SP2 deferred follow-ups (tracked, not done):**
- Defense-in-depth: slugify/reject `[\\/]|..` in `Publish-ItemRun`'s item id (NIT; item ids are
  operator-supplied today, and the old ensemble feed shares the same trust model — not a regression).
- Retire the old ensemble cockpit (`ensembles.py` + `_ensemble.json`/`*.live.json`) once the
  assignment view fully supersedes it — the two feeds run in parallel by design for now.
- The Slice 1 deferrals still stand: stale-run auto-idle (spec §5) and a `frontend-design`
  styling pass for the gutter/assignment board/sprites.

**SP3 — `/baton:idea` front door: SHIPPED** (merged `b348855`, 2026-06-07). One command turns a
raw idea into board-ready GitHub Issues with a single human gate (concept-doc approval).
Job-less stitch (Approach A) of existing primitives — KB prefetch → `/baton:research` ensemble →
`/baton:council` two-round viability debate → a conductor-written concept doc → Issues on Project
#5 — backed by one new tested lib `scripts/idea-lib.ps1` (`New-IdeaWorkspace`,
`New-IdeaConceptDoc`, pure `Build-IdeaIssues`, `gh` `Publish-IdeaIssues` with auth pre-flight
+ per-issue isolation + `--body-file` for the 965-byte rule) and `commands/idea.md`. End
boundary = issues on the board; dispatch stays a separate human act (decision **d023**). Gate:
154 Python + 6 PowerShell suites + bootstrap smoke. Spec/plan:
`docs/superpowers/specs/2026-06-07-sp3-idea-front-door-design.md`,
`docs/superpowers/plans/2026-06-07-sp3-idea-front-door.md`.

**SP3 deferred follow-ups (tracked, not done):**
- Add `gh project item-add` wiring if `gh issue create --project` doesn't place issues on
  Project #5 directly (the command passes `-Project`; local `gh issue create --help`
  confirms `--project` is supported and requires the `project` scope).
- First real `/baton:idea` run is still the acceptance test for project placement. The
  issue publisher now preflights auth and ensures generated labels (`from:idea`,
  `Tier-*`, extras) before creating issues, so a fresh repo's default-label state
  should not block the run.

**2026-06-07 review hardening:** Codex found and fixed two SP2 live-path gaps that
tests did not catch: the deployed `run-feed.ps1` hook now locates
`~/.claude/scripts/runs-lib.ps1` from the deployed `~/.claude/hooks/` layout, and
`run-feed.ps1`/`statusline-feed.ps1` now default to the same runs-root
`current-run.json` pointer written by `Set-CurrentRun`. The tests now cover both
the default pointer path and the deployed hook layout.

**Tools registry + Docling PDF call-out: SHIPPED** (merged `5573ecc`, 2026-06-07). The first
slice of the cost-optimization direction (d024). Stood up **`tools.yaml`** — a non-LLM
capability registry, the co-equal sibling of `fleet.yaml` (decision **d025**: build it at n=1
because it names the `tools` concept a later routing layer needs; tools are declared with
`cost_tier` + `capability`, invoked per-entry `kind` — `python` in-process / `cli` / `http`).
First entry: **Docling** (`kind: python`, `capability: pdf-extract`, `cost_tier: local`).
Wired into KB ingest: `kb/extractors/` converts a corpus file to text (markdown→read,
PDF→Docling via a **lazy/optional** import gated by the registry); the chunker was split into
a pure `chunk_text` + an extractor-fed `chunk_file`; the indexer now discovers `*.pdf` and
counts `extractor_skips`/`extractor_errors`. A PDF is **never silently zero-chunked** — no
tool / not-installed → counted skip, corrupt → error, `.md` pipeline never breaks. New
`tools/` Python package (`registry`/`doctor`/`list`) + `/baton:tools list|doctor` command, deployed
via bootstrap. Gate: 176 Python + 8 PowerShell suites + bootstrap smoke; review verdict SHIP.
Spec/plan: `docs/superpowers/specs/2026-06-07-tools-registry-docling-design.md`,
`docs/superpowers/plans/2026-06-07-tools-registry-docling.md`.

**Tools-registry deferred follow-ups (tracked, not done):**
- Real end-to-end acceptance: `pip install docling`, drop a real PDF under the corpus, run
  `python -m kb.index`, confirm `/baton:kb-search` returns a hit. The Docling shell path is only
  stub/monkeypatch-tested in CI (optional heavy dep — same posture as SP3's `gh`).
- `import sys` in `tools/doctor.py` is unused (harmless; left to avoid a churn commit).
- DOCX/PPTX/scan extractors are trivial to add (extractor keyed by extension) — not built.

**Capability-routing optimizer (decision d026) — auto-router + learning loop, in 3 slices.**
North star (user's words): "a way to code applications, using multiple tools/models to reduce
costs on the orchestrator and let it orchestrate other LLMs and Tools... It needs to learn over
time, integrate the wins and losses... get smarter... understand what I want better... I also
want it fully autonomous — I give it a folder and github repo, and it goes until tokens are out
or it is finished." The model/tool×capability performance dataset is itself a GitHub-backed,
compounding deliverable.

- **Slice 1 — selector + data model: SHIPPED** (merged `82be1b9`, 2026-06-08). PowerShell
  `Select-Capability` (`scripts/routing-lib.ps1`) over `tools.yaml` + `fleet.yaml` returns an
  explainable, **cheapest-tier-first** ranked candidate list (`local`<`free`<`paid`; quality an
  unrated neutral-0.5 slot); `/baton:route <capability> [--max-tier] [--local]` shows the pick + why
  (recommendation only). Specialty models (commit-msg/struct-extract/ocr) migrated from
  `routing.md` prose into `tools.yaml` as `kind:cli` entries; `fleet.yaml` gained a top-level
  `general_capabilities: [code-gen, reasoning, summarize]`. Gate: 26 routing checks + 176 Python
  + 8 PS suites + bootstrap smoke; review SHIP. Spec/plan:
  `docs/superpowers/specs/2026-06-07-routing-s1-capability-selector-design.md`,
  `docs/superpowers/plans/2026-06-07-routing-s1-capability-selector.md`.
- **Slice 2 — auto-dispatch + verify/escalate: SHIPPED** (merged `39c63b2`, closes #34,
  2026-06-08). `scripts/routing-dispatch.ps1`: `Invoke-RoutedCapability` walks
  `Select-Capability`'s cost-ascending ladder, dispatches each candidate (`Invoke-Tool` for
  `tools.yaml` cli entries, `Invoke-Fleet -NoJournal` for fleet models), grades with
  `Test-RoutingOutputHeuristic` (exit 0 + non-empty + per-capability validator), and escalates
  to the next candidate on failure — terminal `escalate-to-conductor` when all fail. Every
  attempt is logged to `$BATON_HOME/routing-journal.jsonl` (structured JSONL — the Slice 3 learning
  substrate). `/baton:route --run "<prompt>"` dispatches + prints the ladder walked. **Grader seam:**
  `Invoke-RoutedCapability -Grader <scriptblock>` (contract `(Capability,Result)->{passed,score,
  reason}`) defaults to heuristic; Slice 3 plugs in its judge here — **decision d027**. Gate: 28
  routing-dispatch checks + routing-lib regression + fleet + bootstrap smoke + 165 Python; review
  SHIP. Spec/plan: `docs/superpowers/specs/2026-06-08-routing-s2-dispatch-verify-escalate-design.md`,
  `docs/superpowers/plans/2026-06-08-routing-s2-dispatch-verify-escalate.md`. Scope note: file
  capabilities (`pdf-extract`/`ocr`) and `http`/`python` tool kinds are NOT auto-dispatched (cli
  tools + fleet models only) — they keep their existing paths.
- **Slice 3 — ratings + learning loop: SHIPPED** (merged `2656ce4`, closes #35, 2026-06-09).
  `scripts/routing-learn.ps1`: `Get-CapabilityQuality` blends the user's ratings + an LLM-judge
  score + heuristic pass-history into a learned per-(capability,candidate) quality (pseudo-count
  Bayesian, trust `Wu 1.0 > Wj 0.5 > Wh 0.25`, prior `k=2`, prior = yaml `quality` or 0.5). It
  replaces Slice 1's static 0.5 as the **within-tier tiebreaker** in `Select-Capability` — the
  cost-ascending formula is untouched, so cost tier still dominates (regression-tested: paid@1.0
  ranks below local@0.0). `Get-LlmJudgeGrader` fills the Slice 2 `-Grader` seam: free heuristic
  gate first (no judge call on broken output), cheap/local judge scores passing output, falls
  back to heuristic on error/no-model. `Invoke-RoutedCapability` stays pure (heuristic default =
  Slice 2); a `-Judge` switch opts in; the auto-on decision (local judge → on, else `--judge`)
  lives in `/baton:route`. Ratings persist to `~/.claude/knowledge/universal/routing-ratings.jsonl`
  (GitHub-backed, universal); the journal stays local. `/baton:route --rate good|bad [note]` captures
  the last winner's rating; `/baton:route <cap>` shows a learned-quality provenance column. Decisions
  **d028** (blend), **d029** (ratings→repo / journal-local split), **d030** (judge free-gate +
  command-layer auto-on). Gate: 11 suites green (routing-learn 43, routing-dispatch 31,
  routing-lib 27, bootstrap 15, all fleet suites) + live deploy smoke; review verdict SHIP.
  Spec/plan: `docs/superpowers/specs/2026-06-08-routing-s3-learning-loop-design.md`,
  `docs/superpowers/plans/2026-06-08-routing-s3-learning-loop.md`.

- **Slice 4 — calibration mode: SHIPPED** (merged `b88b12b`, closes #36, 2026-06-10). The
  **exploration** twin of S3's exploitation. `/baton:route --calibrate "<cap>" "<prompt>"` fans out
  across **all** candidates (within a tier cap), judge-scores each, journals one row per candidate
  (`grader=llm-judge` — signal with zero human effort), and shows a side-by-side table
  (candidate · tier · judge · learned-quality provenance · output excerpt) plus a **pre-filled**
  Phase-2 rate command. Phase 2 — `/baton:route --calibrate "<cap>" --rate "qwen=good devstral=bad …"`
  — records a verdict per candidate to the GitHub-backed ratings store (human thumbs Wu 1.0
  dominate the judge seed). Cost-safe by default: caps at `--max-tier free`; paid candidates need
  explicit `--max-tier paid`; a preview line announces the dispatch count. Architecture: a shared
  `Invoke-RoutedCandidate` helper was extracted from `Invoke-RoutedCapability` so the escalate-and-
  stop loop and calibration's fan-out share one dispatch→grade→journal primitive (regression-safe:
  S2's 31 checks unchanged). New `scripts/routing-calibrate.ps1` (`Invoke-CapabilityCalibration` +
  `Add-CalibrationRatings`). Decision **d031** (judge-seeded with human confirm/override). Gate: 13
  suites green (routing-calibrate 17, routing-dispatch 31, routing-learn 43, routing-lib 27,
  bootstrap 16, all fleet) + live deploy smoke; review verdict SHIP (provenance nit fixed).
  Spec/plan: `docs/superpowers/specs/2026-06-09-routing-s4-calibration-mode-design.md`,
  `docs/superpowers/plans/2026-06-09-routing-s4-calibration-mode.md`.

**Routing optimizer follow-ups (tracked, not done):**
- Per-prompt similarity matching — ratings/judge scores aggregate per capability×candidate, not
  per prompt; a learned router could match new prompts to similar past ones.
- Auto-tuning of the blend weights (`Wu/Wj/Wh`, `k`) instead of the fixed d028 constants.

**Future epic (beyond the routing slices):** a fully-autonomous run-loop — given a folder + GitHub
repo, run until token budget exhausted or the goal is met — built ON TOP OF the router.

**Next (each gets its own spec → plan → build):** the routing optimizer's core is now complete
(S1 selector, S2 dispatch, S3 learning, S4 calibration — all SHIPPED). Candidate next moves:
the **autonomous run-loop epic** (the headline goal), or routing refinements (per-prompt
similarity / weight auto-tuning); plus SP4 surface delight (pixel sprites + IDE renderers) and
the role/adversarial engine + ruflo call-out. Pick at session start.

## A. Re-opening the project (every session)

1. **Open Claude Code in the repo:**
   ```powershell
   cd D:\Dev\baton    # (folder renamed from coding-agent-orchestrator 2026-06-11)
   claude
   ```
   Memory auto-loads (user profile, project state, brainstorming defaults). The project's `CLAUDE.md` loads automatically — Claude will follow the decision-capture rule.

2. **(Optional, one-time per shell)** Enable OTel telemetry capture:
   ```powershell
   . $HOME\.claude\otel-env.ps1
   ```

3. **Health check** (run these in chat):
   - `/baton:fleet doctor` — confirm 5+ providers are reachable
   - `/baton:kb-search "ensemble"` — confirm the index has hits
   - In a second terminal: `python -m dashboard.main` → open `http://localhost:8765` for the portfolio + KB search panel

4. **If anything is off:**
   - `pwsh scripts\bootstrap.ps1 -Force` — re-deploy everything; idempotent
   - `ollama pull nomic-embed-text` — if `/baton:kb-search` says the model is missing
   - `/baton:kb-index --full` — rebuild the vector index from scratch

## B. Pick the next plan from the backlog

5. **Open the Project board:** https://github.com/users/Ryfter/projects/5.
   As of 2026-06-04 the post–Plan-8 backlog (#16–#26) is **cleared** — see
   `docs/releases/2026-06-04-backlog-clearance.md`. The board is empty.

6. **What's left (no open issues — file one when you pick these up):**
   - ~~**Wire `decision-detect` as a `Stop` hook**~~ — **DONE** (verified 2026-06-10): registered in `~/.claude/settings.json` Stop hook + deployed by `bootstrap.ps1:112-116`. Auto-decision-capture is live.
   - **Cross-project consolidation sweep** — blocked until a second project exists (universal guidance stays empty with one project).
   - **Attach decision feedback** — `/baton:decision-feedback <id> worked|didnt|mixed` over d001–d013 to graduate "Open / under-feedback" entries into "Established patterns".
   - **New capability** — brainstorm the next plan; capture the decision, open an issue, run the loop below.

7. **Read the issue body.** Each carries a Tier label, scope, and any noted risks/mitigations. `docs/roadmap.md` has the same content.

## C. Working a single plan with the orchestrator (the loop)

Pick issue **#N** — let's say **#16** (Plan 8.1 auto-index hook). Work it like this:

8. **Open a job:**
   ```
   /baton:job-start "Plan 8.1 — auto-index hook for KB writes (closes #16)"
   ```
   Creates `$BATON_HOME/jobs/<id>/` and starts in the `research` phase.

9. **Research with the fleet + KB pre-fetch** (Plan 8 RAG fires automatically):
   ```
   /baton:research "best pattern for a debounced PostToolUse hook in PowerShell that re-runs python -m kb.index --scope ... on touched files only"
   ```
   Synthesis lands at `<job>/phases/research/ensemble-<ts>/synthesis.md`.

10. **For architectural decisions, run a council or hats:**
    ```
    /baton:six-hats "should the auto-index hook be synchronous or async/debounced?"
    /baton:council "should we debounce by file-path or by time-window?" --providers claude-cli,codex
    ```

11. **Capture lessons as you go:**
    ```
    /baton:job-lesson knowledge "PostToolUse hooks fire after every Write/Edit; KB-scoped path filter is essential"
    ```

12. **Advance to design** (write the spec by hand or via `/baton:six-hats` synthesis):
    ```
    /baton:job-phase next
    ```
    Author `docs/superpowers/specs/2026-MM-DD-plan8.1-design.md`. Capture any architectural decision via the file-based intake (see `CLAUDE.md`).

13. **Advance to code phase:**
    ```
    /baton:job-phase next     # design → code.sprint-1
    /baton:code-decompose docs/superpowers/specs/2026-MM-DD-plan8.1-design.md
    ```
    Claude reads the spec, proposes N subtasks (`files_touched`, `depends_on`), confirms, writes `<job>/phases/code.sprint-1/subtasks.json`.

14. **Dispatch parallel implementations:**
    ```
    /baton:code-parallel
    ```
    One Agent subagent per task in `isolation: worktree`. Independents fire concurrently; dependents wait.

15. **Review the merge plan, then apply:**
    ```
    /baton:code-merge              # see plan + likely conflicts
    /baton:code-merge --apply      # cherry-pick in dep order; stops on first conflict
    ```

16. **Push + PR + merge** (deliberate manual gate):
    ```bash
    git push -u origin <branch>
    gh pr create --title "Plan 8.1: auto-index hook (closes #16)" --body "..."
    # review the PR
    gh pr merge <N> --merge --delete-branch
    git checkout master
    git pull --ff-only origin master
    ```
    The `closes #16` syntax auto-closes the issue and moves it to Done on Project #5.

17. **Wrap the job:**
    ```
    /baton:job-phase done
    ```
    Closes the job, prompts for retro feedback on decisions captured during it.

18. **Update cost** (when your Anthropic billing dashboard refreshes):
    ```
    /baton:cost <new-total>
    ```

19. **Re-index the KB** to absorb the new spec + lessons + decisions:
    ```
    /baton:kb-index               # incremental — milliseconds if nothing changed
    ```

## D. Repeat

Steps 8–19 are the loop. Each backlog issue → one job → one PR → one closed issue. The orchestrator gets better at advising you on its own design as the KB grows (Plan 8 RAG kicks in on every `/baton:research`).

## E. Bootstrap a new project (someday)

When you bring the orchestrator to a different repo:

1. `cd path\to\other\repo` and `claude` (memory auto-loads, project gets its own KB layer at `~/.claude/knowledge/projects/<id>/`)
2. `/baton:project-init` — surfaces universal decision guidance and prompts for per-project overrides
3. Skip to step 8 above (`/baton:job-start "..."`)

Every project gets its own row in the dashboard's Portfolio panel.

## Quick reference — the 17 slash commands

**Routing/observability:** `/baton:log-routing`, `/baton:consolidate-routing`
**Jobs:** `/baton:job-start`, `/baton:job-status`, `/baton:job-list`, `/baton:job-phase`, `/baton:job-resume`, `/baton:job-lesson`, `/baton:consolidate-lessons`
**Fleet:** `/baton:fleet` (doctor/test/list)
**Research:** `/baton:ensemble`, `/baton:research`, `/baton:six-hats`, `/baton:council`
**Code phase:** `/baton:code-decompose`, `/baton:code-parallel`, `/baton:code-merge`
**KB:** `/baton:kb-index`, `/baton:kb-search`
**Decision loop:** (rule in `CLAUDE.md`), `/baton:decision-feedback`, `/baton:consolidate-decisions`, `/baton:project-init`
**Cost:** `/baton:cost`

All deployed to `~/.claude/commands/`. Re-deploy with `pwsh scripts\bootstrap.ps1 -Force`.
