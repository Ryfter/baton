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
. "$PSScriptRoot/plan-gate-lib.ps1"   # Invoke-PlanGate for the opt-in Plan Gate phase (d080).
                                       # Re-sources gate-lib (harmless in PS — functions just redefine).
. "$PSScriptRoot/effective-cost-lib.ps1"   # run-level effective cost (slice 1)
. "$PSScriptRoot/cost-resolver-lib.ps1"   # realized-cost metering (slice 2)
. "$PSScriptRoot/prompt-pool-lib.ps1"   # Slice B: live shadow A/B pool bookkeeping

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

function Get-JsonBlocks {
    <# Every balanced top-level {...} candidate in a reply, in order (string-aware
       depth scan so braces inside JSON string values do not split a block). Needed
       for providers like `codex exec` that echo the prompt (which itself carries a
       JSON schema) before the answer — the greedy Get-JsonBlock spans echo+answer
       into one invalid blob. A mis-scanned candidate simply fails ConvertFrom-Json
       downstream and is skipped. Emits blocks to the pipeline (callers collect
       with @() — no unary-comma wrap, per the house rule). #>
    param([Parameter(Mandatory)][string]$Raw)
    $blocks = [System.Collections.ArrayList]@()
    $depth = 0; $blockStart = -1; $inStr = $false; $escaped = $false
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inStr) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { if ($depth -gt 0) { $inStr = $true } }
        elseif ($ch -eq '{') { if ($depth -eq 0) { $blockStart = $i }; $depth++ }
        elseif ($ch -eq '}') {
            if ($depth -gt 0) {
                $depth--
                if ($depth -eq 0 -and $blockStart -ge 0) {
                    [void]$blocks.Add($Raw.Substring($blockStart, $i - $blockStart + 1))
                    $blockStart = -1
                }
            }
        }
    }
    return $blocks.ToArray()
}

function ConvertTo-PlanObject {
    <# Parse a planner reply into a normalized plan hashtable, or $null when there
       is no valid JSON object or no tasks. Tasks get defaulted fields.
       Candidate order (v1.11.1, multi-model): the greedy whole-span block first
       (the historical fast path — one clean/fenced JSON reply), then balanced
       blocks LAST-first, because a model's answer follows any prompt echo. The
       first candidate that parses AND carries tasks wins. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $candidates = [System.Collections.ArrayList]@()
    $greedy = Get-JsonBlock -Raw $RawStdout
    if ($greedy) { [void]$candidates.Add($greedy) }
    $balanced = @(Get-JsonBlocks -Raw $RawStdout)
    for ($bi = $balanced.Count - 1; $bi -ge 0; $bi--) { [void]$candidates.Add($balanced[$bi]) }
    $o = $null
    foreach ($block in $candidates) {
        try { $parsed = $block | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $parsed.tasks) { continue }
        # Reject the planner prompt's own echoed SCHEMA (a provider that dies after
        # echoing would otherwise hand us its placeholder example as a "plan"):
        # the schema's est_cost_tier placeholder "local|free|paid" is the signature.
        $isSchemaEcho = $false
        foreach ($pt in @($parsed.tasks)) {
            if ($pt.est_cost_tier -and (([string]$pt.est_cost_tier) -match '\|')) { $isSchemaEcho = $true; break }
        }
        if ($isSchemaEcho) { continue }
        $o = $parsed; break
    }
    if ($null -eq $o) { return $null }
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
            verify_profile = if ($t.verify_profile) { [string]$t.verify_profile } else { '' }
            allowed_paths  = @($t.allowed_paths | Where-Object { $_ } | ForEach-Object { [string]$_ })
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

function Format-VerificationSection {
    <# The Gemini CLI narration block (adjudication A2): per verified task, route ->
       worker -> check -> retry -> proves, read from tasks/<id>/verification.json.
       Returns '' when no task was verified (section omitted). #>
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][hashtable]$Plan)
    $lines = [System.Collections.ArrayList]@()
    foreach ($t in @($Plan.tasks)) {
        $vp = Join-Path $RunDir "tasks/$($t.id)/verification.json"
        if (-not (Test-Path -LiteralPath $vp)) { continue }
        try { $v = Get-Content -Raw -LiteralPath $vp | ConvertFrom-Json } catch { continue }
        $mark = if ([string]$v.verdict -eq 'pass') { "PASS (grade $($v.grade))" } else { "FAIL ($($v.failure_category))" }
        $retry = if ($v.retried) { ' after 1 retry' } else { '' }
        [void]$lines.Add("- $($t.id): $mark$retry — proves: $($v.proves)")
    }
    if (@($lines).Count -eq 0) { return '' }
    return "## Verification`n" + (@($lines) -join "`n")
}

