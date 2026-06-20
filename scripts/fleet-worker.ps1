#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:worker runner. Dispatches a metered worker (auto-ticks the Usage Governor
  and maps rate-limits to worker states) and reports per-worker budget/utilization.
.NOTES
  Advisory only. Route-around-exhausted is enforced inside Select-Capability.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'status',
    [Parameter(Position=1)][string]$Name,
    [string]$Model,
    [string]$Prompt,
    [string]$File,
    [switch]$Dry,
    [switch]$Json,
    [string]$UsagePath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'usage-journal.jsonl' } else { Join-Path $HOME '.baton/usage-journal.jsonl' }),
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'worker-lib.ps1')

switch ($Subcommand) {
    'run' {
        if (-not $Name) { Write-Error 'run requires a worker name'; exit 2 }
        $p = $null
        if ($File)        { $p = Get-Content -LiteralPath $File -Raw }
        elseif ($Prompt)  { $p = $Prompt }
        else { Write-Error 'run requires --prompt or --file'; exit 2 }
        $res = Invoke-Worker -Name $Name -Prompt $p -Model $Model -UsagePath $UsagePath -FleetPath $FleetPath -Dry:$Dry
        if ($Json) { [pscustomobject]$res | ConvertTo-Json -Depth 6 }
        else {
            if ($res.output) { Write-Host $res.output }
            Write-Host '---'
            Write-Host (Format-WorkerReport -Result ([hashtable]$res))
        }
        return
    }
    'status' {
        $targets = if ($Name) { ,$Name } else {
            @(Read-Fleet -Path $FleetPath | Where-Object { Test-WorkerAdapter -Provider $_ } | ForEach-Object { [string]$_.name })
        }
        $rows = foreach ($w in $targets) { Get-WorkerStatus -Worker $w -UsagePath $UsagePath -FleetPath $FleetPath }
        if ($Json) { @($rows) | ConvertTo-Json -Depth 6 }
        else {
            Write-Host ("{0,-18} {1,-16} {2,-10} {3}" -f 'WORKER','STATE','UTIL','FORECAST')
            foreach ($r in $rows) {
                $u = if ($null -ne $r.utilization_pct) { "$($r.utilization_pct)%" } else { 'n/a' }
                Write-Host ("{0,-18} {1,-16} {2,-10} {3}" -f $r.worker, $r.state, $u, $r.forecast_status)
            }
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use run|status)"; exit 2 }
}
