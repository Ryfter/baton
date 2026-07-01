#!/usr/bin/env pwsh
<#
.SYNOPSIS
  GEPA-inspired prompt optimization engine for Baton.
.DESCRIPTION
  Analyzes historical runs with "reject" or "polish" verdicts and uses natural
  language reflection to propose — and, opt-in, deploy — a mutated planner
  prompt.
.NOTES
  House trap: under $ErrorActionPreference = 'Stop', Write-Error THROWS, so
  code after it never runs and the function can't return its result to the
  caller. This lib logs failures via [Console]::Error.WriteLine(...) instead.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"
. "$PSScriptRoot/fleet-lib.ps1"

function Get-HistoricalRuns {
    <# Most-recent-first scan of BATON_HOME/runs for reject/polish-verdict runs.
       Guards the unary-comma empty-wrapper trap: `,([array]$x)` on an EMPTY
       array wraps it as a 1-element array containing an empty array (Count=1,
       not 0), so the no-results path returns a plain @() instead. #>
    param([int]$MaxRuns = 5, [string]$Root = (Join-Path (Get-BatonHome) 'runs'))
    if (-not (Test-Path $Root)) { return @() }

    $runs = Get-ChildItem -Directory $Root | Sort-Object CreationTime -Descending
    $results = [System.Collections.ArrayList]@()
    foreach ($run in $runs) {
        $accPath = Join-Path $run.FullName 'acceptance.json'
        $planPath = Join-Path $run.FullName 'plan.json'
        if ((Test-Path $accPath) -and (Test-Path $planPath)) {
            $acc = Get-Content -Raw $accPath | ConvertFrom-Json
            if ($acc.verdict -match 'reject|polish') {
                $plan = Get-Content -Raw $planPath | ConvertFrom-Json
                [void]$results.Add(@{
                    run_id = $run.Name
                    goal = $plan.goal
                    plan_tasks = ($plan.tasks | ConvertTo-Json -Compress)
                    verdict = $acc.verdict
                    reason = $acc.reason
                    findings = ($acc.counts | ConvertTo-Json -Compress)
                    polish_brief = $acc.polish_brief
                })
                if ($results.Count -ge $MaxRuns) { break }
            }
        }
    }
    if ($results.Count -eq 0) { return @() }
    return ,([array]$results)
}

function Build-ReflectionPrompt {
    param([Parameter(Mandatory)][array]$HistoricalRuns, [Parameter(Mandatory)][string]$CurrentPrompt)

    $historyStr = ""
    foreach ($r in $HistoricalRuns) {
        $historyStr += "--- RUN: $($r.run_id) ---`n"
        $historyStr += "Goal: $($r.goal)`n"
        $historyStr += "Generated Plan (Tasks): $($r.plan_tasks)`n"
        $historyStr += "Acceptance Verdict: $($r.verdict)`n"
        $historyStr += "Reason: $($r.reason)`n"
        $historyStr += "Findings: $($r.findings)`n"
        if ($r.polish_brief) { $historyStr += "Polish Brief:`n$($r.polish_brief)`n" }
        $historyStr += "`n"
    }

    return @"
You are a prompt optimization engineer (GEPA optimizer) for an autonomous software agent.
Your objective is to improve the "Conductor Planner Prompt", which is responsible for decomposing a GOAL into an ordered task DAG.

Below are recent runs where the agent failed or required polish, along with the feedback from the Acceptance Gate.
$historyStr

CURRENT PROMPT:
<current_prompt>
$CurrentPrompt
</current_prompt>

INSTRUCTIONS:
1. Reflect on the failures in the historical runs. Identify where the current prompt failed to enforce constraints or generated sub-optimal plans.
2. Output a newly mutated, improved prompt. Ensure that you KEEP the placeholders {{schema}}, {{evi}}, and {{Goal}} exactly as they are in the new prompt.
3. Your output MUST contain the new prompt inside a <new_prompt> XML block.
4. Do not output anything outside of the <new_prompt> block that could be confused with the prompt itself.
"@
}

