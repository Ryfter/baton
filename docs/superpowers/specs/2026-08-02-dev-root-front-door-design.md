# Dev-root front door — `baton <project>`, UI entry points

**Date:** 2026-08-02  
**Status:** design only — not authorized to build  
**Author:** Grok design pass from operator brief + live codebase audit  
**Related:** d076 (project registry / command center), d051 (Style-A + Style-B seam), d086 (golden path / execute defaults), d102 (supervisor durable / shell swappable); CLI control-plane model `2026-07-11-cli-control-plane-system-model-design.md`; project command center `2026-07-04-baton-project-command-center-design.md`; Style-B broker draft `2026-07-04-style-b-broker-cockpit-design.md`; dashboard Live Fleet Ops `2026-07-04-dashboard-live-fleet-ops-design.md`; decouple-from-Claude `2026-08-01-decouple-claude-run-anywhere-design.md` (Phase 1 CLI dispatcher is the substrate this rides)

---

## 0. One-liner

From the operator's development root, **`baton <project>`** is a safe, deterministic short path into that project's Conductor run (brief known, folder known); **`baton`** / **`baton ui`** open the existing web dashboard as a control board *over* the CLI; **`baton --cli`** is a browser-free interactive board of the same surface. No second engine path.

---

## 1. Premise check (verified ground truth)

| Claim | Live finding | Implication |
|---|---|---|
| Project resolution exists | **True.** `registry-lib.ps1`: `Get-ProjectHomeRoot`, `Find-ProjectFolders`, `Resolve-ProjectTarget -Slug` (slug then id). Project folder = `.git` **or** `CHARTER.md`. Lifecycle + blurb via `$BATON_HOME/projects/` + scan fold | Folder + name already known; this design does not invent a registry |
| Dev root is configurable | **Half-true.** `$env:BATON_PROJECTS_ROOT` overrides; **default is hardcoded `D:\dev`** (`Get-ProjectHomeRoot`) | Cross-platform default is a **required** fix in this work |
| Web front end exists | **True.** `dashboard/` FastAPI app (routers, templates, static, readers). Launched only via `python -m` / `uvicorn` today — **not** in `verbs.yaml`, no `baton` verb | Need a launch verb + dispatcher hooks |
| Dashboard reads files | **True.** Readers hit `$BATON_HOME` paths and journals directly. `controls` router shells `ollama`/`lms` only — **not** `baton go` | Observe-by-file is OK; **act** must not grow a parallel engine |
| Repo-local config precedent | **True.** Committed `.baton/verification.json` is required for verified `--execute` labor | Prefer `.baton/project.yaml` for per-project run defaults (same travel-with-repo pattern) |
| CLI today | **True.** `scripts/baton.ps1` + root shim: `baton <verb>`, bare/`--help` → verb list, `verbs --json`, unknown verb exit 2, raw arg passthrough | Collisions A/B are dispatcher changes; not a rewrite |
| `go --project` exists | **True.** `fleet-go.ps1 -Project` → `Resolve-ProjectTarget`; `-GoalFile`; `-Execute` with verification onboarding | Bare project name should **compose** this path, not fork it |
| Standing GUI rule | Binding (control-plane model + command-center Layer 2): GUI is a control board **over** the CLI — call the CLI (or broker queue that runs the same engine), never re-implement folds/dispatch | Name the seam; don't re-litigate |

Nothing above invalidates the three operator wants. It does force honest collision answers (especially on implicit `--execute`).

---

## 2. Operator goals (product surface)

| Invocation | Operator intent |
|---|---|
| `baton atomicforge` | Resolve project → load that project's brief + defaults → start a Conductor path for it (folder already known) |
| `baton` (no args) | Launch the **web** front end so he can drive from a browser |
| `baton --cli` | Launch a **CLI/terminal** version of that same front end (no browser) |

Mental model: stand in the dev root, name a project, work starts; or open the board and pick.

---

## 3. Collision A — `baton <projectname>` vs `baton <verb>`

### Options weighed

