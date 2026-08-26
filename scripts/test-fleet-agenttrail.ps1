#!/usr/bin/env pwsh
# Hermetic checks for scripts/fleet-agenttrail.ps1 — no live npx daemon required.
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agenttrail-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$batonHome = Join-Path $tmp 'baton'
New-Item -ItemType Directory -Force -Path $batonHome | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = $batonHome

$script = Join-Path $PSScriptRoot 'fleet-agenttrail.ps1'
try {
    Check 'script exists' (Test-Path -LiteralPath $script)

    $status = & pwsh -NoProfile -File $script -Action status -Json 2>&1 | Out-String
    Check 'status exits 0 on empty observability' ($LASTEXITCODE -eq 0)
    try {
        $doc = $status | ConvertFrom-Json
        Check 'status ok true' ([bool]$doc.ok)
        Check 'status sidecars empty array' (@($doc.sidecars).Count -eq 0)
        Check 'status pulse_exists false' ($doc.pulse_exists -eq $false)
    } catch {
        Check 'status returns json' $false
    }

    & pwsh -NoProfile -File $script -Action start -Json 2>&1 | Out-Null
    Check 'start without project fails' ($LASTEXITCODE -ne 0)

    & pwsh -NoProfile -File $script -Action stop -Json 2>&1 | Out-Null
    Check 'stop without project fails' ($LASTEXITCODE -ne 0)
} finally {
    $env:BATON_HOME = $prevHome
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
Write-Host 'fleet-agenttrail: all checks passed'
exit 0
