#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:research-gate runner. Resolves the task (url/file/text), produces a
  build/adopt/adapt/inconclusive verdict via the governed fleet, and writes the
  memo — to the active job's research phase when one is active, else stdout.
.NOTES
  Recommend-only. Reads the latest research ensemble synthesis as evidence.
#>
param(
    [string]$Url,
    [string]$File,
    [string]$Text,
    [switch]$Deep,
    [switch]$Json,
    [string]$Out,
    [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'research-gate-lib.ps1')
. (Join-Path $PSScriptRoot 'job-lib.ps1')

# Resolve task text from exactly one of -Url / -File / -Text.
$sources = @($Url, $File, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($sources.Count -ne 1) { Write-Error "Provide exactly one of -Url, -File, or -Text."; exit 2 }
if ($Url)      { $task = (& gh issue view $Url --json title,body --jq '"# " + .title + "\n\n" + .body' 2>&1 | Out-String).Trim() }
elseif ($File) { if (-not (Test-Path $File)) { Write-Error "Input file not found: $File"; exit 2 }; $task = (Get-Content -LiteralPath $File -Raw).Trim() }
else           { $task = $Text.Trim() }

# Test seam: a canned dispatcher injected via env so the suite never calls a model.
if ($env:BATON_RG_TEST_FLEET) { $FleetPath = $env:BATON_RG_TEST_FLEET }
if ($env:BATON_RG_TEST_TOOLS) { $ToolsPath = $env:BATON_RG_TEST_TOOLS }
$dispatcher = $null
if ($env:BATON_RG_TEST_JSON) {
    $canned = $env:BATON_RG_TEST_JSON
    $dispatcher = { param($c,$p) @{ stdout = $canned; stderr=''; exit_code = 0; duration_s = 1 } }
}

# Resolve the active job's research phase (if any).
$jobDir = $null
$state = Read-CurrentJob
if ($state.job_id) { $jobDir = Join-Path (Get-BatonHome) "jobs/$($state.job_id)" }

$gateArgs = @{ Task = $task; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($jobDir) { $gateArgs['JobDir'] = $jobDir }
if ($Deep)   { $gateArgs['Deep']   = $true }
if ($dispatcher) { $gateArgs['Dispatcher'] = $dispatcher; $gateArgs['NoKb'] = $true }
$verdict = Invoke-ResearchGate @gateArgs

$memo = Format-GateMemo -Verdict $verdict
$jsonOut = $verdict | ConvertTo-Json -Depth 6

if ($jobDir) {
    $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
    $dst = Join-Path $jobDir "phases/research"
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Set-Content -Path (Join-Path $dst "gate-$ts.md")   -Value $memo    -Encoding utf8NoBOM
    Set-Content -Path (Join-Path $dst "gate-$ts.json") -Value $jsonOut -Encoding utf8NoBOM
    Write-Host "Verdict written to phases/research/gate-$ts.md"
}
if ($Out) { Set-Content -Path $Out -Value $(if ($Json) { $jsonOut } else { $memo }) -Encoding utf8NoBOM; Write-Host "Wrote $Out" }
if ($Json) { $jsonOut } elseif (-not $jobDir -and -not $Out) { Write-Host $memo } elseif (-not $Out) { Write-Host $memo }
