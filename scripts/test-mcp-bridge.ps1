#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for scripts/mcp-bridge.ps1 (Phase 3 MCP entry point).
  Isolation: $env:BATON_HOME is set to a temp dir seeded with minimal fixtures.
  Every case invokes the bridge as a subprocess and asserts the JSON envelope.
#>
$ErrorActionPreference = 'Stop'
$script:fail = 0

function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" -ForegroundColor Green }
    else    { Write-Host "FAIL: $n" -ForegroundColor Red; $script:fail++ }
}

$bridge = Join-Path $PSScriptRoot 'mcp-bridge.ps1'
$savedHome = $env:BATON_HOME

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-bridge-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $env:BATON_HOME = $tmp

    # --- Seed fixtures ---
    $toolsYaml = @"
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
    stdin: true
"@
    Set-Content -Path (Join-Path $tmp 'tools.yaml') -Value $toolsYaml -Encoding utf8

    $fleetYaml = @"
research_default: [stub-local]
general_capabilities: [code-gen, reasoning]

providers:
  - name: stub-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
  - name: stub-paid
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'pwsh -NoProfile -Command "Write-Output hello"'
  - name: stub-disabled
    kind: cli
    enabled: false
    cost_tier: local
    command_template: 'pwsh -NoProfile -Command "Write-Output nope"'
