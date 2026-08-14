#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Live smoke test for the OpenRouter rows — proves the authenticated HTTP
  transport reaches a real paid endpoint, and reports what each call cost.

.DESCRIPTION
  Runs the canary battery against every enabled `platform: openrouter` row and
  prints a per-row verdict plus the account's credit position before and after,
  so the spend of the smoke itself is visible. Requires $env:OPENROUTER_API_KEY.

  This is a LIVE test: it spends real credit (fractions of a cent on the default
  rows). Nothing here mutates state beyond the fleet journal.

.EXAMPLE
  pwsh -NoProfile -File scripts\smoke-openrouter.ps1

.EXAMPLE
  pwsh -NoProfile -File scripts\smoke-openrouter.ps1 -Rows openrouter-free
#>
param(
    [string[]]$Rows,
    [int]$TimeoutS = 120,
    [string]$FleetPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')
. (Join-Path $PSScriptRoot 'fleet-probe-lib.ps1')

$path = if ($FleetPath) { $FleetPath } else { Join-Path (Get-BatonHome) 'fleet.yaml' }

function Get-OpenRouterCredit {
    <# Read the account's credit position straight from the key endpoint. Purely
       diagnostic here — the routing-facing probe lives in usage-probe-lib. #>
    param([Parameter(Mandatory)][hashtable]$Provider)
    try {
        $auth = Resolve-FleetHttpAuth -Provider $Provider
        if ($auth.error) { return $null }
        $uri = "$([string]$Provider.base_url.TrimEnd('/'))/v1/key"
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $auth.headers -TimeoutSec 20
        return $response.data
    } catch { return $null }
}

function Format-Credit {
    param($Data)
    if ($null -eq $Data) { return '(unavailable)' }
    $used = [double]$Data.usage
    if ($null -eq $Data.limit) { return ('${0:N4} used, no key limit set' -f $used) }
    $limit = [double]$Data.limit
    $pct = if ($limit -gt 0) { ($used / $limit) * 100 } else { 0 }
    return ('${0:N4} of ${1:N2} used ({2:N1}%)' -f $used, $limit, $pct)
}

$fleet = Read-Fleet -Path $path
$targets = @($fleet | Where-Object {
    $_.enabled -eq $true -and [string]$_.platform -eq 'openrouter' -and
    (-not $Rows -or $Rows -contains [string]$_.name)
})
if ($targets.Count -eq 0) {
    Write-Host 'No enabled openrouter rows found in the fleet.' -ForegroundColor Yellow
    exit 2
}

# Fail early and clearly rather than letting every row 401 in turn.
$keyVars = @($targets | ForEach-Object { [string]$_.api_key_env } | Where-Object { $_ } | Select-Object -Unique)
foreach ($keyVar in $keyVars) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($keyVar))) {
        Write-Host "$keyVar is not set — set it before smoking. See docs/authenticated-instruments.md." -ForegroundColor Red
        exit 2
    }
}

Write-Host "=== OpenRouter live smoke ($($targets.Count) row(s)) ===" -ForegroundColor Cyan
$before = Get-OpenRouterCredit -Provider $targets[0]
Write-Host "Credit before: $(Format-Credit $before)"
Write-Host ''

$results = foreach ($row in $targets) {
    Write-Host "-- $($row.name) [$($row.model_default)]" -ForegroundColor Cyan
    $probe = Invoke-FleetProbe -Provider $row -TimeoutS $TimeoutS -FleetPath $path
    $colour = if ($probe.live -eq 'live_ok') { 'Green' } else { 'Red' }
    Write-Host "   $($probe.live)  score=$($probe.score)/4  $($probe.elapsed_s)s  $($probe.reason)" -ForegroundColor $colour
    [pscustomobject]@{
        ROW = $row.name; MODEL = $row.model_default; LIVE = $probe.live
        SCORE = $probe.score; SECONDS = $probe.elapsed_s; REASON = $probe.reason
    }
}

Write-Host ''
$after = Get-OpenRouterCredit -Provider $targets[0]
Write-Host "Credit after:  $(Format-Credit $after)"
if ($null -ne $before -and $null -ne $after) {
    $spent = [double]$after.usage - [double]$before.usage
    Write-Host ('Smoke cost:    ${0:N6}' -f $spent)
}
Write-Host ''
$results | Format-Table -AutoSize | Out-String | Write-Host

$failed = @($results | Where-Object { $_.LIVE -ne 'live_ok' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) row(s) did not answer the canary." -ForegroundColor Red
    exit 1
}
Write-Host 'All rows answered the canary battery.' -ForegroundColor Green
