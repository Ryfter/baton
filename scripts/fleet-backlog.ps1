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
. (Join-Path $PSScriptRoot 'prime-hours.ps1')   # Test-PrimeHoursGate, Get-CapacityProfile, Get-FleetProvider chain
. (Join-Path $PSScriptRoot 'routing-cascade.ps1')   # Invoke-CapabilityCascade (Slice C)

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

function Get-EffectiveRanks {
    <# Effective rank = min(own rank, min effective rank of all transitive dependents).
       A rank-1 task pulls its prerequisites up to rank 1 so they aren't starved. Returns
       @{ id = effRank }. Unranked tasks default to 3. #>
    param([Parameter(Mandatory)][object[]]$Tasks)
    $own = @{}; $dependents = @{}
    foreach ($t in $Tasks) {
        $r = if ($null -ne $t.rank) { [int]$t.rank } else { 3 }
        $own[$t.id] = $r; $dependents[$t.id] = @()
    }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if ($dependents.ContainsKey($d)) { $dependents[$d] += $t.id }
        }
    }
    $eff = @{}
    function script:__effOf($id, $own, $dependents, $eff, $stack) {
        if ($eff.ContainsKey($id)) { return $eff[$id] }
        if ($stack -contains $id) { return $own[$id] }   # cycle guard (DAG already validated upstream)
        $best = $own[$id]
        foreach ($dep in $dependents[$id]) {
            $de = script:__effOf $dep $own $dependents $eff ($stack + $id)
            if ($de -lt $best) { $best = $de }
        }
        $eff[$id] = $best; return $best
    }
    foreach ($t in $Tasks) { [void](script:__effOf $t.id $own $dependents $eff @()) }
    return $eff
}

function Get-BacklogCascadeMode {
    <# 'full' = cascade+output_file (text deliverable, full draft->finish cascade);
       'advisory' = cascade only (draft injected into the agentic prompt); 'none'. #>
    param([Parameter(Mandatory)]$Item)
    if (-not $Item.cascade) { return 'none' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.output_file)) { return 'full' }
    return 'advisory'
}

function Get-AdvisoryPrompt {
    <# Single source of truth for the advisory draft->finisher prompt (test-asserted).
       The concurrent worker receives this with placeholder tokens (see AdvisoryJobWorker). #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Draft
    )
    return @"
$Prompt

A cheaper model produced this DRAFT. Verify it independently; keep what is
correct, fix what is not, and complete the task:

$Draft
"@
}

