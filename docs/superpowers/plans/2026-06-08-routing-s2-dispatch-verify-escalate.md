# Routing Slice 2 — Auto-Dispatch + Verify/Escalate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the router dispatch the cheapest capable candidate for a capability+prompt, heuristically verify the output, escalate up the ranked ladder on failure, and journal every attempt — surfaced via `/route --run`.

**Architecture:** One new PowerShell library `scripts/routing-dispatch.ps1` (dot-sources `routing-lib.ps1`, which transitively loads `fleet-lib.ps1`). It adds four functions — `Invoke-Tool` (dispatch a `tools.yaml` cli entry), `Test-RoutingOutputHeuristic` (the default grader), `Write-RoutingJournalLine` (append a JSONL row), and `Invoke-RoutedCapability` (the dispatch→verify→escalate loop). `Select-Capability` (Slice 1) supplies the cost-ascending ladder; `Invoke-Fleet` (existing) dispatches fleet models. `/route` gains a `--run` action. Heuristic grading only; the `-Grader` scriptblock parameter is the seam Slice 3 fills.

**Tech Stack:** PowerShell 7+ (pwsh), the project's `Check($n,$c)` test harness, JSONL journal via `Add-Content -Encoding utf8NoBOM`.

**Spec:** `docs/superpowers/specs/2026-06-08-routing-s2-dispatch-verify-escalate-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/routing-dispatch.ps1` (create) | Dispatch + verify + escalate + journal. Dot-sources `routing-lib.ps1`. |
| `scripts/test-routing-dispatch.ps1` (create) | Unit tests for all four functions. |
| `commands/route.md` (modify) | Add the `--run "<prompt>"` action. |
| `scripts/bootstrap.ps1` (modify) | Deploy `routing-dispatch.ps1`. |
| `scripts/test-bootstrap.ps1` (modify) | Assert `routing-dispatch.ps1` deploys. |

Convention reminders: PS test harness `Check($n,$c)` increments `$script:fail`; temp fixtures + journal under `[System.IO.Path]::GetTempPath()`; try/finally cleanup; `exit 1`/`0`. `Invoke-Fleet` is called with `-NoJournal` (Slice 2 writes its own richer journal). The grader contract is `(Capability, Result) → @{passed; score; reason}`.

---

### Task 1: Library skeleton + heuristic grader

**Files:**
- Create: `scripts/routing-dispatch.ps1`
- Create: `scripts/test-routing-dispatch.ps1`

- [ ] **Step 1: Create the test file with harness + grader tests**

Create `scripts/test-routing-dispatch.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-dispatch.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-disp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ===== Task 1: heuristic grader =====
    $passRes = @{ stdout = 'some output'; exit_code = 0; duration_s = 1 }
    $emptyRes = @{ stdout = "   `n  "; exit_code = 0; duration_s = 1 }
    $crashRes = @{ stdout = 'partial'; exit_code = 1; duration_s = 1 }

    $g1 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $passRes
    Check 'grader passes non-empty/exit0' ($g1.passed -eq $true -and $g1.score -eq 1.0)

    $g2 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $emptyRes
    Check 'grader fails empty output'      ($g2.passed -eq $false -and $g2.reason -eq 'empty output')

    $g3 = Test-RoutingOutputHeuristic -Capability 'code-gen' -Result $crashRes
    Check 'grader fails non-zero exit'     ($g3.passed -eq $false -and $g3.reason -match 'exit 1')

    $jsonOk  = @{ stdout = '{"a":1}'; exit_code = 0; duration_s = 1 }
    $jsonBad = @{ stdout = 'not json'; exit_code = 0; duration_s = 1 }
    Check 'struct-extract valid JSON pass' ((Test-RoutingOutputHeuristic -Capability 'struct-extract' -Result $jsonOk).passed -eq $true)
    Check 'struct-extract bad JSON fail'   ((Test-RoutingOutputHeuristic -Capability 'struct-extract' -Result $jsonBad).reason -eq 'not valid JSON')

    $cmOk = @{ stdout = "fix: tighten parser`n`nbody"; exit_code = 0; duration_s = 1 }
    Check 'commit-msg subject pass'        ((Test-RoutingOutputHeuristic -Capability 'commit-msg' -Result $cmOk).passed -eq $true)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL — `routing-dispatch.ps1` does not exist yet (dot-source throws).

- [ ] **Step 3: Create the library with the header + grader**

