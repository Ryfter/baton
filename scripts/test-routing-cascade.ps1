#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-cascade.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-casc-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Hermetic isolation: route Get-BatonHome defaults (notably the Usage Governor's
# usage-journal.jsonl, read by Select-Capability's default -UsagePath) into the empty
# temp dir, so a live lockout / conserve_mode never perturbs this suite. Restored below.
$savedBatonHome = $env:BATON_HOME
$env:BATON_HOME = $tmp

try {
    # Fixture: 2 locals (draft by inference), 1 cheap-paid explicitly role:draft,
    # 1 paid explicitly bulk (draft-eligible), 1 paid finisher (by inference).
    $fleetYaml = @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: local-b
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
  - name: cheap-paid-draft
    kind: cli
    enabled: true
    cost_tier: paid
    role: draft
    platform: claude
    command_template: 'x "{{prompt}}"'
  - name: bulk-paid
    kind: cli
    enabled: true
    cost_tier: paid
    role: bulk
    command_template: 'x "{{prompt}}"'
  - name: frontier
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    command_template: 'x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'; Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8
    $toolsPath = Join-Path $tmp 'tools.yaml'; Set-Content -Path $toolsPath -Value "tools:" -Encoding utf8
    $journal   = Join-Path $tmp 'journal.jsonl'
    $common    = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal }

    # ===== role partition =====
    Check 'explicit draft beats paid inference'  ((Get-CascadeRole ([pscustomobject]@{ role='draft';   cost_tier='paid'  })) -eq 'draft')
    Check 'bulk is draft-eligible'               ((Get-CascadeRole ([pscustomobject]@{ role='bulk';    cost_tier='paid'  })) -eq 'draft')
    Check 'explicit finisher beats local'        ((Get-CascadeRole ([pscustomobject]@{ role='finisher';cost_tier='local' })) -eq 'finisher')
    Check 'paid infers finisher'                 ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='paid'  })) -eq 'finisher')
    Check 'local infers draft'                   ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='local' })) -eq 'draft')
    Check 'free infers draft'                    ((Get-CascadeRole ([pscustomobject]@{ role=$null;     cost_tier='free'  })) -eq 'draft')
    Check 'unknown role falls back to inference' ((Get-CascadeRole ([pscustomobject]@{ role='wizard';  cost_tier='local' })) -eq 'draft')

    # ===== drafting + short-circuit =====
    $scoreMap = @{ 'local-a' = 0.95; 'local-b' = 0.5; 'cheap-paid-draft' = 0.5; 'bulk-paid' = 0.5; 'frontier' = 0.92 }
    $judgeGrader = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        $s = if ($scoreMap.ContainsKey($name)) { [double]$scoreMap[$name] } else { 0.3 }
        @{ passed = ($s -ge 0.6); score = $s; reason = 'judged'; grader = 'llm-judge' }
    }.GetNewClosure()
    $echoName = { param($cand,$prompt) @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 } }
    $script:finisherCalls = 0
    $countingEcho = { param($cand,$prompt) if ($cand.name -eq 'frontier') { $script:finisherCalls++ }; @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 } }

    # local-a judge-scores 0.95 >= 0.9 -> draft-sufficient, finisher never dispatched.
    $r1 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -Grader $judgeGrader -Dispatcher $countingEcho @common
    Check 'short-circuit fires'            ($r1.status -eq 'draft-sufficient')
    Check 'short-circuit winner is draft'  ($r1.winner -eq 'local-a')
    Check 'short-circuit zero frontier'    ($r1.frontier_spent -eq $false)
    Check 'finisher never dispatched'      ($script:finisherCalls -eq 0)
    Check 'draft attempts recorded'        (@($r1.draft_attempts).Count -ge 1)

    # DraftCount caps the fan-out in selector order.
    $r2 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -DraftCount 1 -Grader $judgeGrader -Dispatcher $echoName @common
    Check 'DraftCount caps fan-out'        (@($r2.draft_attempts).Count -eq 1)

    # -NoShortCircuit forces the finisher past a 0.95 draft.
    $r3 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -NoShortCircuit -Grader $judgeGrader -Dispatcher $echoName @common
    Check 'NoShortCircuit forces finish'   ($r3.status -eq 'finished')

    # Heuristic (binary) verdict suppresses the short-circuit -> finisher runs.
    $heurGrader = { param($Capability,$Result) @{ passed=$true; score=1.0; reason='ok'; grader='heuristic' } }
    $r4 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -Grader $heurGrader -Dispatcher $echoName @common
    Check 'heuristic verdict never short-circuits' ($r4.status -eq 'finished')

    # Unknown capability -> no-candidate.
    $r5 = Invoke-CapabilityCascade -Capability 'nope' -Prompt 'x' -Grader $heurGrader -Dispatcher $echoName @common
    Check 'unknown cap -> no-candidate'    ($r5.status -eq 'no-candidate')

    # Journal rows carry stage=draft for draft dispatches.
    $stages = @(Get-Content $journal | ForEach-Object { ($_ | ConvertFrom-Json).stage } | Where-Object { $_ -eq 'draft' })
    Check 'journal has stage=draft rows'   ($stages.Count -ge 1)

    # ===== Task 4: finisher paths =====
    # Below-threshold drafts -> finisher runs with the take-and-extend prompt.
    $script:finisherPrompt = $null
    $lowMap = @{ 'local-a' = 0.7; 'local-b' = 0.6; 'cheap-paid-draft' = 0.6; 'bulk-paid' = 0.6 }
    $lowJudge = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        if ($name -eq 'FINISHED') { return @{ passed=$true; score=0.97; reason='judged'; grader='llm-judge' } }
        $s = if ($lowMap.ContainsKey($name)) { [double]$lowMap[$name] } else { 0.3 }
        @{ passed = ($s -ge 0.6); score = $s; reason = 'judged'; grader = 'llm-judge' }
    }.GetNewClosure()
    $captureFinish = {
        param($cand,$prompt)
        if ($cand.name -eq 'frontier') { $script:finisherPrompt = $prompt; return @{ stdout='FINISHED'; stderr=''; exit_code=0; duration_s=1 } }
        @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 }
    }
    $f1 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'TASK-MARKER do x' `
        -Grader $lowJudge -Dispatcher $captureFinish @common
    Check 'below threshold -> finished'      ($f1.status -eq 'finished')
    Check 'finisher wins'                    ($f1.winner -eq 'frontier')
    Check 'frontier_spent true'              ($f1.frontier_spent -eq $true)
    Check 'finisher prompt has task'         ($script:finisherPrompt -match 'TASK-MARKER do x')
    Check 'finisher prompt has best draft'   ($script:finisherPrompt -match 'local-a')
    Check 'finisher prompt is the template'  ($script:finisherPrompt -match "finishing another model's draft")
    Check 'finish_attempt recorded'          ($f1.finish_attempt.candidate -eq 'frontier')

    # All drafts fail -> finisher gets the ORIGINAL prompt alone.
    $script:finisherPrompt = $null
    $allFailJudge = {
        param($Capability, $Result)
        $name = ([string]$Result.stdout).Trim()
        if ($name -eq 'FINISHED') { return @{ passed=$true; score=0.97; reason='judged'; grader='llm-judge' } }
        @{ passed=$false; score=0.0; reason='judged-bad'; grader='llm-judge' }
    }
    $failDrafts = {
        param($cand,$prompt)
        if ($cand.name -eq 'frontier') { $script:finisherPrompt = $prompt; return @{ stdout='FINISHED'; stderr=''; exit_code=0; duration_s=1 } }
        @{ stdout=''; stderr=''; exit_code=1; duration_s=1 }
    }
    $f2 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'ORIGINAL-ONLY' `
        -Grader $allFailJudge -Dispatcher $failDrafts @common
    Check 'all drafts fail -> still finishes'   ($f2.status -eq 'finished')
    Check 'failed drafts -> original prompt'    ($script:finisherPrompt -eq 'ORIGINAL-ONLY')

    # Finisher fails grading -> escalate-to-conductor, paid spend still recorded.
    $allBad = { param($Capability,$Result) @{ passed=$false; score=0.2; reason='judged-bad'; grader='llm-judge' } }
    $f3 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -Grader $allBad -Dispatcher $echoName @common
    Check 'finisher fails -> escalate'       ($f3.status -eq 'escalate-to-conductor')
    Check 'escalate still spent frontier'    ($f3.frontier_spent -eq $true)
    Check 'escalate salvages usable draft'   (-not [string]::IsNullOrWhiteSpace([string]$f3.result.stdout))

    # -RequireLocal -> no paid candidates -> no finisher-eligible -> no-finisher,
    # best passing draft returned.
    $okJudge = { param($Capability,$Result) @{ passed=$true; score=0.7; reason='judged'; grader='llm-judge' } }
    $f4 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -RequireLocal -Grader $okJudge -Dispatcher $echoName @common
    Check 'RequireLocal -> no-finisher'      ($f4.status -eq 'no-finisher')
    Check 'no-finisher returns best draft'   ($f4.winner -in @('local-a','local-b'))
    Check 'no-finisher zero frontier'        ($f4.frontier_spent -eq $false)

    # Gate defers the finisher (all-day peak, rank 3) -> finisher-deferred + provisional draft.
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
    $phCfg = Join-Path $tmp 'prime-hours.yaml'; Set-Content -Path $phCfg -Value $phYaml -Encoding utf8
    $f5 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -Grader $lowJudge -Dispatcher $captureFinish `
        -Rank 3 -PrimeHoursConfig $phCfg -GateNow ([datetime]'2026-06-10T12:00:00') `
        -DraftCount 2 @common
    Check 'peak rank3 -> finisher-deferred'  ($f5.status -eq 'finisher-deferred')
    Check 'deferred keeps best draft'        ($f5.winner -eq 'local-a')
    Check 'deferred zero frontier'           ($f5.frontier_spent -eq $false)
    Check 'deferred finish_attempt gated'    ($f5.finish_attempt.gate -in @('defer','ask'))
    Check 'deferred result is the draft'     ($f5.result.stdout -match 'local-a')

    # Deferred finisher with ALL drafts failing but emitting text -> salvage non-passing draft.
    $f6 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'x' `
        -Grader $allBad -Dispatcher $echoName `
        -Rank 3 -PrimeHoursConfig $phCfg -GateNow ([datetime]'2026-06-10T12:00:00') `
        -DraftCount 2 @common
    Check 'deferred salvages failed draft'   ($f6.status -eq 'finisher-deferred' -and -not [string]::IsNullOrWhiteSpace([string]$f6.result.stdout))

    # Journal rows carry stage=finish for finisher dispatches.
    $finRows = @(Get-Content $journal | ForEach-Object { ($_ | ConvertFrom-Json).stage } | Where-Object { $_ -eq 'finish' })
    Check 'journal has stage=finish rows'    ($finRows.Count -ge 1)

    # ===== [no-finisher mode] =====
    # Recording dispatcher: tracks whether the finisher candidate was called.
    $script:nfFinisherCalled = $false
    $nfRecorder = {
        param($cand,$prompt)
        if ($cand.name -eq 'frontier') { $script:nfFinisherCalled = $true }
        @{ stdout=$cand.name; stderr=''; exit_code=0; duration_s=1 }
    }

    # n1: -NoFinisher + judge score >=0.9 still short-circuits -> draft-sufficient, frontier not spent.
    $script:nfFinisherCalled = $false
    $n1 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -NoFinisher -Grader $judgeGrader -Dispatcher $nfRecorder @common
    Check 'n1: NoFinisher + passing judge still short-circuits'  ($n1.status -eq 'draft-sufficient')
    Check 'n1: NoFinisher short-circuit frontier_spent false'    ($n1.frontier_spent -eq $false)

    # n2-n6: -NoFinisher + below-threshold -> drafts-only with best usable draft.
    # Use lowJudge (all drafts score <0.9) and nfRecorder to verify finisher never called.
    $script:nfFinisherCalled = $false
    $n2 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -NoFinisher -Grader $lowJudge -Dispatcher $nfRecorder @common
    Check 'n2: NoFinisher below-threshold -> drafts-only'        ($n2.status -eq 'drafts-only')
    Check 'n3: NoFinisher winner = best usable draft'            ($n2.winner -in @('local-a','local-b','cheap-paid-draft','bulk-paid'))
    Check 'n4: NoFinisher result carries winner stdout'          (-not [string]::IsNullOrWhiteSpace([string]$n2.result.stdout))
    Check 'n5: NoFinisher finish_attempt is null'                ($null -eq $n2.finish_attempt)
    Check 'n6: NoFinisher frontier_spent false'                  ($n2.frontier_spent -eq $false)
    Check 'n6b: NoFinisher finisher never dispatched'            ($script:nfFinisherCalled -eq $false)

    # n7: all drafts emit empty stdout -> drafts-only with winner $null and result $null.
    $emptyDispatch = { param($cand,$prompt) @{ stdout=''; stderr=''; exit_code=0; duration_s=1 } }
    $n7 = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'do x' `
        -NoFinisher -Grader $lowJudge -Dispatcher $emptyDispatch @common
    Check 'n7: all empty stdout -> drafts-only winner null'      ($null -eq $n7.winner)
    Check 'n7: all empty stdout -> drafts-only result null'      ($null -eq $n7.result)
}
finally {
    if ($null -eq $savedBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $savedBatonHome }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
