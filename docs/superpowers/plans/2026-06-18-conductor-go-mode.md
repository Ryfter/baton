# Conductor (`/baton:go`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Conductor engine behind `/baton:go "<goal>"` — a natural-language front door that parses a model-produced task DAG, walks it under two interrupt guards (budget cap + `reversible:false`), logs an event/decision ledger, and renders a plain-English report.

**Architecture:** A pure PowerShell layer (`conductor-lib.ps1`) provides the deterministic mechanics — plan parsing, topological ordering, the two interrupt checks, the JSONL ledgers, and the report — plus a seamed `Invoke-Conductor` loop. The loop obtains the plan via a `-Planner` seam and each task's result via a `-Spawner` seam; both default to governed fleet dispatch (`Select-Capability` + `Invoke-Fleet`) and are stubbed in tests so the whole engine runs with no network, no model, and no real `~/.baton`. A thin CLI (`fleet-go.ps1`) and slash command (`commands/go.md`) wrap it; the Claude session acts as the live Conductor, narrating from the event stream and handling interrupts.

**Tech Stack:** PowerShell 7+ (pwsh), the existing `baton-home.ps1` / `routing-lib.ps1` / `fleet-lib.ps1` libraries, a hand-rolled `Check` test harness (no Pester).

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-06-18-conductor-go-mode-design.md`. Every task implicitly includes these constraints.
- **Run artifacts** live under `<BATON_HOME>/runs/<run-id>/` where `BATON_HOME` resolves via `Get-BatonHome` (default `~/.baton`). Files: `plan.json`, `events.jsonl`, `decisions.jsonl`, `report.md`.
- **Run id format:** `go-<yyyy-MM-ddTHH-mm-ss>` (colons replaced by dashes — Windows-path-safe).
- **Two interrupts only:** a task whose tier-estimate would push cumulative spend past `budget_cap` (null cap ⇒ never), and a task with `reversible -eq $false`. Everything else proceeds and is logged, never prompted.
- **Hermetic tests:** never write under the real `~/.baton` or `~/.claude`. Isolate with a temp `BATON_HOME` and/or explicit `-RunDir`/`-FleetPath`/`-ToolsPath`. No network: the `-Planner`/`-Spawner`/`-Dispatcher` seams are stubbed. Tests for fleet routing point `-FleetPath` at the repo's `references/fleet.yaml` (a shareable seed) — `Select-Capability` is pure (reads YAML, ranks; no network).
- **Box-private:** never hard-code rosters, endpoints, or budget numbers. `budget_cap` is `null` in all shared code/schema; a real cap arrives only via the `--budget` flag or box-private config.
- **PowerShell traps:** never name a parameter `$Input` or `$Event` (both are automatic variables) — this plan uses `$EventObj`. All file writes use `-Encoding utf8NoBOM`.
- **Array-flatten rule:** unary comma `,([type[]]$x)` protects a single-element array return **only at direct-assignment call sites**; at `@()`-wrapper or hashtable-member sites it nests — there, drop the comma and keep the `[type[]]` cast. `Resolve-TaskOrder` returns at a direct-assignment site, so it uses the comma.
- **Plugin version:** bump `.claude-plugin/plugin.json` from `1.2.0-rc.11` to `1.2.0-rc.12`.
- All new functions live in `scripts/conductor-lib.ps1`; all checks accumulate in the single suite `scripts/test-conductor-lib.ps1` (tasks append to it, never rewrite earlier checks).

---

### Task 1: Plan parsing (pure)

**Files:**
- Create: `scripts/conductor-lib.ps1`
- Create (Test): `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Produces: `New-RunId [-Now <datetime>] -> string`; `Get-JsonBlock -Raw <string> -> string`; `ConvertTo-PlanObject -RawStdout <string> -> hashtable|$null`. The plan hashtable is `@{ run_id:string; goal:string; budget_cap:double|$null; tasks:object[] }`; each task is a `[pscustomobject]` with `id, desc, command, capability, model_pick, depends_on:string[], est_cost_tier, reversible:bool`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-conductor-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/conductor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: plan parsing (pure) ----
    Check 'T1 run id has go- prefix and dashed timestamp' `
        ((New-RunId -Now ([datetime]'2026-06-18T14:22:05')) -eq 'go-2026-06-18T14-22-05')

    $planJson = '{"run_id":"x","goal":"convert pdfs","budget_cap":null,"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","model_pick":"claude-haiku","depends_on":[],"est_cost_tier":"free","reversible":true},{"id":"t2","desc":"build","command":"code-parallel","capability":"code-gen","depends_on":["t1"],"est_cost_tier":"paid"}]}'
    Check 'T2 json block extracted from prose' ((Get-JsonBlock -Raw ("noise " + $planJson + " tail")) -eq $planJson)
    Check 'T3 no json -> empty' ((Get-JsonBlock -Raw 'no braces') -eq '')

    $p = ConvertTo-PlanObject -RawStdout ('```json' + "`n" + $planJson + "`n" + '```')
    Check 'T4 plan parses goal' ($p.goal -eq 'convert pdfs')
    Check 'T5 plan budget_cap null preserved' ($null -eq $p.budget_cap)
    Check 'T6 tasks normalized to array of 2' (@($p.tasks).Count -eq 2)
    Check 'T7 depends_on is array' (@($p.tasks[1].depends_on) -contains 't1')
    Check 'T8 missing reversible defaults true' ($p.tasks[1].reversible -eq $true)
    Check 'T9 missing est_cost_tier defaults free' ((ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"a","desc":"d"}]}').tasks[0].est_cost_tier -eq 'free')
    Check 'T10 garbage -> null' ($null -eq (ConvertTo-PlanObject -RawStdout 'not json'))
    Check 'T11 no tasks key -> null' ($null -eq (ConvertTo-PlanObject -RawStdout '{"goal":"x"}'))
```

