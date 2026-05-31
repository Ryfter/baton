#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Autonomous backlog driver: DAG-ordered, worktree-isolated, gated multi-model dispatch (d008).

.DESCRIPTION
  Strings together the proven primitives into the set-and-forget loop:
    1. Build a dependency DAG from the task list (topological order; cycle-detected).
    2. For each ready item: create an isolated worktree off the integration branch,
       dispatch the implementation to its assigned model, then run the HARD MERGE GATE
       (scripts/fleet-orchestrate.ps1). Merge into integration iff the gate passes.
    3. If a gate blocks an item, every item depending on it is marked dep-blocked —
       unrelated branches keep flowing. Master is never touched.
    4. Live status is emitted to <OutputDir> (_ensemble.json + <id>.live.json) so the
       dashboard cockpit renders the run in real time.

  The implementer is INJECTABLE (a hashtable of model -> scriptblock) so the loop is
  deterministically unit-testable without any model call. New-CodexImplementer wires
  the real `codex exec -` agentic editor for production runs. Text-only models that
  cannot edit a worktree simply have no implementer and are reported 'no-implementer'.
#>

. (Join-Path $PSScriptRoot 'fleet-orchestrate.ps1')
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

function Get-TopoOrder {
    <# Kahn's algorithm over @( @{id; depends_on=@()} ). Throws on cycle/unknown dep. #>
    param([Parameter(Mandatory)][array]$Tasks)
    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $indeg = @{}; $adj = @{}
    foreach ($t in $Tasks) { $indeg[$t.id] = 0; $adj[$t.id] = @() }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if (-not $d) { continue }
            if (-not $byId.ContainsKey($d)) { throw "Task '$($t.id)' depends on unknown '$d'." }
            $adj[$d] += $t.id
            $indeg[$t.id]++
        }
    }
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($t in $Tasks) { if ($indeg[$t.id] -eq 0) { $queue.Enqueue($t.id) } }
    $order = @()
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue(); $order += $n
        foreach ($m in $adj[$n]) { $indeg[$m]--; if ($indeg[$m] -eq 0) { $queue.Enqueue($m) } }
    }
    if ($order.Count -ne $Tasks.Count) { throw "Dependency cycle detected among backlog tasks." }
    return $order
}

function Write-ItemLive {
    param([string]$OutputDir, [string]$Id, [string]$Model, [string]$State, [hashtable]$Extra)
    $rec = @{ label = $Id; provider = $Model; state = $State }
    if ($Extra) { foreach ($k in $Extra.Keys) { $rec[$k] = $Extra[$k] } }
    $rec | ConvertTo-Json -Compress -Depth 5 |
        Set-Content -Path (Join-Path $OutputDir "$Id.live.json") -Encoding utf8NoBOM
}

function New-CodexImplementer {
    <# Real agentic editor: run `codex exec -` with cwd = the item worktree so codex
       edits files in place. Returns a scriptblock(param($wtPath,$item)). #>
    param([int]$TimeoutS = 600)
    return {
        param($wtPath, $item)
        $prompt = $item.prompt
        Push-Location $wtPath
        try {
            $tmp = [System.IO.Path]::GetTempFileName()
            Set-Content -LiteralPath $tmp -Value $prompt -Encoding utf8NoBOM
            try { Get-Content -LiteralPath $tmp -Raw | & codex exec - 2>&1 | Out-Null }
            finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        } finally { Pop-Location }
    }
}

function Invoke-BacklogItem {
    <# One item: worktree -> implement -> gate -> merge-or-block. Emits live status. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Item,
        [Parameter(Mandatory)][scriptblock]$Implementer,
        [string]$Integration = 'integration/backlog',
        [string]$OutputDir,
        [string]$WorktreeRoot
    )
    $id = $Item.id; $model = $Item.model
    $allowed = if ($Item.allowed_paths) { @($Item.allowed_paths) } else { @('*') }
    $maxFiles = if ($Item.max_files) { [int]$Item.max_files } else { 20 }
    $testCmd  = $Item.test_command

    $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'running' -Extra @{ branch = $wt.branch } }

    $implErr = $null
    try { & $Implementer $wt.path $Item } catch { $implErr = $_.Exception.Message }

    $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $wt.path -Branch $wt.branch `
        -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
        -TestCommand $testCmd -AutoCommit

    $reasons = @($res.gate.reasons)
    if ($implErr) { $reasons = @("implementer-error: $implErr") + $reasons }
    $state = if ($res.merged) { 'done' } else { 'blocked' }
    if ($OutputDir) {
        Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State $state `
            -Extra @{ branch = $wt.branch; merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed) }
    }
    return [pscustomobject]@{
        id = $id; model = $model; branch = $wt.branch; path = $wt.path
        merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed)
    }
}

function Invoke-Backlog {
    <#
    .SYNOPSIS  Drive the whole backlog in dependency order through the gate.
    .PARAMETER Tasks         @( @{ id; model; prompt; allowed_paths; test_command; max_files; depends_on } )
    .PARAMETER Implementers  @{ '<model>' = <scriptblock(param($wtPath,$item))> }
    .OUTPUTS     @( per-item result objects ) with .merged / .reasons
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][array]$Tasks,
        [Parameter(Mandatory)][hashtable]$Implementers,
        [string]$Integration = 'integration/backlog',
        [string]$IntegrationBase = 'master',
        [string]$OutputDir,
        [string]$WorktreeRoot
    )
    if ($OutputDir -and -not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    Initialize-IntegrationBranch -RepoRoot $RepoRoot -Base $IntegrationBase -Name $Integration | Out-Null

    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $order = Get-TopoOrder -Tasks $Tasks

    if ($OutputDir) {
        $metaTasks = @($Tasks | ForEach-Object { @{ label = $_.id; provider = $_.model } })
        Write-EnsembleRunMeta -OutputDir $OutputDir -Kind 'backlog' -Prompt 'autonomous backlog run' `
            -Tasks $metaTasks -State 'running' -Started ((Get-Date).ToString('o'))
        foreach ($t in $Tasks) { Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued' }
    }

    $results = @(); $blocked = @{}
    foreach ($id in $order) {
        $item = $byId[$id]
        # dep-block: if any dependency failed to merge, skip this item.
        $deadDep = @(@($item.depends_on) | Where-Object { $_ -and $blocked[$_] })
        if ($deadDep.Count -gt 0) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("dep-blocked: $($deadDep -join ', ')") } }
            $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; reasons = @("dep-blocked: $($deadDep -join ', ')"); changed = @() }
            continue
        }
        $impl = $Implementers[[string]$item.model]
        if (-not $impl) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("no-implementer: '$($item.model)' cannot edit a worktree") } }
            $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; reasons = @("no-implementer: '$($item.model)'"); changed = @() }
            continue
        }
        $r = Invoke-BacklogItem -RepoRoot $RepoRoot -Item $item -Implementer $impl `
            -Integration $Integration -OutputDir $OutputDir -WorktreeRoot $WorktreeRoot
        if (-not $r.merged) { $blocked[$id] = $true }
        $results += $r
    }

    if ($OutputDir) {
        $manifest = @($results | ForEach-Object { @{ label = $_.id; provider = $_.model; status = ($_.merged ? 'ok' : 'error'); duration_s = 0 } })
        $metaTasks = @($Tasks | ForEach-Object { @{ label = $_.id; provider = $_.model } })
        Write-EnsembleRunMeta -OutputDir $OutputDir -Kind 'backlog' -Prompt 'autonomous backlog run' `
            -Tasks $metaTasks -State 'done' -Started ((Get-Date).ToString('o')) -Manifest $manifest
    }
    return $results
}
