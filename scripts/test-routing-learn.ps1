#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-dispatch.ps1"   # loads routing-lib -> routing-learn -> fleet-lib

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-learn-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ===== Task 1: ratings store =====
    $ratings = Join-Path $tmp 'routing-ratings.jsonl'

    # Missing file -> empty, no throw.
    Check 'ratings missing -> empty' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 0)

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'good' -Note 'clean subject' -RatingsPath $ratings `
        -Timestamp '2026-06-08T00:00:00.0000000-06:00'
    $rs = @(Get-CapabilityRatings -RatingsPath $ratings)
    Check 'rating appended'        ($rs.Count -eq 1)
    Check 'rating capability'      ($rs[0].capability -eq 'commit-msg')
    Check 'rating candidate'       ($rs[0].candidate -eq 'devstral')
    Check 'rating value'           ($rs[0].rating -eq 'good')
    Check 'rating note'            ($rs[0].note -eq 'clean subject')
    Check 'rating ts injected'     ($rs[0].ts -eq '2026-06-08T00:00:00.0000000-06:00')

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'bad' -RatingsPath $ratings -Timestamp '2026-06-08T00:00:01.0000000-06:00'
    Check 'rating appends second'  (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)

    # Creates nested dir if absent.
    $nested = Join-Path $tmp 'knowledge/universal/routing-ratings.jsonl'
    Add-CapabilityRating -Capability 'x' -Candidate 'y' -Source 'tools' -Rating 'good' -RatingsPath $nested
    Check 'rating creates nested dir' (Test-Path $nested)

    # Malformed line skipped on read.
    Add-Content -LiteralPath $ratings -Value 'not json{{' -Encoding utf8NoBOM
    Check 'malformed ratings line skipped' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)

    # ===== Task 2: learned quality blend =====
    $jq = Join-Path $tmp 'q-journal.jsonl'
    $rq = Join-Path $tmp 'q-ratings.jsonl'

    # Cold start: no data -> prior.
    Check 'cold-start -> 0.5 prior' ([math]::Abs((Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm1' -JournalPath $jq -RatingsPath $rq) - 0.5) -lt 1e-9)
    Check 'cold-start -> yaml prior' ([math]::Abs((Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm1' -JournalPath $jq -RatingsPath $rq -Prior 0.8) - 0.8) -lt 1e-9)

    # Helper to seed journal rows (passed + grader + score).
    function Add-JRow($cap,$cand,$passed,$score,$grader,$path){
        $o=[ordered]@{ ts='2026-01-01T00:00:00Z'; capability=$cap; candidate=$cand; source='fleet'; kind='cli'; cost_tier='free'; exit_code=0; duration_s=1; passed=$passed; score=$score; reason='x'; grader=$grader }
        Add-Content -LiteralPath $path -Value ($o|ConvertTo-Json -Compress) -Encoding utf8NoBOM
    }

    # All-good user ratings pull quality up toward 1.0.
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm2' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp "2026-01-01T00:00:0$_Z" }
    $qUp = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm2' -JournalPath $jq -RatingsPath $rq
    Check 'good ratings raise quality' ($qUp -gt 0.7)

    # All-bad ratings pull quality down below the prior.
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm3' -Source 'fleet' -Rating 'bad' -RatingsPath $rq -Timestamp "2026-01-01T00:01:0$_Z" }
    $qDn = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm3' -JournalPath $jq -RatingsPath $rq
    Check 'bad ratings lower quality' ($qDn -lt 0.3)

    # Low-n shrinkage: a single good rating stays nearer the prior than 5 do.
    Add-CapabilityRating -Capability 'code-gen' -Candidate 'm4' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp '2026-01-01T00:02:00Z'
    $q1 = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm4' -JournalPath $jq -RatingsPath $rq
    Check 'single rating shrinks toward prior' ($q1 -gt 0.5 -and $q1 -lt $qUp)

    # Judge + heuristic blend (no user ratings): mid-high judge + all-pass heuristic > prior.
    1..4 | ForEach-Object { Add-JRow 'code-gen' 'm5' $true 0.8 'llm-judge' $jq }
    1..4 | ForEach-Object { Add-JRow 'code-gen' 'm5' $true 1.0 'heuristic' $jq }
    $qj = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm5' -JournalPath $jq -RatingsPath $rq
    Check 'judge+heuristic raise quality' ($qj -gt 0.5)

    # Bounded [0,1].
    1..20 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm6' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp "2026-01-01T00:03:$($_.ToString('00'))Z" }
    $qMax = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm6' -JournalPath $jq -RatingsPath $rq
    Check 'quality bounded <= 1' ($qMax -le 1.0 -and $qMax -gt 0.9)

    # Detail breakdown reports component rates + counts.
    $d = Get-CapabilityQualityDetail -Capability 'code-gen' -Candidate 'm5' -JournalPath $jq -RatingsPath $rq
    Check 'detail judge n' ($d.judge.n -eq 4)
    Check 'detail heuristic n' ($d.heuristic.n -eq 8)
    Check 'detail user n zero' ($d.user.n -eq 0)
    Check 'detail quality matches' ([math]::Abs($d.quality - $qj) -lt 1e-9)

    # ===== Task 3: last routed attempt =====
    $jt = Join-Path $tmp 'tail-journal.jsonl'
    Check 'no journal -> null winner' ($null -eq (Get-LastRoutedAttempt -JournalPath $jt))

    Add-JRow 'code-gen' 'a' $false 0.0 'heuristic' $jt
    Add-JRow 'code-gen' 'b' $true  1.0 'heuristic' $jt   # winner of run 1
    Add-JRow 'summarize' 'c' $false 0.0 'heuristic' $jt
    Add-JRow 'summarize' 'd' $true  1.0 'llm-judge' $jt  # winner of run 2 (most recent)
    $last = Get-LastRoutedAttempt -JournalPath $jt
    Check 'last winner is most recent pass' ($last.candidate -eq 'd' -and $last.capability -eq 'summarize')

    Add-JRow 'code-gen' 'e' $false 0.0 'heuristic' $jt
    $last2 = Get-LastRoutedAttempt -JournalPath $jt
    Check 'last winner skips trailing fails' ($last2.candidate -eq 'd')

    # Malformed tail line tolerated.
    Add-Content -LiteralPath $jt -Value 'broken{{' -Encoding utf8NoBOM
    Check 'tail tolerates malformed line' ((Get-LastRoutedAttempt -JournalPath $jt).candidate -eq 'd')

    # ===== Task 4: LLM-judge grader =====
    # Injected judge dispatcher returns a fixed JSON; counts calls to prove short-circuit.
    $script:judgeCalls = 0
    $judgeDisp = { param($model,$prompt) $script:judgeCalls++; '{"score":0.9,"reason":"good output"}' }

    # Heuristic FAIL (empty) short-circuits -> no judge dispatch.
    $grader = Get-LlmJudgeGrader -JudgeModel 'judge-m' -JudgeDispatcher $judgeDisp
    $vEmpty = & $grader -Capability 'code-gen' -Result @{ stdout="  `n "; exit_code=0; duration_s=1 }
    Check 'judge: empty short-circuits'   ($vEmpty.passed -eq $false -and $vEmpty.grader -eq 'heuristic')
    Check 'judge: no dispatch on fail'    ($script:judgeCalls -eq 0)

    # Heuristic PASS -> judge runs, score>=threshold -> pass, tagged llm-judge.
    $vPass = & $grader -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: passes high score'      ($vPass.passed -eq $true -and $vPass.grader -eq 'llm-judge')
    Check 'judge: score surfaced'         ([math]::Abs($vPass.score - 0.9) -lt 1e-9)
    Check 'judge: dispatched once'        ($script:judgeCalls -eq 1)

    # Low judge score -> fail.
    $lowDisp = { param($model,$prompt) '{"score":0.2,"reason":"weak"}' }
    $graderLow = Get-LlmJudgeGrader -JudgeModel 'judge-m' -Threshold 0.6 -JudgeDispatcher $lowDisp
    $vLow = & $graderLow -Capability 'code-gen' -Result @{ stdout='meh'; exit_code=0; duration_s=1 }
    Check 'judge: low score fails'        ($vLow.passed -eq $false -and $vLow.grader -eq 'llm-judge')

    # Judge throws -> heuristic fallback, never blocks.
    $boomDisp = { param($model,$prompt) throw 'model down' }
    $graderBoom = Get-LlmJudgeGrader -JudgeModel 'judge-m' -JudgeDispatcher $boomDisp
    $vBoom = & $graderBoom -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: error -> heuristic fallback' ($vBoom.passed -eq $true -and $vBoom.grader -eq 'heuristic' -and $vBoom.reason -match 'judge unavailable')

    # No judge model available + no injected dispatcher -> heuristic fallback.
    $graderNone = Get-LlmJudgeGrader -FleetPath (Join-Path $tmp 'no-fleet.yaml')
    $vNone = & $graderNone -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: no model -> heuristic'  ($vNone.grader -eq 'heuristic' -and $vNone.reason -match 'judge unavailable')

    # Invoke-LlmJudge parses an embedded JSON object out of chatty output.
    $chatDisp = { param($model,$prompt) 'Here is my rating: {"score": 0.75, "reason": "ok"} done.' }
    $ij = Invoke-LlmJudge -Capability 'code-gen' -Output 'x' -JudgeModel 'j' -Dispatcher $chatDisp
    Check 'Invoke-LlmJudge parses embedded JSON' ([math]::Abs($ij.score - 0.75) -lt 1e-9)

    # ===== Task 5: -Judge switch wires the judge grader + journals the grader tag =====
    $tj = Join-Path $tmp 't5-tools.yaml'
    Set-Content -Path $tj -Value "tools: []" -Encoding utf8
    $fj = Join-Path $tmp 't5-fleet.yaml'
    Set-Content -Path $fj -Value @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
