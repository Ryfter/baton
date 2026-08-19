# Local Front Door Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bare `baton` start a conversation on a provider that cannot be exhausted, turn a long brief into a confirmed job, and fire the existing `baton go --execute` — so Baton stays usable with Claude at 0%.

**Architecture:** One new library, `scripts/converse-lib.ps1`, holding the loop, the two call shapes, and the confirm gate. Device identity gets its own library, `scripts/lms-device-lib.ps1`, because everything else depends on knowing which box a model is on. `scripts/routing-lib.ps1` gains the `converse` preference rule; `scripts/baton.ps1` routes a bare invocation to the loop. No change to `conductor-lib.ps1`, `fleet-executor-lib.ps1`, or any existing verb.

**Tech Stack:** PowerShell 7, LM Studio OpenAI-compatible API (`/v1/chat/completions`), `lms` CLI for device identity and placement.

**Spec:** `docs/superpowers/specs/2026-08-18-local-front-door-design.md`
**Decisions:** `baton-d119`, `baton-d120`, `baton-d121`

## Global Constraints

- Agents must **NEVER** edit `~/.baton/fleet.yaml`. Config changes are listed as operator actions only.
- Every shell command argument stays under **965 bytes**. Prompts go via file or request body, never argv.
- Reachability is **pre-checked**, never discovered by timeout. A 180s stall in a chat loop is fatal.
- The loop reads from an **injectable `InputSource`**, never `Read-Host` directly.
- A **`paid` provider is never auto-selected** for `converse`. Opt-in only.
- Baton **never dispatches a bare LM Studio model key** — always a loaded identifier.
- Do not build: TTS, speech-to-text, a web page, a Buzz seat, Wraith2 support, or anything that merges.
- Tests are bespoke `Check '<name>' (<bool>)` suites in `scripts/test-*.ps1`, registered in `scripts/test-all.ps1`. `Check` asserts the expression is **true** — express negative cases as `Check 'work-box-refused' ($threw)`.

---

### Task 1: Device identity from LM Link

Everything downstream needs to know which box serves a model. The REST API cannot tell you — verified: both `/v1/models` and the native `/api/v1/models` omit the device. Only `lms ls --json` carries `deviceIdentifier`.

**Files:**
- Create: `scripts/lms-device-lib.ps1`
- Create: `scripts/test-lms-device-lib.ps1`
- Modify: `scripts/test-all.ps1` (register the suite)

**Interfaces:**
- Consumes: `lms ls --json` stdout, `lms link status` stdout
- Produces: `Get-LmsModelInventory [-Json <string>]` → array of `@{ model_key; device_id; device_name; size_bytes; max_context }`; `-Json` injects captured output so tests never shell out
- Produces: `Get-LmsDeviceMap [-StatusText <string>]` → hashtable `device_id → device_name` (`$null` id means the local box)
- Produces: `Test-LmsModelAmbiguous -ModelKey <string> -Inventory <array>` → `$true` when the key exists on more than one device
- Produces: `Get-LmsLoadedIdentifier -Identifier <string> [-PsText <string>]` → the loaded record or `$null`

- [ ] **Step 1: Write the first failing behavior test** — `Check 'inventory parses deviceIdentifier' (...)` against a captured `lms ls --json` fixture with one local and one remote model.
- [ ] **Step 2: Implement `Get-LmsModelInventory`** against the fixture. Treat `deviceIdentifier: null` as the local box.
- [ ] **Step 3: Test + implement `Get-LmsDeviceMap`** parsing the `lms link status` block form (`- <name>` / `Identifier: <hash>`).
- [ ] **Step 4: Test + implement `Test-LmsModelAmbiguous`.** Fixture must include a key present on two devices — this is the guard the whole design rests on.
- [ ] **Step 5: Test + implement `Get-LmsLoadedIdentifier`** from an `lms ps` fixture, including the not-loaded case.
- [ ] **Step 6: Register the suite** in `test-all.ps1`; confirm the full run still passes.

---

### Task 2: Placement and reachability

**Files:**
- Modify: `scripts/lms-device-lib.ps1`
- Modify: `scripts/test-lms-device-lib.ps1`

