#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Concurrent fan-out of one prompt to a roster of fleet members.

.DESCRIPTION
  One Start-Job (separate PowerShell process) per provider — process isolation
  prevents env-var collision and contains crashes/hangs. Each job dot-sources
  fleet-lib.ps1 and runs Invoke-Fleet -NoJournal, writing its response to
  <OutputDir>/<provider>.md. The parent waits (with timeout), then writes all
  journal lines SERIALLY (avoiding concurrent-append corruption). Returns a
  manifest. Synthesis is done by the caller (Claude), not here.
#>

. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function Invoke-FleetEnsemble {
    param(
        [Parameter(Mandatory)][string[]]$Providers,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$OutputDir,
        [int]$TimeoutS = 300,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md')
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $libPath = Join-Path $PSScriptRoot 'fleet-lib.ps1'

    # Spawn one process-isolated job per provider.
    $jobMap = @()
    foreach ($p in $Providers) {
        $job = Start-Job -ArgumentList $libPath, $p, $Prompt, $OutputDir, $FleetPath -ScriptBlock {
            param($libPath, $provider, $prompt, $outDir, $fleetPath)
            . $libPath
            $outFile = Join-Path $outDir "$provider.md"
            try {
                $r = Invoke-Fleet -Name $provider -Prompt $prompt -Path $fleetPath -NoJournal
                if ($r.exit_code -eq 0) {
                    Set-Content -Path $outFile -Value ($r.stdout | Out-String).Trim() -Encoding utf8NoBOM
                } else {
                    Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] exit:$($r.exit_code) $($r.stderr)" -Encoding utf8NoBOM
                }
                [pscustomobject]@{ exit_code = $r.exit_code; duration_s = $r.duration_s }
            } catch {
                Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] $($_.Exception.Message)" -Encoding utf8NoBOM
                [pscustomobject]@{ exit_code = -1; duration_s = 0 }
            }
        }
        $jobMap += [pscustomobject]@{ provider = $p; job = $job }
    }

    # Wait for all jobs, bounded by TimeoutS.
    $null = Wait-Job -Job ($jobMap.job) -Timeout $TimeoutS

    $manifest = @()
    foreach ($entry in $jobMap) {
        $job = $entry.job
        $prov = $entry.provider
        $outFile = Join-Path $OutputDir "$prov.md"
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            Set-Content -Path $outFile -Value "[ENSEMBLE TIMEOUT] exceeded ${TimeoutS}s" -Encoding utf8NoBOM
            $manifest += [pscustomobject]@{ provider = $prov; status = 'timeout'; file = $outFile; duration_s = $TimeoutS }
        } else {
            $ret = Receive-Job -Job $job
            $exit = if ($ret -and $null -ne $ret.exit_code) { [int]$ret.exit_code } else { -1 }
            $dur  = if ($ret -and $null -ne $ret.duration_s) { [int]$ret.duration_s } else { 0 }
            $status = if ($exit -eq 0) { 'ok' } else { 'error' }
            $manifest += [pscustomobject]@{ provider = $prov; status = $status; file = $outFile; duration_s = $dur }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    # Parent writes journal lines SERIALLY (no concurrent appends).
    foreach ($m in $manifest) {
        $jexit = switch ($m.status) { 'ok' { 0 } 'timeout' { -2 } default { -1 } }
        Write-FleetJournalLine -Provider $m.provider -DurationS $m.duration_s `
            -ExitCode $jexit -Prompt $Prompt -JournalPath $JournalPath
    }

    return $manifest
}
