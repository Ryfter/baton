#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-calibrate.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-cal-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $toolsYaml = @"
tools:
  - name: docling
    capability: pdf-extract
    kind: python
    enabled: true
    cost_tier: local
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

    $journal = Join-Path $tmp 'cal-journal.jsonl'
    $common  = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal }

    # ===== fan-out: every candidate dispatched even though the first one passes =====
    $script:calls = 0
    $dispAll = { param($c,$p) $script:calls++; @{ stdout="out-$($c.name)"; stderr=''; exit_code=0; duration_s=1 } }

    $o1 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'do x' -Dispatcher $dispAll -MaxCostTier 'paid' @common
    Check 'calibrated status'            ($o1.status -eq 'calibrated')
    Check 'fan-out dispatched all 3'     ($script:calls -eq 3)
    Check 'returns one row per candidate'($o1.candidates.Count -eq 3)
    Check 'all rows passed (heuristic)'  (@($o1.candidates | Where-Object { -not $_.passed }).Count -eq 0)
    Check 'rows carry an excerpt'        (-not [string]::IsNullOrWhiteSpace($o1.candidates[0].excerpt))
    Check 'journal has 3 rows'           (@(Get-Content $journal).Count -eq 3)

    # ===== tier cap: default free excludes the paid candidate =====
    $script:calls = 0
    $o2 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAll -MaxCostTier 'free' @common
    Check 'tier cap free excludes paid'  ($o2.candidates.Count -eq 2 -and @($o2.candidates | Where-Object { $_.cost_tier -eq 'paid' }).Count -eq 0)

    # ===== no-candidate =====
    $o3 = Invoke-CapabilityCalibration -Capability 'nope-cap' -Prompt 'x' -Dispatcher $dispAll @common
    Check 'unknown cap -> no-candidate'  ($o3.status -eq 'no-candidate' -and $o3.candidates.Count -eq 0)

    # ===== injected judge tags journal rows grader=llm-judge =====
    $judgeDisp = { param($model,$prompt) '{"score": 0.8, "reason": "good"}' }
    $journal2 = Join-Path $tmp 'cal-journal2.jsonl'
    $common2  = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath; JournalPath = $journal2 }
    $o4 = Invoke-CapabilityCalibration -Capability 'code-gen' -Prompt 'x' -Dispatcher $dispAll `
            -MaxCostTier 'paid' -Judge -JudgeModel 'fake-judge' -JudgeDispatcher $judgeDisp @common2
    $rows4 = @(Get-Content $journal2 | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'judge tags rows llm-judge'    (@($rows4 | Where-Object { $_.grader -eq 'llm-judge' }).Count -eq 3)
    Check 'judge score flows to rows'    ([math]::Abs([double]$o4.candidates[0].score - 0.8) -lt 0.001)

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail check(s) FAILED"; exit 1 }
    Write-Host "All routing-calibrate checks passed."; exit 0
}
finally {
    Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}
