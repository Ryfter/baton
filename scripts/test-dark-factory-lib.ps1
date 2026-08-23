#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/dark-factory-lib.ps1"

$box = Join-Path ([System.IO.Path]::GetTempPath()) ("df-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $box 'maestro/jobs') | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = $box

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

try {
    Check 'lanes defined' (@(Get-DarkFactoryLanes).Count -ge 3)
    $lanes = Get-DarkFactoryLanes
    Check 'grimdex lane present' (@($lanes | Where-Object lane -eq 'grimdex-edu-curriculum').Count -eq 1)

    $dry = Invoke-DarkFactorySeed -BatonHome $box -DryRun
    $jobFiles = @(Get-ChildItem (Join-Path $box 'maestro/jobs') -Filter 'mj-*.json' -ErrorAction SilentlyContinue)
    Check 'dry-run creates no job files' ($jobFiles.Count -eq 0 -and @($dry.created).Count -ge 2)

    $seed = Invoke-DarkFactorySeed -BatonHome $box
    Check 'seed creates jobs' (@($seed.created).Count -ge 2)
    $jobsDir = Join-Path $box 'maestro/jobs'
    $first = Get-Content -LiteralPath (Join-Path $jobsDir "$($seed.created[0].job_id).json") -Raw | ConvertFrom-Json
    Check 'seeded job tagged dark-factory' (@($first.tags) -contains 'dark-factory')
    Check 'seeded goal carries lane marker' ([string]$first.goal -match 'dark-factory:lane=')

    Check 'second seed skips' (@((Invoke-DarkFactorySeed -BatonHome $box).created).Count -eq 0)
    Check 'lane reports active' (Test-DarkFactoryLaneActive -Lane ([string]$seed.created[0].lane) -Project ([string]$seed.created[0].project) -BatonHome $box)

    $status = Get-DarkFactoryStatus -BatonHome $box
    Check 'status has jobs' ($status.jobs_total -ge 2)
    Check 'status lists lanes' (@($status.lanes).Count -ge 3)
} finally {
    $env:BATON_HOME = $prevHome
    Remove-Item -Recurse -Force $box -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
Write-Host 'dark-factory-lib: all checks passed'
exit 0
