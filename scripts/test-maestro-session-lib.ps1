#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'maestro-session-lib.ps1')
. (Join-Path $PSScriptRoot 'holdout-lib.ps1')

$fail = 0
function Assert($l, $c) { if ($c) { Write-Host "PASS $l" } else { Write-Host "FAIL $l"; $script:fail++ } }

$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-msess-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
try {
    $s = Set-MaestroProjectSession -Project 'baton' -HerdrTarget 'maestro-baton' -Provider 'grok' -Kind 'grok' -BatonHome $tmp
    Assert 'S1 register herdr target' ($s.herdr_target -eq 'maestro-baton')
    $env:HERDR_TARGET = $null
    Assert 'S2 resolve from registry' ((Resolve-MaestroHerdrTarget -Project 'baton' -BatonHome $tmp) -eq 'maestro-baton')
    $env:HERDR_TARGET = 'override-pane'
    Assert 'S3 env overrides registry' ((Resolve-MaestroHerdrTarget -Project 'baton' -BatonHome $tmp) -eq 'override-pane')

    $path = Write-MaestroHandoff -JobId 'mj-test01' -Goal 'Ship holdout spike' -CurrentState 'branch clean' -BatonHome $tmp
    Assert 'S4 handoff written' (Test-Path -LiteralPath $path)
    $expanded = Expand-MaestroGoalWithHandoff -Goal 'Add tests' -JobId 'mj-test01' -BatonHome $tmp
    Assert 'S5 expanded goal cites handoff' ($expanded -match 'Ship holdout spike' -and $expanded -match 'Add tests')

    Assert 'S6 holdout path excluded' (Test-PathIsHoldoutExcluded -Path 'src/.baton/holdout/manifest.json')
    Assert 'S7 normal path not holdout' (-not (Test-PathIsHoldoutExcluded -Path 'scripts/foo.ps1'))
}
finally {
    $env:BATON_HOME = $prev
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'
exit 0