# Fail-open fallback for Build-PlannerPrompt: the exact conductor-planner.txt
# template text, baked in so a missing/corrupt/malformed prompt file on disk
# can never take the planner phase down. Kept in sync by hand with
# prompts/conductor-planner.txt (read-only reference).
$script:DefaultPlannerPrompt = @'
You are a planning orchestrator for an autonomous software conductor. Break the
GOAL into an ordered task DAG that sequences existing Baton building blocks
(triage, research-gate, code-decompose, code-parallel, code-merge) and fleet
capabilities. Respond with ONLY valid JSON matching this schema — no prose, no fences.

Schema:
{{schema}}

Rules: give each task a unique id; use depends_on to order; set reversible=false
ONLY for steps that commit to master, force-push, delete outside a worktree, or
publish externally; prefer the cheapest est_cost_tier that can do the job. Use the
evidence to avoid planning work that already exists.

{{evi}}

## Goal
{{Goal}}
'@

function Build-PlannerPrompt {
    <# Instruct a model to decompose the goal into a task DAG (strict JSON).
       Fail-open + injection-safe:
        - Resolution order: the BATON_HOME copy first (the live copy, possibly
          tuned by the prompt optimizer), then the repo's $PSScriptRoot/../prompts
          copy as a fallback.
        - If neither file exists, is unreadable, or is missing any of the
          required literal placeholders, fall back to $script:DefaultPlannerPrompt
          — this function never throws.
        - Substitution uses [string]::Replace, NOT -replace: $Goal is untrusted
          user text, and a regex replacement would treat literal '$1'/'$&' in the
          goal as backreferences and corrupt the prompt. #>
    param([Parameter(Mandatory)][string]$Goal, [string[]]$RegistryLines = @(), [string]$Template)
    $schema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<ROUTING capability: code-gen for creating/editing files or code, code-transform, reasoning, research, summarize, triage, review — or empty. NEVER a baton command name>",
      "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
'@
    $evi = if ($RegistryLines.Count) {
        "Tools already wired locally:`n" + (($RegistryLines | ForEach-Object { "- $_" }) -join "`n")
    } else { 'Tools already wired locally: (none)' }

    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')
    # Slice B: a caller-supplied template (the shadow challenger) wins when it
    # carries all placeholders; anything less falls through to the live chain.
    $resolved = $null
    if (-not [string]::IsNullOrEmpty($Template)) {
        $hasAllOverride = $true
        foreach ($ph in $requiredPlaceholders) { if (-not $Template.Contains($ph)) { $hasAllOverride = $false; break } }
        if ($hasAllOverride) { $resolved = $Template }
    }
    if ($null -eq $resolved) {
        foreach ($candidatePath in @(
            (Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt'),
            (Join-Path $PSScriptRoot '../prompts/conductor-planner.txt')
        )) {
            if (-not (Test-Path $candidatePath)) { continue }
            $candidate = $null
            try { $candidate = Get-Content -Raw -LiteralPath $candidatePath -ErrorAction Stop } catch { continue }
            if ([string]::IsNullOrEmpty($candidate)) { continue }
            $hasAll = $true
            foreach ($ph in $requiredPlaceholders) { if (-not $candidate.Contains($ph)) { $hasAll = $false; break } }
            if ($hasAll) { $resolved = $candidate; break }
        }
    }
    if ($null -eq $resolved) { $resolved = $script:DefaultPlannerPrompt }

    return $resolved.Replace('{{schema}}', $schema).Replace('{{evi}}', $evi).Replace('{{Goal}}', $Goal)
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
        [scriptblock]$Dispatcher,
        [string]$RunDir,
        [scriptblock]$ShadowResolver
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) { return $null }
    # Slice B: shadow A/B assignment (fail-open; no RunDir = no shadow).
    $shadowTemplate = $null
    if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
        $sv = $null
        try { $sv = if ($ShadowResolver) { & $ShadowResolver } else { Resolve-ShadowVariant } } catch { $sv = $null }
        if ($sv -and $sv.shadow) {
            if ($sv.role -eq 'challenger') { $shadowTemplate = [string]$sv.template }
            try {
                @{ variant_id = [string]$sv.variant_id; role = [string]$sv.role
                   challenger_id = [string]$sv.challenger_id
                   assigned = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDir 'shadow.json') -Encoding utf8NoBOM
                $vsOther = if ($sv.role -eq 'challenger') { 'champion' } else { "challenger $($sv.challenger_id)" }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "prompt variant $($sv.variant_id) ($($sv.role)) — live A/B vs $vsOther")
            } catch { $shadowTemplate = $null }
        }
    }
    $promptParams = @{ Goal = $Goal; RegistryLines = $RegistryLines }
    if ($shadowTemplate) { $promptParams.Template = $shadowTemplate }
    $prompt = Build-PlannerPrompt @promptParams
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
    $verSection = Format-VerificationSection -RunDir $RunDir -Plan $Plan
    if ($verSection) {
        $report = $report + "`n`n" + $verSection
    }
    # Effective cost (slice 1): only when a gate produced a verdict (a quality signal).
    $effectiveCost = $null
    $realizedRunCost = $null
    if ($Gate -and $Gate.verdict) {
        $quality   = Get-QualityScalar -Verdict ([string]$Gate.verdict) -Counts $Gate.counts
        $runCost   = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
        $realizedRunCost = [double]$runCost.cost
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

    # -- Slice B: live shadow A/B accrual + auto-retire. Strictly after the
    # user-facing report; fail-open — a pool problem never breaks the run. --
    try {
        $shadowPath = Join-Path $RunDir 'shadow.json'
        if (Test-Path $shadowPath) {
            $assign = Get-Content -Raw -LiteralPath $shadowPath | ConvertFrom-Json -AsHashtable
            $poolLoaded = Get-PromptPool
            if (($null -ne $assign) -and $assign.variant_id -and $poolLoaded.ok) {
                $livePool = $poolLoaded.pool
                if ($null -eq $realizedRunCost) {
                    # Ungated run: no effective-cost pass ran, meter here — dollars are real either way.
                    $rc = Get-RunCost -Tasks @($TaskCosts) -CostResolver { param($t) Get-RealizedTaskCost -Task $t -RunDir $RunDir }
                    $realizedRunCost = [double]$rc.cost
                }
                $accrue = @{ Pool = $livePool; VariantId = [string]$assign.variant_id; CostUsd = $realizedRunCost }
                if ($Gate -and $Gate.verdict -and (([string]$Gate.verdict) -in @('accept', 'polish', 'reject'))) {
                    $accrue.Verdict = [string]$Gate.verdict
                }
                [void](Add-LiveRunResult @accrue)
                # v1.7.1: judge the challenger this run was ASSIGNED (shadow.json),
                # not whoever selection would pick now — a mid-run evolution must
                # not misattribute the verdict.
                $sv = Get-ShadowVerdict -Pool $livePool -ChallengerId ([string]$assign.challenger_id)
                if ($sv.state -in @('retire', 'promote')) {
                    $challCpa = if ($null -ne $sv.challenger_cpa) { '{0:n4}' -f [double]$sv.challenger_cpa } else { 'n/a (0 accepts)' }
                    $champCpa = if ($null -ne $sv.champion_cpa) { '{0:n4}' -f [double]$sv.champion_cpa } else { 'n/a (0 accepts)' }
                    if ($sv.state -eq 'retire') {
                        $why = "live A/B loss vs $($sv.champion_id): cost_per_accept $challCpa vs $champCpa over $($sv.challenger_gated)/$($sv.champion_gated) gated runs"
                        [void](Set-CandidateRetired -Pool $livePool -Id ([string]$sv.challenger_id) -Reason $why -By ([string]$sv.champion_id))
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "challenger $($sv.challenger_id) auto-retired: $why")
                    } else {
                        # v1.7.1: one nudge per candidate — the --pool report still
                        # shows the live verdict on every invocation.
                        $challNudge = @($livePool.candidates | Where-Object { $_.id -eq $sv.challenger_id })[0]
                        if ($null -eq $challNudge.promote_recommended_at) {
                            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Message "challenger $($sv.challenger_id) is winning in dollars (cost_per_accept $challCpa vs $champCpa) — promote via /baton:optimize-prompt --apply")
                            $challNudge.promote_recommended_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                        }
                    }
                }
                Save-PromptPool -Pool $livePool
            }
        }
    } catch {
        try { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'shadow' -Level 'warn' -Message "shadow accrual failed (run unaffected): $($_.Exception.Message)") } catch { }
    }

    return @{ status = $Status; run_id = $Plan.run_id; run_dir = $RunDir; spend = $Spend; pending_task_id = $PendingTaskId; report = $report; acceptance = $Gate; effective_cost = $effectiveCost }
}

