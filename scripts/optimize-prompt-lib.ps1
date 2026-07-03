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
. "$PSScriptRoot/prompt-pool-lib.ps1"

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

# Offline-eval stand-in for the production plan schema. Both sides of every
# head-to-head are hydrated with the SAME text, so the judge's A/B comparison
# stays fair even though this is not byte-identical to conductor-lib's live
# schema (kept decoupled on purpose — sourcing conductor-lib here would drag
# in the whole run engine).
$script:MinibatchPlanSchema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "tasks": [
    { "id": "<unique>", "desc": "<what>", "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
'@

function Build-HydratedPlannerPrompt {
    <# Literal [string]::Replace — never regex: goals are untrusted user text
       and '$1'/'$&' in a regex replacement would corrupt the prompt. #>
    param([Parameter(Mandatory)][string]$Template, [Parameter(Mandatory)][string]$Goal)
    $evi = 'Tools already wired locally: (none - offline evaluation)'
    return $Template.Replace('{{schema}}', $script:MinibatchPlanSchema).Replace('{{evi}}', $evi).Replace('{{Goal}}', $Goal)
}

function Build-JudgePrompt {
    param(
        [Parameter(Mandatory)][hashtable]$Run,
        [Parameter(Mandatory)][string]$PlanA,
        [Parameter(Mandatory)][string]$PlanB
    )
    $brief = if ($Run.polish_brief) { "Polish brief:`n$($Run.polish_brief)" } else { '' }
    return @"
You are judging two candidate task plans produced for the same goal by an autonomous software agent.
This goal previously FAILED its acceptance gate; the recorded feedback below tells you what a better plan must address.

## Goal
$($Run.goal)

## Acceptance-gate feedback from the failed run
Verdict: $($Run.verdict)
Reason: $($Run.reason)
Findings: $($Run.findings)
$brief

## Plan A
$PlanA

## Plan B
$PlanB

Which plan better addresses the recorded feedback (avoids the same failures, tighter scope, correct ordering)?
Answer with EXACTLY one of A, B, or tie inside a <verdict> tag, e.g. <verdict>A</verdict>. No other output.
"@
}

function Invoke-MinibatchEval {
    <# Head-to-head: candidate vs reference prompt over historical gated runs
       (plan-only generation — no execution). Position bias is cancelled by
       swapping which side is "A" per example. A judge reply without a
       parseable <verdict>, or a failed plan generation, drops the example
       (counted in `dropped`). win_rate = wins/(wins+losses), ties excluded;
       null when nothing scoreable (= "no evidence" upstream). #>
    param(
        [Parameter(Mandatory)][string]$CandidatePrompt,
        [Parameter(Mandatory)][string]$ReferencePrompt,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Runs,
        [Parameter(Mandatory)][scriptblock]$PlanDispatcher,
        [Parameter(Mandatory)][scriptblock]$JudgeDispatcher
    )
    $wins = 0; $losses = 0; $ties = 0; $dropped = 0
    $examples = [System.Collections.ArrayList]@()
    $i = 0
    foreach ($run in @($Runs)) {
        $candIsA = (($i % 2) -eq 0)
        $i++
        $candRes = & $PlanDispatcher (Build-HydratedPlannerPrompt -Template $CandidatePrompt -Goal ([string]$run.goal))
        $refRes = & $PlanDispatcher (Build-HydratedPlannerPrompt -Template $ReferencePrompt -Goal ([string]$run.goal))
        if ((([int]$candRes.exit_code) -ne 0) -or (([int]$refRes.exit_code) -ne 0)) { $dropped++; continue }
        $planA = if ($candIsA) { [string]$candRes.stdout } else { [string]$refRes.stdout }
        $planB = if ($candIsA) { [string]$refRes.stdout } else { [string]$candRes.stdout }
        $judgeRes = & $JudgeDispatcher (Build-JudgePrompt -Run $run -PlanA $planA -PlanB $planB)
        $verdict = $null
        if ((([int]$judgeRes.exit_code) -eq 0) -and (([string]$judgeRes.stdout) -match '<verdict>\s*(A|B|tie)\s*</verdict>')) {
            $verdict = $Matches[1]
        }
        if ($null -eq $verdict) { $dropped++; continue }
        if ($verdict -eq 'tie') {
            $ties++
        } elseif ((($verdict -eq 'A') -and $candIsA) -or (($verdict -eq 'B') -and (-not $candIsA))) {
            $wins++
        } else {
            $losses++
        }
        [void]$examples.Add(@{
            run_id = [string]$run.run_id
            candidate_was = $(if ($candIsA) { 'A' } else { 'B' })
            verdict = $verdict
        })
    }
    $winRate = $null
    if (($wins + $losses) -gt 0) { $winRate = [math]::Round($wins / [double]($wins + $losses), 4) }
    return @{ wins = $wins; losses = $losses; ties = $ties; dropped = $dropped; win_rate = $winRate; examples = @($examples) }
}

function Build-DiagnosisPrompt {
    <# Reflection half of the two-model split: the cheap-side model diagnoses
       WHY the parent prompt produced gate-failing plans. Consumes the gate's
       findings/polish briefs (the ASI channel) plus the fates of prior
       candidates so the loop does not repeat dead mutations. #>
    param(
        [Parameter(Mandatory)][array]$HistoricalRuns,
        [Parameter(Mandatory)][string]$ParentPrompt,
        [array]$PriorFates = @()
    )
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
    $fatesStr = if (@($PriorFates).Count -gt 0) {
        "Earlier mutation attempts and why they were retired (do not repeat these mistakes):`n" +
        ((@($PriorFates) | ForEach-Object { "- $_" }) -join "`n")
    } else { '(no earlier mutation attempts)' }
    return @"
You are the reflection stage of a prompt-optimization loop (GEPA) for an autonomous software agent.
The prompt under study is the "Conductor Planner Prompt", which decomposes a GOAL into an ordered task DAG.

Below are recent runs where plans produced by this prompt failed or required polish, with the acceptance-gate feedback.
$historyStr
$fatesStr

CURRENT PROMPT UNDER STUDY:
<current_prompt>
$ParentPrompt
</current_prompt>

Diagnose, in plain language, WHY this prompt produced plans that drew this feedback: which instructions are missing,
ambiguous, or misprioritized. Do NOT write a new prompt. Output your diagnosis inside a <diagnosis> XML block.
"@
}

function Build-MutationPrompt {
    <# Mutation half: the stronger model rewrites the prompt from the
       diagnosis. Placeholder preservation is instructed here AND enforced
       mechanically by the caller. #>
    param([Parameter(Mandatory)][string]$Diagnosis, [Parameter(Mandatory)][string]$ParentPrompt)
    return @"
You are the mutation stage of a prompt-optimization loop (GEPA) for an autonomous software agent.
A reflection model diagnosed the weaknesses of the current "Conductor Planner Prompt":

<diagnosis>
$Diagnosis
</diagnosis>

CURRENT PROMPT:
<current_prompt>
$ParentPrompt
</current_prompt>

Rewrite the prompt to fix the diagnosed weaknesses. Requirements:
1. KEEP the placeholders {{schema}}, {{evi}}, and {{Goal}} exactly as they are.
2. Keep it concise — do not pad; every added instruction must earn its tokens.
3. Output the complete new prompt inside a <new_prompt> XML block, and nothing else that could be confused with it.
"@
}

function Get-DefaultReflectTier {
    <# Reflection defaults one tier below mutation (spec). #>
    param([Parameter(Mandatory)][string]$MaxCostTier)
    switch ($MaxCostTier) {
        'paid' { return 'free' }
        'free' { return 'local' }
        default { return 'local' }
    }
}

function Invoke-TierRoutedModel {
    <# Default (non-seamed) dispatch: cheapest reasoning-capable worker within
       the tier, via the existing fleet routing. Same result contract as the
       dispatcher seams: @{ stdout; exit_code }. #>
    param(
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$Tier,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$FleetPath,
        [Parameter(Mandatory)][string]$ToolsPath
    )
    $cands = Select-Capability -Capability reasoning -MaxCostTier $Tier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if (($null -eq $cands) -or (@($cands | Where-Object { $null -ne $_ }).Count -lt 1)) {
        return @{ stdout = ''; exit_code = 1 }
    }
    return (Invoke-Fleet -Name @($cands)[0].name -Prompt $Prompt -Path $FleetPath -NoJournal)
}

function Invoke-PromptEvolution {
    <#
    .SYNOPSIS
      One or more GEPA generations: select -> reflect -> mutate -> evaluate ->
      dual gate. Replaces the v1 single-shot Invoke-PromptOptimizer
      (-Generations 1 on an empty pool reproduces its observable behavior).
    .DESCRIPTION
      Default: gate survivors are recorded in the pool as 'candidate' and the
      latest survivor is written to conductor-planner.candidate.txt for human
      review — the live prompt is never touched. -Apply: promotes the latest
      survivor (timestamped .bak of the live prompt, champion swap in the
      pool, other actives marked stale for re-evaluation). Every model call
      fail-opens to "no proposal this generation" with an honest reason; the
      manifest is saved once per generation, never mid-flight.
    .NOTES
      Returns @{ success; applied; candidate_path; reason; generations; rescored }.
      rescored = @(@{ id; win_rate }, …) for any stale actives re-scored vs
      the current champion at run start (empty array when none were stale).
      Seams: -ReflectDispatcher/-MutateDispatcher/-PlanDispatcher/
      -JudgeDispatcher (contract: param($prompt) -> @{ stdout; exit_code }),
      -Draw (parent-selection randomness).
    #>
    param(
        [int]$MaxRuns = 5,
        [int]$Generations = 1,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [ValidateSet('local','free','paid')][string]$ReflectTier,
        [double]$LengthCapMultiplier = 2.0,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$PromptPath = $(
            $p = Join-Path $PSScriptRoot '../prompts/conductor-planner.txt'
            if (Test-Path $p) { $p } else { Join-Path (Get-BatonHome) 'prompts/conductor-planner.txt' }
        ),
        [string]$PoolDir = (Get-PromptPoolDir),
        [switch]$Apply,
        [scriptblock]$ReflectDispatcher,
        [scriptblock]$MutateDispatcher,
        [scriptblock]$PlanDispatcher,
        [scriptblock]$JudgeDispatcher,
        [scriptblock]$Draw
    )
    if (-not $ReflectTier) { $ReflectTier = Get-DefaultReflectTier -MaxCostTier $MaxCostTier }
    $requiredPlaceholders = @('{{schema}}', '{{evi}}', '{{Goal}}')
    $rescored = [System.Collections.ArrayList]@()
    $fail = { param($reason, $gens)
        @{ success = $false; applied = $false; candidate_path = $null; reason = $reason; generations = @($gens); rescored = @($rescored) }
    }

    # -- pool: load, seed if absent, refuse if corrupt --
    $loaded = Get-PromptPool -PoolDir $PoolDir
    if (-not $loaded.ok) {
        if ($loaded.reason -eq 'absent') {
            $loaded = Initialize-PromptPool -SeedPromptPath $PromptPath -PoolDir $PoolDir
            if (-not $loaded.ok) {
                [Console]::Error.WriteLine("optimize-prompt: $($loaded.reason)")
                return (& $fail $loaded.reason @())
            }
            Write-Host "Pool seeded from live prompt ($PromptPath) as p001/champion."
        } else {
            [Console]::Error.WriteLine("optimize-prompt: $($loaded.reason) — refusing to run.")
            return (& $fail $loaded.reason @())
        }
    }
    $pool = $loaded.pool

    $runs = Get-HistoricalRuns -MaxRuns $MaxRuns
    if (@($runs).Count -eq 0) {
        Write-Host "No historical runs requiring polish or reject found."
        return (& $fail 'no historical runs requiring polish or reject' @())
    }

    # Default live dispatchers (any seam overrides its stage).
    if (-not $ReflectDispatcher) { $ReflectDispatcher = { param($p) Invoke-TierRoutedModel -Tier $ReflectTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $MutateDispatcher) { $MutateDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $PlanDispatcher) { $PlanDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }
    if (-not $JudgeDispatcher) { $JudgeDispatcher = { param($p) Invoke-TierRoutedModel -Tier $MaxCostTier -Prompt $p -FleetPath $FleetPath -ToolsPath $ToolsPath }.GetNewClosure() }

    # -- v1.7.1: re-score stale actives (win rate nulled by a champion swap)
    # against the CURRENT champion before evolving. Spend happens only inside
    # this explicit run; the /baton:go path never re-scores. --
    $staleActives = @($pool.candidates | Where-Object {
        ($_.status -eq 'candidate') -and ($null -eq $_.offline.minibatch.win_rate_vs_champion)
    })
    if (@($staleActives).Count -gt 0) {
        $champRescoreRec = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0]
        $champRescoreText = $null
        try { $champRescoreText = Get-Content -Raw -LiteralPath (Join-Path $PoolDir ([string]$champRescoreRec.file)) -ErrorAction Stop } catch { $champRescoreText = $null }
        if ([string]::IsNullOrEmpty($champRescoreText)) {
            [Console]::Error.WriteLine("optimize-prompt: re-score skipped — champion file unreadable; stale candidates stay stale.")
            $staleActives = @()
        }
        foreach ($sc in $staleActives) {
            $scText = $null
            try { $scText = Get-Content -Raw -LiteralPath (Join-Path $PoolDir ([string]$sc.file)) -ErrorAction Stop } catch { $scText = $null }
            if ([string]::IsNullOrEmpty($scText)) {
                [Console]::Error.WriteLine("optimize-prompt: re-score skipped for $($sc.id) — candidate file unreadable.")
                continue
            }
            $mb = Invoke-MinibatchEval -CandidatePrompt $scText -ReferencePrompt $champRescoreText `
                -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher
            $sc.offline.minibatch = @{
                wins = $mb.wins; losses = $mb.losses; ties = $mb.ties
                win_rate_vs_champion = $mb.win_rate; examples = @($mb.examples)
            }
            [void]$rescored.Add(@{ id = [string]$sc.id; win_rate = $mb.win_rate })
            $wrNote = if ($null -ne $mb.win_rate) { $mb.win_rate } else { 'no evidence (stays stale)' }
            Write-Host "Re-scored $($sc.id) vs champion $($pool.champion): $wrNote"
        }
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
    }

    $seedRec = @($pool.candidates | Where-Object { $_.origin -eq 'seed' })
    $seedTokens = if (@($seedRec).Count -gt 0) { [int]$seedRec[0].offline.prompt_tokens }
                  else { [int]@($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0].offline.prompt_tokens }
    $lengthCap = [int][math]::Ceiling($LengthCapMultiplier * $seedTokens)

    $lastSurvivor = $null
    $genRecords = [System.Collections.ArrayList]@()
    for ($g = 1; $g -le $Generations; $g++) {
        $genRec = @{ generation = $g; parent = $null; child = $null; pass = $false; reasons = @(); win_rate_vs_champion = $null; win_rate_vs_parent = $null }
        [void]$genRecords.Add($genRec)

        $selectParams = @{ Pool = $pool }
        if ($Draw) { $selectParams.Draw = $Draw }
        $parent = Select-ParentCandidate @selectParams
        $parent.offline.times_selected = ([int]$parent.offline.times_selected) + 1
        $genRec.parent = [string]$parent.id
        $parentText = Get-Content -Raw (Join-Path $PoolDir ([string]$parent.file))
        Write-Host "Generation ${g}: parent $($parent.id) selected."

        $fates = @($pool.candidates | Where-Object { $_.status -eq 'retired' } |
            ForEach-Object { "$($_.id) retired: $($_.retired_reason)" })

        # -- reflect --
        $diagRes = & $ReflectDispatcher (Build-DiagnosisPrompt -HistoricalRuns @($runs) -ParentPrompt $parentText -PriorFates $fates)
        $diag = $null
        if ((([int]$diagRes.exit_code) -eq 0) -and (([string]$diagRes.stdout) -match '(?s)<diagnosis>(.*?)</diagnosis>')) {
            $diag = $Matches[1].Trim()
        }
        if ([string]::IsNullOrWhiteSpace($diag)) {
            $genRec.reasons = @('reflection failed (no <diagnosis> block)')
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: reflection failed — no proposal this generation.")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- mutate --
        $mutRes = & $MutateDispatcher (Build-MutationPrompt -Diagnosis $diag -ParentPrompt $parentText)
        $childText = $null
        if (([int]$mutRes.exit_code) -eq 0) {
            $raw = [string]$mutRes.stdout
            $open = $raw.IndexOf('<new_prompt>')
            $close = $raw.LastIndexOf('</new_prompt>')
            if (($open -ge 0) -and ($close -gt $open)) {
                $childText = $raw.Substring($open + '<new_prompt>'.Length, $close - $open - '<new_prompt>'.Length).Trim()
            }
        }
        if ([string]::IsNullOrWhiteSpace($childText)) {
            $genRec.reasons = @('mutation failed (no <new_prompt> block)')
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: mutation failed — no proposal this generation.")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- mechanical rejection: placeholders + length cap (recorded as retired) --
        $childId = Get-NextCandidateId -Pool $pool
        $childTokens = Get-PromptTokenEstimate -Text $childText
        $missing = @($requiredPlaceholders | Where-Object { -not $childText.Contains($_) })
        $mechReason = $null
        if (@($missing).Count -gt 0) { $mechReason = "mutation missing placeholder(s): $($missing -join ', ')" }
        elseif ($childTokens -gt $lengthCap) { $mechReason = "length cap exceeded ($childTokens tokens > cap $lengthCap = ${LengthCapMultiplier}x seed $seedTokens)" }
        if ($mechReason) {
            $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'candidate' -PromptTokens $childTokens
            Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
            $pool.candidates = @($pool.candidates) + @($child)
            [void](Set-CandidateRetired -Pool $pool -Id $childId -Reason $mechReason)
            $genRec.child = $childId
            $genRec.reasons = @($mechReason)
            [Console]::Error.WriteLine("optimize-prompt: generation ${g}: $mechReason")
            Save-PromptPool -Pool $pool -PoolDir $PoolDir
            continue
        }

        # -- evaluate (minibatch): always vs champion; vs parent too when distinct --
        $championRec = @($pool.candidates | Where-Object { $_.id -eq $pool.champion })[0]
        $championText = Get-Content -Raw (Join-Path $PoolDir ([string]$championRec.file))
        $mbChampion = Invoke-MinibatchEval -CandidatePrompt $childText -ReferencePrompt $championText `
            -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher
        $wrVsParent = if ($parent.id -eq $pool.champion) { $mbChampion.win_rate }
        else {
            (Invoke-MinibatchEval -CandidatePrompt $childText -ReferencePrompt $parentText `
                -Runs @($runs) -PlanDispatcher $PlanDispatcher -JudgeDispatcher $JudgeDispatcher).win_rate
        }
        $genRec.win_rate_vs_champion = $mbChampion.win_rate
        $genRec.win_rate_vs_parent = $wrVsParent

        # -- record child + dual gate --
        $child = New-PoolCandidateRecord -Id $childId -Parent ([string]$parent.id) -Origin 'mutation' -Status 'candidate' -PromptTokens $childTokens
        $child.offline.minibatch = @{
            wins = $mbChampion.wins; losses = $mbChampion.losses; ties = $mbChampion.ties
            win_rate_vs_champion = $mbChampion.win_rate; examples = @($mbChampion.examples)
        }
        $gate = Test-DualGate -Child $child -WinRateVsParent $wrVsParent -Pool $pool
        Set-Content -LiteralPath (Join-Path $PoolDir "$childId.txt") -Value $childText -Encoding utf8NoBOM
        $genRec.child = $childId
        $genRec.pass = $gate.pass
        $genRec.reasons = @($gate.reasons)
        $pool.candidates = @($pool.candidates) + @($child)
        if ($gate.pass) {
            $lastSurvivor = $child
            Write-Host "Generation ${g}: $childId SURVIVED the dual gate (vs champion: $($mbChampion.win_rate), vs parent: $wrVsParent)."
        } else {
            [void](Set-CandidateRetired -Pool $pool -Id $childId -Reason (@($gate.reasons) -join '; '))
            Write-Host "Generation ${g}: $childId retired — $($child.retired_reason)."
        }
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
    }

    if ($null -eq $lastSurvivor) {
        return (& $fail 'no candidate survived the dual gate' $genRecords)
    }
    $survivorText = Get-Content -Raw (Join-Path $PoolDir ([string]$lastSurvivor.file))

    if ($Apply) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupPath = "$PromptPath.bak-$stamp"
        if (Test-Path $PromptPath) { Copy-Item -LiteralPath $PromptPath -Destination $backupPath -Force }
        Set-Content -LiteralPath $PromptPath -Value $survivorText -Encoding utf8NoBOM
        [void](Set-CandidateRetired -Pool $pool -Id ([string]$pool.champion) -Reason 'superseded' -By ([string]$lastSurvivor.id))
        foreach ($c in @($pool.candidates)) {
            if (($c.status -eq 'candidate') -and ($c.id -ne $lastSurvivor.id)) {
                # Scores were measured against the OLD champion: mark stale
                # (excluded from the Pareto front until re-evaluated).
                $c.offline.minibatch.win_rate_vs_champion = $null
            }
        }
        $lastSurvivor.status = 'champion'
        $lastSurvivor.offline.minibatch.win_rate_vs_champion = 0.5
        $pool.champion = [string]$lastSurvivor.id
        Save-PromptPool -Pool $pool -PoolDir $PoolDir
        Write-Host "Applied: $($lastSurvivor.id) promoted to champion; live prompt deployed to $PromptPath (backup: $backupPath)."
        return @{ success = $true; applied = $true; candidate_path = $null; reason = "applied $($lastSurvivor.id) to live prompt"; generations = @($genRecords); rescored = @($rescored) }
    }

    $candidatePath = Join-Path (Split-Path -Parent $PromptPath) 'conductor-planner.candidate.txt'
    Set-Content -LiteralPath $candidatePath -Value $survivorText -Encoding utf8NoBOM
    Write-Host "Proposed candidate $($lastSurvivor.id) written to $candidatePath for review. Live prompt untouched."
    return @{ success = $true; applied = $false; candidate_path = $candidatePath; reason = "candidate $($lastSurvivor.id) proposed for review"; generations = @($genRecords); rescored = @($rescored) }
}