| Option | Pros | Cons |
|---|---|---|
| **A1. Verbs always win** | Scripts, agents, and muscle memory stay stable; finite reserved set; explainable | Project whose slug equals a verb is unreachable via bare name |
| **A2. Projects win when resolved** | Matches "type the project name" intuition | `baton go` becomes a project run if a folder is named `go` — silent catastrophe for every script |
| **A3. Context-sensitive** (projects only from projects root) | Softens collision rate | Still wrong if someone names a folder `go` under the root; hard to document; agents rarely at root |
| **A4. Sigil only** (`baton @atomicforge`) | Zero collision | Worse ergonomics; `@` is awkward in some shells; abandons the bare-name ask |

### Decision: **A1 — verbs win; bare name is project only when not a verb; long form always works**

**Resolution order** (first match wins; stop):

| Step | Token / condition | Action |
|---|---|---|
| 0 | No args | Collision B (bare `baton`) |
| 1 | Global flags as first token: `--help` / `-h` / `help`, `--version`, `--cli`, `--json` (if we ever allow global json) | Handle as dispatcher builtins; never as project |
| 2 | First token is a **registered verb** name (`verbs.yaml`) | Dispatch that verb (today's behavior) |
| 3 | First token is a **reserved future/special** name reserved in this design even if not yet in yaml: `run`, `ui`, `dashboard` (once registered, they are step 2) | Same as verb |
| 4 | First token matches `Resolve-ProjectTarget -Slug` → `status=resolved` | **Project short path** (§5) |
| 5 | Else | Unknown: treat as unknown verb **or** unknown project (unified message, exit 2) |

**Shadowed projects (slug collides with a verb):**

- Bare `baton <slug>` runs the **verb**, never the project. No silent project run.
- On `baton project list` (and `project list --json`), mark shadowed entries: `shadowed_by_verb: true` + `run_via: "baton run <slug>"`.
- Optional stderr one-liner when a human runs `baton project list` and any shadow exists:  
  `note: N project slug(s) shadow verb names; use 'baton run <slug>' for those.`
- **Unambiguous long form (required in v1):**  
  `baton run <project> [go-flags…]`  
  Always means project short path, even if `<project>` equals a verb name.  
  Also always valid:  
  `baton go --project <slug> --goal-file <brief> …` (existing engine surface).

**No sigil in v1.** Revisit only if real operators hit frequent shadows; the verb list is small (~17) and project slugs rarely match (`go`, `gate`, `cost`, `project`, `fleet`, …).

**Why not projects-win:** a folder named `go` would steal the entire Conductor verb. That failure mode is worse than forcing `baton run go` for a misnamed project.

---

## 4. Collision B — bare `baton` currently prints help

### Options weighed

| Option | Pros | Cons |
|---|---|---|
| **B1. Always help; explicit `baton ui`** | Zero surprise; CI-safe; agents unchanged | Operator must learn a second token for "open the board" |
| **B2. Always UI** | Matches literal ask | Every forgotten arg, every agent smoke, every CI `baton` starts a server — large footgun |
| **B3. Context-sensitive** | Matches "I start from `D:\dev`" mental model; keeps help elsewhere | Slightly more logic; must define "projects root" equality carefully |
| **B4. Interactive choose** (help vs UI menu) | Safe | Clunky; breaks non-interactive |

### Decision: **B3 + hard escape hatches — context-sensitive default, never accidental in CI**

| Invocation | Behavior |
|---|---|
| `baton` (no args), **interactive TTY**, cwd **is** the projects root (see equality below), and **not** auto-suppressed | Launch **web** UI (§7) |
| `baton` (no args), any other case | Print help (today's verb list), exit 0 |
| `baton --help` / `-h` / `help` | **Always** help, exit 0 — even at projects root |
| `baton ui` / `baton dashboard` | **Always** launch web UI (verbs) |
| `baton --cli` | **Always** launch CLI front end (§8), regardless of cwd |
| Auto-suppress UI (even at projects root) if **any** of: `CI=true` / `TF_BUILD` / `GITHUB_ACTIONS` / non-interactive (`[Console]::IsInputRedirected` or no TTY), `$env:BATON_NO_UI=1`, or `$env:BATON_UI=0` | Fall back to help (exit 0). Message optional one-line on stderr only when `BATON_DEBUG=1` |

**Projects-root equality:** resolve cwd and `Get-ProjectHomeRoot` to full paths (case-insensitive on Windows) and compare. Not "under" the root — **exactly** the root. Sitting inside `AtomicForge` still gets help on bare `baton` (you already know which project you are in; use verbs or `baton run …`).

**Why B3 over B2:** the operator's muscle memory ("from the dev folder, type `baton`") is real, and Layer-1 command center already framed that home base. Always-UI breaks the CLI-first control-plane doctrine for every non-human caller. Context-sensitive + explicit verbs is the smallest change that honors both.

**Assumption (flagged):** agents that invoke bare `baton` from the projects root expecting a verb list are rare; if that appears, they should set `BATON_NO_UI=1` or call `baton --help`.

---

## 5. Collision C — where the brief and run defaults live

### Options weighed

| Option | Pros | Cons |
|---|---|---|
| **C1. Single index at dev root** (`D:\dev\baton-projects.yaml`) | One file to edit | Does not travel with the repo; other clones/users get nothing; becomes a second registry next to `$BATON_HOME/projects/` |
| **C2. Repo-local `.baton/project.yaml`** | Matches `verification.json` precedent; git-tracked; works for other users | Operator must add a file per project (one-time) |
| **C3. Both + precedence** | Box can override budget without dirtying git | Two places to look; need a clear table |

### Decision: **C3 — repo-local is authoritative for brief + shared defaults; box-private may override machine-only knobs**

**Primary (repo, git-tracked):** `.baton/project.yaml`  
**Optional override (box-private):** `$BATON_HOME/projects/<id>/run-defaults.json`  
**Discovery fallback:** if no `project.yaml`, try well-known brief paths (see schema); never invent spend.

### Precedence (later wins only where noted)

| Field | Source order (first present wins unless noted) |
|---|---|
| `brief` path | 1) CLI `--brief` / `--goal-file` 2) `.baton/project.yaml` `brief` 3) box-private override `brief` 4) well-known fallbacks 5) error |
| `stakes`, `budget`, `max_tier` | 1) CLI flags 2) box-private override 3) `project.yaml` `defaults` 4) engine defaults |
| **`execute`** | **CLI only in v1** — see §6. Config may *document* intent but must not auto-arm labor |

