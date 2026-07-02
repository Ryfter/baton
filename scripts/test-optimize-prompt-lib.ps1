#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for GEPA-inspired optimize-prompt-lib.ps1 (house Check/PASS-FAIL
  style — Pester failures don't propagate exit codes reliably here; this
  suite is exit-code gated).
.DESCRIPTION
  Hermetic: temp BATON_HOME, temp runs dirs, temp prompt files; never reads
  or writes the real ~/.claude or ~/.baton.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'optimize-prompt-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("opt-lib-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

$prevBatonHome = $env:BATON_HOME
try {
    # ---- Get-HistoricalRuns: nonexistent root -> empty ----
    $emptyRunsRoot = Join-Path (New-TempDir) 'nonexistent'
    $runsEmpty = Get-HistoricalRuns -Root $emptyRunsRoot
    Check 'O1 nonexistent root -> empty array (Count 0)' (@($runsEmpty).Count -eq 0)

    # ---- Get-HistoricalRuns: root EXISTS but has no qualifying runs ----
    # Guards the unary-comma empty-wrapper trap: `,([array]$x)` on an empty
    # array wraps it as a 1-element array containing an empty array.
    $noQualifyRoot = New-TempDir
    $runNoQ = Join-Path $noQualifyRoot 'go-clean'
    New-Item -ItemType Directory -Force -Path $runNoQ | Out-Null
    @{ goal = 'G'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $runNoQ 'plan.json')
    @{ verdict = 'accept' } | ConvertTo-Json | Set-Content (Join-Path $runNoQ 'acceptance.json')
    $runsNoQ = Get-HistoricalRuns -Root $noQualifyRoot
    Check 'O2 root exists, no qualifying runs -> Count is 0, not 1' (@($runsNoQ).Count -eq 0)

    # ---- Get-HistoricalRuns: populated ----
    $popRoot = New-TempDir
    $run1 = Join-Path $popRoot 'go-1'
    New-Item -ItemType Directory -Force -Path $run1 | Out-Null
    @{ goal = 'G1'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $run1 'plan.json')
    @{ verdict = 'reject'; reason = 'R1'; counts = @{ critical = 1 }; polish_brief = 'P1' } | ConvertTo-Json | Set-Content (Join-Path $run1 'acceptance.json')
    $run2 = Join-Path $popRoot 'go-2'
    New-Item -ItemType Directory -Force -Path $run2 | Out-Null
    @{ goal = 'G2'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $run2 'plan.json')
    @{ verdict = 'accept' } | ConvertTo-Json | Set-Content (Join-Path $run2 'acceptance.json')
    $runsPop = Get-HistoricalRuns -Root $popRoot
    Check 'O3 populated root returns only reject/polish runs' (@($runsPop).Count -eq 1)
    Check 'O4 returned run has the right id' ($runsPop[0].run_id -eq 'go-1')
    Check 'O5 returned run carries the verdict' ($runsPop[0].verdict -eq 'reject')

    # ==== M-series: minibatch evaluator ====
    $mbRuns = @(
        @{ run_id = 'go-1'; goal = 'Goal one'; verdict = 'reject'; reason = 'R1'; findings = '{}'; polish_brief = 'P1' },
        @{ run_id = 'go-2'; goal = 'Goal two'; verdict = 'polish'; reason = 'R2'; findings = '{}'; polish_brief = $null }
    )

    # Hydration is literal (injection-safe) and total.
    $hyd = Build-HydratedPlannerPrompt -Template 'T {{schema}} | {{evi}} | {{Goal}}' -Goal 'costs $1 and $$'
    Check 'M1 hydration replaces Goal literally (no regex corruption)' ($hyd -match [regex]::Escape('costs $1 and $$'))
    Check 'M2 hydration removes all placeholders' (-not ($hyd -match '\{\{(schema|evi|Goal)\}\}'))

    $jp = Build-JudgePrompt -Run $mbRuns[0] -PlanA 'PLAN_A_TEXT' -PlanB 'PLAN_B_TEXT'
    Check 'M3 judge prompt carries goal, feedback, both plans, verdict tag' (
        ($jp -match 'Goal one') -and ($jp -match 'R1') -and ($jp -match 'PLAN_A_TEXT') -and
        ($jp -match 'PLAN_B_TEXT') -and ($jp -match '<verdict>')
    )

    # Plan dispatcher echoes its prompt so the judge stub can tell sides apart.
    $echoPlan = { param($p) @{ stdout = $p; exit_code = 0 } }

    # Judge stub: verdict goes to whichever side's plan contains CAND_MARK.
    $judgeCand = { param($p)
        $aIdx = $p.IndexOf('## Plan A'); $bIdx = $p.IndexOf('## Plan B')
        $aTxt = $p.Substring($aIdx, $bIdx - $aIdx)
        $v = if ($aTxt.Contains('CAND_MARK')) { 'A' } else { 'B' }
        @{ stdout = "<verdict>$v</verdict>"; exit_code = 0 }
    }
    $mb1 = Invoke-MinibatchEval -CandidatePrompt 'CAND_MARK {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'REF {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeCand
    Check 'M4 candidate-favoring judge -> win rate 1 across position swap' (
        ($mb1.wins -eq 2) -and ($mb1.losses -eq 0) -and (([double]$mb1.win_rate) -eq 1.0)
    )

    # Position-bias probe: a judge that ALWAYS answers A splits with the swap.
    $judgeAlwaysA = { param($p) @{ stdout = '<verdict>A</verdict>'; exit_code = 0 } }
    $mb2 = Invoke-MinibatchEval -CandidatePrompt 'CAND_MARK {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'REF {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeAlwaysA
    Check 'M5 position swap cancels an always-A judge (1 win, 1 loss)' (
        ($mb2.wins -eq 1) -and ($mb2.losses -eq 1) -and (([double]$mb2.win_rate) -eq 0.5)
    )

    $judgeTie = { param($p) @{ stdout = '<verdict>tie</verdict>'; exit_code = 0 } }
    $mb3 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeTie
    Check 'M6 all ties -> win_rate null, ties counted' (($null -eq $mb3.win_rate) -and ($mb3.ties -eq 2))

    $judgeGarbage = { param($p) @{ stdout = 'no tag here'; exit_code = 0 } }
    $mb4 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $echoPlan -JudgeDispatcher $judgeGarbage
    Check 'M7 unparseable judge output -> examples dropped and counted' (($mb4.dropped -eq 2) -and ($null -eq $mb4.win_rate))

    $planFail = { param($p) @{ stdout = ''; exit_code = 1 } }
    $mb5 = Invoke-MinibatchEval -CandidatePrompt 'C {{schema}} {{evi}} {{Goal}}' `
        -ReferencePrompt 'R {{schema}} {{evi}} {{Goal}}' -Runs $mbRuns `
        -PlanDispatcher $planFail -JudgeDispatcher $judgeTie
    Check 'M8 failed plan generation -> example dropped' ($mb5.dropped -eq 2)

    # ==== E-series: Invoke-PromptEvolution ====
    # Shared hermetic fixture: temp BATON_HOME with one polish run + live prompt.
    function New-EvoFixture {
        $root = New-TempDir
        $runsRoot = Join-Path $root 'runs'
        $runDir = Join-Path $runsRoot 'go-1'
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        @{ goal = 'G1'; tasks = @() } | ConvertTo-Json | Set-Content (Join-Path $runDir 'plan.json')
        @{ verdict = 'polish'; reason = 'R1'; counts = @{ important = 1 }; polish_brief = 'P1' } |
            ConvertTo-Json | Set-Content (Join-Path $runDir 'acceptance.json')
        $promptDir = Join-Path $root 'prompts'
        New-Item -ItemType Directory -Force -Path $promptDir | Out-Null
        $livePath = Join-Path $promptDir 'conductor-planner.txt'
        Set-Content -LiteralPath $livePath -Value 'LIVE {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        return @{ root = $root; live = $livePath; pool = (Join-Path $promptDir 'pool') }
    }
    $okReflect = { param($p) @{ stdout = '<diagnosis>too vague about ordering</diagnosis>'; exit_code = 0 } }
    $okMutate = { param($p) @{ stdout = '<new_prompt>BETTER v2 {{schema}} {{evi}} {{Goal}}</new_prompt>'; exit_code = 0 } }
    $echoPlan2 = { param($p) @{ stdout = $p; exit_code = 0 } }
    $judgeBetter = { param($p)
        $aIdx = $p.IndexOf('## Plan A'); $bIdx = $p.IndexOf('## Plan B')
        $v = if ($p.Substring($aIdx, $bIdx - $aIdx).Contains('BETTER')) { 'A' } else { 'B' }
        @{ stdout = "<verdict>$v</verdict>"; exit_code = 0 }
    }

    # E1+E2: first run seeds the pool, survivor proposed, live untouched (v1 regression).
    $fx1 = New-EvoFixture
    $env:BATON_HOME = $fx1.root
    $ev1 = Invoke-PromptEvolution -PromptPath $fx1.live -PoolDir $fx1.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E1 first evolution seeds the pool (p001 champion)' ((Get-PromptPool -PoolDir $fx1.pool).pool.champion -eq 'p001')
    Check 'E2 survivor: success, candidate file written, live prompt untouched' (
        $ev1.success -and (-not $ev1.applied) -and (Test-Path $ev1.candidate_path) -and
        ((Get-Content -Raw $fx1.live) -match '^LIVE')
    )
    $pool1 = (Get-PromptPool -PoolDir $fx1.pool).pool
    $p002 = @($pool1.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E3 child recorded as candidate with parent p001 and scores' (
        ($p002.status -eq 'candidate') -and ($p002.parent -eq 'p001') -and
        (([double]$p002.offline.minibatch.win_rate_vs_champion) -eq 1.0)
    )
    Check 'E4 child text file written to pool' ((Get-Content -Raw (Join-Path $fx1.pool 'p002.txt')) -match '^BETTER v2')
    Check 'E5 generation record present' ((@($ev1.generations).Count -eq 1) -and (@($ev1.generations)[0].pass))

    # E6: placeholder-dropping mutation -> retired, no proposal.
    $fx2 = New-EvoFixture
    $env:BATON_HOME = $fx2.root
    $badMutate = { param($p) @{ stdout = '<new_prompt>DROPPED THE PLACEHOLDERS</new_prompt>'; exit_code = 0 } }
    $ev2 = Invoke-PromptEvolution -PromptPath $fx2.live -PoolDir $fx2.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $badMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool2 = (Get-PromptPool -PoolDir $fx2.pool).pool
    $ret2 = @($pool2.candidates | Where-Object { $_.status -eq 'retired' })
    Check 'E6 placeholder drop -> retired with reason, run reports no survivor' (
        (-not $ev2.success) -and (@($ret2).Count -eq 1) -and ($ret2[0].retired_reason -match 'placeholder')
    )

    # E7: length cap (seed ~8 tokens; 2x cap; give a huge mutation).
    $fx3 = New-EvoFixture
    $env:BATON_HOME = $fx3.root
    $longBody = ('x' * 400)
    $longMutate = { param($p) @{ stdout = "<new_prompt>$longBody {{schema}} {{evi}} {{Goal}}</new_prompt>"; exit_code = 0 } }.GetNewClosure()
    $ev3 = Invoke-PromptEvolution -PromptPath $fx3.live -PoolDir $fx3.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $longMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $ret3 = @((Get-PromptPool -PoolDir $fx3.pool).pool.candidates | Where-Object { $_.status -eq 'retired' })
    Check 'E7 length cap -> retired with length reason' (
        (-not $ev3.success) -and (@($ret3).Count -eq 1) -and ($ret3[0].retired_reason -match 'length cap')
    )

    # E8: all-ties judge -> gate fail (no evidence).
    $fx4 = New-EvoFixture
    $env:BATON_HOME = $fx4.root
    $judgeTie2 = { param($p) @{ stdout = '<verdict>tie</verdict>'; exit_code = 0 } }
    $ev4 = Invoke-PromptEvolution -PromptPath $fx4.live -PoolDir $fx4.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeTie2 -Draw { param($t) 0.0 }
    Check 'E8 all ties -> no survivor, no-evidence reason recorded' (
        (-not $ev4.success) -and ((@(@($ev4.generations)[0].reasons) -join ';') -match 'no evidence')
    )

    # E9: -Apply promotes the survivor (champion swap + backup + stale-marking).
    $fx5 = New-EvoFixture
    $env:BATON_HOME = $fx5.root
    $ev5 = Invoke-PromptEvolution -PromptPath $fx5.live -PoolDir $fx5.pool -Apply `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    $pool5 = (Get-PromptPool -PoolDir $fx5.pool).pool
    $old5 = @($pool5.candidates | Where-Object { $_.id -eq 'p001' })[0]
    $new5 = @($pool5.candidates | Where-Object { $_.id -eq 'p002' })[0]
    Check 'E9a apply: live prompt overwritten with survivor text' ((Get-Content -Raw $fx5.live) -match '^BETTER v2')
    Check 'E9b apply: timestamped backup of previous live prompt exists' (@(Get-ChildItem "$($fx5.live).bak-*").Count -eq 1)
    Check 'E9c apply: champion swapped, old champion retired as superseded' (
        ($pool5.champion -eq 'p002') -and ($new5.status -eq 'champion') -and
        ($old5.status -eq 'retired') -and ($old5.retired_reason -eq 'superseded')
    )
    Check 'E9d apply: new champion re-baselined to 0.5' (([double]$new5.offline.minibatch.win_rate_vs_champion) -eq 0.5)

    # E10: corrupt pool manifest -> refuse to run.
    $fx6 = New-EvoFixture
    $env:BATON_HOME = $fx6.root
    New-Item -ItemType Directory -Force -Path $fx6.pool | Out-Null
    Set-Content -LiteralPath (Join-Path $fx6.pool 'pool.json') -Value '{ broken' -Encoding utf8NoBOM
    $ev6 = Invoke-PromptEvolution -PromptPath $fx6.live -PoolDir $fx6.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E10 corrupt pool -> refuses, manifest untouched' (
        (-not $ev6.success) -and ($ev6.reason -match 'corrupt') -and
        ((Get-Content -Raw (Join-Path $fx6.pool 'pool.json')) -match 'broken')
    )

    # E11: no gated runs -> honest no-op.
    $fx7 = New-EvoFixture
    Remove-Item -Recurse -Force (Join-Path $fx7.root 'runs')
    $env:BATON_HOME = $fx7.root
    $ev7 = Invoke-PromptEvolution -PromptPath $fx7.live -PoolDir $fx7.pool `
        -ReflectDispatcher $okReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E11 no gated runs -> no-op with honest reason' ((-not $ev7.success) -and ($ev7.reason -match 'no historical runs'))

    # E12: reflection failure -> generation fail-open, pool not grown.
    $fx8 = New-EvoFixture
    $env:BATON_HOME = $fx8.root
    $failReflect = { param($p) @{ stdout = ''; exit_code = 1 } }
    $ev8 = Invoke-PromptEvolution -PromptPath $fx8.live -PoolDir $fx8.pool `
        -ReflectDispatcher $failReflect -MutateDispatcher $okMutate `
        -PlanDispatcher $echoPlan2 -JudgeDispatcher $judgeBetter -Draw { param($t) 0.0 }
    Check 'E12 reflection failure -> fail-open, only the seed in the pool' (
        (-not $ev8.success) -and (@((Get-PromptPool -PoolDir $fx8.pool).pool.candidates).Count -eq 1)
    )

    # E13: builders carry their contracts.
    $dg = Build-DiagnosisPrompt -HistoricalRuns @(@{ run_id = 'go-1'; goal = 'G'; plan_tasks = '[]'; verdict = 'reject'; reason = 'R'; findings = '{}'; polish_brief = 'P' }) `
        -ParentPrompt 'PARENT_TEXT' -PriorFates @('p009 retired: length cap')
    Check 'E13a diagnosis prompt: history + parent + prior fates + <diagnosis> tag' (
        ($dg -match 'go-1') -and ($dg -match 'PARENT_TEXT') -and ($dg -match 'p009 retired') -and ($dg -match '<diagnosis>')
    )
    $mt = Build-MutationPrompt -Diagnosis 'DIAG_TEXT' -ParentPrompt 'PARENT_TEXT'
    Check 'E13b mutation prompt: diagnosis + parent + placeholder-keep + <new_prompt> tag' (
        ($mt -match 'DIAG_TEXT') -and ($mt -match 'PARENT_TEXT') -and ($mt -match '\{\{schema\}\}') -and ($mt -match '<new_prompt>')
    )

    if ($null -eq $prevBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prevBatonHome }

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    if ($null -eq $prevBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prevBatonHome }
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