Create `scripts/routing-dispatch.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing dispatcher (Slice 2). Dispatches the cheapest capable candidate
  for a capability, verifies its output with a heuristic grader, escalates up the
  ranked ladder on failure, and journals every attempt.
.DESCRIPTION
  Builds on Slice 1's Select-Capability. Heuristic grading only; the -Grader parameter
  on Invoke-RoutedCapability is the seam Slice 3 fills (LLM-judge + user ratings).
  See docs/superpowers/specs/2026-06-08-routing-s2-dispatch-verify-escalate-design.md.
#>

# routing-lib.ps1 gives Select-Capability/Read-Tools/Get-CostTierRank and dot-sources
# fleet-lib.ps1 (Invoke-Fleet, Invoke-Fleet-Cli) transitively.
. "$PSScriptRoot/routing-lib.ps1"

function Test-RoutingOutputHeuristic {
    <# Default grader. Deterministic and free. Contract: (Capability, Result) -> {passed, score, reason}.
       Result is a dispatch result hashtable {stdout, exit_code, ...}. Heuristic score is binary. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][hashtable]$Result
    )
    if ([int]$Result.exit_code -ne 0) {
        return @{ passed = $false; score = 0.0; reason = "exit $([int]$Result.exit_code)" }
    }
    $out = [string]$Result.stdout
    if ([string]::IsNullOrWhiteSpace($out)) {
        return @{ passed = $false; score = 0.0; reason = 'empty output' }
    }
    switch ($Capability) {
        'struct-extract' {
            try { $null = $out | ConvertFrom-Json -ErrorAction Stop }
            catch { return @{ passed = $false; score = 0.0; reason = 'not valid JSON' } }
        }
        'commit-msg' {
            $subject = $out -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($subject)) {
                return @{ passed = $false; score = 0.0; reason = 'no commit subject line' }
            }
        }
        default { }   # base gate already satisfied; non-empty output suffices (quality is Slice 3)
    }
    return @{ passed = $true; score = 1.0; reason = 'ok' }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: PASS (7 grader checks), `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(routing): Slice 2 grader (Test-RoutingOutputHeuristic) + skeleton"
```

---

### Task 2: Journal writer

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (add `Write-RoutingJournalLine`)
- Modify: `scripts/test-routing-dispatch.ps1` (add journal tests)

- [ ] **Step 1: Add the failing journal tests**

In `scripts/test-routing-dispatch.ps1`, insert this block inside the `try`, immediately after the Task 1 grader block (before the closing `}` of `try`):

```powershell
    # ===== Task 2: journal =====
    $journal = Join-Path $tmp 'routing-journal.jsonl'
    Write-RoutingJournalLine -Capability 'commit-msg' -Candidate 'git-commit-message' `
        -Source 'tools' -Kind 'cli' -CostTier 'local' -ExitCode 0 -DurationS 1 `
        -Passed $true -Score 1.0 -Reason 'ok' -JournalPath $journal `
        -Timestamp '2026-06-08T00:00:00.0000000-06:00'
    $jl = @(Get-Content $journal)
    Check 'journal writes one line'    ($jl.Count -eq 1)
    $obj = $jl[0] | ConvertFrom-Json
    Check 'journal capability field'   ($obj.capability -eq 'commit-msg')
    Check 'journal passed bool'        ($obj.passed -eq $true)
    Check 'journal score field'        ($obj.score -eq 1.0)
    Check 'journal ts injected'        ($obj.ts -eq '2026-06-08T00:00:00.0000000-06:00')
    Check 'journal reason field'       ($obj.reason -eq 'ok')

    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'gemini' `
        -Source 'fleet' -Kind 'cli' -CostTier 'free' -ExitCode 0 -DurationS 5 `
        -Passed $false -Score 0.0 -Reason 'empty output' -JournalPath $journal `
        -Timestamp '2026-06-08T00:00:01.0000000-06:00'
    Check 'journal appends second line' (@(Get-Content $journal).Count -eq 2)
