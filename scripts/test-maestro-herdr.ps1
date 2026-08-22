#!/usr/bin/env pwsh
# Hermetic tests for maestro-herdr.ps1 (doctor + fire param validation only).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'maestro-herdr.ps1')

$fail = 0
function Assert($l, $c) { if ($c) { Write-Host "PASS $l" } else { Write-Host "FAIL $l"; $script:fail++ } }

$threw = $false
try { Invoke-MaestroHerdrFire -Goal 'test goal' -Target '' } catch { $threw = $true }
Assert 'H1 fire without target throws' $threw

$hasHerdr = $null -ne (Get-Command herdr -ErrorAction SilentlyContinue)
if ($hasHerdr) {
    try {
        $d = Test-HerdrDoctor
        Assert 'H2 doctor returns version string' (-not [string]::IsNullOrWhiteSpace([string]$d.version))
        Assert 'H3 doctor returns exe path' (Test-Path -LiteralPath ([string]$d.exe))
    } catch {
        Assert 'H2/H3 doctor when herdr present' $false
    }
} else {
    Write-Host 'SKIP H2/H3 — herdr not on PATH'
}

if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'
exit 0
