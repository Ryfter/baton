#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:usage runner. Reads/writes the Usage Governor journal: worker availability
  state, lockouts with reset ETAs, a global conserve posture, and a usage forecast.
.NOTES
  Availability only — does not dispatch work. Route-around-exhausted is enforced in
  Select-Capability; this is the operator surface for that state.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'status',
    [Parameter(Position=1)][string]$Worker,
    [string]$Reset,
    [string]$Until,
    [string]$Reason,
    [int]$Count,
    [string]$Unit = 'requests',
    [switch]$Json,
    [string]$UsagePath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'usage-journal.jsonl' } else { Join-Path $HOME '.baton/usage-journal.jsonl' }),
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'usage-lib.ps1')
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
try { . (Join-Path $PSScriptRoot 'copilot-credit-lib.ps1') } catch { }   # panel is optional (d079)

function Write-StateLine($s) {
    $note = if ($s.eta_human) { $s.eta_human } elseif ($s.reason) { $s.reason } else { '' }
    Write-Host ("{0,-18} {1,-18} {2}" -f $s.worker, $s.state, $note)
}

switch ($Subcommand) {
    'lockout' {
        $ra = if ($Reset) { ConvertTo-UsageInstant -When $Reset } else { $null }
        Set-WorkerLockout -Worker $Worker -ResetAt $ra -Reason $Reason -UsagePath $UsagePath
    }
    'limit' {
        $ra = if ($Reset) { ConvertTo-UsageInstant -When $Reset } else { $null }
        Set-WorkerLimited -Worker $Worker -ResetAt $ra -Reason $Reason -UsagePath $UsagePath
    }
    'cooldown' { Set-WorkerCooldown -Worker $Worker -Until (ConvertTo-UsageInstant -When $Until) -UsagePath $UsagePath }
    'clear'    { Clear-Worker -Worker $Worker -UsagePath $UsagePath }
    'conserve' { Set-ConserveMode -On ($Worker -eq 'on') -UsagePath $UsagePath }
    'tick'     {
        if ($Count -le 0) { Write-Error "tick requires --count greater than 0 (a 0-count tick would dilute the forecast)"; exit 2 }
        Add-UsageTick -Worker $Worker -Count $Count -Unit $Unit -UsagePath $UsagePath
    }
    'forecast' {
        $targets = if ($Worker) { ,$Worker } else { @(Get-AllWorkerStates -UsagePath $UsagePath -FleetPath $FleetPath | ForEach-Object { $_.worker }) }
        $fc = foreach ($w in $targets) { Get-UsageForecast -Worker $w -UsagePath $UsagePath -FleetPath $FleetPath }
        if ($Json) { @($fc) | ConvertTo-Json -Depth 6 }
        else { foreach ($f in $fc) { Write-Host ("{0,-18} {1,-16} rate={2}/{3}{4}" -f $f.worker, $f.status, $f.run_rate, $f.unit, $(if ($null -ne $f.days_to_exhaustion) { " ~$($f.days_to_exhaustion)d left" } else { '' })) } }
        return
    }
    'status' {
        $states = Get-AllWorkerStates -UsagePath $UsagePath -FleetPath $FleetPath
        $conserve = Get-ConserveMode -UsagePath $UsagePath
        # Copilot credit panel (d079): gate on a locally-configured budget BEFORE any
        # fetch, so an unconfigured box renders byte-for-byte as before. Fail-open.
        $ccForecast = $null
        if (Get-Command Get-CopilotCreditForecast -ErrorAction SilentlyContinue) {
            $ccBudget = Get-WorkerBudget -Worker 'gh-copilot' -FleetPath $FleetPath
            if ($null -ne $ccBudget) {
                try { $ccForecast = Get-CopilotCreditForecast -FleetPath $FleetPath } catch { $ccForecast = $null }
            }
        }
        if ($Json) {
            $obj = [ordered]@{ conserve_mode = $conserve; workers = @($states) }
            if ($null -ne $ccForecast) { $obj.copilot_credits = $ccForecast }
            [pscustomobject]$obj | ConvertTo-Json -Depth 6
        }
        else {
            Write-Host ("conserve_mode: {0}" -f $conserve)
            Write-Host ("{0,-18} {1,-18} {2}" -f 'WORKER','STATE','ETA/REASON')
            foreach ($s in $states) { Write-StateLine $s }
            if ($null -ne $ccForecast) { Write-CopilotCreditPanel -Forecast $ccForecast }
        }
        if (-not $Json) {
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds @('budget') }
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use status|lockout|limit|cooldown|clear|conserve|tick|forecast)"; exit 2 }
}

# Mutating subcommands: echo the resulting state unless --json.
if (-not $Json) {
    if ($Subcommand -eq 'conserve') { Write-Host ("conserve_mode -> {0}" -f (Get-ConserveMode -UsagePath $UsagePath)) }
    elseif ($Worker) {
        $st = Get-WorkerState -Worker $Worker -UsagePath $UsagePath
        Write-Host ("{0} -> {1}{2}" -f $Worker, $st.state, $(if ($st.eta_human) { " ($($st.eta_human))" } else { '' }))
    }
}