**Interfaces:**
- Produces: `Resolve-BatonModelPlacement -ModelKey <string> -Inventory <array> [-ExcludeDevices <string[]>] [-AllowWorkBox]` → `@{ ok; device_id; device_name; reason }`. Refuses when the key is ambiguous and no device was pinned; refuses when the only host is excluded.
- Produces: `Assert-BatonModelLoaded -Identifier <string> -ModelKey <string> [-Loader <scriptblock>] [-PsText <string>]` → `@{ ok; loaded; identifier; reason }`. `-Loader` is the injection seam; the real path shells `lms load <key> --identifier <id> --ttl <n>`.
- Produces: `Test-BatonMouthReachable -Identifier <string> [-PsText <string>] [-StatusText <string>]` → `@{ ok; reason }` in well under a second.

- [ ] **Step 1: Write the failing test** — `Check 'ambiguous key refuses dispatch' ($result.ok -eq $false)`.
- [ ] **Step 2: Implement `Resolve-BatonModelPlacement`.** Default `-ExcludeDevices` to the work box; `-AllowWorkBox` is the only way past it, and the reason string must say so.
- [ ] **Step 3: Test + implement `Assert-BatonModelLoaded`** with an injected `-Loader`. No test may shell out to `lms`.
- [ ] **Step 4: Test + implement `Test-BatonMouthReachable`** — loaded, not-loaded, and device-disconnected cases.
- [ ] **Step 5: Test the exclusion is on by default** — `Check 'work box excluded unless opted in' (...)`. This is the data-placement guard; it must fail closed.

---

### Task 3: The `converse` capability

**Files:**
- Modify: `scripts/routing-lib.ps1` (beside `Select-Capability`)
- Modify: `scripts/test-routing-lib.ps1`

**Interfaces:**
- Produces: `Select-ConverseProvider [-AllowPaid] [-FleetPath] [-ToolsPath]` → ranked candidates claiming `converse`, `local`/`free` first. **Without `-AllowPaid`, `paid` rows are filtered out entirely** — not merely ranked last.
- Consumes: existing `Select-Capability -Capability 'converse'` for the base roster.

- [ ] **Step 1: Write the failing test** — a fixture fleet where the only `converse` claimant is `paid`; `Check 'paid never auto-selected' ($candidates.Count -eq 0)`.
- [ ] **Step 2: Implement `Select-ConverseProvider`** as a filter over `Select-Capability`. Do not fork the ranking logic.
- [ ] **Step 3: Test `-AllowPaid` admits the paid row** and that the choice is reported, not silent.
- [ ] **Step 4: Test the empty-roster case** returns an honest failure — never a silent fallback to any other capability.

---

### Task 4: Talk and extract call shapes

**Files:**
- Create: `scripts/converse-lib.ps1`
- Create: `scripts/test-converse-lib.ps1`
- Modify: `scripts/test-all.ps1`

**Interfaces:**
- Produces: `Invoke-ConverseTalk -History <array> -Identifier <string> [-Dispatcher <scriptblock>]` → `@{ ok; text }`. Full history, prose out.
- Produces: `Invoke-ConverseExtract -Brief <string> -Identifier <string> [-Dispatcher <scriptblock>]` → `@{ ok; project; goal; stakes; raw }`. **No history. Reasoning off.** Strict JSON via `response_format` `json_schema`.
- Produces: `Invoke-ConverseIntent -Message <string> -Identifier <string> [-Dispatcher <scriptblock>]` → one of `chat|work|status|hold`, defaulting to `chat` when unparseable.

- [ ] **Step 1: Write the failing test** — `Check 'extract returns strict json' (...)` with an injected `-Dispatcher` returning a canned body. No live model in any test.
- [ ] **Step 2: Implement `Invoke-ConverseExtract`.** The request body must set reasoning off — `gemma-4-12b-qat` reports `reasoning.default: on`, and a thinking preamble breaking a strict-JSON parse is the June 2026 judge outage repeating.
- [ ] **Step 3: Test malformed JSON** — `Check 'malformed extract does not fabricate' ($r.ok -eq $false)`. It must ask again, never invent a job.
- [ ] **Step 4: Test + implement `Invoke-ConverseTalk`**, asserting full history is sent.
- [ ] **Step 5: Test + implement `Invoke-ConverseIntent`**, including the unparseable-defaults-to-chat case.

