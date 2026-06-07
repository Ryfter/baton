#!/usr/bin/env pwsh
# Writer library for the legibility feed (~/.claude/runs/). Producers (hooks,
# status line, fleet dispatch) call these. Reads are done in Python by the dashboard.

function Get-RunsRoot([string]$RunsRoot) {
    if ($RunsRoot) { return $RunsRoot }
    if ($env:ROUTING_RUNS_ROOT) { return $env:ROUTING_RUNS_ROOT }
    return (Join-Path $HOME '.claude/runs')
}

function Ensure-RunDir([string]$RunsRoot, [string]$Id) {
    $dir = Join-Path (Get-RunsRoot $RunsRoot) $Id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Now-Iso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

function Set-RunRecord {
    param(
        [string]$RunsRoot, [Parameter(Mandatory)][string]$Id, [string]$Name,
        [string]$Model, [string]$Status, [string]$Reasoning, [string]$Project,
        [string]$Tree, [bool]$Worktree = $false, [object]$ContextPct,
        [double]$CostUsd = 0, [int]$TokensIn = 0, [int]$TokensOut = 0,
        [string]$CurrentStep, [object]$ParkedQuestion, [string[]]$FilesTouched
    )
    $dir = Ensure-RunDir $RunsRoot $Id
    $path = Join-Path $dir 'run.json'
    $rec = if (Test-Path $path) { Get-Content $path -Raw | ConvertFrom-Json } else { [pscustomobject]@{ id = $Id; started_at = (Now-Iso) } }
    $rec | Add-Member -NotePropertyName id -NotePropertyValue $Id -Force
    if ($Name)        { $rec | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
    if ($Model)       { $rec | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force }
    if ($Status)      { $rec | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force }
    if ($Reasoning)   { $rec | Add-Member -NotePropertyName reasoning -NotePropertyValue $Reasoning -Force }
    if ($Project)     { $rec | Add-Member -NotePropertyName project -NotePropertyValue $Project -Force }
    if ($Tree)        { $rec | Add-Member -NotePropertyName tree -NotePropertyValue $Tree -Force }
    # Guard: only write these when caller explicitly passed them (partial updates must not reset existing values)
    if ($PSBoundParameters.ContainsKey('Worktree'))   { $rec | Add-Member -NotePropertyName worktree -NotePropertyValue $Worktree -Force }
    if ($null -ne $ContextPct)                        { $rec | Add-Member -NotePropertyName context_pct -NotePropertyValue ([int]$ContextPct) -Force }
    if ($PSBoundParameters.ContainsKey('CostUsd'))    { $rec | Add-Member -NotePropertyName cost_usd -NotePropertyValue $CostUsd -Force }
    if ($PSBoundParameters.ContainsKey('TokensIn'))   { $rec | Add-Member -NotePropertyName tokens_in -NotePropertyValue $TokensIn -Force }
    if ($PSBoundParameters.ContainsKey('TokensOut'))  { $rec | Add-Member -NotePropertyName tokens_out -NotePropertyValue $TokensOut -Force }
    if ($CurrentStep) { $rec | Add-Member -NotePropertyName current_step -NotePropertyValue $CurrentStep -Force }
    if ($null -ne $ParkedQuestion) { $rec | Add-Member -NotePropertyName parked_question -NotePropertyValue $ParkedQuestion -Force }
    # FilesTouched: ensure single-element lists serialise as JSON arrays, not bare strings
    if ($PSBoundParameters.ContainsKey('FilesTouched')) {
        $rec | Add-Member -NotePropertyName files_touched -NotePropertyValue ([object[]]$FilesTouched) -Force
    }
    $rec | Add-Member -NotePropertyName updated_at -NotePropertyValue (Now-Iso) -Force
    $rec | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8
}

function Add-RunEvent {
    param(
        [string]$RunsRoot, [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$What,
        [string]$Why, [string]$Status
    )
    $dir = Ensure-RunDir $RunsRoot $Id
    $obj = [ordered]@{ ts = (Now-Iso); kind = $Kind; what = $What }
    if ($Why)    { $obj.why = $Why }
    if ($Status) { $obj.status = $Status }
    ($obj | ConvertTo-Json -Compress) | Add-Content -Path (Join-Path $dir 'events.jsonl') -Encoding utf8
}

function Set-RunStatus {
    param([string]$RunsRoot, [Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Status, [object]$ParkedQuestion)
    Set-RunRecord -RunsRoot $RunsRoot -Id $Id -Status $Status -ParkedQuestion $ParkedQuestion
}

function Set-GlobalStrip {
    param([string]$RunsRoot, [object]$RateLimitPct, [string]$RateLimitResetsAt, [double]$SpendTodayUsd = 0, [int]$ActiveRuns = 0)
    $root = Get-RunsRoot $RunsRoot
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $obj = [ordered]@{ spend_today_usd = $SpendTodayUsd; active_runs = $ActiveRuns }
    if ($null -ne $RateLimitPct) { $obj.rate_limit_pct = [int]$RateLimitPct }
    if ($RateLimitResetsAt)      { $obj.rate_limit_resets_at = $RateLimitResetsAt }
    ($obj | ConvertTo-Json) | Set-Content -Path (Join-Path $root 'index.json') -Encoding utf8
}

function Get-RunAnswer {
    param([string]$RunsRoot, [Parameter(Mandatory)][string]$Id)
    $path = Join-Path (Get-RunsRoot $RunsRoot) "$Id/answer.txt"
    if (Test-Path $path) { return (Get-Content $path -Raw).TrimEnd("`r","`n") }
    return $null
}
