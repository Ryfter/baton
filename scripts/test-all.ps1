#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Run every scripts/test-*.ps1 suite and exit non-zero if any of them fails.
.DESCRIPTION
  Baton's suites are standalone scripts that print PASS:/FAIL: lines and exit 1 on
  failure. Until this script there was no single command that ran them all, which
  meant .baton/verification.json had no way to express "the whole repo still
  passes" — every profile could only name one suite. This is that command.

  Exit code is the contract (the verification runner reads it, not the text):
  0 = every suite exited 0; 1 = at least one suite failed or timed out.

  -Filter takes a wildcard matched against the suite FILE NAME, so a profile can
  verify one area (e.g. -Filter 'test-conductor*') without a new script per area.
.NOTES
  Excluded from bootstrap deployment by the existing 'test-*.ps1' exclude pattern.
#>
param(
    [string]$Filter = 'test-*.ps1',
    [int]$TimeoutSeconds = 300,
    # Suites to skip, by file name (wildcards allowed). Kept EMPTY on purpose: a
    # skip list that ships green is a lie about coverage. Pass it explicitly when
    # you need to quarantine a suite for one run.
    [string[]]$Exclude = @()
)

$ErrorActionPreference = 'Stop'
$suiteDir = $PSScriptRoot

# This script's own name matches the default 'test-*.ps1' filter, so without an
# unconditional self-exclusion it Start-Processes itself once per pass and forks
# until the box runs out of processes -- meaning the 'full' profile could never
# pass. Not part of -Exclude: a caller-supplied list must not be able to switch
# the guard off.
$selfName = Split-Path -Leaf $PSCommandPath

$suites = @(Get-ChildItem -Path $suiteDir -Filter $Filter -File | Sort-Object Name |
    Where-Object { $_.Name -ne $selfName } |
    Where-Object { $name = $_.Name; -not (@($Exclude) | Where-Object { $name -like $_ }) })

if ($suites.Count -lt 1) {
    Write-Host "test-all: no suite matched filter '$Filter' in $suiteDir"
    exit 1
}

$failed = [System.Collections.ArrayList]@()
$passed = 0
foreach ($suite in $suites) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-File', $suite.FullName) `
        -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        [void]$failed.Add("$($suite.Name) (timeout after ${TimeoutSeconds}s)")
        Write-Host "TIMEOUT: $($suite.Name)"
        continue
    }
    $sw.Stop()
    if ($proc.ExitCode -eq 0) {
        $passed++
        Write-Host ("SUITE PASS: {0} ({1:n1}s)" -f $suite.Name, $sw.Elapsed.TotalSeconds)
    } else {
        [void]$failed.Add("$($suite.Name) (exit $($proc.ExitCode))")
        Write-Host ("SUITE FAIL: {0} (exit {1}, {2:n1}s)" -f $suite.Name, $proc.ExitCode, $sw.Elapsed.TotalSeconds)
    }
}

Write-Host ''
Write-Host "test-all: $passed/$($suites.Count) suite(s) passed"
if ($failed.Count -gt 0) {
    Write-Host "FAILED SUITES:"
    foreach ($f in $failed) { Write-Host "  - $f" }
    exit 1
}
exit 0