---

### Task 5: The loop and the confirm gate

**Files:**
- Modify: `scripts/converse-lib.ps1`
- Modify: `scripts/test-converse-lib.ps1`

**Interfaces:**
- Produces: `Start-ConverseLoop -InputSource <scriptblock> [-OutputSink <scriptblock>] [-Dispatcher <scriptblock>] [-Firer <scriptblock>] [-Project <string>]` → exit code. `-InputSource` returns one line or `$null` to end; `-Firer` receives the confirmed job. All four are injection seams; **nothing calls `Read-Host`**.
- Produces: `Confirm-ConverseJob -Job <hashtable> -InputSource <scriptblock> -OutputSink <scriptblock>` → `$true`/`$false`. Renders `{project, goal, stakes}` before anything fires.
- Produces: `New-ConverseJobRecord -Job <hashtable> [-Root <path>]` → the job-record path under `$BATON_HOME/maestro/jobs/`, matching the 2026-08-15 front-door spec. Does not invent a parallel store.

- [ ] **Step 1: Write the failing test** — a scripted `-InputSource` of two lines; `Check 'loop terminates on null input' (...)`.
- [ ] **Step 2: Implement `Start-ConverseLoop`** wiring intent → extract → confirm → fire.
- [ ] **Step 3: Test the confirm gate blocks** — `Check 'declined job never fires' ($fired -eq $false)`. Nothing spends money or writes code without a yes.
- [ ] **Step 4: Test + implement `New-ConverseJobRecord`** into a temp root.
- [ ] **Step 5: Test degradation** — unreachable mouth falls to the next candidate and says so in one line; empty roster prints that `baton go --goal "…"` still works.

---

### Task 6: Bare `baton` starts the loop

**Files:**
- Modify: `scripts/baton.ps1` (dispatcher entry)
- Modify: `scripts/verbs.yaml` (document the change)
- Modify: `scripts/test-baton-dispatch.ps1`
- Modify: `docs/` — the verb-list behaviour change

**Interfaces:**
- Consumes: `$args.Count -eq 0`
- Produces: bare `baton` → `Start-ConverseLoop`; `baton --help` / `-h` / `baton verbs` → the verb list (previously bare `baton`)

- [ ] **Step 1: Write the failing test** — `Check 'bare baton starts loop' (...)` and `Check 'baton --help still lists verbs' (...)`.
- [ ] **Step 2: Grep for non-interactive callers of bare `baton`** before changing it — hooks, scripts, docs, `.claude/`. This is a breaking change; confirm nothing depends on the old output.
- [ ] **Step 3: Implement the dispatch change.** Unknown verb still exits 2; every existing verb is untouched.
- [ ] **Step 4: Run `scripts/test-all.ps1`** and confirm no regression beyond the known `test-heartbeat` failure (tracked in #193 / PR #194).

---

## Operator actions (Kevin — not the implementing agent)

These are `~/.baton/fleet.yaml` edits, which harnesses must never make:

- [ ] Add `converse` to the `capabilities` list of the chosen local row.
- [ ] `lms link set-preferred-device` as the global backstop against ambiguous keys.
- [ ] Decide whether `ITSCM-KRANK2` is ever permitted, and under what flag.

## Open questions

Carried from the draft, plus review findings:

1. **How is the paid opt-in expressed** — env var, `baton --allow-paid`, or a fleet.yaml field? Task 3 assumes a parameter; the persistent form is undecided.
2. **`lms` output stability.** `Get-LmsDeviceMap` parses human-readable `lms link status`; there is no `--json` for it. If LM Studio changes that format the parse breaks. Consider pinning fixtures and failing loud on unparseable input.
3. **`Invoke-Fleet-Cli` has `[int]$TimeoutS = 120` that demonstrably did not cap a 3,955-second `grok-cli` hang** (observed 2026-08-19). The loop must not inherit that path's timeout behaviour — worth its own issue.
4. **Mouth model choice is not settled by this plan.** `gemma-4-12b-qat` lives on droid.local *and* the work box, so it needs an explicit device pin. A Firefly-only key would avoid the ambiguity entirely.
