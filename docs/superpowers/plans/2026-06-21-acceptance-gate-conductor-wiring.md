# Acceptance Gate → Conductor Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a successful Conductor (`/baton:go`) DAG walk, run the Sprint-7 Acceptance/Polish Gate over the finished artifact as an opt-in, advisory, fail-open acceptance phase that stamps the run accept/polish/reject before completing.

**Architecture:** A surgical extension to `Invoke-Conductor` plus two new pure helpers in `conductor-lib.ps1`. The gate call is injected via a `-Gater` seam (mirroring the existing `-Planner`/`-Spawner`/`-Dispatcher`), so tests never hit real reviewers. Verdict maps to terminal status; the ordered gate result is written as a 5th run artifact.

**Tech Stack:** PowerShell 7 (pwsh). Hermetic `Check`-harness tests (temp dirs, try/catch, seam stubs, child-process CLI). The gate is `Invoke-AcceptanceGate` from `gate-lib.ps1`.

## Global Constraints

- **Opt-in, default off:** the acceptance phase runs only when a gate target resolves (`-GateArtifact <text>` or `-GateDiff <range>`). No target → phase skipped → behavior byte-for-byte identical to today. (d-cg-1)
- **Advisory, no new interrupt:** the phase runs AFTER the walk; it never auto-runs a polish pass and never re-runs the walk. d052's two interrupts (budget cap + `reversible:false` destructive) stay the only two. (d-cg-2)
- **Verdict → terminal status:** `accept` → `completed`; `polish` → `completed` (+ polish brief + a `gate` event); `reject` → new terminal status **`rejected`** (+ findings/brief). Reject rolls nothing back. (d-cg-3)
- **Fail-open:** gate throws / zero reviewers / no verdict → log a `gate` warn event, status stays `completed`. A broken gate never fails a successful run. (d-cg-4)
- **Seamed + 5th artifact:** `-Gater` injectable; ordered result written to `acceptance.json` alongside `plan.json`/`events.jsonl`/`decisions.jsonl`/`report.md`; report gains `## Acceptance`. (d-cg-5)
- **Gate result type:** `Invoke-AcceptanceGate` returns an `[ordered]` dictionary (`@{verdict;reason;counts=@{critical;important;minor};findings;polish_brief;reviews;unparsed}`); test stubs return a plain `@{}`. Any param/local holding it MUST be **untyped** (not `[hashtable]`) so both an `OrderedDictionary` and a `Hashtable` bind.
- **PowerShell traps:** never name a param/local `$args`/`$input`/`$event`/`$matches`/`$host`; wrap function calls in parentheses inside comparisons. Existing engine code uses `$EventObj` (not `$Event`) — follow it.
- **Version:** plugin `1.4.0-rc.1 → 1.4.0-rc.2`.

---

### Task 1: Pure helpers — `Resolve-GateArtifact` + `Format-AcceptanceSection`

**Files:**
- Modify: `scripts/conductor-lib.ps1` (add two functions after `Format-RunReport`, ~line 196)
- Modify (test): `scripts/test-conductor-lib.ps1` (append a block before the final summary at ~line 166)

**Interfaces:**
- Consumes: `git` on PATH (for the `-Diff` path).
- Produces:
  - `Resolve-GateArtifact([string]$Artifact, [string]$Diff) -> [string]` — literal `$Artifact` if non-empty; else `git diff $Diff` stdout (joined with newlines) when `$Diff` non-empty and git exits 0; else `''` (git failure → `''`, fail-open).
  - `Format-AcceptanceSection($Gate) -> [string]` — the `## Acceptance` markdown block (verdict, reason, counts; polish brief appended only when verdict ≠ `accept`). `$Gate` is untyped (accepts ordered dict or hashtable).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, insert this block immediately BEFORE the final summary block (the line `    Write-Host ""` followed by `    if ($script:fail -gt 0)` near line 166):