```

- [ ] **Step 2: Run the test to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL — `Write-RoutingJournalLine` is not defined.

- [ ] **Step 3: Implement `Write-RoutingJournalLine`**

Append to `scripts/routing-dispatch.ps1` (after `Test-RoutingOutputHeuristic`):

```powershell
function Write-RoutingJournalLine {
    <# Append one compact JSON row (JSONL) per dispatch attempt. A logging fault warns
       and returns; it never crashes the dispatch loop. -Timestamp is injectable for tests. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Source, [string]$Kind, [string]$CostTier,
        [int]$ExitCode, [int]$DurationS,
        [bool]$Passed, [double]$Score, [string]$Reason,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp; capability = $Capability; candidate = $Candidate
        source = $Source; kind = $Kind; cost_tier = $CostTier
        exit_code = $ExitCode; duration_s = $DurationS
        passed = $Passed; score = $Score; reason = $Reason
    }
    try {
        $line = ($row | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $JournalPath -Value $line -Encoding utf8NoBOM
    } catch {
        Write-Warning "routing journal write failed: $($_.Exception.Message)"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: PASS (grader + 7 journal checks), `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(routing): Write-RoutingJournalLine (JSONL attempt log)"
```

---

### Task 3: Tool dispatcher (`Invoke-Tool`)

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (add `Invoke-Tool`)
- Modify: `scripts/test-routing-dispatch.ps1` (add dispatch tests)

- [ ] **Step 1: Add the failing dispatch tests**

In `scripts/test-routing-dispatch.ps1`, insert inside the `try`, after the Task 2 block. The fixtures use `pwsh` itself as a deterministic, cross-platform echo target (the command tokens contain no spaces, so the whitespace split is safe):

```powershell
    # ===== Task 3: Invoke-Tool =====
    $echoTool = @{ name='echo-tool'; kind='cli'; stdin=$true
                   command_template='pwsh -NoProfile -Command [Console]::In.ReadToEnd()' }
    $r1 = Invoke-Tool -Tool $echoTool -Prompt 'hello-stdin'
    Check 'Invoke-Tool stdin echoes prompt' ($r1.stdout -match 'hello-stdin' -and $r1.exit_code -eq 0)
    Check 'Invoke-Tool returns duration'    ($r1.ContainsKey('duration_s'))

    $argTool = @{ name='arg-tool'; kind='cli'; stdin=$false
                  command_template='pwsh -NoProfile -Command $args[0]' }
    $r2 = Invoke-Tool -Tool $argTool -Prompt 'arg-prompt'
    Check 'Invoke-Tool non-stdin passes arg' ($r2.stdout -match 'arg-prompt' -and $r2.exit_code -eq 0)

    $badTool = @{ name='bad'; kind='cli'; stdin=$false; command_template='no-such-exe-xyz-123' }
    $r3 = Invoke-Tool -Tool $badTool -Prompt 'x'
    Check 'Invoke-Tool missing exe -> exit -1' ($r3.exit_code -eq -1 -and $r3.stderr)
```

- [ ] **Step 2: Run the test to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL — `Invoke-Tool` is not defined.

- [ ] **Step 3: Implement `Invoke-Tool`**

Append to `scripts/routing-dispatch.ps1` (after `Write-RoutingJournalLine`):

```powershell
function Invoke-Tool {
    <# Dispatch a tools.yaml kind:cli entry. Pipe the prompt via stdin when stdin:true
       (robust path, immune to embedded quotes/$/backticks); otherwise pass it as the
       final positional arg. Returns @{ stdout; stderr; exit_code; duration_s }.
       -TimeoutS is accepted for signature parity with Invoke-Fleet-Cli (not enforced inline). #>
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$TimeoutS = 120
    )
    $cmd = [string]$Tool.command_template
    $tokens = $cmd -split '\s+' | Where-Object { $_ -ne '' }
    $exe = $tokens[0]
    $rest = @($tokens | Select-Object -Skip 1)
    $start = Get-Date
    try {
        if ($Tool.stdin -eq $true) {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmpFile -Value $Prompt -Encoding utf8NoBOM
                $out = (Get-Content -LiteralPath $tmpFile -Raw | & $exe @rest 2>&1 | Out-String)
            } finally {
                Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
            }
        } else {
            $out = (& $exe @rest $Prompt 2>&1 | Out-String)
        }
        $exit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: PASS (grader + journal + 4 Invoke-Tool checks), `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(routing): Invoke-Tool (cli tool dispatch via stdin/arg)"
```

---

### Task 4: The dispatch/verify/escalate loop (`Invoke-RoutedCapability`)

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (add `Invoke-RoutedCapability`)
- Modify: `scripts/test-routing-dispatch.ps1` (add loop tests + fixtures)

- [ ] **Step 1: Add the failing loop tests**

In `scripts/test-routing-dispatch.ps1`, insert inside the `try`, after the Task 3 block. This block writes its own `tools.yaml`/`fleet.yaml` fixtures and a fresh journal, and uses an injected `-Dispatcher` so no real model is called:

```powershell
    # ===== Task 4: Invoke-RoutedCapability =====
    $toolsYaml = @"
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
"@
    $toolsPath = Join-Path $tmp 'tools.yaml'
    Set-Content -Path $toolsPath -Value $toolsYaml -Encoding utf8

    $fleetYaml = @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: free-b
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'x "{{prompt}}"'
  - name: paid-c
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    $journal4 = Join-Path $tmp 'loop-journal.jsonl'
    $common4 = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal4 }

    # Dispatcher: only paid-c produces non-empty output -> escalates past local + free.
    $dispThird = {
        param($cand, $prompt)
        if ($cand.name -eq 'paid-c') { @{ stdout='WORKS'; stderr=''; exit_code=0; duration_s=1 } }
        else { @{ stdout=''; stderr=''; exit_code=0; duration_s=1 } }
    }
    $o1 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'do x' -Dispatcher $dispThird @common4
    Check 'escalates to 3rd candidate' ($o1.status -eq 'passed' -and $o1.winner -eq 'paid-c')
    Check 'walked all 3 attempts'      ($o1.attempts.Count -eq 3)
    Check 'first attempt failed'       ($o1.attempts[0].passed -eq $false)
    Check 'winning attempt passed'     ($o1.attempts[2].passed -eq $true)
    Check 'loop journaled 3 rows'      (@(Get-Content $journal4).Count -eq 3)

    # All candidates fail -> escalate-to-conductor.
    $dispFail = { param($cand,$prompt) @{ stdout=''; stderr=''; exit_code=0; duration_s=0 } }
    $o2 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispFail @common4
    Check 'all fail -> escalate'       ($o2.status -eq 'escalate-to-conductor')
    Check 'all candidates attempted'   ($o2.attempts.Count -eq 3)

    # Unknown capability -> no-candidate, no attempts.
    $o3 = Invoke-RoutedCapability -Capability 'nope-cap' -Prompt 'x' -Dispatcher $dispThird @common4
    Check 'unknown cap -> no-candidate' ($o3.status -eq 'no-candidate')
    Check 'no-candidate no attempts'    ($o3.attempts.Count -eq 0)

    # Cheapest dispatched first: when all pass, local-a wins on attempt 1.
    $dispAllPass = { param($cand,$prompt) @{ stdout='OK'; stderr=''; exit_code=0; duration_s=0 } }
    $o4 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAllPass @common4
    Check 'cheapest wins first'        ($o4.winner -eq 'local-a' -and $o4.attempts.Count -eq 1)

    # Grader seam: a custom grader that rejects everything overrides the passing dispatch.
    $rejectGrader = { param($Capability,$Result) @{ passed=$false; score=0.0; reason='custom-reject' } }
    $o5 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAllPass -Grader $rejectGrader @common4
    Check 'custom grader overrides'    ($o5.status -eq 'escalate-to-conductor' -and $o5.attempts[0].reason -eq 'custom-reject')

    # Non-cli tool kind is skipped (pdf-extract -> docling is kind:python); only candidate -> escalate.
    $o6 = Invoke-RoutedCapability -Capability 'pdf-extract' -Prompt 'x' @common4
    Check 'non-cli kind skipped'       ($o6.attempts.Count -eq 1 -and $o6.attempts[0].reason -match 'unsupported kind')
    Check 'only non-cli -> escalate'   ($o6.status -eq 'escalate-to-conductor')
```

- [ ] **Step 2: Run the test to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL — `Invoke-RoutedCapability` is not defined.

- [ ] **Step 3: Implement `Invoke-RoutedCapability`**

Append to `scripts/routing-dispatch.ps1` (after `Invoke-Tool`):

```powershell
function Invoke-RoutedCapability {
    <# Dispatch -> verify -> escalate over Select-Capability's cost-ascending candidates.
       The first candidate whose output passes the grader wins. If all fail, the outcome
       is 'escalate-to-conductor' (PowerShell cannot invoke Claude; Claude is the orchestrator).
       -Grader is the seam Slice 3 fills (default = heuristic). -Dispatcher is test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [scriptblock]$Grader,
        [scriptblock]$Dispatcher,
        [string]$ToolsPath = (Join-Path $HOME '.claude/tools.yaml'),
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = Select-Capability @sel

    $attempts = [System.Collections.ArrayList]@()
    if (-not $candidates -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; winner=$null; result=$null; attempts=@() }
    }

    foreach ($c in $candidates) {
        # Slice 2 dispatches only cli tools + fleet models. Skip other tool kinds.
        if ($c.source -eq 'tools' -and $c.kind -ne 'cli') {
            $reason = "unsupported kind $($c.kind) in Slice 2"
            [void]$attempts.Add([pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0 })
            Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath
            continue
        }

        # Dispatch (injected for tests, else real).
        try {
            if ($Dispatcher) {
                $result = & $Dispatcher $c $Prompt
            } elseif ($c.source -eq 'tools') {
                $tool = Read-Tools -Path $ToolsPath | Where-Object { $_.name -eq $c.name } | Select-Object -First 1
                $result = Invoke-Tool -Tool $tool -Prompt $Prompt -TimeoutS $TimeoutS
            } else {
                $result = Invoke-Fleet -Name $c.name -Prompt $Prompt -Path $FleetPath -NoJournal
            }
        } catch {
            $result = @{ stdout=''; stderr=$_.Exception.Message; exit_code=-1; duration_s=0 }
        }

        # Verify (custom grader via the seam, else the heuristic default).
        try {
            if ($Grader) { $verdict = & $Grader -Capability $Capability -Result $result }
            else         { $verdict = Test-RoutingOutputHeuristic -Capability $Capability -Result $result }
        } catch {
            $verdict = @{ passed=$false; score=0.0; reason="grader error: $($_.Exception.Message)" }
        }

        [void]$attempts.Add([pscustomobject]@{
            candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier
            passed=[bool]$verdict.passed; score=[double]$verdict.score; reason=[string]$verdict.reason
            duration_s=[int]$result.duration_s
        })
        Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind `
            -CostTier $c.cost_tier -ExitCode ([int]$result.exit_code) -DurationS ([int]$result.duration_s) `
            -Passed ([bool]$verdict.passed) -Score ([double]$verdict.score) -Reason ([string]$verdict.reason) `
            -JournalPath $JournalPath

        if ($verdict.passed) {
            return [pscustomobject]@{ status='passed'; capability=$Capability; winner=$c.name; result=$result; attempts=$attempts.ToArray() }
        }
    }

    return [pscustomobject]@{ status='escalate-to-conductor'; capability=$Capability; winner=$null; result=$null; attempts=$attempts.ToArray() }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: PASS (all grader + journal + Invoke-Tool + 11 loop checks), `ALL PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(routing): Invoke-RoutedCapability dispatch/verify/escalate loop"
```

---

### Task 5: `/route --run` action

**Files:**
- Modify: `commands/route.md`

- [ ] **Step 1: Replace the command body to add the `--run` action**

In `commands/route.md`, update the front-matter and the body. First, refresh the `description`
line so it no longer says dispatch is a "later slice" — change it to:

```
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), reading tools.yaml + fleet.yaml. Without --run it recommends; with --run "<prompt>" it auto-dispatches, verifies the output, and escalates up the cost ladder.
```

Then change the `argument-hint` to:

```
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"]
```

Then replace the `## Steps` section (lines under `## Steps` through the end of step 4) with:

```markdown
## Steps

1. **Parse `$ARGUMENTS`:** the first token is `<capability>`; optional `--max-tier local|free|paid`,
   `--local`, and `--run "<prompt>"`. Empty capability → stop with:
   *"Usage: /route \"<capability>\" [--max-tier local|free|paid] [--local] [--run \"<prompt>\"]"*.

2. **Without `--run` (recommendation mode, unchanged):**

   ```powershell
   . "$HOME/.claude/scripts/routing-lib.ps1"
   $sel = @{ Capability = '<capability>' }
   if ($local)   { $sel['RequireLocal'] = $true }
   if ($maxTier) { $sel['MaxCostTier']  = '<tier>' }
   $cands = Select-Capability @sel
   ```

   - If `$cands` is empty, say no candidate serves `<capability>` and list `Get-KnownCapabilities`.
   - Otherwise print the ranked table and the top pick:

     ```powershell
     $cands | Format-Table name, source, kind, cost_tier, quality, why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
     ```

   Note this is a recommendation; pass `--run "<prompt>"` to dispatch.

3. **With `--run "<prompt>"` (dispatch mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($local)   { $opt['RequireLocal'] = $true }
   if ($maxTier) { $opt['MaxCostTier']  = '<tier>' }
   $outcome = Invoke-RoutedCapability @opt
   foreach ($a in $outcome.attempts) {
       $mark = if ($a.passed) { 'PASS' } else { 'fail' }
       Write-Host ("  {0,-5} {1,-22} {2}  ({3}s)  {4}" -f $a.cost_tier, $a.candidate, $mark, $a.duration_s, $a.reason)
   }
   ```

   Then report the outcome by `$outcome.status`:
   - `passed` → state the winner and show `$outcome.result.stdout`.
   - `escalate-to-conductor` → tell the user every candidate failed (list the per-attempt
     reasons above) and that it is escalating to the conductor (you, Claude) to do the task
     directly or pick a model manually.
   - `no-candidate` → no candidate serves `<capability>`; list `Get-KnownCapabilities`.

   Finish with: *"Logged $($outcome.attempts.Count) attempt(s) to ~/.claude/routing-journal.jsonl."*

4. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.
```

- [ ] **Step 2: Verify the command file reads correctly**

Run: `pwsh -NoProfile -Command "Get-Content commands/route.md | Select-String -Pattern '--run','Invoke-RoutedCapability' | Measure-Object | Select-Object -Expand Count"`
Expected: a count ≥ 2 (the hint + the dispatch call appear).

- [ ] **Step 3: Commit**

```bash
git add commands/route.md
git commit -m "feat(routing): /route --run dispatch action with ladder trace"
```

---

### Task 6: Bootstrap deployment

**Files:**
- Modify: `scripts/bootstrap.ps1:250` (libs array)
- Modify: `scripts/test-bootstrap.ps1` (add assertion)

- [ ] **Step 1: Add the failing bootstrap smoke assertion**

In `scripts/test-bootstrap.ps1`, after the `routing-lib.ps1` assertion (line ~29), add:

```powershell
Assert "would deploy routing-dispatch.ps1" ($out -match 'routing-dispatch\.ps1')
```

- [ ] **Step 2: Run the bootstrap smoke test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — dry-run output does not mention `routing-dispatch.ps1` yet.

- [ ] **Step 3: Add `routing-dispatch.ps1` to the bootstrap libs array**

In `scripts/bootstrap.ps1` line 250, change the libs array entry from:

```powershell
'fleet-ensemble.ps1', 'routing-lib.ps1', 'six-hats-lib.ps1',
```

to:

```powershell
'fleet-ensemble.ps1', 'routing-lib.ps1', 'routing-dispatch.ps1', 'six-hats-lib.ps1',
```

(The surrounding `foreach ($script in @( ... ))` copy loop already deploys every entry; no other change is needed. `route.md` was added to the commands array in Slice 1, and `routing-journal.jsonl` needs no seed — it is created on first write.)

- [ ] **Step 4: Run the bootstrap smoke test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — includes `would deploy routing-dispatch.ps1`, `ALL PASS`/no failures, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(routing): deploy routing-dispatch.ps1 via bootstrap"
```

---

## Final Verification (run before the gated merge)

- [ ] Run the new suite: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1` → `ALL PASS`, exit 0.
- [ ] Run the Slice 1 suite (regression): `pwsh -NoProfile -File scripts/test-routing-lib.ps1` → `ALL PASS`.
- [ ] Run the bootstrap smoke: `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → no failures.
- [ ] Run the fleet suite (Invoke-Fleet contract): `pwsh -NoProfile -File scripts/test-fleet-lib.ps1` → passes.
- [ ] Run the Python gate: `python -m pytest dashboard kb -q` → passes.
- [ ] Live smoke (recommendation path still works): `pwsh -NoProfile -Command ". scripts/routing-dispatch.ps1; (Invoke-RoutedCapability -Capability 'nope' -Prompt 'x' -ToolsPath references/tools.yaml -FleetPath references/fleet.yaml).status"` → prints `no-candidate`.

---

## Notes for the Implementer

- **Append, don't rewrite:** Tasks 2–4 append functions to `routing-dispatch.ps1` and insert test blocks into the single `try` of `scripts/test-routing-dispatch.ps1`. Keep the harness header (Task 1) and the `finally`/exit footer intact; new test blocks go before the closing `}` of `try`.
- **`Invoke-Fleet -NoJournal`** is mandatory in the real-dispatch branch — Slice 2 owns the journal; double-logging to `model-routing-log.md` would pollute it.
- **Grader contract** is `(Capability, Result) → @{passed; score; reason}`. Any custom grader (Slice 3) must accept `-Capability` and `-Result` named params and return those three keys.
- **No `routing-journal.jsonl` seed** — it is created on first `Add-Content`. Do not add a bootstrap seed step for it.
- **PowerShell gotchas:** wrap `Get-Content` reads of the journal in `@(...)` before `.Count` (a 1-line file returns a string, not an array). `$LASTEXITCODE` can be `$null` before any native call — the `Invoke-Tool` guard handles it.
```