"@ -Encoding utf8
    $jj = Join-Path $tmp 't5-journal.jsonl'

    $candDisp  = { param($cand,$prompt) @{ stdout='generated code'; stderr=''; exit_code=0; duration_s=1 } }
    $jDisp     = { param($model,$prompt) '{"score":0.95,"reason":"great"}' }
    $oJ = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $candDisp `
            -Judge -JudgeModel 'local-a' -JudgeDispatcher $jDisp `
            -ToolsPath $tj -FleetPath $fj -JournalPath $jj
    Check 'judge path: passes'          ($oJ.status -eq 'passed' -and $oJ.winner -eq 'local-a')
    $jrow = (@(Get-Content $jj))[0] | ConvertFrom-Json
    Check 'judge path: grader logged'   ($jrow.grader -eq 'llm-judge')
    Check 'judge path: judge score logged' ([math]::Abs($jrow.score - 0.95) -lt 1e-9)

    $jj2 = Join-Path $tmp 't5b-journal.jsonl'
    $oH = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $candDisp `
            -ToolsPath $tj -FleetPath $fj -JournalPath $jj2
    $hrow = (@(Get-Content $jj2))[0] | ConvertFrom-Json
    Check 'default path: grader=heuristic' ($hrow.grader -eq 'heuristic')

    # ===== Task 6: learned quality flows into Select-Capability =====
    $t6tools = Join-Path $tmp 't6-tools.yaml'
    Set-Content -Path $t6tools -Value @"
tools:
  - name: tool-local
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
  - name: tool-paid
    kind: cli
    enabled: true
    cost_tier: paid
    capability: commit-msg
"@ -Encoding utf8
    $t6fleet = Join-Path $tmp 't6-fleet.yaml'
    Set-Content -Path $t6fleet -Value "general_capabilities: []`n`nproviders: []" -Encoding utf8
    $t6ratings = Join-Path $tmp 't6-ratings.jsonl'
    $t6journal = Join-Path $tmp 't6-journal.jsonl'

    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'commit-msg' -Candidate 'tool-paid' -Source 'tools' -Rating 'good' -RatingsPath $t6ratings -Timestamp "2026-02-01T00:00:0$_Z" }
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'commit-msg' -Candidate 'tool-local' -Source 'tools' -Rating 'bad' -RatingsPath $t6ratings -Timestamp "2026-02-01T00:01:0$_Z" }

    $cands = Select-Capability -Capability 'commit-msg' -ToolsPath $t6tools -FleetPath $t6fleet -RatingsPath $t6ratings -JournalPath $t6journal
    Check 'cost tier still dominates' ($cands[0].name -eq 'tool-local')
    Check 'paid learned quality high'  (($cands | Where-Object { $_.name -eq 'tool-paid' }).quality -gt 0.7)
    Check 'local learned quality low'  (($cands | Where-Object { $_.name -eq 'tool-local' }).quality -lt 0.3)
    Check 'quality_detail attached'    ($null -ne ($cands[0].quality_detail))
    Check 'quality_detail user n'      (($cands | Where-Object { $_.name -eq 'tool-paid' }).quality_detail.user.n -eq 5)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