```powershell
    # ---- d058: acceptance-phase pure helpers ----
    Check 'T60 Resolve-GateArtifact returns literal artifact' ((Resolve-GateArtifact -Artifact 'the diff text') -eq 'the diff text')
    Check 'T61 Resolve-GateArtifact empty when neither given' ((Resolve-GateArtifact) -eq '')
    Check 'T62 Resolve-GateArtifact bogus diff range -> empty (fail-open)' ((Resolve-GateArtifact -Diff 'no-such-ref-zzz..also-no-ref-zzz') -eq '')
    $acc = Format-AcceptanceSection -Gate @{ verdict='polish'; reason='1 important finding'; counts=@{critical=0;important=1;minor=2}; polish_brief='[important][api] fix the thing' }
    Check 'T63 acceptance section shows verdict + counts' (($acc -match '## Acceptance') -and ($acc -match 'polish') -and ($acc -match '1 important'))
    Check 'T64 polish brief present when not accept' ($acc -match 'fix the thing')
    $accA = Format-AcceptanceSection -Gate @{ verdict='accept'; reason='no blocking findings'; counts=@{critical=0;important=0;minor=0}; polish_brief='No polish needed' }
    Check 'T65 accept omits the polish brief block' ($accA -notmatch '### Polish brief')
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: FAIL/ERROR — `Resolve-GateArtifact` / `Format-AcceptanceSection` not defined.

- [ ] **Step 3: Implement the two helpers**

In `scripts/conductor-lib.ps1`, immediately after the `Format-RunReport` function (it ends with its closing `}` near line 196), add:

```powershell
function Resolve-GateArtifact {
    <# The artifact text to gate: literal -Artifact wins; else `git diff <range>` for
       -Diff; else ''. A git failure returns '' (fail-open -> the phase no-ops). #>
    param([string]$Artifact, [string]$Diff)
    if (-not [string]::IsNullOrWhiteSpace($Artifact)) { return $Artifact }
    if (-not [string]::IsNullOrWhiteSpace($Diff)) {
        try {
            $out = & git diff $Diff 2>$null
            if ($LASTEXITCODE -ne 0) { return '' }
            return (@($out) -join "`n")
        } catch { return '' }
    }
    return ''
}

function Format-AcceptanceSection {
    <# Render the `## Acceptance` markdown block from a gate result (ordered or hashtable).
       Polish brief only when verdict != accept. #>
    param([Parameter(Mandatory)]$Gate)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Acceptance')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Verdict:** $($Gate.verdict)")
    if ($Gate.reason) { [void]$sb.AppendLine("**Reason:** $($Gate.reason)") }
    $c = $Gate.counts
    if ($c) { [void]$sb.AppendLine("**Findings:** $($c.critical) critical, $($c.important) important, $($c.minor) minor") }
    if (($Gate.verdict -ne 'accept') -and $Gate.polish_brief) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Polish brief')
        [void]$sb.AppendLine([string]$Gate.polish_brief)
    }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: PASS — T60–T65 pass; existing T1–T59 still pass; `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): pure gate-artifact resolver + acceptance report section (d058)"
```

---

### Task 2: Acceptance phase in `Invoke-Conductor` + `Complete-Run -Gate`

**Files:**
- Modify: `scripts/conductor-lib.ps1` (dot-source ~line 14; `Complete-Run` ~line 291-304; `Invoke-Conductor` params ~line 310-321 and its final `return` ~line 375)
- Modify (test): `scripts/test-conductor-lib.ps1` (append a seamed block before the final summary)

**Interfaces:**
- Consumes: `Resolve-GateArtifact`, `Format-AcceptanceSection` (Task 1); `Invoke-AcceptanceGate` (from `gate-lib.ps1`); `New-RunEvent`/`Add-RunEvent` (existing).
- Produces: `Invoke-Conductor` accepts `-GateArtifact [string]`, `-GateDiff [string]`, `-Gater [scriptblock]` (signature `{ param($artifact, $goal) }` → a gate result with a `.verdict`). `Complete-Run` accepts `-Gate` (untyped); when present it writes `acceptance.json` and appends `## Acceptance` to the report, and returns `acceptance` in its result hashtable. Terminal status is `completed` (accept/polish) or `rejected` (reject).

- [ ] **Step 1: Write the failing seamed tests**

