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
. (Join-Path $PSScriptRoot 'fleet-runs-bridge.ps1')

function script:Publish-ItemRunSafe {
    # NB: parameter is $Splat, not $Args — $Args is a PowerShell automatic
    # variable (unbound-arg array) and splatting it (@Args) picks up the
    # automatic, not this param, breaking the call.
    param([hashtable]$Splat)
    try { Publish-ItemRun @Splat } catch { Write-Verbose "runs-feed publish failed: $_" }
}

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
    Set-JsonFileAtomic -Path (Join-Path $OutputDir "$Id.live.json") -Json ($rec | ConvertTo-Json -Compress -Depth 5)
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
    Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }

    $implErr = $null
    try { & $Implementer $wt.path $Item } catch { $implErr = $_.Exception.Message }

    $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $wt.path -Branch $wt.branch `
        -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
        -TestCommand $testCmd -WorktreeRoot $WorktreeRoot -AutoCommit

    $reasons = @($res.gate.reasons)
    if ($implErr) { $reasons = @("implementer-error: $implErr") + $reasons }
    $state = if ($res.merged) { 'done' } else { 'blocked' }
    if ($OutputDir) {
        Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State $state `
            -Extra @{ branch = $wt.branch; merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed) }
    }
    if ($res.merged) {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'done'; Branch = $wt.branch }
    } else {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Branch = $wt.branch; Reasons = $reasons }
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
        foreach ($t in $Tasks) {
            Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued'
            Publish-ItemRunSafe @{ Id = $t.id; Model = $t.model; State = 'queued'; Name = $t.title }
        }
    }

    $results = @(); $blocked = @{}
    foreach ($id in $order) {
        $item = $byId[$id]
        # dep-block: if any dependency failed to merge, skip this item.
        $deadDep = @(@($item.depends_on) | Where-Object { $_ -and $blocked[$_] })
        if ($deadDep.Count -gt 0) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("dep-blocked: $($deadDep -join ', ')") } }
            Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Reasons = @("dep-blocked: $($deadDep -join ', ')") }
            $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; reasons = @("dep-blocked: $($deadDep -join ', ')"); changed = @() }
            continue
        }
        $impl = $Implementers[[string]$item.model]
        if (-not $impl) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("no-implementer: '$($item.model)' cannot edit a worktree") } }
            Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Reasons = @("no-implementer: '$($item.model)'") }
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

# Job body run in each child process: write a 'running' heartbeat, pipe the prompt
# file into the model CLI (cwd = the item's worktree), then a terminal heartbeat.
$script:BacklogJobWorker = {
    param($wtPath, $promptFile, $id, $outDir, $model, $exe, $argsJson)
    $live = Join-Path $outDir "$id.live.json"
    # Inline atomic write (this runs in a child job with no dot-sourced helpers).
    $writeLive = { param($obj) $j = $obj | ConvertTo-Json -Compress; Set-Content -LiteralPath "$live.tmp" -Value $j -Encoding utf8NoBOM; Move-Item -LiteralPath "$live.tmp" -Destination $live -Force }
    $started = (Get-Date).ToString('o')
    & $writeLive @{ label = $id; provider = $model; state = 'running'; started = $started }
    Set-Location $wtPath
    $exit = 0
    try {
        $argList = @($argsJson | ConvertFrom-Json)
        Get-Content -LiteralPath $promptFile -Raw | & $exe @argList 2>&1 | Out-Null
        $exit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } catch { $exit = -1 }
    & $writeLive @{ label = $id; provider = $model; state = 'implemented'; started = $started;
       ended = (Get-Date).ToString('o'); exit = $exit }
}