function Copy-BacklogItem {
    <# Shallow item copy as a hashtable: items arrive as hashtables (tests/dashboard)
       or PSCustomObjects (run-backlog via ConvertFrom-Json); advisory mode mutates
       prompt on a copy, never the caller's object. #>
    param([Parameter(Mandatory)]$Item)
    $h = @{}
    if ($Item -is [hashtable]) { foreach ($k in $Item.Keys) { $h[$k] = $Item[$k] } }
    else { foreach ($p in $Item.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

$script:DefaultCascadeInvoker = {
    # Contract: param($Item, $EffRank, $NoFinisher, $Opts) -> Invoke-CapabilityCascade result.
    # $Opts keys (all optional): FleetPath, ToolsPath, PrimeHoursConfig, GateNow, JournalPath.
    param($Item, $EffRank, $NoFinisher, $Opts)
    $a = @{ Capability = $(if ($Item.capability) { [string]$Item.capability } else { 'code-gen' })
            Prompt     = [string]$Item.prompt }
    if ($null -ne $EffRank)        { $a.Rank = [int]$EffRank }
    if ($NoFinisher)               { $a.NoFinisher = $true }
    if ($Opts) {
        if ($Opts.FleetPath)        { $a.FleetPath        = $Opts.FleetPath }
        if ($Opts.ToolsPath)        { $a.ToolsPath        = $Opts.ToolsPath }
        if ($Opts.PrimeHoursConfig) { $a.PrimeHoursConfig = $Opts.PrimeHoursConfig }
        if ($null -ne $Opts.GateNow){ $a.GateNow          = $Opts.GateNow }
        if ($Opts.JournalPath)      { $a.JournalPath      = $Opts.JournalPath }
    }
    Invoke-CapabilityCascade @a
}

function Get-EffectiveMaxParallel {
    <# Surge consumption (parent spec A.2): an explicit cap is multiplied by the
       surge concurrency_factor; 0 = unbounded stays unbounded (back-compat). #>
    param(
        [Parameter(Mandatory)][int]$MaxParallel,
        [Parameter(Mandatory)]$Capacity
    )
    if ($MaxParallel -le 0) { return 0 }
    if ($Capacity.surge) { return [int][math]::Ceiling($MaxParallel * [double]$Capacity.concurrency_factor) }
    return $MaxParallel
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
    <# One item: worktree -> implement -> gate -> merge-or-block. Emits live status.
       For cascade mode 'full': no agentic implementer; cascade produces the file content.
       For cascade mode 'advisory': run cascade (NoFinisher) first, inject draft into prompt. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Item,
        [scriptblock]$Implementer,
        [string]$Integration = 'integration/backlog',
        [string]$OutputDir,
        [string]$WorktreeRoot,
        [int]$EffectiveRank = 3,
        [scriptblock]$CascadeInvoker,
        [hashtable]$CascadeOpts
    )
    $id      = $Item.id
    $mode    = Get-BacklogCascadeMode -Item $Item
    $model   = if ($mode -eq 'full' -and [string]::IsNullOrWhiteSpace([string]$Item.model)) { 'cascade' } else { [string]$Item.model }
    $invoker = if ($CascadeInvoker) { $CascadeInvoker } else { $script:DefaultCascadeInvoker }
    $allowed  = if ($Item.allowed_paths) { @($Item.allowed_paths) } else { @('*') }
    $maxFiles = if ($Item.max_files) { [int]$Item.max_files } else { 20 }
    $testCmd  = $Item.test_command

    # ── mode 'full': cascade produces the file; no agentic implementer ──────────
    if ($mode -eq 'full') {
        $of = [string]$Item.output_file
        # Traversal guard: absolute path or any '..' segment → blocked
        if ([System.IO.Path]::IsPathRooted($of) -or $of -match '\.\.') {
            $reasons = @("output_file traversal guard: '$of' is not a relative path inside the repo")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full' } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id = $id; model = $model; merged = $false; reasons = $reasons; changed = @() }
        }
        if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'running' -Extra @{ cascade = 'full' } }
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running' }

        $cres = $null; $cascadeErr = $null
        try { $cres = & $invoker $Item $EffectiveRank $false $CascadeOpts } catch { $cascadeErr = $_.Exception.Message }

        if ($cascadeErr -or $null -eq $cres) {
            $reasons = @("cascade-error: $(if ($cascadeErr) { $cascadeErr } else { 'no result' })")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full' } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id = $id; model = $model; merged = $false; reasons = $reasons; changed = @() }
        }

        if ($cres.status -eq 'finisher-deferred') {
            $reasons = @("deferred: cascade finisher gated until off-peak")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'deferred' -Extra @{ reasons = $reasons; cascade = 'full'; cascade_status = $cres.status } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'deferred'; Reasons = $reasons }
            return [pscustomobject]@{ id = $id; model = $model; merged = $false; deferred = $true; reasons = $reasons; changed = @() }
        }

        if ($cres.status -notin @('draft-sufficient','finished')) {
            $reasons = @("cascade: $($cres.status)")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full'; cascade_status = $cres.status } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id = $id; model = $model; merged = $false; reasons = $reasons; changed = @(); cascade_status = $cres.status }
        }

        # Success: write output_file into a fresh worktree, then gate + merge
        $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
        $outPath = Join-Path $wt.path $of
        $outDir2 = Split-Path $outPath -Parent
        if (-not (Test-Path $outDir2)) { New-Item -ItemType Directory -Force -Path $outDir2 | Out-Null }
        Set-Content -LiteralPath $outPath -Value ([string]$cres.result.stdout) -Encoding utf8NoBOM

        $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $wt.path -Branch $wt.branch `
            -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
            -TestCommand $testCmd -WorktreeRoot $WorktreeRoot -AutoCommit

        $reasons = @($res.gate.reasons)
        $state = if ($res.merged) { 'done' } else { 'blocked' }
        if ($OutputDir) {
            Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State $state `
                -Extra @{ branch = $wt.branch; merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed)
                           cascade = 'full'; cascade_status = $cres.status; winner = $cres.winner; frontier_spent = [bool]$cres.frontier_spent }
        }
        if ($res.merged) {
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'done'; Branch = $wt.branch }
        } else {
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Branch = $wt.branch; Reasons = $reasons }
        }
        return [pscustomobject]@{
            id = $id; model = $model; branch = $wt.branch; path = $wt.path
            merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed)
            cascade_status = $cres.status; winner = $cres.winner; frontier_spent = [bool]$cres.frontier_spent
        }
    }

    # ── mode 'advisory': run cascade (NoFinisher) before the agentic implementer ─
    if ($mode -eq 'advisory') {
        try {
            $d = & $invoker $Item $EffectiveRank $true $CascadeOpts
            if ($d -and $d.winner -and $d.result -and -not [string]::IsNullOrWhiteSpace([string]$d.result.stdout)) {
                $Item = Copy-BacklogItem -Item $Item
                $Item.prompt = Get-AdvisoryPrompt -Prompt ([string]$Item.prompt) -Draft ([string]$d.result.stdout)
                $Item.advisory_draft_winner = $d.winner
            }
        } catch { Write-Verbose "advisory cascade failed (fail-open): $_" }
    }

    # ── agentic implementer flow (mode 'none' or 'advisory') ────────────────────
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
    .PARAMETER Tasks           @( @{ id; model; prompt; allowed_paths; test_command; max_files; depends_on } )
    .PARAMETER Implementers    @{ '<model>' = <scriptblock(param($wtPath,$item))> }
    .PARAMETER CascadeInvoker  Injected cascade dispatcher (tests); defaults to DefaultCascadeInvoker.
    .OUTPUTS     @( per-item result objects ) with .merged / .reasons
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][array]$Tasks,
        [Parameter(Mandatory)][hashtable]$Implementers,
        [string]$Integration = 'integration/backlog',
        [string]$IntegrationBase = 'master',
        [string]$OutputDir,
        [string]$WorktreeRoot,
        [string]$FleetPath,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
        [scriptblock]$CascadeInvoker,
        [string]$ToolsPath,
        [string]$JournalPath
    )
    if ($OutputDir -and -not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    Initialize-IntegrationBranch -RepoRoot $RepoRoot -Base $IntegrationBase -Name $Integration | Out-Null

    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $order = Get-TopoOrder -Tasks $Tasks
    # Effective-rank tiebreak among ready (topologically-valid) items: a rank-1 task pulls
    # its prerequisites up so they aren't starved. IndexOf preserves topo order on ties.
    $eff = Get-EffectiveRanks -Tasks $Tasks
    $topo = $order
    $order = @($order | Sort-Object @{ e = { $eff[$_] } }, @{ e = { [array]::IndexOf($topo, $_) } })

    $cascadeOpts = @{}
    if ($FleetPath)                                         { $cascadeOpts.FleetPath        = $FleetPath }
    if ($ToolsPath)                                         { $cascadeOpts.ToolsPath        = $ToolsPath }
    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $cascadeOpts.PrimeHoursConfig = $PrimeHoursConfig }
    if ($PSBoundParameters.ContainsKey('GateNow'))          { $cascadeOpts.GateNow          = $GateNow }
    if ($JournalPath)                                       { $cascadeOpts.JournalPath      = $JournalPath }

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
        $mode = Get-BacklogCascadeMode -Item $item
        # dep-block: if any dependency failed to merge, skip this item.
        $deadDep = @(@($item.depends_on) | Where-Object { $_ -and $blocked[$_] })
        if ($deadDep.Count -gt 0) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("dep-blocked: $($deadDep -join ', ')") } }
            Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Reasons = @("dep-blocked: $($deadDep -join ', ')") }
            $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; reasons = @("dep-blocked: $($deadDep -join ', ')"); changed = @() }
            continue
        }
        $impl = if ($mode -ne 'full') { $Implementers[[string]$item.model] } else { $null }
        if ($mode -ne 'full' -and -not $impl) {
            $blocked[$id] = $true
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'blocked' -Extra @{ reasons = @("no-implementer: '$($item.model)' cannot edit a worktree") } }
            Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'blocked'; Reasons = @("no-implementer: '$($item.model)'") }
            $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; reasons = @("no-implementer: '$($item.model)'"); changed = @() }
            continue
        }
        # Prime-hours gate (unattended): only paid providers in a non-full-cascade peak window are gated.
        # Full-cascade items skip the driver gate (the cascade gates its own finisher).
        # Fail-open: an absent fleet.yaml or unknown model -> no provider -> no gating.
        if ($mode -ne 'full') {
            $provArgs = @{ Name = [string]$item.model }
            if ($FleetPath) { $provArgs.Path = $FleetPath }
            $prov = try { Get-FleetProvider @provArgs } catch { $null }
            if ($prov -and $prov.cost_tier -eq 'paid') {
                $gateArgs = @{ Rank = [int]$eff[$id]; CostTier = 'paid' }
                if ($PSBoundParameters.ContainsKey('GateNow'))          { $gateArgs.Now = $GateNow }
                if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $gateArgs.ConfigPath = $PrimeHoursConfig }
                $gate = Test-PrimeHoursGate @gateArgs
                $eff2 = if ($gate.decision -eq 'ask') { $gate.default } else { $gate.decision }
                if ($eff2 -eq 'defer') {
                    $blocked[$id] = $true
                    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'deferred' -Extra @{ reasons = @("deferred until off-peak: $($gate.reason)") } }
                    Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'deferred'; Reasons = @("deferred until off-peak: $($gate.reason)") }
                    $results += [pscustomobject]@{ id = $id; model = $item.model; merged = $false; deferred = $true; reasons = @("deferred until off-peak: $($gate.reason)"); changed = @() }
                    continue
                }
            }
        }
        $r = Invoke-BacklogItem -RepoRoot $RepoRoot -Item $item -Implementer $impl `
            -Integration $Integration -OutputDir $OutputDir -WorktreeRoot $WorktreeRoot `
            -EffectiveRank ([int]$eff[$id]) -CascadeInvoker $CascadeInvoker -CascadeOpts $cascadeOpts
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
        [int]$TimeoutS = 900,
        [int]$MaxParallel = 0,
        [string]$FleetPath,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow
    )
    if ($OutputDir -and -not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path (Split-Path $RepoRoot -Parent) 'cao-worktrees' }
    Initialize-IntegrationBranch -RepoRoot $RepoRoot -Base $IntegrationBase -Name $Integration | Out-Null

    $byId = @{}; foreach ($t in $Tasks) { $byId[$t.id] = $t }
    $null = Get-TopoOrder -Tasks $Tasks   # validate DAG (throws on cycle/unknown dep)
    $orderIndex = @{}; $i = 0; foreach ($id in (Get-TopoOrder -Tasks $Tasks)) { $orderIndex[$id] = $i++ }
    $eff = Get-EffectiveRanks -Tasks $Tasks
    $capArgs = @{}
    if ($PSBoundParameters.ContainsKey('GateNow'))          { $capArgs.Now        = $GateNow }
    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $capArgs.ConfigPath = $PrimeHoursConfig }
    $capN = Get-EffectiveMaxParallel -MaxParallel $MaxParallel -Capacity (Get-CapacityProfile @capArgs)

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
        # 2. ready = unprocessed, every dependency processed AND merged — sorted by
        #    ascending effective rank (topo index tiebreak), then paid-peak gated,
        #    then capped to the surge-scaled MaxParallel.
        $ready = @($byId.Keys | Where-Object {
            -not $proc.ContainsKey($_) -and
            (@(@($byId[$_].depends_on) | Where-Object { $_ -and -not ($proc.ContainsKey($_) -and $proc[$_].merged) }).Count -eq 0)
        } | Sort-Object @{ e = { $eff[$_] } }, @{ e = { $orderIndex[$_] } })
        if ($ready.Count -eq 0) { break }

        # Paid-peak gate (unattended; full-cascade items gate INSIDE the cascade).
        $gated = [System.Collections.ArrayList]@()
        foreach ($id in $ready) {
            $item = $byId[$id]
            if ((Get-BacklogCascadeMode -Item $item) -ne 'full') {
                $provArgs = @{ Name = [string]$item.model }
                if ($FleetPath) { $provArgs.Path = $FleetPath }
                $prov = try { Get-FleetProvider @provArgs } catch { $null }
                if ($prov -and $prov.cost_tier -eq 'paid') {
                    $gateArgs = @{ Rank = [int]$eff[$id]; CostTier = 'paid' }
                    if ($PSBoundParameters.ContainsKey('GateNow'))          { $gateArgs.Now        = $GateNow }
                    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $gateArgs.ConfigPath = $PrimeHoursConfig }
                    $gate = Test-PrimeHoursGate @gateArgs
                    $eff2 = if ($gate.decision -eq 'ask') { $gate.default } else { $gate.decision }
                    if ($eff2 -eq 'defer') {
                        $reasons = @("deferred until off-peak: $($gate.reason)")
                        if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'deferred' -Extra @{ reasons = $reasons } }
                        Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'deferred'; Reasons = $reasons }
                        $proc[$id] = [pscustomobject]@{ id = $id; model = $item.model; merged = $false; deferred = $true; reasons = $reasons; changed = @() }
                        continue
                    }
                }
            }
            [void]$gated.Add($id)
        }
        $ready = @($gated)
        if ($capN -gt 0 -and $ready.Count -gt $capN) { $ready = @($ready | Select-Object -First $capN) }
        if ($ready.Count -eq 0) { continue }

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
