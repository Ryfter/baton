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
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