function Invoke-PromptOptimizer {
    <#
    .SYNOPSIS
      GEPA reflection loop: propose (default) or apply (-Apply) a mutated
      planner prompt based on recent reject/polish-verdict runs.
    .DESCRIPTION
      Default (no -Apply): writes the mutated prompt to a sibling
      conductor-planner.candidate.txt file for human review. The live prompt
      is never touched.
      -Apply: validates the mutation contains all three literal placeholders
      ({{schema}}, {{evi}}, {{Goal}}) — the same gate that guards the default
      candidate write, since an invalid candidate is useless either way. If
      any placeholder is missing, nothing is written and success=false. If
      valid, backs up the current live prompt to
      <PromptPath>.bak-<yyyyMMdd-HHmmss> beside it, then overwrites the live
      copy.
    .NOTES
      Returns @{ success; applied; candidate_path; reason }.
      -Dispatcher is a test seam: when supplied, Select-Capability/Invoke-Fleet
      are skipped entirely and `& $Dispatcher $optPrompt` is called instead,
      expected to return @{ stdout=...; exit_code=... }.
    #>
    param(
        [int]$MaxRuns = 5,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$PromptPath = $(
            $p = Join-Path $PSScriptRoot '../prompts/conductor-planner.txt'
            if (Test-Path $p) { $p } else { Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt' }
        ),
        [switch]$Apply,
        [scriptblock]$Dispatcher
    )
    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')

    $runs = Get-HistoricalRuns -MaxRuns $MaxRuns
    if (@($runs).Count -eq 0) {
        Write-Host "No historical runs requiring polish or reject found."
        return @{ success = $false; applied = $false; candidate_path = $null; reason = 'no historical runs requiring polish or reject' }
    }

    Write-Host "Found $(@($runs).Count) runs for optimization. Building reflection prompt..."
    $currentPrompt = Get-Content -Raw $PromptPath
    $optPrompt = Build-ReflectionPrompt -HistoricalRuns $runs -CurrentPrompt $currentPrompt

    if ($Dispatcher) {
        $res = & $Dispatcher $optPrompt
    } else {
        $cands = Select-Capability -Capability reasoning -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
            [Console]::Error.WriteLine("optimize-prompt: no capability candidates found.")
            return @{ success = $false; applied = $false; candidate_path = $null; reason = 'no capability candidates found' }
        }
        $pick = $cands[0]
        Write-Host "Routing optimization to $($pick.name)..."
        $res = Invoke-Fleet -Name $pick.name -Prompt $optPrompt -Path $FleetPath -NoJournal
    }

    if ([int]$res.exit_code -ne 0) {
        [Console]::Error.WriteLine("optimize-prompt: optimization request failed (exit $([int]$res.exit_code)).")
        return @{ success = $false; applied = $false; candidate_path = $null; reason = 'optimization request failed' }
    }

    $raw = [string]$res.stdout
    $open = $raw.IndexOf('<new_prompt>')
    $close = $raw.LastIndexOf('</new_prompt>')
    if ($open -lt 0 -or $close -le $open) {
        [Console]::Error.WriteLine("optimize-prompt: could not find <new_prompt> tags in model output.")
        return @{ success = $false; applied = $false; candidate_path = $null; reason = 'no <new_prompt> tags in model output' }
    }
    $start = $open + '<new_prompt>'.Length
    $newPrompt = $raw.Substring($start, $close - $start).Trim()

    $missing = @($requiredPlaceholders | Where-Object { -not $newPrompt.Contains($_) })
    if (@($missing).Count -gt 0) {
        [Console]::Error.WriteLine("optimize-prompt: mutated prompt is missing placeholder(s): $($missing -join ', ').")
        return @{ success = $false; applied = $false; candidate_path = $null; reason = "mutation missing placeholder(s): $($missing -join ', ')" }
    }

    if ($Apply) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupPath = "$PromptPath.bak-$stamp"
        if (Test-Path $PromptPath) { Copy-Item -LiteralPath $PromptPath -Destination $backupPath -Force }
        Set-Content -LiteralPath $PromptPath -Value $newPrompt -Encoding utf8NoBOM
        Write-Host "Applied: live prompt deployed to $PromptPath (backup: $backupPath)."
        return @{ success = $true; applied = $true; candidate_path = $null; reason = 'applied to live prompt' }
    }

    $candidatePath = Join-Path (Split-Path -Parent $PromptPath) 'conductor-planner.candidate.txt'
    Set-Content -LiteralPath $candidatePath -Value $newPrompt -Encoding utf8NoBOM
    Write-Host "Proposed candidate written to $candidatePath for review. Live prompt untouched."
    return @{ success = $true; applied = $false; candidate_path = $candidatePath; reason = 'candidate proposed for review' }
}
