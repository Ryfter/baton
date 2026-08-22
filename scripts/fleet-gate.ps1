#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:gate runner. Runs a competitive acceptance review of a work artifact
  (file / git diff / stdin) and prints an accept/polish/reject verdict with
  deduped findings + a polish brief. Advisory only — never blocks.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'run',
    [string]$Task,
    [string]$Artifact,
    [string]$File,
    [string]$Diff,
    [string]$Reviewers,
    [switch]$Panel,
    [switch]$FailLoud,
    [switch]$Json,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$RepoPath,
    [string]$BaseSha = 'HEAD',
    [string]$Worktree
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate-lib.ps1')
. (Join-Path $PSScriptRoot 'holdout-lib.ps1')
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }

switch ($Subcommand) {
    'holdout' {
        if (-not $RepoPath) { [Console]::Error.WriteLine('holdout requires -RepoPath'); exit 2 }
        $wt = if ($Worktree) { $Worktree } else { $RepoPath }
        $base = (& git -C $RepoPath rev-parse $BaseSha 2>$null)
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("holdout: invalid BaseSha $BaseSha"); exit 2 }
        $suite = Invoke-HoldoutSuite -RepoPath $RepoPath -BaseSha $base.Trim() -WorktreeRoot $wt
        if ($Json) { $suite | ConvertTo-Json -Depth 6 }
        else { Write-Host (Format-HoldoutReport -SuiteResult $suite) }
        exit $(if ($suite.ok) { 0 } else { 1 })
    }
    'run' {
        if (-not $Task) { [Console]::Error.WriteLine('run requires --task (what the artifact was supposed to do)'); exit 2 }
        $art = $null
        if     ($File)     { $art = Get-Content -LiteralPath $File -Raw }
        elseif ($Diff)     { $art = (& git diff $Diff 2>&1 | Out-String) }
        elseif ($Artifact) { $art = $Artifact }
        elseif ([Console]::IsInputRedirected) { $art = [Console]::In.ReadToEnd() }
        else { [Console]::Error.WriteLine('run requires --file, --diff, --artifact, or piped stdin'); exit 2 }
        if ([string]::IsNullOrWhiteSpace($art)) { [Console]::Error.WriteLine('run: artifact is empty'); exit 2 }
        $revList = if ($Reviewers) { @($Reviewers -split '\s*,\s*' | Where-Object { $_ }) } else { @() }
        $callArgs = @{ Artifact = $art; Task = $Task; FleetPath = $FleetPath }
        if ($revList.Count) { $callArgs['Reviewers'] = $revList }
        if ($Panel) { $callArgs['Panel'] = $true }
        if ($FailLoud) { $callArgs['FailLoud'] = $true }
        try { $res = Invoke-AcceptanceGate @callArgs }
        catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
        if ($Json) { [pscustomobject]$res | ConvertTo-Json -Depth 6 }
        else {
            Write-Host (Format-GateReport -Result ([hashtable]$res))
            Write-Host '---'
            Write-Host $res.polish_brief
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
        }
        return
    }
    default { [Console]::Error.WriteLine("unknown subcommand: $Subcommand (use run|holdout)"); exit 2 }
}
