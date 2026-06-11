#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing cascade (Engine Slice B). Cheap draft-eligible candidates draft;
  a frontier finisher takes-and-extends the best draft; a judge-scored good-enough
  draft short-circuits the finisher entirely (zero frontier spend).
.DESCRIPTION
  Dot-sources routing-dispatch.ps1 (which pulls routing-lib -> routing-learn + fleet-lib),
  so Select-Capability, Invoke-RoutedCandidate, and Get-LlmJudgeGrader are in scope.
  See docs/superpowers/specs/2026-06-11-cost-engine-slice-b-cascade-design.md.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-dispatch.ps1"

function Get-CascadeRole {
    <# Effective cascade role for a Select-Capability candidate. Explicit role field
       wins (draft|bulk|finisher; bulk is draft-eligible); unknown/absent values fall
       back to cost-tier inference: paid -> finisher, local/free -> draft (fail-open).
       Explicit-beats-inferred is how cheap-paid (Haiku/Sonnet-class) entries draft. #>
    param([Parameter(Mandatory)]$Candidate)
    switch ([string]$Candidate.role) {
        'draft'    { return 'draft' }
        'bulk'     { return 'draft' }
        'finisher' { return 'finisher' }
    }
    if ($Candidate.cost_tier -eq 'paid') { return 'finisher' }
    return 'draft'
}

function Get-CascadeFinisherPrompt {
    <# Single source of truth for the take-and-extend finisher prompt (test-asserted). #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Draft
    )
    return @"
You are finishing another model's draft. TASK:
$Prompt

DRAFT (may be incomplete or flawed — keep what is good, fix what is not,
extend to fully satisfy the TASK; output ONLY the finished result):
$Draft
"@
}

function Invoke-CapabilityCascade {
    <# Draft -> good-enough gate -> finish. Statuses: draft-sufficient | finished |
       finisher-deferred | no-finisher | no-candidate | escalate-to-conductor.
       frontier_spent is true only when a paid finisher actually dispatched.
       The short-circuit requires an llm-judge verdict: the heuristic grader is binary
       (pass = 1.0) and would skip the finisher on every pass (spec decision 2). #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$DraftCount = 3,
        [double]$GoodEnough = 0.9,
        [switch]$NoShortCircuit,
        [scriptblock]$Grader,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
        [scriptblock]$Dispatcher,
        [int]$Rank = [int]::MinValue,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = Select-Capability @sel
    if (-not $candidates -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; winner=$null
                                  result=$null; draft_attempts=@(); finish_attempt=$null; frontier_spent=$false }
    }

    # Grader: -Grader wins (tests); else judge by default — the short-circuit needs a
    # scored verdict, and Get-LlmJudgeGrader itself falls back to heuristic (tagged so).
    $effGrader = if ($Grader) { $Grader }
                 else { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }

    $drafters  = @($candidates | Where-Object { (Get-CascadeRole $_) -eq 'draft' } | Select-Object -First $DraftCount)
    $finishers = @($candidates | Where-Object { (Get-CascadeRole $_) -eq 'finisher' })

    # Common Invoke-RoutedCandidate args (gate params flow to drafts too: a paid
    # draft-by-explicit-role is still a paid dispatch and gets rank-gated as such).
    $rcCommon = @{
        Capability = $Capability; EffGrader = $effGrader; Dispatcher = $Dispatcher
        TimeoutS = $TimeoutS; ToolsPath = $ToolsPath; FleetPath = $FleetPath; JournalPath = $JournalPath
    }
    if ($Rank -ne [int]::MinValue)                 { $rcCommon['Rank'] = $Rank }
    if ($PrimeHoursConfig)                         { $rcCommon['PrimeHoursConfig'] = $PrimeHoursConfig }
    if ($PSBoundParameters.ContainsKey('GateNow')) { $rcCommon['GateNow'] = $GateNow }

    # ── Draft stage (serial; parallel fan-out is Slice C) ──
    $draftAttempts = [System.Collections.ArrayList]@()
    $best = $null   # @{ attempt; result } — passed beats unpassed, then higher score wins
    foreach ($d in $drafters) {
        $rc = Invoke-RoutedCandidate @rcCommon -Candidate $d -Prompt $Prompt -Stage 'draft'
        [void]$draftAttempts.Add($rc.attempt)
        $better = if ($null -eq $best) { $true }
                  elseif ([bool]$rc.attempt.passed -ne [bool]$best.attempt.passed) { [bool]$rc.attempt.passed }
                  else { $rc.attempt.score -gt $best.attempt.score }
        if ($better) { $best = $rc }
    }

    # ── Short-circuit: judge-scored good-enough draft ships, zero frontier spend ──
    if (-not $NoShortCircuit -and $best -and $best.attempt.passed -and
        $best.attempt.score -ge $GoodEnough -and $best.attempt.grader -eq 'llm-judge') {
        return [pscustomobject]@{ status='draft-sufficient'; capability=$Capability
                                  winner=$best.attempt.candidate; result=$best.result
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$null; frontier_spent=$false }
    }

    # ── Finisher stage ──
    $bestPassedName   = if ($best -and $best.attempt.passed) { $best.attempt.candidate } else { $null }
    $bestPassedResult = if ($best -and $best.attempt.passed) { $best.result } else { $null }
    # Salvage pair for the deferred/escalate paths: spec steps 7-8 return the best
    # USABLE draft (non-empty stdout), passing or not — work is never lost. The
    # no-finisher path stays passing-only (spec step 5 says "best passing draft").
    $bestUsableName   = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { $best.attempt.candidate } else { $null }
    $bestUsableResult = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { $best.result } else { $null }
    if ($finishers.Count -eq 0) {
        return [pscustomobject]@{ status='no-finisher'; capability=$Capability
                                  winner=$bestPassedName; result=$bestPassedResult
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$null; frontier_spent=$false }
    }
    $f = $finishers[0]   # selector order = cheapest capable finisher first
    $draftText = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { [string]$best.result.stdout } else { $null }
    $fPrompt = if ($draftText) { Get-CascadeFinisherPrompt -Prompt $Prompt -Draft $draftText } else { $Prompt }
    $frc = Invoke-RoutedCandidate @rcCommon -Candidate $f -Prompt $fPrompt -Stage 'finish'

    if ($frc.attempt.reason -match '^deferred: prime-hours') {
        # Slice A gate deferred the paid step. Best draft is the provisional result.
        return [pscustomobject]@{ status='finisher-deferred'; capability=$Capability
                                  winner=$bestUsableName; result=$bestUsableResult
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$false }
    }
    $spent = ($f.cost_tier -eq 'paid')   # it dispatched; pass or fail, paid was spent
    # NOTE: frontier_spent tracks the FINISHER only; a paid drafter (explicit role) can
    # spend without setting it — the advisor must read the journal for total paid spend.
    if ($frc.attempt.passed) {
        return [pscustomobject]@{ status='finished'; capability=$Capability
                                  winner=$f.name; result=$frc.result
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$spent }
    }
    return [pscustomobject]@{ status='escalate-to-conductor'; capability=$Capability
                              winner=$null; result=$bestUsableResult
                              draft_attempts=$draftAttempts.ToArray(); finish_attempt=$frc.attempt; frontier_spent=$spent }
}
