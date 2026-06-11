#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-cascade.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-casc-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

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
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
