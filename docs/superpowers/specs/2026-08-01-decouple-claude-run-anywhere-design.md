# Decouple Baton from Claude; run anywhere

**Date:** 2026-08-01  
**Status:** design only — not authorized to build  
**Author:** Grok design pass from operator brief + live codebase audit  
**Related:** d051 (Style-A + Style-B seam), d076 (project registry), d086 (golden path), d091 (instrument ABI), d102 (supervisor durable / shell swappable); system model `2026-07-11-cli-control-plane-system-model-design.md`; Style-B draft `2026-07-04-style-b-broker-cockpit-design.md`

---

## Premise check (where ground truth needs correction)

Build on the operator audit; flag only verified drift.

| Claim | Live finding | Implication |
|---|---|---|
| ~46 slash commands in `commands/*.md` | **52** command files today | Same shape; size estimate is slightly low |
| No standalone CLI entry point | **Half-true.** There is no unified `baton <verb>` dispatcher, but most engines already have `scripts/fleet-*.ps1` / `*-lib.ps1` runners (`fleet-go.ps1`, `fleet-gate.ps1`, `fleet-plan-gate.ps1`, job-lib, routing-dispatch, …). The gap is a **single argv front door + re-homed verb semantics**, not a green-field engine CLI |
| Hooks die outside Claude | True for automatic host hooks; the underlying scripts under `scripts/hooks/` are plain `pwsh` and can be invoked from CLI lifecycle |
| MCP has no go/execute/gate/plan-gate | **True** — bridge ops are exactly: capabilities, route-select, route-dispatch, fleet-list, fleet-doctor, fleet-test, job-status, job-list |
| Windows-only: scheduled tasks, CIM/WMI, named mutex (~6 files) | **Narrower than stated.** Hard Windows binding found: **`schtasks` in heartbeat install/uninstall/reschedule** (`fleet-heartbeat.ps1`, `heartbeat-lib.ps1`). `verification-lib.ps1` already branches on `$IsWindows` for platform keys (portable pattern). **No `Get-CimInstance` / WMI** in `scripts/`. Window-service already uses a **portable file claim** (`FileMode.CreateNew` on `*.claimed`) as its cross-process mutex — not a Windows named mutex |
| Governor specifies Windows named mutex | Design-only (PR **#154**, not merged). Must not ship that primitive as-is; file-lease / flock-style already proven in-tree |
| Projects root defaults to Windows path | **True:** `Get-ProjectHomeRoot` → `D:\dev` unless `BATON_PROJECTS_ROOT` | Override exists; default should become OS-neutral |
| Deploy path is vendor-neutral | **False-ish.** Bootstrap still deploys into `~/.claude/`; **47/52** command bodies hardcode `$HOME/.claude/scripts/…` | Re-homing must fix **script resolution**, not only command format |

Nothing above invalidates the two requirements. It does change sequencing: the highest-leverage first step is a **CLI dispatcher over existing runners**, not a rewrite of the engine.

---

## 1. Front-door decision

### Options weighed

| Option | Avoids new vendor lock-in? | Effort to re-home ~50 verbs | Fits “supervisor = core, chat = client”? | Budget pressure |
|---|---|---|---|---|
| **A. Standalone CLI dispatcher** (`baton` → `scripts/baton.ps1` or install shim) | Yes | Medium — map verbs to existing `fleet-*.ps1` / libs; thin host adapters later | Yes — matches d102 + CLI control-plane model | Best: zero session tax for engine verbs |
| **B. Expand MCP as primary** | Yes (protocol-level) | Medium-high — still need verb contracts; MCP is awkward for long DAGs, interrupts, streaming narration | Partial — good for IDEs, weak as operator primary | Good for multi-client; poor sole front door |
| **C. Another vendor coding CLI as shell** (Codex / Cursor / Grok Build as the conductor host) | **No** — swaps Claude lock-in for a peer | High — rewrites host glue + hooks per vendor | Contradicts d102 and the NARROW review (no resident shell product) | Operator still pays a host; may not be the 5× cheaper vendor |
| **D. Custom text/REPL** | Yes | High — new UX surface + interrupt UX + history | Duplicates CLI + dashboard without new power | Nice later; not phase-1 |

### Recommendation

**Primary front door: A — a vendor-neutral `baton` CLI over the existing PowerShell engine.**

- **Canonical operator path:**  
  `baton go "…" --execute`, `baton fleet doctor --live`, `baton job list`, `baton plan-gate …`  
  Implemented as one dispatcher that resolves verb → existing script/lib, with `--json` as the default machine contract (human text is a formatter on top).
- **MCP becomes a first-class client of the same dispatcher** (not a parallel op table). Every MCP tool is `baton <verb> --json` (or a shared bridge that calls the same function the CLI calls). Pipeline verbs (`go`, `gate`, `plan-gate`, `research-gate`, `worker`, …) land here in phase 1–2.
- **Claude Code slash commands become optional thin skins** — generated or hand-thinned stubs that parse `$ARGUMENTS` and call `baton …`. Claude remains *a* conversational shell and *a* fleet instrument when worth it — never the control plane.
- **Other coding CLIs** (Codex, Grok Build, Cursor, etc.) are the same class of optional shell: they may host a short “conductor prompt” that shells out to `baton`, or they may be pure instruments. Do **not** build a second host-native command tree for each.
- **Style-B broker / dashboard submit** (existing draft) remains the scale substrate for headless queue + interrupt inbox — **not** the day-1 front door. CLI first; broker when concurrent/headless needs exceed a single process.

### Explicit non-choice

Do not make “switch conductor to Codex/Grok Build sessions” the decoupling strategy. That preserves the anti-pattern (host session = product) under a different logo, and the budget problem is vendor *dependence*, not only Anthropic.

---

## 2. Re-homing the command surface

### Problem today

```
commands/*.md  ──(Claude only)──►  agent improvises steps  ──►  ~/.claude/scripts/*.ps1
        │
        └── 47/52 files hardcode Claude deploy path
```

MCP has a **second** partial surface (8 tools). Docs describe a third mental model. Drift is inevitable.

### Canonical form: the **verb contract**

One source of truth per verb, host-agnostic:

```text
verbs/<name>.yaml          # identity, argv schema, class, runner, mcp exposure
scripts/<runner>.ps1       # deterministic engine (already mostly exists)
prompts/ or commands/      # OPTIONAL conversational overlays (generated/thin)
```

**Minimum fields for a verb contract:**

| Field | Purpose |
|---|---|
| `name` | Stable id (`go`, `fleet`, `job-list`) |
| `summary` | One-line help / MCP description |
| `class` | `engine` \| `interactive` \| `hybrid` (see below) |
| `runner` | Path + param map into existing script (`fleet-go.ps1`, …) |
| `argv` | Flags, types, mutual exclusions (mirror current `argument-hint`) |
| `json_schema` | Shape of `--json` success/error envelope |
| `mcp` | `expose: true/false`, tool name, long-running flag |
| `interrupts` | Structural only for `go` (budget, destructive); others usually none |
| `needs_job` / `needs_repo` | Preflight predicates |

**Generation / delegation (avoid three copies):**

1. **CLI** reads contracts → subcommands + help + validation.  
2. **MCP** exposes `mcp.expose` verbs as tools; implementation = same runner functions, never reimplemented in Python except where already Python (`kb_search`).  
3. **Host skins** (`commands/*.md`, future Codex skills, etc.) are **generated stubs**: “parse args → `baton <name> …` → narrate JSON if interactive.” Human-authored prose for teaching (`start`) lives in a `docs/` or `playbooks/` overlay referenced by the stub, not duplicated into three hosts.

Until a generator exists, the **manual rule** is: edit runner + contract; host `.md` may only parse and shell out. No new logic in `commands/*.md`.

### Script resolution (must fix with re-home)

Replace `$HOME/.claude/scripts` with a resolution order:

1. `$env:BATON_REPO_ROOT/scripts` (dev / source checkout)  
2. `$env:BATON_HOME/scripts` (optional local overrides)  
3. Install location next to the `baton` shim  
4. Legacy fallback: `~/.claude/scripts` (compat, warn once)

Bootstrap continues to *optionally* deploy for Claude plugin users, but the engine no longer **requires** that path.

### Verb classification (cheap wins first)

Rough split of the 52 commands (heuristic from bodies + runners; refine when contracting):

#### Class `engine` — deterministic / structured; **no model required** for the verb itself

These should work on a box with zero paid providers installed (they may *invoke* models when the operator asks, but the verb is a pure dispatcher).

| Cluster | Examples |
|---|---|
| Fleet ops | `fleet` (list/doctor), `models`, `tools`, `usage`, `effective-cost`, `cost` |
| Jobs / projects | `job-list`, `job-status`, `job-phase` (state machine), `projects`, `project` |
| KB / memory plumbing | `kb-index`, `kb-search` (local embed), `remember`/`recall` file paths, `memory-ingest` |
| Gates as runners | `gate`, `plan-gate`, `research-gate` (call models, but CLI-complete) |
| Conductor engine | `go` (full pipeline already in `fleet-go.ps1`), `worker`, `heartbeat`, `window-service`, `ship-report` |
| Routing | `route` (select / dispatch), `log-routing` (append), `optimize-prompt` |
| Ensemble primitives | `ensemble`, `six-hats`, `council`, `research` (job-scoped wrapper) |
| Direct instrument | `codex`, `grok`, `gemini`, `agy` (pass-through dispatch) |
| Consolidate / triage | `consolidate-*`, `triage`, `idea` (scripted pipelines) |

**Cheap win:** expose all of these on CLI + MCP before touching interactive coaching.

#### Class `interactive` — needs a conversational agent (or a structured interview loop)

| Verb | Why |
|---|---|
| `start` / `init` / `initialize` | Adaptive interview, teaching narration, resume choice |
| Parts of `go` **as a chat shell** | Narrate events, ask on budget/destructive interrupts, help on plan-rejected |
| `project-init` | Calibrate guidance with operator dialogue |
| `consolidate-routing` | Propose catalog edits; human approve |
| `code-decompose` / merge planning prose | Peer coordination + confirmation |

These do **not** block engine operability: `go` already runs headless via `fleet-go.ps1`; `start` can degrade to required-flags-only (`--name --folder --goal`) on CLI with exit 2 if missing, while chat shells keep the interview.

#### Class `hybrid`

- `go`: engine = plan→walk→gates; interactive layer = narration + interrupt Q&A.  
- `job-start` / `job-resume`: mostly engine; Claude md adds “suspend or resume?” confirmation.  
- `route --run`: engine; conversational “what should I use?” is hybrid.

### What interactive hosts still own

- Multi-turn clarification when the operator refuses to pass flags.  
- Taste seams (merge word, design forks) — never automated.  
- Optional coach footers / teaching tone.

They must **not** own: routing math, DAG walk, gates, usage governor, worktree labor, cost ledgers.

---

## 3. The conductor without the incumbent

### What “conductor” is today (two layers that got conflated)

| Layer | What it is | Where it lives |
|---|---|---|
| **Engine conductor** | Plan via routed planner prompt → Kahn walk → budget/destructive guards → gates → artifacts | `conductor-lib.ps1` + `fleet-go.ps1` — **already vendor-neutral** |
| **Session conductor** | Parse NL goal, shell out to engine, narrate `events.jsonl` / `decisions.jsonl`, ask on interrupts, coach tone | `commands/go.md` inside Claude (Style-A, d051) |

The three-tier diagram in the go-mode spec still names “this Claude session” as the conductor. **Live architecture has already moved the brain into `fleet-go`.** The session is mostly a skin.

### What a single fleet dispatch cannot do (that the interactive conductor does)

1. **Structural interrupt dialogue** — budget raise / destructive approval, then resume (engine stops; someone must answer).  
2. **Streaming / progressive narration** — turn event log into operator-facing progress without the operator polling files.  
3. **Recovery coaching** — plan-rejected, verification-failed, missing `verification.json`: offer scaffold vs `--no-verify` vs goal rewrite.  
4. **Session memory across turns** — “raise budget and continue that run” without re-pasting paths.  
5. **Taste seams** — merge word, product forks (playbook steps 10–11).  

Items 1–2 are **product-essential** for autonomy+legibility. Items 3–4 can be CLI flags + dashboard. Item 5 stays human forever.

### Replacement model

```
Operator
   │
   ├─► baton go …              (primary; headless-capable)
   ├─► optional chat shell     (Claude / Codex / Grok / local) that ONLY:
   │      • collects goal / answers interrupts
   │      • calls baton / reads run dir
   │      • never reimplements the DAG
   └─► optional Style-B broker  (queue + interrupt files; later)
```

**Conductor prompt as a capability (optional):**  
A thin “session conductor” system prompt (extract of `go.md` minus engine steps) can be dispatched via `Select-Capability` / `Invoke-RoutedCapability` for operators who want NL without a coding-agent host — e.g. local or free-tier model that only emits structured next actions (`run_baton`, `ask_user`, `done`). That is **not** required for operability; it is a convenience product on top of the CLI.

**Default cost posture for that role:** free/local first; escalate only if the operator wants richer narration. Never put the session conductor on a frontier paid model by default when the engine already planned with a routed planner.

### Style-A vs Style-B under decoupling

- **Style-A** remains: any interactive shell that stays alive for one run and answers interrupts on stdin/chat.  
- **Style-B** (file queue + broker) is how Style-A dies cleanly when the laptop lid closes — still correct, still later.  
- **d102** stands: supervisor/engine is durable; agentic coding CLI is a swappable client.

---

## 4. Replacing the hooks

Host: `hooks/hooks.json` (Claude Code only). Implementations: portable `pwsh` under `scripts/hooks/`.

| Hook / script | What it provides | Essential? | Replacement |
|---|---|---|---|
| **SessionStart → `baton-init.ps1`** | Ensure `BATON_HOME`, seed configs, one-time migrate from `~/.claude` | **Essential once per box** | `baton init` / first `baton` invocation; optional login shell snippet. Drop automatic-every-session if CLI guarantees init |
| **SessionStart → `baton-coach.ps1`** | Coaching digest / guided-use | Nice-to-have | CLI: `baton coach status` or footer flag; **droppable** outside interactive shells |
| **SessionStart/resume/compact → `baton-session-start.ps1`** | Neutral session markers under `$BATON_HOME/sessions/` | Useful for project command center “active” | Any shell adapter writes the same marker JSON (already harness-neutral contract). CLI long-runs can write markers too |
| **PostToolUse → `log-tool-call.ps1`** | OTel / observation of host tool calls | Observability for Claude labor | Only meaningful inside a tool-using host; engine already journals fleet dispatches. **Drop outside Claude**; keep as optional host adapter |
| **PostToolUse → `run-feed.ps1`** | Statusline / live run feed | Nice for Claude UX | Dashboard + `baton runs watch`; **droppable** |
| **Stop → `decision-detect.ps1`** | Heuristic decision capture | Valuable but already opt-in-ish | `baton decisions detect` on demand; or post-run compound closeout. Not required for ship path |
| **SessionEnd → `baton-session-stop.ps1`** | Clear/update session + project resume pointer | Useful | Mirror on CLI exit / broker run end |
| **User-settings `kb-autoindex`** (not in plugin hooks.json) | Re-index KB on file write | Useful | File watcher optional; explicit `baton kb-index`; dashboard cron |

### Policy

- **Must survive everywhere:** `BATON_HOME` init/seed, run journals, fleet/routing journals, session markers **when a session exists**.  
- **Shell-optional:** coach, run-feed, host tool-call logging, decision-detect automation.  
- **Do not** port Claude’s hook graph 1:1 to every OS — port the **effects** that the control loop needs (observe → remember), invoked from CLI lifecycle and run closeout.

---

## 5. Cross-platform plan

**Baseline requirement:** PowerShell 7 (`pwsh`) on Windows, Linux, macOS. No Windows PowerShell 5.1 dependency for the engine.

### Facilities

| Facility | Today | Portable replacement | Abstraction boundary | Must-work vs degrade |
|---|---|---|---|---|
| **Scheduling (heartbeat)** | `schtasks` one-shot self-reschedule | Interface `Register-BatonSchedule` / `Unregister-…`: Windows → Task Scheduler; Linux → user systemd timer **or** crontab; macOS → `launchd` plist. Always support `-PrintSchedule` + manual `baton heartbeat --now` | `heartbeat-lib` schedule provider | **Degrade:** install may fail; **must-work:** manual beat + anchor math (already independent of scheduler) |
| **Process / host inspection** | Minimal; no WMI found in engine | Use `Get-Process`, `/proc`, and .NET where needed; avoid CIM | Any future host-info helper behind `Get-HostResourceSnapshot` | Degrade to “unknown load” → conservative local caps |
| **Cross-process lock** | Window-service: **file CreateNew claim** (good). Governor design: Windows named mutex (**reject as-is**) | Prefer **file leases** (claim file + heartbeat mtime + stale reclaim) — already proven. Optional: `flock` via libc on Unix; on Windows use exclusive file create, not `Global\` mutex | `Enter-BatonLock` / `Exit-BatonLock` in a tiny lock lib used by governor + broker | **Must-work** for concurrent local labor; fail **closed** for local resource claims (per governor intent) |
| **Path handling** | Mostly `Join-Path` / .NET full path; good | Ban hardcoded `D:\…`; always `BATON_PROJECTS_ROOT`; normalize with `[IO.Path]::GetFullPath`; case-insensitive compares only when `$IsWindows` | registry / start-lib | **Must-work** |
| **`$BATON_HOME`** | Default `~/.baton` — already portable | Keep; document XDG optional later (`$XDG_STATE_HOME/baton`) without forcing it | `Get-BatonHome` | **Must-work** |
| **Projects root** | Default `D:\dev` | Default: `$HOME/dev` or `$HOME/Dev` if exists, else `$HOME/projects`; override `BATON_PROJECTS_ROOT` | `Get-ProjectHomeRoot` | **Must-work** with override; empty scan is ok |
| **KB path** | Default `~/.claude/knowledge` | Keep env override; add `BATON_KB_ROOT` defaulting to legacy path for compat, document move to `~/.baton/knowledge` or Grimdex checkout | `kb/paths.py` + PS kb-lib | Degrade: search returns empty if missing |
| **Deploy scripts path** | `~/.claude/scripts` | See §2 resolution order | `Get-BatonScriptsRoot` | **Must-work** without Claude install |
| **Named pipes / Global mutex** | Not in engine today | Do not introduce | — | — |
| **Verification presets** | Already `windows` / `posix` keys | Keep | `verification-lib` | **Must-work** |

### Feature detection pattern

```text
if (Can-Schedule) { install }
else { warn + print manual command + rely on heartbeat --now / external cron }
```

Never fail engine startup because a scheduler backend is missing.

### Local resource governor (PR #154 alignment)

When built: **file-lease locks keyed by `(host, stack)`**, weights as queue priority, fail closed for local. Reuse window-service claim semantics. Do not depend on Windows mutex namespaces.

---

## 6. Cost strategy (budget ~5× down)

### Principle

Keep multi-provider routing; change **defaults and ceilings** so paid frontier is **opt-in by stakes**, not ambient atmosphere. The engine already has `MaxCostTier`, depth policy, usage governor, and quality_first failover — use them deliberately.

### Role matrix (concrete)

| Role | Safe default tier | Escalate when | Do **not** cheap-out |
|---|---|---|---|
| **Session conductor / narration** | free / local / none (CLI only) | Operator wants NL coaching | Not a quality floor role |
| **Planner** (`Build-PlannerPrompt` → route) | free → paid only if free fails schema or stakes high | `stakes: high`, prior plan-rejected, large GoalFile | Bad plans waste all labor; keep a **quality floor** (schema-valid DAG + stakes present). Prefer mid-tier over weakest local if plan-reject rate rises |
| **Plan Gate peers** | free/local for light; **≥1 strong peer** on standard/high | high stakes, security-sensitive | Understaffed gate already fail-loud; do not staff with models that cannot follow JSON finding schema |
| **Worker / agentic labor** | cheapest **agentic** capable; prefer free subscription instruments | high stakes, prior verification-failed | **#150 lesson:** weak workers can violate `allowed_paths` and lie. Scope oracle remains fail-closed; keep agentic workers at a proven floor for edit tasks (not the weakest chat model) |
| **Acceptance panel — strong roles** (correctness, security, architecture, spec-compliance) | mid/strong | always for high stakes | These catch silent wrongness; cheap false-green is expensive |
| **Acceptance panel — cheap roles** (simplicity, framework-style) | local/free | — | Safe to stay cheap |
| **Research / ensemble / council** | free+local roster; paid optional | viability / legal / high-ambiguity | Default `research_default` should **not** lead with paid Claude |
| **Judge / routing grade** | local small model | calibration only | Already intended as cheap |
| **Heartbeat anchor** | cheapest subscription path that actually opens the window | — | Today Claude-haiku shaped; if that vendor is cut, re-bind anchor to whichever subscription still has a 5h window, or drop paid anchor and keep free housekeeping only |
| **Synthesize** (ensemble merge) | free/mid | large divergent roster | Needs coherence; not the absolute cheapest dump |

### Default flips (config, not code philosophy)

1. **`research_default`:** drop paid CLI from the default list; use free + local (+ one free cloud if available). Paid only via `--providers` / higher tier flag.  
2. **Global default `MaxCostTier` for interactive shells:** `free` for explore; `paid` only on `go --execute` or explicit `--max-tier paid`. (CLI can default execute to `paid` but journal why.)  
3. **Depth policy:** map `stakes: low` → local/free only; `standard` → free first with one paid escalate; `high` → allow paid planner + strong review without apology.  
4. **quality_first failover stays on** for labor and gates — never substitute a known-weaker peer just to spend less after a quality failure.  
5. **Subscription vs API:** prefer instruments that are already prepaid (seat) over metered API when quality is comparable; usage governor + soft caps prevent burning the seat early.  
6. **Local capacity:** respect d043 (one model server / VRAM). Expanding **local** capacity is the durable answer to a 5× cloud cut — routing should surface “add local headroom” rather than silently climb paid tiers.

### Metrics to watch after the flip

- Plan-reject rate and reason codes  
- Verification-failed rate (especially scope oracle)  
- Acceptance reject / needs-polish rate  
- Effective cost per completed run  
- % runs that touched `paid` tier  

If plan-reject or scope violations spike after downgrading workers/planners, raise the floor for those roles only — not the whole fleet.

---

## 7. Phased plan

Each phase leaves a working system. Earliest phase already reduces dependence.

| Phase | Outcome | Rough size | Dependence reduced? |
|---|---|---|---|
| **0 — Contract freeze (docs only)** | Verb inventory table (52→contract draft), class labels, script resolution design, this doc accepted | S (0.5–1 d) | Clarifies; no runtime change |
| **1 — CLI dispatcher + path fix** | `baton` / `baton.ps1` dispatches top engine verbs to existing runners; `Get-BatonScriptsRoot`; stop *requiring* `~/.claude/scripts` for those verbs; `baton go|fleet|job|route|usage|gate|plan-gate` with `--json` | M (3–5 d) | **Yes — operator can run golden path without Claude** |
| **2 — MCP parity** | Bridge ops + tools for go / gate / plan-gate / research-gate / worker / projects; MCP calls same functions as CLI | M (2–4 d) | Yes — any MCP client is a valid front end |
| **3 — Verb contracts + thin skins** | YAML contracts for engine class; generate or rewrite Claude `commands/*.md` as pure shells; fix remaining hardcoded paths | M (3–5 d) | Claude becomes optional skin |
| **4 — Portable scheduling + defaults** | Heartbeat schedule providers; projects-root default; `BATON_KB_ROOT`; cost default flips in seed `fleet.yaml` / docs | S–M (2–3 d) | Linux/macOS operable; spend posture fixed |
| **5 — Conductor client pack** | Extract interactive conductor playbook as host-neutral prompt + interrupt stdin protocol for CLI; optional free/local conductor dispatch | S–M (2–3 d) | NL UX without incumbent |
| **6 — Style-B broker (slice 1 only)** | Queue + park interrupts on files; no cockpit required | M–L (per existing Style-B draft) | Headless durability |
| **Later / not yet** | Full web cockpit, multi-host skins, governor build, resident shell product | — | — |

### Highest-leverage first step

**Phase 1: ship a `baton` CLI that can run `go --execute` (and fleet doctor, job status, plan-gate) without Claude installed**, resolving scripts from the repo or `BATON_HOME`, with JSON output.

That single step turns the already-neutral engine into an operable product under the new budget, and makes every later phase additive.

### Explicitly do **not** attempt yet

- Replacing Claude with another coding-agent host as the system of record  
- Building the full Style-B cockpit / multiplexer / resident shell (NARROW review still holds)  
- Rewriting the engine in Python/Go “for portability” — `pwsh` is already the portability layer  
- Maintaining parallel MCP op logic separate from CLI  
- Shipping the governor on Windows named mutexes  
- Auto-merge or removing human merge word  
- Big-bang rewrite of all 52 command markdown files before the dispatcher exists  
- Making local models the sole planner/worker without measuring plan-reject and scope-violation rates  

### Dependencies on in-flight work

- Merge/deploy **#153** (`-GoalFile`) still improves plan quality under any front door — orthogonal but high leverage for finish-rate.  
- Governor (**#154**) should absorb the portable lock decision from §5 before implementation.  
- Green walk / finish-rate remains the product proof; decoupling must not stall that arc — Phase 1 should help it (headless reproducible runs).

---

## Assumptions and risks

### Assumptions

1. Operator can install PowerShell 7 on every target OS.  
2. At least one non-Claude instrument remains available for labor (Codex, Grok, Gemini, local, or HTTP) — otherwise Baton still routes but cannot execute agentic edits.  
3. d102 / CLI-control-plane doctrine remains binding.  
4. File-based run artifacts remain the Style-A/B seam (no need for a network control protocol in v1).  
5. Budget drop is primarily against one paid vendor; free/local/other seats still exist or can be added.

### Risks

| Risk | Mitigation |
|---|---|
| CLI ships but operators still only know `/baton:…` | Docs + `baton help` mirror COMMANDS.md; keep Claude skins working |
| Thin skins lose teaching quality of `start` | Keep playbook prose in docs; CLI supports flags-only path; chat skin optional |
| Cost defaults cause more plan-rejects / scope lies | Role-based floors (§6); monitor metrics; raise floors selectively |
| MCP long-running `go` timeouts | Async pattern: MCP starts run, returns `run_id`; client polls `baton runs show` |
| Scheduler portability half-done on Linux/macOS | Manual heartbeat always works; install is best-effort |
| Script resolution breaks existing Claude plugin users | Legacy fallback path + bootstrap still deploys for them |
| Scope creep into Style-B cockpit | Phase gate: broker slice 1 only after CLI+MCP solid |
| Dual-maintaining contracts and old md | Generator or “md must only shell out” review check in CI later |

### Success criteria (design-level)

1. On a machine with **no Claude Code**, `pwsh` + Baton checkout + one labor provider can run `baton go "…" --execute` through plan → labor → verify → report.  
2. Same verbs available via MCP without a second implementation.  
3. Claude plugin still works as a thin client.  
4. Heartbeat and projects scan work on Linux/macOS with documented env overrides (scheduler install may be manual).  
5. Default research/ensemble paths do not require the expensive vendor.

---

## Summary recommendation

Make **`baton` CLI the primary front door**, expand **MCP as a peer client of the same runners**, and demote **Claude Code (and every other coding CLI) to optional shells + optional instruments**. Re-home commands as **verb contracts + existing PowerShell runners**, with host markdown generated or reduced to shells. Treat the conductor as **engine-first** (already true in `fleet-go`) plus a thin interrupt/narration client. Port hooks by **effect**, not by host graph. Prefer **file leases** over Windows mutexes. Point cost defaults at free/local with **quality floors** on planner, plan-gate, agentic labor, and strong acceptance roles.

**Build first:** Phase 1 dispatcher + script root resolution so the golden path no longer has a Claude door on it.