Well-known brief fallbacks (relative to project folder), first existing file:

1. `.baton/brief.md`
2. `BRIEF.md`
3. `docs/brief.md`
4. path from `project.yaml` only if set earlier in the chain

If none: exit 2 with a message that names the checked paths and how to add `.baton/project.yaml`.

### Schema — `.baton/project.yaml`

```yaml
# .baton/project.yaml — repo-local Baton project front-door config
schema: 1

# Path to the default goal/brief text for `baton <slug>` / `baton run <slug>`.
# Relative paths are from the project folder root.
brief: docs/briefs/current.md

# Optional human label (does not replace registry blurb; display only).
# name: Atomic Forge

defaults:
  # Conductor economy knobs — passed through to `baton go` when set.
  stakes: standard          # low | standard | high (when go supports it)
  budget: null              # number or null = engine default
  max_tier: paid            # local | free | paid (or whatever go accepts today)

  # DOCUMENTATION ONLY in v1 — never auto-enables --execute (see §6).
  # Allowed values if present: false | omit. true is rejected at read time with exit 2.
  # execute: false

# Optional: extra argv always appended to the composed `go` invocation
# (after defaults, before user tail). Prefer empty.
# extra_args: []
```

**Validation:**

- `schema` must be `1`.
- `brief` if set must be a non-empty string; resolved path must exist at run time (not only at parse time) or exit 2.
- Unknown keys: ignore with a single stderr warning (forward-compatible), or strict mode later — **v1 = warn once**.
- `defaults.execute: true` → **hard error** in v1 ("execute cannot be enabled from project config; pass --execute on the CLI").

### Box-private override shape

`$BATON_HOME/projects/<id>/run-defaults.json`:

```json
{
  "schema": 1,
  "brief": null,
  "defaults": {
    "budget": 25,
    "max_tier": "free"
  }
}
```

Use for machine-specific spend caps. Must not set `execute: true`.

---

## 6. Safety — bare project name and `--execute` (where the brief is wrong)

