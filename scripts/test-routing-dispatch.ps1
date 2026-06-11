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
    Check 'journal grader defaults heuristic' ($obj.grader -eq 'heuristic')

    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'gemini' `
        -Source 'fleet' -Kind 'cli' -CostTier 'free' -ExitCode 0 -DurationS 5 `
        -Passed $false -Score 0.0 -Reason 'empty output' -JournalPath $journal `
        -Timestamp '2026-06-08T00:00:01.0000000-06:00'
    Check 'journal appends second line' (@(Get-Content $journal).Count -eq 2)

    # ===== Task 3: Invoke-Tool =====
    $echoTool = @{ name='echo-tool'; kind='cli'; stdin=$true
                   command_template='pwsh -NoProfile -Command [Console]::In.ReadToEnd()' }
    $r1 = Invoke-Tool -Tool $echoTool -Prompt 'hello-stdin'
    Check 'Invoke-Tool stdin echoes prompt' ($r1.stdout -match 'hello-stdin' -and $r1.exit_code -eq 0)
    Check 'Invoke-Tool returns duration'    ($r1.ContainsKey('duration_s'))

    $argTool = @{ name='arg-tool'; kind='cli'; stdin=$false
                  command_template='pwsh -NoProfile -Command & { $args[0] }' }
    $r2 = Invoke-Tool -Tool $argTool -Prompt 'arg-prompt'
    Check 'Invoke-Tool non-stdin passes arg' ($r2.stdout -match 'arg-prompt' -and $r2.exit_code -eq 0)

    $badTool = @{ name='bad'; kind='cli'; stdin=$false; command_template='no-such-exe-xyz-123' }
    $r3 = Invoke-Tool -Tool $badTool -Prompt 'x'
    Check 'Invoke-Tool missing exe -> exit -1' ($r3.exit_code -eq -1 -and $r3.stderr)

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

    # ===== Slice A: prime-hours gate on the paid tier (opt-in via -Rank) =====
    $phYaml = @"
timezone: local
default_rank: 3
windows:
  - name: peak
    days: [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
    start: "00:00"
    end: "23:59"
    kind: peak
"@
    $phCfg = Join-Path $tmp 'prime-hours.yaml'
    Set-Content -Path $phCfg -Value $phYaml -Encoding utf8

    # No -Rank -> NO gating -> cheapest (local-a) wins (regression-equivalent).
    $allPass = { param($cand,$prompt) @{ stdout='OK'; stderr=''; exit_code=0; duration_s=0 } }
    $g0 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $allPass @common4
    Check 'no -Rank: no gating, local wins' ($g0.winner -eq 'local-a')

    # Rank 3 in an all-day peak window: only paid works, but paid is deferred -> escalate.
    $onlyPaidWorks = { param($cand,$prompt) if ($cand.cost_tier -eq 'paid') { @{ stdout='WORKS'; stderr=''; exit_code=0; duration_s=1 } } else { @{ stdout=''; stderr=''; exit_code=0; duration_s=1 } } }
    $g3 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $onlyPaidWorks -Rank 3 -PrimeHoursConfig $phCfg -GateNow ([datetime]'2026-06-10T12:00:00') @common4
    Check 'rank3 peak: paid deferred -> escalate' ($g3.status -eq 'escalate-to-conductor')
    Check 'paid attempt tagged gated' (@($g3.attempts | Where-Object { $_.candidate -eq 'paid-c' -and $_.gate -eq 'defer' }).Count -eq 1)

    # Rank 1 in peak: ask -> default run -> paid-c dispatched -> wins.
    $g1 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $onlyPaidWorks -Rank 1 -PrimeHoursConfig $phCfg -GateNow ([datetime]'2026-06-10T12:00:00') @common4
    Check 'rank1 peak: paid runs (ask->run)' ($g1.status -eq 'passed' -and $g1.winner -eq 'paid-c')

    # ===== Slice B: stage field + grader tag =====
    $journalS = Join-Path $tmp 'stage-journal.jsonl'
    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'local-a' `
        -Source 'fleet' -Kind 'cli' -CostTier 'local' -ExitCode 0 -DurationS 1 `
        -Passed $true -Score 0.8 -Reason 'ok' -Stage 'draft' -JournalPath $journalS `
        -Timestamp '2026-06-11T00:00:00.0000000-06:00'
    $sObj = @(Get-Content $journalS)[0] | ConvertFrom-Json
    Check 'journal row carries stage'    ($sObj.stage -eq 'draft')

    Write-RoutingJournalLine -Capability 'code-gen' -Candidate 'local-a' `
        -Source 'fleet' -Kind 'cli' -CostTier 'local' -ExitCode 0 -DurationS 1 `
        -Passed $true -Score 0.8 -Reason 'ok' -JournalPath $journalS `
        -Timestamp '2026-06-11T00:00:01.0000000-06:00'
    $sObj2 = @(Get-Content $journalS)[1] | ConvertFrom-Json
    Check 'no -Stage -> no stage field'  ($null -eq $sObj2.PSObject.Properties['stage'])

    # Invoke-RoutedCandidate: -Stage flows to the journal; attempt carries the grader tag.
    $noRatings = Join-Path $tmp 'no-ratings.jsonl'
    # Select-Capability returns ,([object[]]) (NoEnumerate) — index the returned array directly.
    $candS = (Select-Capability -Capability 'code-gen' -ToolsPath $toolsPath -FleetPath $fleetPath -RatingsPath $noRatings -JournalPath $journalS)[0]
    $journalS2 = Join-Path $tmp 'stage-journal2.jsonl'
    $rcS = Invoke-RoutedCandidate -Capability 'code-gen' -Candidate $candS -Prompt 'x' `
        -Dispatcher $dispAllPass -ToolsPath $toolsPath -FleetPath $fleetPath `
        -JournalPath $journalS2 -Stage 'finish'
    $sRow = @(Get-Content $journalS2)[0] | ConvertFrom-Json
    Check 'RoutedCandidate journals stage'   ($sRow.stage -eq 'finish')
    Check 'attempt carries grader tag'       ($rcS.attempt.grader -eq 'heuristic')
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
