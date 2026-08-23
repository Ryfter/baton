#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/dark-factory-lib.ps1"

$box = Join-Path ([System.IO.Path]::GetTempPath()) ("df-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $box 'maestro/jobs') | Out-Null
$env:BATON_HOME = $box

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

Check 'lanes defined' (@(Get-DarkFactoryLanes).Count -ge 3)
$lanes = Get-DarkFactoryLanes
Check 'grimdex lane present' (@($lanes | Where-Object lane -eq 'grimdex-edu-curriculum').Count -eq 1)

$seed = Invoke-DarkFactorySeed -BatonHome $box
Check 'seed creates jobs' (@($seed.created).Count -ge 2)
Check 'second seed skips' (@((Invoke-DarkFactorySeed -BatonHome $box).created).Count -eq 0)

$status = Get-DarkFactoryStatus -BatonHome $box
Check 'status has jobs' ($status.jobs_total -ge 2)

Remove-Item -Recurse -Force $box -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
Write-Host 'dark-factory-lib: all checks passed'
exit 0