### Operator literal

> equivalent to `baton go --project atomicforge --brief <brief> --execute`

### Assessment

**Implicit `--execute` from a bare project name is too dangerous to ship as the default in v1.** Reasons:

1. **Spend and labor.** `--execute` starts agentic worktrees, plan gate, acceptance, verification — real API cost and machine load. A typo (`baton atomcforge` → closest? no — wrong project if similar slug exists) or muscle-memory fat-finger should not burn quota.
2. **Precedent.** Verified labor already fail-closed without committed `.baton/verification.json`. The house pattern is **guard before spend**, not convenience before guard.
3. **CLI-first control plane.** Irreversible / expensive acts stay human-armed (system model L4). Bare name is a *selector*, not a detonation.
4. **Scripting.** `for p in …; baton $p` must not mean "execute every project."

### Decision: **compose `go` with brief + defaults; `--execute` is never implicit**

| Invocation | Effect |
|---|---|
| `baton <project>` | Resolve → load brief → compose **`baton go --project <slug> --goal-file <brief> [defaults…]`** **without** `--execute` (plan / dry Conductor path as engine defines today) |
| `baton <project> --execute` | Same + `--execute` (full labor). User tail after the project token is passed through to `go` |
| `baton run <project> [--execute] [go-flags…]` | Identical composition; required when slug shadows a verb |
| Non-interactive + `--execute` | Allowed (operator or CI deliberately armed) |
| Interactive + `--execute` | No extra confirm in v1 (the flag *is* the confirm). Optional later: `defaults.confirm_execute: true` for double confirm — **out of v1** |

**Print a one-line composition echo** before invoking (human mode only):

```text
baton: project 'atomicforge' → go --project atomicforge --goal-file D:\dev\AtomicForge\docs\briefs\current.md
baton: labor is OFF (pass --execute to spend). Plan-only / non-execute path.
```

With `--execute`:

```text
baton: project 'atomicforge' → go --project atomicforge --goal-file … --execute
baton: labor is ON.
```

**If the operator later insists bare name = full execute:** ship only behind an explicit box-level opt-in, e.g. `$BATON_HOME/config` `bare_project_execute: true` **and** interactive confirm Y/n, default N. Not in v1 defaults. Record as a product decision if flipped.

### Exit codes (project short path)

| Case | Exit | stderr gist |
|---|---|---|
| Unknown project (and not a verb) | **2** | `baton: no project matches '<token>'. Run 'baton project list'. Projects root: <path>.` + closest-slug hint if edit distance small (same idea as closest verb) |
| Project resolved, brief missing | **2** | Names paths checked + how to add `.baton/project.yaml` |
| `project.yaml` invalid / `execute: true` in config | **2** | Specific validation error |
| Shadowed slug used as bare name | **0/verb** | Verb runs (not an error). Hint only on project list |
| Composed `go` failure | **go's exit** | Passthrough |

---

## 7. Web UI launch (`ui` / `dashboard` / bare-at-root)

### Verb registry

Add to `scripts/verbs.yaml`:

```yaml
  - name: ui
    summary: Launch the Baton web front end (dashboard) on localhost.
    class: hybrid
    runner: fleet-ui.ps1
    json: true
  - name: dashboard
    summary: Alias for ui — launch the web front end.
    class: hybrid
    runner: fleet-ui.ps1
    json: true
  - name: run
    summary: Unambiguous project short path (brief + go composition).
    class: hybrid
    runner: fleet-run.ps1
    json: true
```

(`dashboard` may instead be a dispatcher alias without a second yaml row if the parser gains aliases later; two rows sharing a runner is fine for v1 and needs no parser change.)

### Runner responsibilities (`fleet-ui.ps1`)

1. Resolve dashboard app root (repo `dashboard/` via `Resolve-BatonScript` / install layout — same resolve story as other runners).
2. Ensure Python deps available (fail with install hint if not).
3. Bind **127.0.0.1** default port **8765** (matches `dashboard/main.py` today); override with `--port` / `$env:BATON_UI_PORT`.
4. If port busy: print clear error + how to pick another port; exit 1 (do not silently pick a random port in v1).
5. Start uvicorn / `python -m dashboard.main` in foreground (Ctrl+C stops). Optional `--detach` **out of v1**.
6. If interactive and `--no-open` not set: open default browser to `http://127.0.0.1:8765/` once.
7. `--json` on start: print `{ "url", "port", "pid" }` then continue or exit per flag — useful for agents; **v1 minimum:** print URL on stdout always.

