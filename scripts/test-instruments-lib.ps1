#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/instruments-lib.ps1"

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$repo = Split-Path -Parent $PSScriptRoot
$path = Join-Path $repo 'references/instruments.yaml'
$rows = @(Read-Instruments -Path $path)
Check 'registry parses' ($rows.Count -ge 5)
Check 'coding instrument exists' (@($rows | Where-Object { $_.name -eq 'coding' }).Count -eq 1)
Check 'security-researcher scheduled' (@($rows | Where-Object { $_.name -eq 'security-researcher' -and $_.kind -eq 'scheduled' }).Count -eq 1)

$coding = Get-InstrumentByName -Name 'coding' -Path $path
Check 'Get-InstrumentByName seat' ([string]$coding.default_seat -eq 'openrouter-ox-alpha')

$job = [pscustomobject]@{ instrument = 'research'; goal = 'scan docs' }
$res = Resolve-InstrumentForJob -Job $job -Path $path
Check 'Resolve-InstrumentForJob by name' ([string]$res.name -eq 'research')

$capJob = [pscustomobject]@{ capability = 'security-sweep'; goal = 'nightly' }
$res2 = Resolve-InstrumentForJob -Job $capJob -Path $path
Check 'Resolve-InstrumentForJob by capability' ([string]$res2.name -eq 'security-researcher')

$brief = Get-InstrumentInitBrief -Instrument $coding -RepoRoot $repo
Check 'init brief resolves' ($brief -match 'pytest|python')

if ($script:fail -gt 0) { exit 1 }
Write-Host "instruments-lib: all checks passed ($($rows.Count) rows)"
exit 0