In `scripts/test-conductor-lib.ps1`, insert this block immediately after the Task 1 block you added (still before the final summary):

```powershell
    # ---- d058: acceptance phase (seamed -Gater) ----
    $gtHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-gate-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $gtHome | Out-Null
    $gPlanner = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( [pscustomobject]@{ id='t1'; desc='do t1'; command='x'; capability='reasoning'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true } ) } }
    $gSpawner = { param($task) @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }

    # no gate target -> completed, no acceptance.json
    $rn = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-none') -Planner $gPlanner -Spawner $gSpawner
    Check 'T66 no gate target -> completed' ($rn.status -eq 'completed')
    Check 'T67 no gate target -> no acceptance.json' (-not (Test-Path (Join-Path $gtHome 'r-none/acceptance.json')))

    # accept -> completed + acceptance.json + ## Acceptance in report
    $gaterAccept = { param($art,$goal) @{ verdict='accept'; reason='clean'; counts=@{critical=0;important=0;minor=1}; polish_brief='No polish needed'; findings=@(); reviews=@(); unparsed=@() } }
    $ra = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-accept') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'finished work' -Gater $gaterAccept
    Check 'T68 accept verdict -> completed' ($ra.status -eq 'completed')
    Check 'T69 accept writes acceptance.json' (Test-Path (Join-Path $gtHome 'r-accept/acceptance.json'))
    Check 'T70 report has ## Acceptance' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-accept/report.md') -Raw) -match '## Acceptance')

    # polish -> completed + brief in report + gate event
    $gaterPolish = { param($art,$goal) @{ verdict='polish'; reason='1 important'; counts=@{critical=0;important=1;minor=0}; polish_brief='[important][x] do better'; findings=@(); reviews=@(); unparsed=@() } }
    $rp = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-polish') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterPolish
    Check 'T71 polish verdict -> completed' ($rp.status -eq 'completed')
    Check 'T72 polish brief in report' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-polish/report.md') -Raw) -match 'do better')
    Check 'T73 gate event logged' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-polish/events.jsonl') -Raw) -match '"kind":"gate"')

    # reject -> rejected status
    $gaterReject = { param($art,$goal) @{ verdict='reject'; reason='1 critical'; counts=@{critical=1;important=0;minor=0}; polish_brief='[critical][x] broken'; findings=@(); reviews=@(); unparsed=@() } }
    $rr = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-reject') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterReject
    Check 'T74 reject verdict -> rejected status' ($rr.status -eq 'rejected')

    # gate throws -> fail-open completed + warn event
    $gaterThrow = { param($art,$goal) throw 'reviewer exploded' }
    $rt = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-throw') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterThrow
    Check 'T75 gate throw -> completed (fail-open)' ($rt.status -eq 'completed')
    Check 'T76 gate throw logs warn event' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-throw/events.jsonl') -Raw) -match 'acceptance gate failed')

    Remove-Item -Recurse -Force $gtHome -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: FAIL — `Invoke-Conductor` has no `-GateArtifact`/`-Gater` params (T68+ fail; the no-target T66/T67 may pass already).

- [ ] **Step 3a: Dot-source `gate-lib.ps1`**

In `scripts/conductor-lib.ps1`, after the existing `. "$PSScriptRoot/routing-lib.ps1"` line (line 14), add:

```powershell
. "$PSScriptRoot/gate-lib.ps1"   # Invoke-AcceptanceGate for the acceptance phase (d058)
```

- [ ] **Step 3b: Add the `-Gate` parameter to `Complete-Run`**

In `scripts/conductor-lib.ps1`, replace the entire `Complete-Run` function (lines ~291-304) with:

```powershell
function Complete-Run {
    <# Render report.md (+ optional ## Acceptance) and return the terminal status hashtable.
       -Gate (untyped: ordered dict or hashtable) writes acceptance.json + appends the section. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = '',
        $Gate = $null
    )
    $report = Format-RunReport -Plan $Plan -Decisions @($Decisions) -Spend $Spend -Status $Status -PendingTaskId $PendingTaskId
    if ($Gate) {
        $report = $report + "`n`n" + (Format-AcceptanceSection -Gate $Gate)
        ($Gate | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance.json') -Encoding utf8NoBOM
    }
    Set-Content -LiteralPath (Join-Path $RunDir 'report.md') -Value $report -Encoding utf8NoBOM
    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report; acceptance = $Gate }
}
```

- [ ] **Step 3c: Add the gate params to `Invoke-Conductor`**

In `scripts/conductor-lib.ps1`, in the `Invoke-Conductor` param block (lines ~310-321), add three params after `[scriptblock]$Dispatcher` (keep the existing ones):

```powershell
        [scriptblock]$Dispatcher,
        [string]$GateArtifact,
        [string]$GateDiff,
        [scriptblock]$Gater