### Bare `baton` at projects root

Dispatcher calls the same code path as `baton ui` (shared function, not a copy-paste of uvicorn flags).

---

## 8. CLI front end (`baton --cli`)

### What it is (concretely)

A **browser-free interactive control board**, not a second product:

1. **Project roster** — active / inactive / archived (call existing `fleet-project.ps1` / registry lib, prefer `baton project list --json` if present, else direct lib for v1 speed).
2. **Picker** — number or slug to select.
3. **Project card** — blurb, folder, brief path (resolved), last resume pointer if any, shadowed-verb warning.
4. **Actions menu:**
   - **Plan** → compose `baton go --project … --goal-file …` (no execute)
   - **Execute** → same + `--execute` (print warning, require typed `yes` in interactive mode)
   - **Open folder** → print path / `Start-Process` explorer (platform-appropriate) — optional
   - **Fleet doctor** → `baton fleet doctor` (or current fleet list entry)
   - **Launch web UI** → `baton ui`
   - **Quit**

### What it is not (v1)

- Not a full TUI framework (no blessed/textual dependency required).
- Not a live streaming run watcher (read `report.md` / tell user where the run dir is is enough).
- Not a reimplementation of Conductor.

### Implementation sketch

- `scripts/fleet-cli-board.ps1` (or `baton-cli-board.ps1`) invoked from dispatcher on `--cli`.
- Plain `Read-Host` menus + `Write-Host` tables — works on a headless SSH box with a TTY; if no TTY, exit 2: `baton: --cli requires an interactive terminal`.
- Every mutating / spending action is a **subprocess to `baton <verb> …`**, not a direct conductor-lib call from the menu (keeps the seam honest).

---

## 9. How the web UI drives the CLI (the seam)

### Standing rule

The GUI is a **control board over the CLI surface**. It must not grow a parallel Conductor, plan-gate, or verification implementation.

### Two seams (name them)

| Seam | Direction | Use |
|---|---|---|
| **Observe seam — artifact/file read** | Dashboard readers → `$BATON_HOME` files, run dirs, journals | Already exists; correct for **immutable artifacts** (JSONL, report.md). Folds that live only in PS should not be re-coded in Python |
| **Act seam — CLI process** | Dashboard (or board) → subprocess `baton <verb> …` (or `pwsh -File scripts/…` via the same resolve path) | **Any** command that plans, executes, gates, or mutates fleet state |
| **Act seam — broker queue** (existing Style-B design; not required for this v1) | Dashboard writes `$BATON_HOME/broker/queue/*.json`; broker runs engine | Long-running / session-free executes when Style-B ships |

**Live Fleet Ops design already chose:** fold semantics via PS CLI `--json` + TTL cache (`pscli.py` concept); raw run artifacts read as files. This front-door design **binds** that:

- New "Run this project" button (when added) → **must** call `baton run <slug> --execute …` or enqueue broker job that ends in the same `go` path.
- Forbidden: Python reimplementation of `Resolve-ProjectTarget` + conductor walk.

### v1 dashboard change for this work

**Minimal:** launchability only (`baton ui`). No requirement to rewrite existing readers in this slice.  
**Documented debt:** controls that shell `ollama`/`lms` directly are out-of-band utilities, not Conductor; leave them. Future "Go" controls use the Act seam above.

---

## 10. Cross-platform projects root

Replace hardcoded `D:\dev` as the sole default.

### Resolution order for `Get-ProjectHomeRoot`

1. `$env:BATON_PROJECTS_ROOT` if set and non-empty  
2. Optional box config: `$BATON_HOME/config.json` (or existing home config if one lands) key `projects_root`  
3. **Portable default:** `Join-Path $HOME 'dev'` (PowerShell: `[Environment]::GetFolderPath('UserProfile')` or `$HOME`)  
4. **Windows migration comfort (v1 only):** if step 3 path does not exist **and** `D:\dev` exists as a directory, use `D:\dev` and emit a **one-time** stderr note:  
   `baton: using D:\dev as projects root (legacy). Set BATON_PROJECTS_ROOT or create ~/dev to silence.`  
   Do not write state that forces D: forever.

