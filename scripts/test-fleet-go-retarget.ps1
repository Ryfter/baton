# scripts/test-fleet-go-retarget.ps1
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
    # known slug → runs, exit 0, report mentions the resolved run
    $out = & pwsh -NoProfile -File $go -Project 'widget' -Goal 'do a thing' 2>&1
    Assert 'G1 known --slug runs (exit 0)' ($LASTEXITCODE -eq 0)

    # unknown slug → exit 2, stderr message
    $err = & pwsh -NoProfile -File $go -Project 'ghost' -Goal 'x' 2>&1
    Assert 'G2 unknown --slug exits 2' ($LASTEXITCODE -eq 2)
    Assert 'G3 unknown --slug names the slug' ("$err" -match 'ghost')
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRoot) { Remove-Item Env:BATON_PROJECTS_ROOT -EA SilentlyContinue } else { $env:BATON_PROJECTS_ROOT = $oldRoot }
    Remove-Item Env:BATON_GO_TEST_PLAN, Env:BATON_GO_TEST_SPAWN -EA SilentlyContinue
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