(The suite's `} catch {} ; exit` tail is added in Task 6 once all sections exist. Until then, run with the temporary tail shown in Step 2.)

- [ ] **Step 2: Run test to verify it fails**

Append a temporary tail so the file runs, then invoke:

```powershell
Add-Content scripts/test-conductor-lib.ps1 "`n} catch { Write-Host `"ERROR: `$(`$_.Exception.Message)`"; exit 1 }`nWrite-Host `"`"; if (`$script:fail -gt 0) { Write-Host `"`$script:fail FAILED`"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }"
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — `conductor-lib.ps1` does not exist / functions not defined.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/conductor-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Conductor engine (/baton:go). Parses a model-produced task DAG, walks it under
  two interrupt guards (budget cap + reversible:false), logs event/decision
  ledgers, and renders a report. Pure layer + seamed Invoke-Conductor.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-go.ps1 wraps it for
  /baton:go. routing-lib brings Select-Capability and (via fleet-lib) Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-06-18-conductor-go-mode-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function New-RunId {
    param([datetime]$Now = (Get-Date))
    return 'go-' + $Now.ToString('yyyy-MM-ddTHH-mm-ss')
}

function Get-JsonBlock {
    <# First '{' to last '}' from a possibly fenced/prose-wrapped reply; '' if none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open = $Raw.IndexOf('{'); $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function ConvertTo-PlanObject {
    <# Parse a planner reply into a normalized plan hashtable, or $null when there
       is no valid JSON object or no tasks. Tasks get defaulted fields. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-JsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($null -eq $o.tasks) { return $null }
    $tasks = foreach ($t in @($o.tasks)) {
        [pscustomobject]@{
            id            = [string]$t.id
            desc          = [string]$t.desc
            command       = [string]$t.command
            capability    = [string]$t.capability
            model_pick    = [string]$t.model_pick
            depends_on    = @($t.depends_on | Where-Object { $_ })
            est_cost_tier = if ($t.est_cost_tier) { [string]$t.est_cost_tier } else { 'free' }
            reversible    = if ($null -eq $t.reversible) { $true } else { [bool]$t.reversible }
        }
    }
    if (@($tasks).Count -lt 1) { return $null }
    return @{
        run_id     = [string]$o.run_id
        goal       = [string]$o.goal
        budget_cap = if ($null -eq $o.budget_cap) { $null } else { [double]$o.budget_cap }
        tasks      = @($tasks)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: PASS — T1 through T11 all PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): plan parsing pure layer (Task 1)"
```

---

### Task 2: DAG ordering & interrupt guards (pure)

**Files:**
- Modify: `scripts/conductor-lib.ps1` (append functions)
- Modify: `scripts/test-conductor-lib.ps1` (append checks)

**Interfaces:**
- Consumes: the task `[pscustomobject]` shape from Task 1 (`id`, `depends_on`, `est_cost_tier`, `reversible`).
- Produces: `Resolve-TaskOrder -Tasks <array> -> object[]` (stable topological order; throws on cycle or unknown dependency); `Get-TaskCostEstimate -Tier <string> [-PaidPerCall <double>] -> double`; `Test-BudgetExceeded -CumulativeSpend <double> -TaskEstimate <double> -BudgetCap <object> -> bool`; `Test-TaskDestructive -Task <object> -> bool`.

- [ ] **Step 1: Write the failing test**

Append inside the `try { … }` block of `scripts/test-conductor-lib.ps1`, after the Task 1 checks:

```powershell
    # ---- Task 2: DAG order + guards (pure) ----
    $mk = { param($id,$deps,$tier='free',$rev=$true) [pscustomobject]@{ id=$id; desc=$id; command=''; capability=''; model_pick=''; depends_on=@($deps); est_cost_tier=$tier; reversible=$rev } }
    $tasks = @( (& $mk 't2' @('t1')), (& $mk 't1' @()), (& $mk 't3' @('t1','t2')) )
    $order = Resolve-TaskOrder -Tasks $tasks
    Check 'T12 topo order puts t1 first' ($order[0].id -eq 't1')
    Check 'T13 topo order respects deps (t2 before t3)' (([array]($order.id)).IndexOf('t2') -lt ([array]($order.id)).IndexOf('t3'))
    Check 'T14 order returns all tasks' (@($order).Count -eq 3)

    $cyc = @( (& $mk 'a' @('b')), (& $mk 'b' @('a')) )
    $threw = $false; try { Resolve-TaskOrder -Tasks $cyc } catch { $threw = $true }
    Check 'T15 cycle throws' $threw

    $unknown = @( (& $mk 'a' @('zzz')) )
    $threw2 = $false; try { Resolve-TaskOrder -Tasks $unknown } catch { $threw2 = $true }
    Check 'T16 unknown dependency throws' $threw2

    Check 'T17 paid tier estimates the per-call figure' ((Get-TaskCostEstimate -Tier 'paid' -PaidPerCall 0.05) -eq 0.05)
    Check 'T18 free tier estimates zero' ((Get-TaskCostEstimate -Tier 'free' -PaidPerCall 0.05) -eq 0.0)
    Check 'T19 local tier estimates zero' ((Get-TaskCostEstimate -Tier 'local') -eq 0.0)

    Check 'T20 null cap never exceeds' (-not (Test-BudgetExceeded -CumulativeSpend 99 -TaskEstimate 99 -BudgetCap $null))
    Check 'T21 over cap exceeds' (Test-BudgetExceeded -CumulativeSpend 0.08 -TaskEstimate 0.05 -BudgetCap 0.10)
    Check 'T22 under cap does not exceed' (-not (Test-BudgetExceeded -CumulativeSpend 0.02 -TaskEstimate 0.05 -BudgetCap 0.10))

    Check 'T23 reversible:false is destructive' (Test-TaskDestructive -Task (& $mk 'x' @() 'free' $false))
    Check 'T24 reversible:true is not destructive' (-not (Test-TaskDestructive -Task (& $mk 'x' @() 'free' $true)))
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — `Resolve-TaskOrder` and the guard functions are not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/conductor-lib.ps1`:

```powershell
function Resolve-TaskOrder {
    <# Stable topological order via Kahn's algorithm. Throws on a dependency cycle
       or a dependency on an unknown id. Ready tasks are emitted in original order. #>
    param([Parameter(Mandatory)][array]$Tasks)
    $byId = @{}; foreach ($t in $Tasks) { if ($t.id) { $byId[$t.id] = $t } }
    $indeg = @{}; foreach ($t in $Tasks) { $indeg[$t.id] = 0 }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if (-not $byId.ContainsKey($d)) { throw "Task '$($t.id)' depends on unknown id '$d'." }
            $indeg[$t.id]++
        }
    }
    $ordered = [System.Collections.ArrayList]@()
    $ready   = [System.Collections.ArrayList]@()
    foreach ($t in $Tasks) { if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) } }
    while ($ready.Count -gt 0) {
        $id = $ready[0]; $ready.RemoveAt(0)
        [void]$ordered.Add($byId[$id])
        foreach ($t in $Tasks) {
            if (@($t.depends_on) -contains $id) {
                $indeg[$t.id]--
                if ($indeg[$t.id] -eq 0) { [void]$ready.Add($t.id) }
            }
        }
    }
    if ($ordered.Count -ne $Tasks.Count) { throw 'Plan has a dependency cycle.' }
    return ,([array]$ordered)
}

function Get-TaskCostEstimate {
    <# Coarse v1 estimate: paid -> per-call figure; local/free/unknown -> 0. #>
    param([Parameter(Mandatory)][string]$Tier, [double]$PaidPerCall = 0.05)
    if ($Tier -eq 'paid') { return $PaidPerCall }
    return 0.0
}

function Test-BudgetExceeded {
    <# True when cumulative + this task's estimate would cross the cap. Null cap -> never. #>
    param([double]$CumulativeSpend, [double]$TaskEstimate, $BudgetCap)
    if ($null -eq $BudgetCap) { return $false }
    return (($CumulativeSpend + $TaskEstimate) -gt [double]$BudgetCap)
}

function Test-TaskDestructive {
    <# A node tagged reversible:false always interrupts. #>
    param([Parameter(Mandatory)]$Task)
    return ($Task.reversible -eq $false)
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: PASS — T1 through T24.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): DAG ordering + interrupt guards (Task 2)"
```

---

### Task 3: Ledgers, run dir & report (pure + IO)

**Files:**
- Modify: `scripts/conductor-lib.ps1` (append functions)
- Modify: `scripts/test-conductor-lib.ps1` (append checks)

**Interfaces:**
- Consumes: the plan hashtable (Task 1).
- Produces: `New-RunEvent [-TaskId] -Kind <string> [-Message] [-Level] [-Now] -> [ordered]`; `New-RunDecision [-TaskId] -Chose <string> [-Alternatives <string[]>] [-Why] [-CostTier] [-Now] -> [ordered]`; `Add-RunEvent -RunDir <string> -EventObj <object>`; `Add-RunDecision -RunDir <string> -Decision <object>`; `Initialize-RunDir [-RunId] [-Root] -> string` (the run dir path); `Format-RunReport -Plan <hashtable> [-Decisions] [-Spend] [-Status] [-PendingTaskId] -> string`.

- [ ] **Step 1: Write the failing test**

Append inside the `try { … }` block, after Task 2 checks:

```powershell
    # ---- Task 3: ledgers, run dir, report (pure + IO) ----
    $tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
    $runDir = Initialize-RunDir -RunId 'go-unit-1' -Root $tmpHome
    Check 'T25 run dir created' (Test-Path $runDir)
    Check 'T26 run dir named for run id' ((Split-Path $runDir -Leaf) -eq 'go-unit-1')

    $ev = New-RunEvent -TaskId 't1' -Kind 'started' -Message 'hello'
    Check 'T27 event has utc ts and kind' (($ev.kind -eq 'started') -and ($ev.ts -match 'Z$'))
    Add-RunEvent -RunDir $runDir -EventObj $ev
    Add-RunEvent -RunDir $runDir -EventObj (New-RunEvent -TaskId 't1' -Kind 'finished')
    $evLines = Get-Content -LiteralPath (Join-Path $runDir 'events.jsonl')
    Check 'T28 two events appended as jsonl' (@($evLines).Count -eq 2)
    Check 'T29 event line is valid json' ((($evLines[0] | ConvertFrom-Json).kind) -eq 'started')

    $dec = New-RunDecision -TaskId 't1' -Chose 'docling' -Alternatives @('markitdown') -Why 'already wired' -CostTier 'local'
    Check 'T30 decision records choice + alts' (($dec.chose -eq 'docling') -and (@($dec.alternatives) -contains 'markitdown'))
    Add-RunDecision -RunDir $runDir -Decision $dec
    Check 'T31 decision appended' ((Get-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') | Measure-Object -Line).Lines -ge 1)

    $plan = @{ run_id='go-unit-1'; goal='convert pdfs'; budget_cap=$null; tasks=@(
        [pscustomobject]@{ id='t1'; desc='research'; command='research-gate'; capability='research'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true }
    ) }
    $report = Format-RunReport -Plan $plan -Decisions @($dec) -Spend 0.0 -Status 'completed'
    Check 'T32 report names the goal' ($report -match 'convert pdfs')
    Check 'T33 report shows status' ($report -match 'completed')
    Check 'T34 report lists the decision' ($report -match 'docling')
    $reportI = Format-RunReport -Plan $plan -Status 'interrupted-budget' -PendingTaskId 't1'
    Check 'T35 interrupted report names paused task' ($reportI -match 't1')

    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — ledger/report functions not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/conductor-lib.ps1`:

```powershell
function New-RunEvent {
    <# Pure factory for an events.jsonl record. ($EventObj, not $Event: $Event is a
       PowerShell automatic variable.) #>
    param(
        [string]$TaskId = '',
        [Parameter(Mandatory)][string]$Kind,
        [string]$Message = '',
        [string]$Level = 'info',
        [datetime]$Now = (Get-Date)
    )
    return [ordered]@{
        ts      = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        level   = $Level
        task_id = $TaskId
        kind    = $Kind
        message = $Message
    }
}

function New-RunDecision {
    <# Pure factory for a decisions.jsonl record (an autonomous guess + alternatives). #>
    param(
        [string]$TaskId = '',
        [Parameter(Mandatory)][string]$Chose,
        [string[]]$Alternatives = @(),
        [string]$Why = '',
        [string]$CostTier = '',
        [datetime]$Now = (Get-Date)
    )
    return [ordered]@{
        ts           = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        task_id      = $TaskId
        chose        = $Chose
        alternatives = @($Alternatives)
        why          = $Why
        cost_tier    = $CostTier
    }
}

function Add-RunEvent {
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)]$EventObj)
    $line = ($EventObj | ConvertTo-Json -Compress -Depth 6)
    Add-Content -LiteralPath (Join-Path $RunDir 'events.jsonl') -Value $line -Encoding utf8NoBOM
}

function Add-RunDecision {
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)]$Decision)
    $line = ($Decision | ConvertTo-Json -Compress -Depth 6)
    Add-Content -LiteralPath (Join-Path $RunDir 'decisions.jsonl') -Value $line -Encoding utf8NoBOM
}

function Initialize-RunDir {
    param([string]$RunId = (New-RunId), [string]$Root)
    if (-not $Root) { $Root = Join-Path (Get-BatonHome) 'runs' }
    $dir = Join-Path $Root $RunId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Format-RunReport {
    <# Plain-English run report rendered from the plan + decision ledger. #>
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = ''
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Conductor run — $($Plan.run_id)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Goal:** $($Plan.goal)")
    [void]$sb.AppendLine("**Status:** $Status")
    if (($Status -ne 'completed') -and $PendingTaskId) { [void]$sb.AppendLine("**Paused at:** $PendingTaskId") }
    [void]$sb.AppendLine(("**Spend:** {0:0.00}" -f $Spend))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Tasks')
    foreach ($t in @($Plan.tasks)) {
        $tag = if ($t.capability) { "$($t.command)/$($t.capability)" } else { $t.command }
        [void]$sb.AppendLine("- $($t.id): $($t.desc) [$tag] ($($t.est_cost_tier))")
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Decisions')
    if (@($Decisions).Count -eq 0) { [void]$sb.AppendLine('(none recorded)') }
    foreach ($d in @($Decisions)) {
        $alt = if (@($d.alternatives).Count) { " (alts: $((@($d.alternatives)) -join ', '))" } else { '' }
        [void]$sb.AppendLine("- $($d.task_id): chose **$($d.chose)** — $($d.why)$alt")
    }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: PASS — T1 through T35.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): event/decision ledgers + run report (Task 3)"
```

---

### Task 4: Planner prompt & seamed plan phase

**Files:**
- Modify: `scripts/conductor-lib.ps1` (append functions)
- Modify: `scripts/test-conductor-lib.ps1` (append checks)

**Interfaces:**
- Consumes: `ConvertTo-PlanObject` (Task 1); `Select-Capability` / `Invoke-Fleet` (existing libs).
- Produces: `Build-PlannerPrompt -Goal <string> [-RegistryLines <string[]>] -> string`; `Invoke-PlanPhase -Goal <string> [-RunId] [-BudgetCap] [-MaxCostTier] [-FleetPath] [-ToolsPath] [-RegistryLines] [-Dispatcher <scriptblock>] -> hashtable|$null`. The `-Dispatcher` seam takes `param($cand,$prompt)` and returns `@{ stdout; stderr; exit_code; duration_s }` (the `Invoke-Fleet` shape).

- [ ] **Step 1: Write the failing test**

Append inside the `try { … }` block, after Task 3 checks:

```powershell
    # ---- Task 4: planner prompt + seamed plan phase ----
    $pp = Build-PlannerPrompt -Goal 'convert pdfs to markdown' -RegistryLines @('docling — pdf-extract (local)')
    Check 'T36 planner prompt includes goal' ($pp -match 'convert pdfs to markdown')
    Check 'T37 planner prompt includes registry evidence' ($pp -match 'docling')
    Check 'T38 planner prompt includes schema + reversible rule' (($pp -match '"tasks"') -and ($pp -match 'reversible'))

    $refFleet = Join-Path $PSScriptRoot '../references/fleet.yaml'
    $tmpTools = Join-Path ([System.IO.Path]::GetTempPath()) "cond-tools-$([System.IO.Path]::GetRandomFileName()).yaml"
    Set-Content -Path $tmpTools -Value 'tools: []' -Encoding utf8NoBOM
    $cannedPlan = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $disp = { param($c,$p) @{ stdout = $cannedPlan; stderr=''; exit_code = 0; duration_s = 1 } }
    $plan = Invoke-PlanPhase -Goal 'convert pdfs' -RunId 'go-unit-2' -FleetPath $refFleet -ToolsPath $tmpTools -Dispatcher $disp
    Check 'T39 plan phase returns a plan' ($null -ne $plan)
    Check 'T40 plan phase stamps run id' ($plan.run_id -eq 'go-unit-2')
    Check 'T41 plan phase stamps goal' ($plan.goal -eq 'convert pdfs')
    Check 'T42 plan phase parsed the task' (@($plan.tasks).Count -eq 1)

    $dispBad = { param($c,$p) @{ stdout = 'not json'; stderr=''; exit_code = 0; duration_s = 1 } }
    Check 'T43 unparseable planner reply -> null' ($null -eq (Invoke-PlanPhase -Goal 'x' -FleetPath $refFleet -ToolsPath $tmpTools -Dispatcher $dispBad))

    Remove-Item -Force $tmpTools -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — `Build-PlannerPrompt` / `Invoke-PlanPhase` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/conductor-lib.ps1`:

```powershell
function Build-PlannerPrompt {
    <# Instruct a model to decompose the goal into a task DAG (strict JSON). #>
    param([Parameter(Mandatory)][string]$Goal, [string[]]$RegistryLines = @())
    $schema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<capability or empty>", "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
'@
    $evi = if ($RegistryLines.Count) {
        "Tools already wired locally:`n" + (($RegistryLines | ForEach-Object { "- $_" }) -join "`n")
    } else { 'Tools already wired locally: (none)' }
    return @"
You are a planning orchestrator for an autonomous software conductor. Break the
GOAL into an ordered task DAG that sequences existing Baton building blocks
(triage, research-gate, code-decompose, code-parallel, code-merge) and fleet
capabilities. Respond with ONLY valid JSON matching this schema — no prose, no fences.

Schema:
$schema

Rules: give each task a unique id; use depends_on to order; set reversible=false
ONLY for steps that commit to master, force-push, delete outside a worktree, or
publish externally; prefer the cheapest est_cost_tier that can do the job. Use the
evidence to avoid planning work that already exists.

$evi

## Goal
$Goal
"@
}

function Invoke-PlanPhase {
    <# Route the goal to a reasoning-capable worker, parse its task DAG. Returns a
       plan hashtable or $null. -Dispatcher injects for tests; real path uses Invoke-Fleet. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$RunId,
        $BudgetCap = $null,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string[]]$RegistryLines = @(),
        [scriptblock]$Dispatcher
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) { return $null }
    $prompt = Build-PlannerPrompt -Goal $Goal -RegistryLines $RegistryLines
    $res = & $dispatch $cands[0] $prompt
    if ([int]$res.exit_code -ne 0) { return $null }
    $plan = ConvertTo-PlanObject -RawStdout ([string]$res.stdout)
    if ($null -eq $plan) { return $null }
    if ($RunId) { $plan.run_id = $RunId }
    $plan.goal = $Goal
    if ($null -ne $BudgetCap) { $plan.budget_cap = [double]$BudgetCap }
    return $plan
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: PASS — T1 through T43. (If `references/fleet.yaml` lacks a `reasoning`-capable provider, T39–T42 surface it — the seed has `claude-sonnet` with `reasoning`; do not weaken the test, fix the seed.)

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): planner prompt + seamed plan phase (Task 4)"
```

---

### Task 5: The conductor loop (seamed)

**Files:**
- Modify: `scripts/conductor-lib.ps1` (append functions)
- Modify: `scripts/test-conductor-lib.ps1` (append checks)

**Interfaces:**
- Consumes: every function from Tasks 1–4.
- Produces: `Invoke-TaskViaFleet -Task <object> [-FleetPath] [-ToolsPath] [-MaxCostTier] [-Dispatcher] -> hashtable`; `Complete-Run -RunDir <string> -Plan <hashtable> [-Decisions] [-Spend] [-Status] [-PendingTaskId] -> hashtable`; `Invoke-Conductor -Goal <string> [-RunDir] [-BudgetCap] [-PaidPerCall] [-MaxCostTier] [-FleetPath] [-ToolsPath] [-Planner <scriptblock>] [-Spawner <scriptblock>] [-Dispatcher <scriptblock>] -> hashtable`. The `-Planner` seam takes `param($goal)` and returns a plan hashtable (or `$null`). The `-Spawner` seam takes `param($task)` and returns `@{ ok:bool; spend:double; chose:string; why:string; alternatives:string[] }`. `Invoke-Conductor` returns `@{ status; run_id; run_dir; spend; pending_task_id; report }` where `status ∈ {completed, interrupted-budget, interrupted-destructive, failed, plan-failed, plan-invalid}`.

- [ ] **Step 1: Write the failing test**

Append inside the `try { … }` block, after Task 4 checks:

```powershell
    # ---- Task 5: the conductor loop (seamed) ----
    $tmpHome2 = Join-Path ([System.IO.Path]::GetTempPath()) "cond-loop-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpHome2 | Out-Null
    $mkTask = { param($id,$deps,$tier='free',$rev=$true) [pscustomobject]@{ id=$id; desc="do $id"; command='x'; capability='reasoning'; model_pick=''; depends_on=@($deps); est_cost_tier=$tier; reversible=$rev } }

    # Happy path: 3 tasks, all reversible, under budget.
    $planner = { param($goal) @{ run_id='ignored'; goal=$goal; budget_cap=$null; tasks=@( (& $mkTask 't1' @()), (& $mkTask 't2' @('t1')), (& $mkTask 't3' @('t2')) ) } }
    $seen = [System.Collections.ArrayList]@()
    $spawner = { param($task) [void]$seen.Add($task.id); @{ ok=$true; spend=0.0; chose='claude-haiku'; why="ran $($task.id)"; alternatives=@('local-x') } }
    $run1 = Join-Path $tmpHome2 'go-loop-1'
    $r1 = Invoke-Conductor -Goal 'do the thing' -RunDir $run1 -Planner $planner -Spawner $spawner
    Check 'T44 completed status' ($r1.status -eq 'completed')
    Check 'T45 tasks ran in dependency order' (($seen[0] -eq 't1') -and ($seen[2] -eq 't3'))
    Check 'T46 plan.json written' (Test-Path (Join-Path $run1 'plan.json'))
    Check 'T47 report.md written' (Test-Path (Join-Path $run1 'report.md'))
    Check 'T48 decisions logged for each task' ((Get-Content -LiteralPath (Join-Path $run1 'decisions.jsonl') | Measure-Object -Line).Lines -eq 3)
    Check 'T49 events include finished' ((Get-Content -LiteralPath (Join-Path $run1 'events.jsonl') -Raw) -match 'finished')

    # Budget interrupt: a paid task that would cross a tiny cap halts BEFORE running.
    $seenB = [System.Collections.ArrayList]@()
    $spawnerB = { param($task) [void]$seenB.Add($task.id); @{ ok=$true; spend=0.0; chose='m'; why=''; alternatives=@() } }
    $plannerB = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=0.01; tasks=@( (& $mkTask 't1' @() 'free'), (& $mkTask 't2' @('t1') 'paid') ) } }
    $r2 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-2') -BudgetCap 0.01 -PaidPerCall 0.05 -Planner $plannerB -Spawner $spawnerB
    Check 'T50 budget interrupt status' ($r2.status -eq 'interrupted-budget')
    Check 'T51 budget interrupt names pending task' ($r2.pending_task_id -eq 't2')
    Check 'T52 paid task did NOT run' (-not ($seenB -contains 't2'))

    # Destructive interrupt: a reversible:false task halts before running.
    $seenD = [System.Collections.ArrayList]@()
    $spawnerD = { param($task) [void]$seenD.Add($task.id); @{ ok=$true; spend=0.0; chose='m'; why=''; alternatives=@() } }
    $plannerD = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( (& $mkTask 't1' @()), (& $mkTask 't2' @('t1') 'free' $false) ) } }
    $r3 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-3') -Planner $plannerD -Spawner $spawnerD
    Check 'T53 destructive interrupt status' ($r3.status -eq 'interrupted-destructive')
    Check 'T54 destructive task did NOT run' (-not ($seenD -contains 't2'))

    # Plan failure: planner returns null.
    $r4 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-4') -Planner { param($goal) $null } -Spawner $spawner
    Check 'T55 plan-failed status' ($r4.status -eq 'plan-failed')

    Remove-Item -Recurse -Force $tmpHome2 -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run test to verify it fails**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — `Invoke-Conductor` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/conductor-lib.ps1`:

```powershell
function Invoke-TaskViaFleet {
    <# Default executor when no -Spawner is injected: route the task's capability
       through the fleet (a model call). Non-destructive by construction — it never
       touches the repo; real code/merge execution is wired by a box via -Spawner. #>
    param(
        [Parameter(Mandatory)]$Task,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [scriptblock]$Dispatcher
    )
    $cap = if ($Task.capability) { $Task.capability } else { 'reasoning' }
    $cands = Select-Capability -Capability $cap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
        return @{ ok = $false; spend = 0.0; chose = ''; why = "no candidate for capability '$cap'"; alternatives = @() }
    }
    $pick = $cands[0]
    $prompt = "Task: $($Task.desc)"
    $res = if ($Dispatcher) { & $Dispatcher $pick $prompt } else { Invoke-Fleet -Name $pick.name -Prompt $prompt -Path $FleetPath -NoJournal }
    $alts = @($cands | Select-Object -Skip 1 | ForEach-Object { $_.name })
    return @{ ok = ([int]$res.exit_code -eq 0); spend = 0.0; chose = $pick.name; why = "routed $cap -> $($pick.name)"; alternatives = $alts }
}

function Complete-Run {
    <# Render report.md and return the terminal status hashtable. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = ''
    )
    $report = Format-RunReport -Plan $Plan -Decisions @($Decisions) -Spend $Spend -Status $Status -PendingTaskId $PendingTaskId
    Set-Content -LiteralPath (Join-Path $RunDir 'report.md') -Value $report -Encoding utf8NoBOM
    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report }
}

function Invoke-Conductor {
    <# Full-auto engine: plan, then walk the DAG under the two interrupt guards,
       logging events/decisions, and render a report. -Planner/-Spawner/-Dispatcher
       inject for tests; real path uses Invoke-PlanPhase + Invoke-TaskViaFleet. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$RunDir,
        $BudgetCap = $null,
        [double]$PaidPerCall = 0.05,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Planner,
        [scriptblock]$Spawner,
        [scriptblock]$Dispatcher
    )
    if (-not $RunDir) { $RunDir = Initialize-RunDir }
    else { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
    $runId = Split-Path $RunDir -Leaf

    # 1. Plan phase.
    $plan = if ($Planner) { & $Planner $Goal }
            else { Invoke-PlanPhase -Goal $Goal -RunId $runId -BudgetCap $BudgetCap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath -Dispatcher $Dispatcher }
    if ($null -eq $plan) {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message 'planning failed')
        $empty = @{ run_id = $runId; goal = $Goal; budget_cap = $BudgetCap; tasks = @() }
        return (Complete-Run -RunDir $RunDir -Plan $empty -Status 'plan-failed')
    }
    $plan.run_id = $runId
    ($plan | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'started' -Message "plan: $(@($plan.tasks).Count) tasks")

    # 2. Order the DAG.
    try { $order = Resolve-TaskOrder -Tasks @($plan.tasks) }
    catch {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message $_.Exception.Message)
        return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
    }

    # 3. Guarded walk.
    $spend = 0.0
    $decisions = [System.Collections.ArrayList]@()
    foreach ($task in $order) {
        $est = Get-TaskCostEstimate -Tier $task.est_cost_tier -PaidPerCall $PaidPerCall
        if (Test-BudgetExceeded -CumulativeSpend $spend -TaskEstimate $est -BudgetCap $BudgetCap) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "budget: would cross cap at $($task.id)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-budget' -PendingTaskId $task.id)
        }
        if (Test-TaskDestructive -Task $task) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "destructive: $($task.id) is reversible:false")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-destructive' -PendingTaskId $task.id)
        }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'started' -Message $task.desc)
        $r = if ($Spawner) { & $Spawner $task }
             else { Invoke-TaskViaFleet -Task $task -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher }
        $tspend = if ($null -ne $r.spend) { [double]$r.spend } else { $est }
        $spend += $tspend
        if ($r.chose) {
            $dec = New-RunDecision -TaskId $task.id -Chose ([string]$r.chose) -Alternatives (@($r.alternatives)) -Why ([string]$r.why) -CostTier $task.est_cost_tier
            Add-RunDecision -RunDir $RunDir -Decision $dec
            [void]$decisions.Add($dec)
        }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'spent' -Message ("{0:0.00}" -f $tspend))
        $kind = if ($r.ok) { 'finished' } else { 'error' }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind $kind -Message $task.desc)
        if (-not $r.ok) {
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'failed' -PendingTaskId $task.id)
        }
    }
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'completed')
}
```

- [ ] **Step 4: Run test to verify it passes**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: PASS — T1 through T55.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): guarded full-auto loop (Task 5)"
```

---

### Task 6: CLI, slash command, deployment & finalize suite

**Files:**
- Create: `scripts/fleet-go.ps1`
- Create: `commands/go.md`
- Modify: `scripts/test-conductor-lib.ps1` (append child-process checks + the closing tail)
- Modify: `scripts/bootstrap.ps1:259` (add scripts to the manifest)
- Modify: `scripts/test-bootstrap.ps1` (add two deploy asserts)
- Modify: `.claude-plugin/plugin.json` (version bump)

**Interfaces:**
- Consumes: `Invoke-Conductor`, `Initialize-RunDir`, `ConvertTo-PlanObject` (conductor-lib); `Get-BatonHome` (baton-home).
- Produces: the `/baton:go` CLI. Env test seams: `BATON_GO_TEST_PLAN` (a canned plan JSON → wired as `-Planner`) and `BATON_GO_TEST_SPAWN=1` (force every task to succeed → wired as `-Spawner`), so the child-process test runs with zero network.

- [ ] **Step 1: Write the failing test**

Append inside the `try { … }` block of `scripts/test-conductor-lib.ps1`, after Task 5 checks:

```powershell
    # ---- Task 6: CLI child-process (zero network) ----
    $cli = Join-Path $PSScriptRoot 'fleet-go.ps1'
    Check 'T56 fleet-go.ps1 exists' (Test-Path $cli)
    $cliHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-cli-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    $env:BATON_HOME = $cliHome
    $env:BATON_GO_TEST_PLAN = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_SPAWN = '1'
    $out = & pwsh -NoProfile -File $cli -Goal 'convert pdfs' -Json 2>&1 | Out-String
    Check 'T57 CLI exits cleanly and reports completed' ($out -match 'completed')
    $runRoot = Join-Path $cliHome 'runs'
    $made = @(Get-ChildItem -Path $runRoot -Directory -ErrorAction SilentlyContinue)
    Check 'T58 CLI created a run dir' (@($made).Count -ge 1)
    Check 'T59 CLI wrote report.md' (Test-Path (Join-Path $made[0].FullName 'report.md'))
    Remove-Item Env:\BATON_HOME, Env:\BATON_GO_TEST_PLAN, Env:\BATON_GO_TEST_SPAWN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $cliHome -ErrorAction SilentlyContinue

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
```

If you added the temporary tail in Task 1 Step 2, delete it now — this is the single permanent closing tail.

- [ ] **Step 2: Run test to verify it fails**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

Expected: FAIL — `fleet-go.ps1` does not exist (T56+).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/fleet-go.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:go runner. Turns a natural-language goal into a planned, guarded,
  full-auto run: plan DAG -> walk under budget + destructive guards -> ledgers +
  report under BATON_HOME/runs/<run-id>/.
.NOTES
  The Claude session is the live Conductor; this CLI is its deterministic engine.
#>
param(
    [string]$Goal,
    [string]$Text,
    [double]$Budget,
    [switch]$Json,
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'conductor-lib.ps1')

$theGoal = @($Goal, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($theGoal)) { Write-Error 'Provide a goal via -Goal "<text>" (or -Text).'; exit 2 }

$runDir = Initialize-RunDir -RunId (New-RunId)

$go = @{ Goal = $theGoal; RunDir = $runDir; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($PSBoundParameters.ContainsKey('Budget')) { $go['BudgetCap'] = $Budget }

# Test seams: a canned plan and/or forced-success spawner so the suite never calls a model.
if ($env:BATON_GO_TEST_PLAN) {
    $canned = $env:BATON_GO_TEST_PLAN
    $go['Planner'] = { param($g) $p = ConvertTo-PlanObject -RawStdout $canned; if ($p) { $p.goal = $g }; $p }.GetNewClosure()
}
if ($env:BATON_GO_TEST_SPAWN -eq '1') {
    $go['Spawner'] = { param($task) @{ ok = $true; spend = 0.0; chose = 'test-stub'; why = "ran $($task.id)"; alternatives = @() } }
}

$result = Invoke-Conductor @go

if ($Json) {
    $result | ConvertTo-Json -Depth 8
} else {
    Write-Host $result.report
    Write-Host ""
    Write-Host "Status: $($result.status)  ·  spend $('{0:0.00}' -f $result.spend)  ·  $($result.run_dir)"
    if ($result.status -like 'interrupted-*') {
        Write-Host "Paused at $($result.pending_task_id). Review, then resume to continue past this guard."
    }
}
```

Create `commands/go.md`:

```markdown
---
description: Natural-language front door — describe an outcome and the Conductor plans it into a task DAG, then runs it full-auto under two guards (budget cap + destructive action), narrating as it goes. Interrupts only to cross a budget ceiling or before an irreversible action; guesses through everything else and logs every choice. Run artifacts (plan.json / events.jsonl / decisions.jsonl / report.md) land under BATON_HOME/runs/<run-id>/.
argument-hint: "<what you want done>" [--budget <n>] [--max-tier local|free|paid]
---

# /baton:go

You are the **Conductor**. The user describes an outcome; you plan it and drive it to
completion, interrupting only for the two guards. Stay thin — coordinate, narrate, and
let the engine and the fleet do the work.

## Steps

1. Treat `$ARGUMENTS` as the goal (strip any `--budget <n>` / `--max-tier <t>` flags).

2. Run the engine:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal>" -Json
   # add -Budget <n> and/or -MaxCostTier <tier> when the user supplied them
   ```

3. Read the returned JSON (`status`, `run_dir`, `spend`, `pending_task_id`, `report`).
   Narrate the run from `<run_dir>/events.jsonl` as terse one-liners, and surface the
   autonomous choices from `<run_dir>/decisions.jsonl` so the user can see what you
   guessed.

4. Report by `status`:
   - `completed` → show the `report` and the total spend.
   - `interrupted-budget` → the next task would cross the budget cap. Show what is
     pending (`pending_task_id`) and its estimated cost, and ASK the user whether to
     raise `--budget` and resume.
   - `interrupted-destructive` → the next task is `reversible:false` (touches master,
     force-push, out-of-worktree delete, or external publish). Describe exactly what it
     would do and ASK for explicit approval before resuming.
   - `failed` → a task could not complete; show the failing task and the event log.
   - `plan-failed` / `plan-invalid` → planning produced no usable DAG; show why and
     offer to retry with a sharper goal.

5. Everything not on the two guards already ran without asking — do not re-litigate it.
   Point the user at the `report.md` for the full plain-English summary.

## Notes

- The Conductor never touches the user's checkout directly: real code/merge execution
  rides the existing gated-merge flow (per-item branches → PR). The engine itself only
  plans, routes, and logs.
- Run artifacts are box-private under `BATON_HOME/runs/<run-id>/`.

## Arguments

$ARGUMENTS
```

Modify `scripts/bootstrap.ps1` line 259 — add the two scripts to the manifest array, immediately after `'fleet-research-gate.ps1',`:

```powershell
'research-gate-lib.ps1', 'fleet-research-gate.ps1', 'conductor-lib.ps1', 'fleet-go.ps1', 'idea-lib.ps1'
```

Add two asserts to `scripts/test-bootstrap.ps1`, after the `fleet-research-gate` assert (line 49):

```powershell
Assert "deploys conductor-lib script" ($out -match 'conductor-lib\.ps1')
Assert "deploys fleet-go script"      ($out -match 'fleet-go\.ps1')
```

Bump `.claude-plugin/plugin.json`:

```json
  "version": "1.2.0-rc.12",
```

- [ ] **Step 4: Run tests to verify they pass**

```powershell
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

Expected: `test-conductor-lib.ps1` → ALL CHECKS PASS (T1–T59). `test-bootstrap.ps1` → all asserts pass including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-go.ps1 commands/go.md scripts/test-conductor-lib.ps1 scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(conductor): /baton:go CLI + command + deploy wiring (Task 6)"
```

---

## Self-review notes (for the executor)

- **Spec coverage:** §2 three-tier model → the seamed engine (`-Planner`/`-Spawner`); §3 Style-A substrate → CLI + `go.md` driven by the Claude session; §4 full-auto + two interrupts → `Invoke-Conductor` guard checks (Tasks 2 & 5); §5 file contract → `plan.json`/`events.jsonl`/`decisions.jsonl`/`report.md` (Tasks 1, 3, 5); §6.1 legibility → events/decisions/report + `go.md` narration; §6.2 guards → `Test-BudgetExceeded`/`Test-TaskDestructive` + the structural no-direct-execution backstop (engine only routes/logs); §9 testing → hermetic suite + child-process zero-network test.
- **Out of scope (do not build):** Style-B daemon/cockpit; new interrupt categories; multi-run concurrency; live worktree code execution inside the engine (rides the `-Spawner` seam). The default `Invoke-TaskViaFleet` is a model call by design — non-destructive — which is what makes the safety claim hold.
- **Type consistency:** the `-Spawner` result shape `@{ ok; spend; chose; why; alternatives }` is produced by the test stubs (Task 5) and `Invoke-TaskViaFleet` (Task 5) identically; the `-Dispatcher` result shape `@{ stdout; stderr; exit_code; duration_s }` matches `Invoke-Fleet` and the research-gate convention.
```