Document in README / getting-started: set `BATON_PROJECTS_ROOT` on first install.

---

## 11. Dispatcher algorithm (normative)

Pseudo-flow for `scripts/baton.ps1` after loading verbs:

```
args = argv
if args empty:
  if Should-LaunchUiBare():  # TTY && !CI && !BATON_NO_UI && cwd == projects root
    invoke ui runner; exit its code
  else:
    Show-BatonHelp; exit 0

head, tail = args[0], args[1..]

if head in (--help|-h|help): help; exit 0
if head == --version: version; exit 0
if head == --cli: invoke cli-board; exit its code
if head == verbs: … existing …

if head matches verb in verbs.yaml:
  dispatch verb with tail; exit runner code

# project short path
resolved = Resolve-ProjectTarget -Slug head
if resolved.status == 'resolved':
  # If head was a verb we never get here.
  invoke project composition (fleet-run.ps1 or inline) with project=head, tail passthrough
  exit that code

# unknown
hint = closest verb OR closest project slug
error "unknown verb or project 'head'"; suggest project list / --help
exit 2
```

**`baton run`** is a normal verb whose runner **requires** a project token as first of its args (or `--project`), then applies the same composition. That keeps unambiguous form inside the verb table.

---

## 12. Config file schemas (summary)

| File | Location | Tracked? | Purpose |
|---|---|---|---|
| `.baton/project.yaml` | project repo | yes | brief + shared defaults |
| `.baton/verification.json` | project repo | yes | existing execute oracle (unchanged) |
| `.baton/brief.md` | project repo | optional | well-known brief fallback |
| `$BATON_HOME/projects/<id>/…` | box | private | registry blurb/lifecycle (existing) + optional `run-defaults.json` |
| `$env:BATON_PROJECTS_ROOT` | env | n/a | dev root override |

---

## 13. v1 scope (couple of days)

Buildable without Style-B broker, without dashboard redesign, without new TUI deps.

| # | Item | Done when |
|---|---|---|
| 1 | Portable `Get-ProjectHomeRoot` + tests | Default is not Windows-only; env override still wins; legacy D:\dev fallback documented |
| 2 | `.baton/project.yaml` reader + validation (`schema: 1`, reject `execute: true`) | Unit tests hermetic |
| 3 | `baton run <project>` verb + composition to `fleet-go.ps1` | Plan path + `--execute` passthrough; echo composition |
| 4 | Bare `baton <project>` when not a verb → same as `run` | Resolution-order tests including shadow with a fixture verb name |
| 5 | `ui` + `dashboard` verbs → start dashboard on 127.0.0.1:8765 | Smoke: process listens; help still works |
| 6 | Bare `baton` context rule + CI/TTY suppress | Tests with mocked cwd / env |
| 7 | `baton --cli` minimal roster + plan/execute menus | Manual smoke on a box without browser |
| 8 | Unknown project exit 2 + message | Test |
| 9 | `project list` shadow annotation | Test with a temp projects root containing a folder named like a verb |
| 10 | Docs: COMMANDS.md / getting-started one section | Operator can discover the three entry points |

### Deliberately excluded (v1)

- Implicit `--execute` from bare project name (or from `project.yaml`)
- Style-B broker queue + cockpit submit
- Rewriting dashboard readers to all go through PS CLI (debt stays documented)
- Fancy TUI (textual/rich full-screen)
- Detached/background UI daemon + multi-instance manager
- Sigil form (`@project`)
- Auto-creating `.baton/project.yaml` on first run (scaffold can be a later `baton project init` flag)
- Remote UI / auth / non-localhost bind
- Changing Conductor, plan-gate, or verification semantics
- Renaming existing verbs to free up slug space

---

## 14. Testing plan (design-level)

