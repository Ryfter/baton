#!/usr/bin/env pwsh
# Bridge: project one backlog item (id x model x worktree) into the legibility
# feed ($BATON_HOME/runs/) as a single run, updated across its lifecycle. Called
# from the PARENT process of the fleet drivers — never the Start-Job worker.

. (Join-Path $PSScriptRoot 'runs-lib.ps1')

function Publish-ItemRun {
    param(
        [string]$RunsRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][ValidateSet('queued','running','done','blocked')][string]$State,
        [string]$Name,
        [string]$Project = 'baton',
        [string]$Branch,
        [string[]]$Reasons
    )
    if (-not $Name) { $Name = $Id }
    $runId = "backlog-$Id-$Model"

    # ensemble state -> legibility status
    $status = switch ($State) {
        'queued'  { 'queued' }
        'running' { 'running' }
        'done'    { 'done' }
        'blocked' { 'failed' }
    }

    $recArgs = @{ RunsRoot = $RunsRoot; Id = $runId; Name = $Name; Model = $Model; Status = $status; Project = $Project }
    if ($Branch) { $recArgs['Tree'] = $Branch; $recArgs['Worktree'] = $true }
    if ($State -eq 'blocked' -and $Reasons -and $Reasons.Count -gt 0) {
        $recArgs['CurrentStep'] = "blocked: $($Reasons[0])"
    }
    Set-RunRecord @recArgs

    # one narration event per transition
    switch ($State) {
        'queued'  { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'action' -What "queued for $Model" }
        'running' { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'action' -What "implementing $Id" }
        'done'    { Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'result' -What "merged to integration" -Status 'done' }
        'blocked' {
            $why = if ($Reasons) { ($Reasons -join '; ') } else { 'gate blocked' }
            Add-RunEvent -RunsRoot $RunsRoot -Id $runId -Kind 'result' -What "gate blocked: $Id" -Why $why -Status 'failed'
        }
    }
}
