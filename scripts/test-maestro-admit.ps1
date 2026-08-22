#!/usr/bin/env pwsh
# Hermetic tests for maestro-admit.ps1 (Slice 2 admission).
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("maestro-admit-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$jobsDir = Join-Path $tmp 'maestro/jobs'
New-Item -ItemType Directory -Force -Path $jobsDir | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = $tmp

try {
    function Write-TestJob {
        param([string]$Id, [string]$Project, [string]$Status, [string]$Created, [string]$HeldFrom)
        $job = [ordered]@{
            id          = $Id
            project     = $Project
            goal        = 'test goal'
            stakes      = 'standard'
            missed_fire = 'catch-up'
            source      = 'web'
            status      = $Status
            run_id      = $null
            provider    = $null
            created_at  = $Created
        }
        if ($HeldFrom) { $job.held_from = $HeldFrom }
        ($job | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $jobsDir "$Id.json") -Encoding utf8NoBOM
    }

    Write-TestJob -Id 'mj-aaaaaaaaaaaa' -Project 'baton' -Status 'queued' -Created '2026-08-21T01:00:00Z'
    Write-TestJob -Id 'mj-bbbbbbbbbbbb' -Project 'canvas-toolchain' -Status 'queued' -Created '2026-08-21T01:01:00Z'
    Write-TestJob -Id 'mj-cccccccccccc' -Project 'baton' -Status 'held' -Created '2026-08-21T00:59:00Z' -HeldFrom 'queued'

    & (Join-Path $PSScriptRoot 'maestro-admit.ps1') -BatonHome $tmp -MaxParallel 8 -Json | Out-Null

    $j1 = Get-Content -LiteralPath (Join-Path $jobsDir 'mj-aaaaaaaaaaaa.json') -Raw | ConvertFrom-Json
    $j2 = Get-Content -LiteralPath (Join-Path $jobsDir 'mj-bbbbbbbbbbbb.json') -Raw | ConvertFrom-Json
    $j3 = Get-Content -LiteralPath (Join-Path $jobsDir 'mj-cccccccccccc.json') -Raw | ConvertFrom-Json

    Check 'baton blocked by held sibling stays queued' ([string]$j1.status -eq 'queued')
    Check 'canvas-toolchain admitted' ([string]$j2.status -eq 'admitted')
    Check 'held job untouched' ([string]$j3.status -eq 'held')

    & (Join-Path $PSScriptRoot 'maestro-release.ps1') -BatonHome $tmp -JobId 'mj-cccccccccccc' -Json | Out-Null
    $j3 = Get-Content -LiteralPath (Join-Path $jobsDir 'mj-cccccccccccc.json') -Raw | ConvertFrom-Json
    Check 'release restores held job to queued' ([string]$j3.status -eq 'queued')
    Check 'held_from cleared after release' (-not ($j3.PSObject.Properties.Name -contains 'held_from'))
} finally {
    $env:BATON_HOME = $prevHome
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
Write-Host 'test-maestro-admit: OK'