- **Dispatcher unit/integration** (`test-baton-cli.ps1` extension):  
  - verb still wins over same-named project folder  
  - bare project composes expected argv (spy/stub `fleet-go`)  
  - unknown → exit 2  
  - bare args + CI env → help, no listen socket  
  - bare args + cwd=projects root + TTY mock → ui runner invoked  
- **Registry:** portable root resolution table  
- **project.yaml:** valid / missing brief / execute:true rejected  
- **No live LLM** in these tests

---

## 15. Assumptions (flagged)

1. **Phase-1 `baton` dispatcher is the real front door** (decouple design / PR #155 line) — this spec extends it; it does not reintroduce slash-only entry.
2. **`go` without `--execute` remains a useful "plan / prepare" path** and is safe enough as the bare-project default. If non-execute `go` ever becomes spendy, bare project must switch to **card-only** (print composition, require an explicit verb).
3. **Operator accepts one file per repo** (`.baton/project.yaml` or a well-known brief path) rather than a single dev-root index.
4. **Localhost UI without auth** remains acceptable (existing dashboard posture).
5. **Exact path equality** for "at projects root" is enough; nested "monorepo root that isn't the scan root" is out of scope.
6. **Closest-slug hints** reuse the same edit-distance helper as verbs (or a shared function).

---

## 16. Where this might be wrong (design critique)

1. **Implicit execute** — Operator asked for full equivalence including `--execute`. This spec **refuses** that as the default. If the daily habit is truly "from D:\dev, type the name, walk away," the missing piece is not bare-name execute; it is a **named, visible arming** (`baton run x --execute` or board "Execute" with typed `yes`). Flipping bare name to execute later is a one-line policy change + tests — safer to start closed.
2. **Context-sensitive bare `baton`** — Some operators will still type `baton` inside a project and expect UI. Mitigation: `baton ui` is always one word away; docs put it in the getting-started three-liner.
3. **Verbs-win** — A project literally named `project` or `go` is awkward forever via bare name. Unambiguous `run` is mandatory; naming guidance in docs: avoid verb slugs.
4. **Dual config (repo + box)** — Two sources can confuse; v1 should print which brief path was chosen on every project short path.
5. **CLI board quality** — A Read-Host menu is utilitarian, not delightful. That matches NARROW reviews (no cockpit product ahead of finish-rate). If the board feels dead, invest in web UI act-seam buttons after broker, not a TUI rewrite.
6. **Dashboard still file-reads** — Strict "everything through CLI" would force every page through pwsh startup cost. Artifact reads stay; **folds and acts** go through CLI. That split is intentional, not a cop-out.
7. **`dashboard` and `ui` both as verbs** — Tiny namespace tax; worth it for discoverability.

---

## 17. Decisions summary (quick table)

| Collision / topic | Decision |
|---|---|
| A — name clash | **Verbs win**; `baton run <project>` long form; list marks shadows |
| B — bare `baton` | **UI only if** interactive + cwd == projects root + not CI/suppressed; else help; `--help` always help; `baton ui` always UI |
| C — brief home | **`.baton/project.yaml`** primary; box-private overrides for machine knobs; well-known brief fallbacks |
| Execute | **Never implicit**; config cannot set `execute: true` |
| CLI board | Interactive roster + plan/execute menus; acts shell out to `baton` |
| Web act seam | Subprocess CLI (or future broker queue); no parallel engine |
| verbs.yaml | Add `ui`, `dashboard`, `run` |
| Unknown project | Exit **2**, clear message + projects root path |
| Dev root default | `$HOME/dev`, env override, legacy `D:\dev` if exists |

---

## 18. Open questions for the operator (non-blocking for implementation plan)

These do not block writing a plan if the defaults above stand; answer only if you want a different product:

1. Confirm **refuse implicit `--execute`** (recommended) vs **box-level opt-in later**.
2. Prefer **`baton ui` only** (drop context-sensitive bare UI) if surprise still feels high after reading §4.
3. Is **`dashboard` as alias verb** wanted, or only `ui`?

---

## 19. Next step after approval

Hand to `writing-plans` → implementation plan under `docs/superpowers/plans/2026-08-02-dev-root-front-door.md` covering dispatcher changes, yaml schema, runners, and tests listed in §13. No code until the operator approves this spec (or amends the three collision decisions).