function Invoke-BacklogConcurrent {
    <#
    .SYNOPSIS  Wave-based CONCURRENT backlog driver: independent items implement in
               parallel (one process per item, isolated worktree); merges serialize.
    .PARAMETER ModelSpecs  @{ '<model>' = @{ exe='codex'; args=@('exec','-') } }
                           The prompt is piped to `<exe> <args...>` in the worktree.
    .DESCRIPTION
      Each wave: launch every READY item (all deps already merged) concurrently as a
      Start-Job; wait for the wave; then gate + merge each finished item SERIALLY in
      topo order (only the orchestrator merges, into the target branch). Newly-unblocked
      dependents run in the next wave. A blocked item dep-blocks its dependents.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][array]$Tasks,
        [Parameter(Mandatory)][hashtable]$ModelSpecs,
        [string]$Integration = 'master',
        [string]$IntegrationBase = 'master',
        [string]$OutputDir,
        [string]$WorktreeRoot,
        [int]$TimeoutS = 900
    )
    if ($OutputDir -and -not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path (Split-Path $RepoRoot -Parent) 'cao-worktrees' }
    Initialize-IntegrationBranch -RepoRoot $RepoRoot -Base $IntegrationBase -Name $Integration | Out-Null

    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $null = Get-TopoOrder -Tasks $Tasks   # validate DAG (throws on cycle/unknown dep)
    $orderIndex = @{}; $i = 0; foreach ($id in (Get-TopoOrder -Tasks $Tasks)) { $orderIndex[$id] = $i++ }

    if ($OutputDir) {
        $metaTasks = @($Tasks | ForEach-Object { @{ label = $_.id; provider = $_.model } })
        Write-EnsembleRunMeta -OutputDir $OutputDir -Kind 'backlog-concurrent' -Prompt 'autonomous concurrent backlog run' `
            -Tasks $metaTasks -State 'running' -Started ((Get-Date).ToString('o')) -TimeoutS $TimeoutS
        foreach ($t in $Tasks) {
            Write-ItemLive -OutputDir $OutputDir -Id $t.id -Model $t.model -State 'queued'
            Publish-ItemRunSafe @{ Id = $t.id; Model = $t.model; State = 'queued'; Name = $t.title }
        }
    }

    $proc = @{}   # id -> result object (merged bool)
    while ($proc.Count -lt $Tasks.Count) {
        # 1. dep-block items whose dependency already failed.
        foreach ($id in $byId.Keys) {
            if ($proc.ContainsKey($id)) { continue }
            $deadDep = @(@($byId[$id].depends_on) | Where-Object { $_ -and $proc.ContainsKey($_) -and -not $proc[$_].merged })
            if ($deadDep.Count -gt 0) {
                if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $byId[$id].model -State 'blocked' -Extra @{ reasons = @("dep-blocked: $($deadDep -join ', ')") } }
                Publish-ItemRunSafe @{ Id = $id; Model = $byId[$id].model; State = 'blocked'; Reasons = @("dep-blocked: $($deadDep -join ', ')") }
                $proc[$id] = [pscustomobject]@{ id = $id; model = $byId[$id].model; merged = $false; reasons = @("dep-blocked: $($deadDep -join ', ')"); changed = @() }
            }
        }
        # 2. ready = unprocessed, every dependency processed AND merged.
        $ready = @($byId.Keys | Where-Object {
            -not $proc.ContainsKey($_) -and
            (@(@($byId[$_].depends_on) | Where-Object { $_ -and -not ($proc.ContainsKey($_) -and $proc[$_].merged) }).Count -eq 0)
        })
        if ($ready.Count -eq 0) { break }

        # 3. launch ready items concurrently (worktrees created serially first).
        $jobs = @{}
        foreach ($id in $ready) {
            $item = $byId[$id]; $model = [string]$item.model
            if (-not $ModelSpecs[$model]) {
                if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = @("no-implementer: '$model'") } }
                Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = @("no-implementer: '$model'") }
                $proc[$id] = [pscustomobject]@{ id = $id; model = $model; merged = $false; reasons = @("no-implementer: '$model'"); changed = @() }
                continue
            }
            $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
            $pf = Join-Path ([System.IO.Path]::GetTempPath()) "cao-prompt-$id-$($model -replace '[^\w]','_').txt"
            Set-Content -LiteralPath $pf -Value $item.prompt -Encoding utf8NoBOM
            $spec = $ModelSpecs[$model]
            $argsJson = (@($spec.args) | ConvertTo-Json -Compress)
            if (-not $argsJson) { $argsJson = '[]' }
            $job = Start-Job -ScriptBlock $script:BacklogJobWorker -ArgumentList $wt.path, $pf, $id, $OutputDir, $model, $spec.exe, $argsJson
            $jobs[$id] = @{ job = $job; wt = $wt; pf = $pf; item = $item }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }
        }
        if ($jobs.Count -eq 0) { continue }

        # 4. wait for the whole wave, then gate + merge SERIALLY in topo order.
        $null = Wait-Job -Job (@($jobs.Values | ForEach-Object { $_.job })) -Timeout $TimeoutS
        foreach ($id in ($jobs.Keys | Sort-Object { $orderIndex[$_] })) {
            $info = $jobs[$id]; $item = $info.item
            if ($info.job.State -eq 'Running') { Stop-Job -Job $info.job -ErrorAction SilentlyContinue }
            Remove-Job -Job $info.job -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $info.pf -ErrorAction SilentlyContinue
            $allowed  = if ($item.allowed_paths) { @($item.allowed_paths) } else { @('*') }
            $maxFiles = if ($item.max_files) { [int]$item.max_files } else { 20 }
            $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $info.wt.path -Branch $info.wt.branch `
                -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
                -TestCommand $item.test_command -WorktreeRoot $WorktreeRoot -AutoCommit
            $state = if ($res.merged) { 'done' } else { 'blocked' }
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State $state -Extra @{ merged = $res.merged; reasons = @($res.gate.reasons); changed = @($res.gate.changed); branch = $info.wt.branch } }
            if ($res.merged) {
                Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'done'; Branch = $info.wt.branch }
            } else {
                Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Branch = $info.wt.branch; Reasons = @($res.gate.reasons) }
            }
            $proc[$id] = [pscustomobject]@{ id = $id; model = $item.model; merged = $res.merged; reasons = @($res.gate.reasons); changed = @($res.gate.changed); branch = $info.wt.branch }
        }
    }

    $results = @($Tasks | ForEach-Object { $proc[$_.id] })
    if ($OutputDir) {
        $manifest = @($results | ForEach-Object { @{ label = $_.id; provider = $_.model; status = ($_.merged ? 'ok' : 'error'); duration_s = 0 } })
        $metaTasks = @($Tasks | ForEach-Object { @{ label = $_.id; provider = $_.model } })
        Write-EnsembleRunMeta -OutputDir $OutputDir -Kind 'backlog-concurrent' -Prompt 'autonomous concurrent backlog run' `
            -Tasks $metaTasks -State 'done' -Started ((Get-Date).ToString('o')) -Manifest $manifest
    }
    return $results
}