```

- [ ] **Step 3d: Replace the final `return` with the acceptance phase**

In `scripts/conductor-lib.ps1`, the `Invoke-Conductor` walk ends with this single line (line ~375):

```powershell
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'completed')
```

Replace that one line with:

```powershell
    # 4. Acceptance phase (d058): opt-in, advisory, fail-open. Runs only after a
    #    successful walk and only when a gate target resolves.
    $gate = $null
    $finalStatus = 'completed'
    $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
    if (-not [string]::IsNullOrWhiteSpace($art)) {
        $gateErr = $null
        try {
            $gate = if ($Gater) { & $Gater $art $plan.goal }
                    else { Invoke-AcceptanceGate -Artifact $art -Task $plan.goal -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath }
        } catch { $gate = $null; $gateErr = $_.Exception.Message }
        if ($null -eq $gate -or -not $gate.verdict) {
            $msg = if ($gateErr) { "acceptance gate failed: $gateErr" } else { 'acceptance gate produced no verdict (fail-open)' }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message $msg)
            $gate = $null
        } else {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Message "acceptance verdict: $($gate.verdict) — $($gate.reason)")
            if ($gate.verdict -eq 'reject') { $finalStatus = 'rejected' }
        }
    }
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: PASS — T66–T76 pass; existing T1–T59 + Task-1 T60–T65 still pass; `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): opt-in advisory acceptance phase wired to the gate (d058)"
```

---

### Task 3: CLI flags + test seam + command doc + plugin bump

**Files:**
- Modify: `scripts/fleet-go.ps1` (param block ~line 10-18; `$go` assembly ~line 27-37)
- Modify: `commands/go.md` (argument-hint, engine snippet, status list, artifacts list)
- Modify (test): `scripts/test-conductor-lib.ps1` (extend the CLI section with a gate child-process check)
- Modify: `.claude-plugin/plugin.json` (version)

**Interfaces:**
- Consumes: `Invoke-Conductor -GateArtifact/-GateDiff/-Gater` (Task 2).
- Produces: `fleet-go.ps1` accepts `-GateArtifact`/`-GateDiff` and honors a `BATON_GO_TEST_GATE` env seam (its value is the canned verdict string) for hermetic CLI tests.

- [ ] **Step 1: Write the failing CLI test**

In `scripts/test-conductor-lib.ps1`, in the existing "Task 6: CLI child-process" section, immediately AFTER the line `Check 'T59 CLI wrote report.md' (...)` and BEFORE the `Remove-Item Env:\BATON_HOME, ...` cleanup line, add:

```powershell
    # d058: CLI acceptance phase via the BATON_GO_TEST_GATE seam (reject -> rejected)
    $env:BATON_HOME = $cliHome
    $env:BATON_GO_TEST_PLAN = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_SPAWN = '1'
    $env:BATON_GO_TEST_GATE = 'reject'
    $outG = & pwsh -NoProfile -File $cli -Goal 'convert pdfs' -GateArtifact 'finished work' -Json 2>&1 | Out-String
    Check 'T60c CLI gate reject -> rejected status' ($outG -match 'rejected')
    Remove-Item Env:\BATON_GO_TEST_GATE -ErrorAction SilentlyContinue
```