"@
    Set-Content -Path (Join-Path $tmp 'fleet.yaml') -Value $fleetYaml -Encoding utf8

    # Seed a test job
    $jobDir = Join-Path $tmp 'jobs\j-test'
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    $now = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    $manifestYaml = @"
id: j-test
title: "Test Job"
created_at: $now
status: active
project: baton
current_phase: research
phase_started_at: $now
sprint_count: 0
last_updated: $now
"@
    Set-Content -Path (Join-Path $jobDir 'manifest.yaml') -Value $manifestYaml -Encoding utf8
    # active current-job
    $currentJobJson = '{"job_id":"j-test","phase":"research"}'
    Set-Content -Path (Join-Path $tmp 'current-job.json') -Value $currentJobJson -Encoding utf8

    # Helper: invoke bridge, return parsed JSON
    function Invoke-Bridge {
        param([string]$Op, [hashtable]$OpArgs)
        $argPath = $null
        if ($OpArgs -and $OpArgs.Count -gt 0) {
            $argPath = [System.IO.Path]::GetTempFileName()
            $OpArgs | ConvertTo-Json -Compress | Set-Content -Path $argPath -Encoding utf8
        }
        $pArgs = @('-NoProfile', '-File', $bridge, '-Op', $Op)
        if ($argPath) { $pArgs += @('-ArgsPath', $argPath) }
        $out = (& pwsh @pArgs 2>&1 | Out-String).Trim()
        if ($argPath -and (Test-Path $argPath)) { Remove-Item $argPath -Force }
        if ([string]::IsNullOrWhiteSpace($out)) { return $null }
        # Take the last non-empty line (handles stray lib chatter)
        $lastLine = ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
        try { return $lastLine | ConvertFrom-Json } catch { return $null }
    }

    # ---- Case 1: capabilities ---
    $r = Invoke-Bridge -Op 'capabilities'
    Check 'capabilities: ok=true'           ($r -and $r.ok -eq $true)
    Check 'capabilities: non-empty array'   ($r -and $r.capabilities -and $r.capabilities.Count -gt 0)
    Check 'capabilities: contains commit-msg' ($r -and ($r.capabilities -contains 'commit-msg'))

    # ---- Case 2: route-select ---
    $r = Invoke-Bridge -Op 'route-select' -OpArgs @{ capability = 'commit-msg' }
    Check 'route-select: ok=true'           ($r -and $r.ok -eq $true)
    Check 'route-select: candidates array'  ($r -and $null -ne $r.candidates)
    Check 'route-select: has name field'    ($r -and $r.candidates -and $r.candidates.Count -gt 0 -and $r.candidates[0].name)
    Check 'route-select: has cost_tier'     ($r -and $r.candidates -and $r.candidates.Count -gt 0 -and $r.candidates[0].cost_tier)

    # ---- Case 3: fleet-list ---
    $r = Invoke-Bridge -Op 'fleet-list'
    Check 'fleet-list: ok=true'             ($r -and $r.ok -eq $true)
    Check 'fleet-list: providers array'     ($r -and $null -ne $r.providers)
    Check 'fleet-list: stub-local present'  ($r -and ($r.providers | Where-Object { $_.name -eq 'stub-local' }))
    $fl = $r.providers | Where-Object { $_.name -eq 'stub-local' } | Select-Object -First 1
    Check 'fleet-list: name field'          ($fl -and $fl.name)
    Check 'fleet-list: kind field'          ($fl -and $fl.kind -eq 'cli')
    Check 'fleet-list: enabled field'       ($fl -and $fl.enabled -eq $true)
    Check 'fleet-list: cost_tier field'     ($fl -and $fl.cost_tier -eq 'local')

    # ---- Case 4: fleet-doctor ---
    $r = Invoke-Bridge -Op 'fleet-doctor'
    Check 'fleet-doctor: ok=true'           ($r -and $r.ok -eq $true)
    Check 'fleet-doctor: rows present'      ($r -and $null -ne $r.rows)
    Check 'fleet-doctor: healthy is bool'   ($r -and ($r.healthy -is [bool]))

    # ---- Case 5: job-status (active) ---
    $r = Invoke-Bridge -Op 'job-status'
    Check 'job-status: ok=true'             ($r -and $r.ok -eq $true)
    Check 'job-status: active=true'         ($r -and $r.active -eq $true)
    Check 'job-status: job_id=j-test'       ($r -and $r.job_id -eq 'j-test')
    Check 'job-status: manifest has title'  ($r -and $r.manifest -and $r.manifest.title)

    # ---- Case 6: job-status (no current-job.json) ---
    $stateFile = Join-Path $tmp 'current-job.json'
    if (Test-Path $stateFile) { Remove-Item $stateFile -Force }
    $r = Invoke-Bridge -Op 'job-status'
    Check 'job-status no-job: ok=true'      ($r -and $r.ok -eq $true)
    Check 'job-status no-job: active=false' ($r -and $r.active -eq $false)
    # restore for subsequent tests
    Set-Content -Path $stateFile -Value $currentJobJson -Encoding utf8

    # ---- Case 7: job-list ---
    $r = Invoke-Bridge -Op 'job-list' -OpArgs @{ filter = 'all' }
    Check 'job-list: ok=true'               ($r -and $r.ok -eq $true)
    Check 'job-list: jobs array'            ($r -and $null -ne $r.jobs)
    Check 'job-list: contains j-test'       ($r -and ($r.jobs | Where-Object { $_.id -eq 'j-test' }))

    # ---- Case 8: unknown op → ok=false, exit 0 ---
    $argFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = (& pwsh -NoProfile -File $bridge -Op 'no-such-op' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        $lastLine = ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
        $r = try { $lastLine | ConvertFrom-Json } catch { $null }
        Check 'unknown op: ok=false'          ($r -and $r.ok -eq $false)
        Check 'unknown op: error mentions op' ($r -and [string]$r.error -match 'no-such-op')
        Check 'unknown op: exit 0'            ($exitCode -eq 0)
    } finally {
        if (Test-Path $argFile) { Remove-Item $argFile -Force }
    }

    # ---- Case 9: missing/garbage ArgsPath — no crash, ok present ---
    $r = Invoke-Bridge -Op 'capabilities' -OpArgs $null
    Check 'null args no crash: ok present'  ($r -and $null -ne $r.ok)

    # Test with a nonexistent path passed explicitly
    $out2 = (& pwsh -NoProfile -File $bridge -Op 'capabilities' -ArgsPath 'C:\nonexistent\path\args.json' 2>&1 | Out-String).Trim()
    $lastLine2 = ($out2 -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Last 1)
    $r2 = try { $lastLine2 | ConvertFrom-Json } catch { $null }
    Check 'garbage ArgsPath no crash: ok present' ($r2 -and $null -ne $r2.ok)

    # ---- Case 10: route-dispatch with nonexistent capability ---
    # Invoke-RoutedCapability returns status='no-candidate' when no candidates found
    $r = Invoke-Bridge -Op 'route-dispatch' -OpArgs @{ capability = 'nonexistent-cap-xyz'; prompt = 'test' }
    Check 'route-dispatch no-cand: ok=true'    ($r -and $r.ok -eq $true)
    Check 'route-dispatch no-cand: no-candidate status' ($r -and $r.status -eq 'no-candidate')

} finally {
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
