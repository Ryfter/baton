# scripts/test-fleet-go-goalfile.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$go = Join-Path $here 'fleet-go.ps1'

$root = Join-Path ([IO.Path]::GetTempPath()) ("bgo-" + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $root 'Widget'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$home2 = Join-Path $root 'home'; New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$oldHome = $env:BATON_HOME; $oldRoot = $env:BATON_PROJECTS_ROOT
$env:BATON_HOME = $home2; $env:BATON_PROJECTS_ROOT = $root
$env:BATON_GO_TEST_PLAN = '{"goal":"x","tasks":[{"id":"t1","desc":"noop","depends_on":[],"cost_tier":"local","reversible":true}]}'
$env:BATON_GO_TEST_SPAWN = '1'
try {
    # large goal file (>965 bytes) accepted; sentinel at end must reach the planner
    $sentinel = 'SENTINEL_GOALFILE_END_MARKER_9f3c2a'
    $pad = 'x' * 1000
    $bigBody = "brief prefix`n$pad`n$sentinel"
    $byteLen = [Text.Encoding]::UTF8.GetByteCount($bigBody)
    Assert 'G0 goal body exceeds 965 bytes' ($byteLen -gt 965)
    $bigFile = Join-Path $root 'big-goal.txt'
    [IO.File]::WriteAllText($bigFile, $bigBody)

    $out = & pwsh -NoProfile -File $go -Project 'widget' -GoalFile $bigFile 2>&1
    Assert 'G1 large -GoalFile runs (exit 0)' ($LASTEXITCODE -eq 0)
    Assert 'G2 large -GoalFile carries end sentinel to planner' ("$out" -match [regex]::Escape($sentinel))

    # mutually exclusive with -Goal
    $err = & pwsh -NoProfile -File $go -Project 'widget' -GoalFile $bigFile -Goal 'inline' 2>&1
    Assert 'G3 -GoalFile + -Goal exits 2' ($LASTEXITCODE -eq 2)

    # mutually exclusive with -Text
    $err = & pwsh -NoProfile -File $go -Project 'widget' -GoalFile $bigFile -Text 'inline' 2>&1
    Assert 'G4 -GoalFile + -Text exits 2' ($LASTEXITCODE -eq 2)

    # missing file path
    $missing = Join-Path $root 'no-such-goal.txt'
    $err = & pwsh -NoProfile -File $go -Project 'widget' -GoalFile $missing 2>&1
    Assert 'G5 missing -GoalFile exits 2' ($LASTEXITCODE -eq 2)
    Assert 'G6 missing -GoalFile names the path' ("$err" -match [regex]::Escape($missing))

    # empty / whitespace-only file
    $emptyFile = Join-Path $root 'empty-goal.txt'
    [IO.File]::WriteAllText($emptyFile, "   `n`t  ")
    $err = & pwsh -NoProfile -File $go -Project 'widget' -GoalFile $emptyFile 2>&1
    Assert 'G7 empty -GoalFile exits 2' ($LASTEXITCODE -eq 2)

    # no goal by any route
    $err = & pwsh -NoProfile -File $go -Project 'widget' 2>&1
    Assert 'G8 no goal exits 2' ($LASTEXITCODE -eq 2)
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRoot) { Remove-Item Env:BATON_PROJECTS_ROOT -EA SilentlyContinue } else { $env:BATON_PROJECTS_ROOT = $oldRoot }
    Remove-Item Env:BATON_GO_TEST_PLAN, Env:BATON_GO_TEST_SPAWN -EA SilentlyContinue
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