(Note: this reuses `$cli`/`$cliHome` from the existing CLI section; keep it before that section's `Remove-Item` cleanup. The check id `T60c` avoids colliding with Task 1's `T60`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: FAIL — `fleet-go.ps1` has no `-GateArtifact` param / no `BATON_GO_TEST_GATE` seam, so the run completes instead of `rejected`.

- [ ] **Step 3a: Add the CLI params**

In `scripts/fleet-go.ps1`, in the `param(...)` block, add two params after `[switch]$Json` (before `[ValidateSet(...)]$MaxCostTier`):

```powershell
    [switch]$Json,
    [string]$GateArtifact,
    [string]$GateDiff,
```

- [ ] **Step 3b: Thread the params + the test seam into `$go`**

In `scripts/fleet-go.ps1`, after the existing block that wires `BATON_GO_TEST_SPAWN` (ends ~line 37, before `$result = Invoke-Conductor @go`), add:

```powershell
if ($PSBoundParameters.ContainsKey('GateArtifact')) { $go['GateArtifact'] = $GateArtifact }
if ($PSBoundParameters.ContainsKey('GateDiff')) { $go['GateDiff'] = $GateDiff }
# Test seam: a canned gate verdict so the suite never calls real reviewers.
if ($env:BATON_GO_TEST_GATE) {
    $cannedVerdict = $env:BATON_GO_TEST_GATE
    $go['Gater'] = { param($art, $goal) @{ verdict = $cannedVerdict; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() } }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: PASS — `ALL CHECKS PASS` (incl. T60c).

- [ ] **Step 5: Update `commands/go.md`**

Make these four edits in `commands/go.md`:

1. **Frontmatter `argument-hint`** (line 3) — replace with:
   ```
   argument-hint: "<what you want done>" [--budget <n>] [--max-tier local|free|paid] [--gate-artifact <text> | --gate-diff <range>]
   ```

2. **Frontmatter `description`** (line 2) — change the artifacts parenthetical `(plan.json / events.jsonl / decisions.jsonl / report.md)` to `(plan.json / events.jsonl / decisions.jsonl / report.md / acceptance.json)`.

3. **Engine snippet** (the comment after the `pwsh -File ...` line, ~line 20) — append a line:
   ```powershell
   # add -GateArtifact "<text>" or -GateDiff "<range>" to gate the finished work (accept/polish/reject)
   ```

4. **Status list** (step 4, ~line 36) — add this bullet after the `failed` bullet:
   ```markdown
   - `rejected` → the optional acceptance gate reviewed the finished work and rejected it.
     Show the `## Acceptance` section of `report.md` (verdict, findings, polish brief); the
     work already ran — this is an advisory quality verdict, not a rollback.
   ```

- [ ] **Step 6: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.4.0-rc.1",` to `"version": "1.4.0-rc.2",`.

- [ ] **Step 7: Run the full conductor suite + bootstrap**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL CHECKS PASS`.
Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: exit 0 (conductor-lib.ps1 + fleet-go.ps1 already in the manifest; no manifest change needed).

- [ ] **Step 8: Commit**

```bash
git add scripts/fleet-go.ps1 commands/go.md scripts/test-conductor-lib.ps1 .claude-plugin/plugin.json
git commit -m "feat(conductor): /baton:go --gate-artifact/--gate-diff + plugin 1.4.0-rc.2 (d058)"
```

---

## Notes for the final whole-branch review

- Confirm the **no-gate-target** path is byte-for-byte unchanged (status `completed`, the original four artifacts, no `acceptance.json`) — this is the common path and must not regress.
- Confirm the phase adds **no new mid-walk interrupt**: budget + destructive remain the only two, and the gate runs strictly after a successful walk.
- Confirm fail-open: a throwing gater and a no-verdict result both leave status `completed` with a `gate` warn event.
- Confirm the `$Gate` handling is **untyped** end-to-end (ordered dict from the real `Invoke-AcceptanceGate` must bind to `Complete-Run -Gate` and serialize to `acceptance.json`).
- Box-private unchanged (the reviewer pair lives only in live `~/.baton/fleet.yaml`).
- Tracked follow-ups (do not implement): task-output bus + sequenceable `gate` task; budget-gating the gate's reviewer spend; auto-polish loop; and the separate quality-adjusted **effective-cost** metric brainstorm (paper-informed).
```