function Invoke-PlanRevise {
    <# One-shot revise pass (d080, Slice 2): re-plan $Goal with the prior plan and the
       peer-review revise brief appended, parse via ConvertTo-PlanObject, and return the
       revised plan — overwriting plan.json on success. Fail-open by construction: a
       missing reviewing worker, a non-zero exit, an unparseable reply, OR a throw from
       the dispatch all return the ORIGINAL plan ($Run) unchanged and log the fall-back.
       Never a second attempt, never a throw. Mirrors Invoke-PlanPhase's reasoning
       routing and its -Dispatcher test seam so hermetic tests can stub the worker. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [Parameter(Mandatory)][string]$PlanJson,
        [Parameter(Mandatory)][string]$ReviseBrief,
        [Parameter(Mandatory)][hashtable]$Run,
        [string]$RunDir,
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
    $failMsg = 'revise pass failed to parse — proceeding with the original plan'
    # Widen fail-open (codex): ALL revise-pass work — roster resolution (Select-Capability
    # can throw on a malformed fleet/tools file), prompt build, dispatch, and parse — runs
    # inside one try. ANY failure returns the ORIGINAL plan ($Run) with the fail-open event.
    # A missing worker still short-circuits inside the try with the same message. No behavior
    # change on the success path.
    $revised = $null
    try {
        $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
            if ($RunDir) { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message $failMsg) }
            return $Run
        }
        # Reuse the standard planner prompt, then append the prior plan + the brief. Literal
        # concatenation only — $PlanJson/$ReviseBrief are untrusted; never -replace (a '$1'/'$&'
        # in the text would be read as a regex backreference and corrupt the prompt).
        $base = Build-PlannerPrompt -Goal $Goal -RegistryLines $RegistryLines
        $prompt = $base + "`n`n## Prior plan (JSON)`n" + $PlanJson +
                  "`n`n## Peer review findings — revise the plan to address these`n" + $ReviseBrief +
                  "`n`nEmit the FULL revised plan as JSON in the same schema. Address every finding you can without expanding scope."
        $res = & $dispatch $cands[0] $prompt
        if ([int]$res.exit_code -eq 0) { $revised = ConvertTo-PlanObject -RawStdout ([string]$res.stdout) }
    } catch {
        Write-Debug "revise pass failed: $($_.Exception.Message)"
    }
    if ($null -eq $revised) {
        if ($RunDir) { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message $failMsg) }
        return $Run
    }
    # Carry the run identity forward from the original plan (the revised reply may have
    # invented its own run_id/goal/budget_cap — the run's own values win).
    $revised.run_id = $Run.run_id
    $revised.goal = $Goal
    $revised.budget_cap = $Run.budget_cap
    if ($RunDir) {
        ($revised | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message 'plan revised once per peer review — walking the revised plan (no re-gate)')
    }
    return $revised
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
        [scriptblock]$Gater,
        [scriptblock]$DiffProvider,
        [switch]$PlanGate,
        [switch]$PlanGateFailLoud,
        [string[]]$PlanReviewers,
        [bool]$PlanRevise = $true,
        [scriptblock]$PlanGateDispatcher,
        [switch]$AcceptanceGate,
        [switch]$AcceptancePanel,
        [switch]$AcceptanceFailLoud,
        [switch]$Verify,
        [switch]$RequireVerify,
        [scriptblock]$VerifyPreflight,
        [switch]$NormalizeMissingStakes
    )
    if (-not $RunDir) { $RunDir = Initialize-RunDir }
    else { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
    $runId = Split-Path $RunDir -Leaf

    # 1. Plan phase.
    $plan = if ($Planner) { & $Planner $Goal }
            else { Invoke-PlanPhase -Goal $Goal -RunId $runId -BudgetCap $BudgetCap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath -Dispatcher $Dispatcher -RunDir $RunDir }
    if ($null -eq $plan) {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'error' -Level 'error' -Message 'planning failed')
        $empty = @{ run_id = $runId; goal = $Goal; budget_cap = $BudgetCap; tasks = @() }
        return (Complete-Run -RunDir $RunDir -Plan $empty -Status 'plan-failed')
    }
    $plan.run_id = $runId
    if ($NormalizeMissingStakes) {
        $missingStakes = 0
        foreach ($plannedTask in @($plan.tasks)) {
            if ([string]::IsNullOrWhiteSpace([string]$plannedTask.stakes)) {
                $plannedTask | Add-Member -NotePropertyName stakes -NotePropertyValue 'standard' -Force
                $plannedTask | Add-Member -NotePropertyName stakes_basis -NotePropertyValue 'legacy plan omitted stakes' -Force
                $missingStakes++
            }
        }
        if ($missingStakes -gt 0) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'policy' -Level 'warn' -Message "$missingStakes task(s) missing stakes normalized to standard; stakes routing arrives in PR-B (#98)")
        }
    }
    ($plan | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $RunDir 'plan.json') -Encoding utf8NoBOM
    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'started' -Message "plan: $(@($plan.tasks).Count) tasks")

    # 1.5 Plan Gate (d080, Slice 2): policy-selected peer once-over BEFORE the walk.
    #     — a sibling of the post-work Acceptance Gate (d058), but it reviews the not-yet-run
    #     PLAN. Legacy calls remain advisory/fail-open; -PlanGateFailLoud turns missing
    #     evidence, infrastructure failure, and a failed required revise pass into
    #     plan-gate-degraded before any DAG labor.
    if ($PlanGate) {
        # The exact plan.json we just wrote is the artifact the reviewers see.
        $planJsonText = Get-Content -Raw -LiteralPath (Join-Path $RunDir 'plan.json')
        $pgRes = $null
        try {
            $pgRes = Invoke-PlanGate -Goal $Goal -PlanJson $planJsonText -Reviewers $PlanReviewers `
                -Dispatcher $PlanGateDispatcher -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath `
                -FailLoud:$PlanGateFailLoud
        } catch {
            # Standalone remains advisory. Execute fail-loud consumes the null below.
            if (-not $PlanGateFailLoud) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'warn' -Message "plan gate failed (fail-open, walking the plan as-is): $($_.Exception.Message)")
            }
            $pgRes = $null
        }
        if ($PlanGateFailLoud -and $null -eq $pgRes) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message 'PLAN GATE DEGRADED — gate returned no usable result — no labor will run')
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
        }
        if ($null -ne $pgRes) {
            $pgJson = ConvertTo-Json -Depth 8 -InputObject $pgRes
            Set-Content -LiteralPath (Join-Path $RunDir 'plan-review.json') -Value $pgJson -Encoding utf8NoBOM
            $c = $pgRes.counts
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message "plan verdict: $($pgRes.verdict) — $($pgRes.reason) ($($c.critical) critical, $($c.important) important, $($c.minor) minor)")
            if ($PlanGateFailLoud -and ($pgRes.degraded -or $pgRes.fail_open)) {
                $pgReason = if ([string]::IsNullOrWhiteSpace([string]$pgRes.reason)) { 'gate returned a degraded result' } else { [string]$pgRes.reason }
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message "PLAN GATE DEGRADED — $pgReason — no labor will run")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
            }
            $verdict = [string]$pgRes.verdict
            if ($verdict -ne 'accept') {
                Set-Content -LiteralPath (Join-Path $RunDir 'revise_brief.md') -Value ([string]$pgRes.revise_brief) -Encoding utf8NoBOM
            }
            if ($verdict -eq 'reject') {
                # Hard stop: report the rejection, then exit clean via the same Complete-Run
                # path plan-failed uses. No walk, no worktree, no spend.
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'warn' -Message "plan rejected before the walk: $($pgRes.reason) — no worktree, no labor, no spend")
                return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-rejected')
            }
            elseif ($verdict -eq 'revise') {
                if ($PlanRevise) {
                    # One revise pass, then walk whichever plan survives (no re-gate, Slice 2).
                    $priorPlan = $plan
                    $revisedPlan = Invoke-PlanRevise -Goal $Goal -PlanJson $planJsonText -ReviseBrief ([string]$pgRes.revise_brief) `
                        -Run $plan -RunDir $RunDir -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath -Dispatcher $Dispatcher
                    if ($PlanGateFailLoud -and [object]::ReferenceEquals($priorPlan, $revisedPlan)) {
                        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Level 'error' -Message 'PLAN GATE DEGRADED — required revise pass failed — no labor will run')
                        return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-gate-degraded')
                    }
                    $plan = $revisedPlan
                    $plan.run_id = $runId
                } else {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'plan-gate' -Message 'revise recommended, auto-revise disabled — proceeding with the original plan')
                }
            }
        }
    }

    # 1.7 Verification preflight (d082 V2): OPT-IN. Freeze every referenced verify
    #     profile from the base revision and validate it BEFORE the walk — an unknown,
    #     missing, or lint-failing contract fails the plan closed (plan-invalid) before
    #     any labor spend. Fail-CLOSED (unlike the advisory gates): a task that demands
    #     verification cannot run without a resolvable oracle. Without -Verify this block
    #     is skipped entirely (default path unchanged).
    if ($Verify -and $VerifyPreflight) {
        $pf = $null
        try { $pf = & $VerifyPreflight $plan }
        catch {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight threw: $($_.Exception.Message)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
        if ($null -ne $pf -and -not $pf.ok) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'verification' -Level 'error' -Message "verification preflight failed: $($pf.reason) — no walk, no spend")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Status 'plan-invalid')
        }
    }

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
        # Verification (d082 V2): announce the sub-lifecycle before labor so the six-kind
        # event contract is literal (review M1). Only for a -Verify run on a task that
        # actually carries a frozen contract — an unprofiled task stays silent here.
        if ($Verify -and [string]$task.verify_profile) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-started' -Message "verifying: $($task.verify_profile)")
        }
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
        # Verification (d082 V2): the verifying spawner attaches a `verification`
        # result and/or an `unverified` mark to $r. Emit the legible event trail and
        # map a verification failure to its own terminal status. When -Verify is off
        # or the task carried no contract, $r has neither key and this is inert.
        if ($Verify -and $r.unverified) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-unverified' -Message "no verification contract — proceeding unverified")
        }
        if ($Verify -and $r.verification) {
            $v = $r.verification
            if ($v.retried) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-retry-started' -Message "verification failed ($($v.first_failure_category)) — one evidence-informed retry")
            }
            if ([string]$v.verdict -eq 'pass') {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-passed' -Message "verified (grade: $($v.grade)) — $($v.proves)")
            }
            elseif ([string]$v.failure_category -in @('scope-violation','protected-path-mutated')) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-scope-violation' -Level 'warn' -Message "scope/oracle violation ($($v.failure_category)) — fail-closed, no retry")
            }
            else {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'task-verification-failed' -Level 'warn' -Message "verification failed ($($v.failure_category))")
            }
        }
        $kind = if ($r.ok) { 'finished' } else { 'error' }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind $kind -Message $task.desc)
        if (-not $r.ok) {
            $failStatus = if ($Verify -and $r.verification -and [string]$r.verification.verdict -ne 'pass') { 'verification-failed' } else { 'failed' }
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $failStatus -PendingTaskId $task.id)
        }
    }
    # 4. Acceptance phase (d058): runs after a successful walk when policy enables it.
    #    Legacy direct callers remain advisory; execute supplies panel + fail-loud.
    $gate = $null
    $finalStatus = 'completed'
    $acceptanceEnabled = if ($PSBoundParameters.ContainsKey('AcceptanceGate')) {
        [bool]$AcceptanceGate
    } else {
        $PSBoundParameters.ContainsKey('GateArtifact') -or
        $PSBoundParameters.ContainsKey('GateDiff') -or
        $null -ne $DiffProvider
    }
    # Slice 2 (d078): a -DiffProvider produces the walk's cumulative diff post-walk;
    # non-empty -> recorded to changes.diff and gated as the artifact. Absent, empty,
    # or throwing (fail-open) -> the existing -GateArtifact/-GateDiff path unchanged.
    $art = ''
    $diffProviderFailed = $false
    if ($DiffProvider) {
        $produced = ''
        try { $produced = [string](& $DiffProvider) }
        catch {
            $diffProviderFailed = $true
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message "diff provider failed (fail-open): $($_.Exception.Message)")
        }
        if (-not [string]::IsNullOrWhiteSpace($produced)) {
            Set-Content -LiteralPath (Join-Path $RunDir 'changes.diff') -Value $produced -Encoding utf8NoBOM
            $art = $produced
        }
    }
    if ([string]::IsNullOrWhiteSpace($art)) { $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff }
    if ($acceptanceEnabled -and -not [string]::IsNullOrWhiteSpace($art)) {
        $gateErr = $null
        try {
            $gate = if ($Gater) { & $Gater $art $plan.goal }
                    else {
                        $gateArgs = @{
                            Artifact = $art
                            Task = $plan.goal
                            MaxCostTier = $MaxCostTier
                            FleetPath = $FleetPath
                            ToolsPath = $ToolsPath
                        }
                        if ($AcceptancePanel) { $gateArgs['Panel'] = $true }
                        if ($AcceptanceFailLoud) { $gateArgs['FailLoud'] = $true }
                        Invoke-AcceptanceGate @gateArgs
                    }
        } catch { $gate = $null; $gateErr = $_.Exception.Message }
        if ($null -eq $gate -or -not $gate.verdict) {
            $msg = if ($gateErr) { "acceptance gate failed: $gateErr" } else { 'acceptance gate produced no verdict (fail-open)' }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message $msg)
            $gate = $null
            if ($AcceptanceFailLoud) { $finalStatus = 'acceptance-degraded' }
        } else {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Message "acceptance verdict: $($gate.verdict) — $($gate.reason)")
            if ($AcceptanceFailLoud -and $gate.degraded) { $finalStatus = 'acceptance-degraded' }
            elseif ($gate.verdict -eq 'reject') { $finalStatus = 'rejected' }
            elseif ($AcceptanceFailLoud -and $gate.verdict -eq 'polish') { $finalStatus = 'needs-polish' }
        }
    }
    if ($acceptanceEnabled -and $AcceptanceFailLoud -and $diffProviderFailed) {
        $finalStatus = 'acceptance-degraded'
    }
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts)
}
