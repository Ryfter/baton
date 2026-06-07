#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code statusLine command. Writes session fields into the active run +
  global strip, then prints a one-line status string. Never throws.

.NOTE
  Field names follow Claude Code's statusLine payload; unknown/absent fields
  render as '—'. The 5-hour rate-limit timer is not assumed present (spec §6).
#>
param(
    [string]$RunsRoot    = $(if ($env:ROUTING_RUNS_ROOT) { $env:ROUTING_RUNS_ROOT } else { Join-Path $HOME '.claude/runs' }),
    [string]$PointerPath = (Join-Path $HOME '.claude/current-run.json')
)
$ErrorActionPreference = 'Continue'

function Field($obj, [string[]]$names) {
    foreach ($n in $names) {
        if ($obj -and ($obj.PSObject.Properties.Name -contains $n)) { return $obj.$n }
    }
    return $null
}

$model = '—'; $folder = '—'; $cost = $null
try {
    . "$PSScriptRoot/runs-lib.ps1"
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        $p = $raw | ConvertFrom-Json
        $modelObj = Field $p @('model')
        $model    = (Field $modelObj @('id','display_name')) ; if (-not $model) { $model = '—' }
        $ws       = Field $p @('workspace')
        $dir      = Field $ws @('current_dir','cwd')
        if ($dir) { $folder = Split-Path -Leaf $dir }
        $costObj  = Field $p @('cost')
        $cost     = Field $costObj @('total_cost_usd')

        if (Test-Path $PointerPath) {
            $ptr = Get-Content $PointerPath -Raw | ConvertFrom-Json
            if ($ptr.id) {
                # NOTE: renamed from $args (automatic variable) to $splat to avoid collision
                $splat = @{ RunsRoot = $RunsRoot; Id = $ptr.id }
                if ($model -ne '—') { $splat.Model = $model }
                if ($folder -ne '—') { $splat.Project = $folder }
                if ($null -ne $cost) { $splat.CostUsd = [double]$cost }
                Set-RunRecord @splat
            }
        }
        if ($null -ne $cost) { Set-GlobalStrip -RunsRoot $RunsRoot -SpendTodayUsd ([double]$cost) -ActiveRuns 0 }
    }
} catch { }

$costStr = if ($null -ne $cost) { '$' + ('{0:N2}' -f [double]$cost) } else { '$—' }
Write-Output "$model · $costStr · 📁 $folder"
exit 0
