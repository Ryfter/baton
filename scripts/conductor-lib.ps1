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
. "$PSScriptRoot/gate-lib.ps1"   # Invoke-AcceptanceGate for the acceptance phase (d058)
. "$PSScriptRoot/effective-cost-lib.ps1"   # run-level effective cost (slice 1)

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
    <# Render report.md (+ optional ## Acceptance) and return the terminal status hashtable.
       -Gate (untyped: ordered dict or hashtable) writes acceptance.json + appends the section. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Plan,
        [array]$Decisions = @(),
        [double]$Spend = 0.0,
        [string]$Status = 'completed',
        [string]$PendingTaskId = '',
        $Gate = $null,
        [object[]]$TaskCosts = @()
    )
    $report = Format-RunReport -Plan $Plan -Decisions @($Decisions) -Spend $Spend -Status $Status -PendingTaskId $PendingTaskId
    if ($Gate) {
        $report = $report + "`n`n" + (Format-AcceptanceSection -Gate $Gate)
        ($Gate | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'acceptance.json') -Encoding utf8NoBOM
    }
    # Effective cost (slice 1): only when a gate produced a verdict (a quality signal).
    $effectiveCost = $null
    if ($Gate -and $Gate.verdict) {
        $quality   = Get-QualityScalar -Verdict ([string]$Gate.verdict) -Counts $Gate.counts
        $runCost   = Get-RunCost -Tasks @($TaskCosts)
        $effective = Get-EffectiveCost -Cost $runCost.cost -Quality $quality
        $breakdown = Get-WorkerBreakdown -Tasks @($TaskCosts)
        $record = New-EffectiveCostRecord -RunId $Plan.run_id -Verdict ([string]$Gate.verdict) `
            -Quality $quality -Cost $runCost.cost -CostBasis $runCost.basis -Attempts $runCost.attempts `
            -EffectiveCost $effective -Workers $breakdown
        $report = $report + "`n`n" + (Format-EffectiveCostSection -Record $record)
        ($record | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'effective-cost.json') -Encoding utf8NoBOM
        $effectiveCost = $effective
    }
    Set-Content -LiteralPath (Join-Path $RunDir 'report.md') -Value $report -Encoding utf8NoBOM
    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report; acceptance = $Gate; effective_cost = $effectiveCost }
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
        [scriptblock]$Dispatcher,
        [string]$GateArtifact,
        [string]$GateDiff,
        [scriptblock]$Gater
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
    $taskCosts = [System.Collections.ArrayList]@()
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
        # Numerator is the cost-tier ESTIMATE (basis='estimate'), matching the budget
        # guard and the record's label — realized spend ($tspend) is a placeholder
        # (0.0) today; realized cost arrives later via Get-RunCost's -CostResolver seam.
        [void]$taskCosts.Add(@{ id = $task.id; worker = ([string]$r.chose); cost = $est })
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'spent' -Message ("{0:0.00}" -f $tspend))
        $kind = if ($r.ok) { 'finished' } else { 'error' }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind $kind -Message $task.desc)
        if (-not $r.ok) {
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'failed' -PendingTaskId $task.id)
        }
    }
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
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts)
}
