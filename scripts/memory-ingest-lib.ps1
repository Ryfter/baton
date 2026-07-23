#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Conductor-ledger -> Memory Bridge auto-ingest (pure fold + write).
.DESCRIPTION
  Reads a run dir's plan.json + events.jsonl + decisions.jsonl (+ acceptance.json
  when present, report.md for terminal status) and folds them into normalized
  problem/attempt/outcome rows via Add-MemoryEvent. Routing decisions alone are
  not memory rows; stakes_basis + task_id ride in refs. Idempotent on
  (run_id, signature). Fail-soft on corrupt/missing ledger pieces.
.NOTES
  Does not invent a parallel memory schema — reuses memory-lib.ps1.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/memory-lib.ps1"

# Event kinds that are pure routing / bookkeeping — never become memory rows.
$script:MemoryIngestRoutingNoiseKinds = @(
    'started', 'spent', 'policy', 'shadow', 'plan-gate',
    'task-verification-started', 'task-retry-started', 'task-unverified',
    'interrupt', 'verification'
)

function Resolve-MemoryIngestRunDir {
    <# Resolve -Run as an absolute run dir, or as an id under $BATON_HOME/runs/.
       Missing path returns $null (caller fail-softs). #>
    param(
        [Parameter(Mandatory)][string]$Run,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ([string]::IsNullOrWhiteSpace($Run)) { return $null }
    $trim = $Run.Trim()
    if (Test-Path -LiteralPath $trim -PathType Container) {
        return (Resolve-Path -LiteralPath $trim).Path
    }
    $under = Join-Path (Join-Path $BatonHome 'runs') $trim
    if (Test-Path -LiteralPath $under -PathType Container) {
        return (Resolve-Path -LiteralPath $under).Path
    }
    return $null
}

function Read-MemoryIngestJsonl {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    try {
        foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
        }
    } catch { return ([object[]]@()) }
    return ([object[]]$out.ToArray())
}

function Read-MemoryIngestJson {
    <# Best-effort single JSON object; missing/corrupt -> $null. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Get-MemoryIngestRunStatus {
    <# Terminal status from report.md **Status:** line, else inferred from
       acceptance / events. Empty when unknown. #>
    param(
        [string]$RunDir,
        $Acceptance,
        [object[]]$Events = @()
    )
    $reportPath = Join-Path $RunDir 'report.md'
    if (Test-Path -LiteralPath $reportPath) {
        try {
            foreach ($line in (Get-Content -LiteralPath $reportPath -ErrorAction Stop)) {
                if ($line -match '^\*\*Status:\*\*\s*(\S+)') { return $Matches[1].Trim() }
            }
        } catch { }
    }
    if ($Acceptance -and $Acceptance.verdict) {
        $v = [string]$Acceptance.verdict
        if ($v -eq 'reject') { return 'rejected' }
        if ($v -eq 'polish') { return 'needs-polish' }
        if ($v -eq 'accept') { return 'completed' }
    }
    $kinds = @($Events | ForEach-Object { [string]$_.kind })
    if ($kinds -contains 'task-verification-failed' -or $kinds -contains 'task-scope-violation') {
        return 'verification-failed'
    }
    if ($kinds -contains 'error') { return 'failed' }
    return ''
}

function ConvertTo-MemoryOutcomeFromRun {
    <# Map conductor terminal status (+ optional acceptance) to Add-MemoryEvent
       outcomes: pass|fail|partial|unknown.
         failed / verification-failed / rejected / plan-failed / plan-rejected -> fail
         completed + accept (or no gate) -> pass
         needs-polish (or polish acceptance) -> partial  #>
    param(
        [string]$Status,
        $Acceptance
    )
    $st = ([string]$Status).ToLowerInvariant()
    $verdict = if ($Acceptance -and $Acceptance.verdict) { ([string]$Acceptance.verdict).ToLowerInvariant() } else { '' }

    if ($st -in @('failed', 'verification-failed', 'rejected', 'plan-failed', 'plan-rejected')) {
        return 'fail'
    }
    if ($st -eq 'needs-polish') { return 'partial' }
    if ($verdict -eq 'reject') { return 'fail' }
    if ($verdict -eq 'polish') { return 'partial' }
    if ($st -eq 'completed') {
        if ($verdict -eq 'accept' -or [string]::IsNullOrWhiteSpace($verdict)) { return 'pass' }
        return 'pass'
    }
    if ($st -eq 'acceptance-degraded') { return 'partial' }
    if ($verdict -eq 'accept') { return 'pass' }
    return 'unknown'
}

function Get-MemoryIngestTaskMap {
    <# plan.tasks -> hashtable id -> task object. #>
    param($Plan)
    $map = @{}
    if (-not $Plan) { return $map }
    foreach ($t in @($Plan.tasks)) {
        if ($null -eq $t) { continue }
        $tid = [string]$t.id
        if ($tid) { $map[$tid] = $t }
    }
    return $map
}

function Get-MemoryIngestDecisionMap {
    <# decisions.jsonl -> last decision per task_id (routing noise as data, not rows). #>
    param([object[]]$Decisions = @())
    $map = @{}
    foreach ($d in @($Decisions)) {
        if ($null -eq $d) { continue }
        $tid = [string]$d.task_id
        if ($tid) { $map[$tid] = $d }
    }
    return $map
}

function New-MemoryIngestRowFields {
    <# One field row ready for Add-MemoryEvent. Returns pscustomobject (not a
       bare hashtable — hashtables enumerate in the pipeline and collapse folds). #>
    param(
        [Parameter(Mandatory)][string]$Problem,
        [string]$Approach = '',
        [ValidateSet('pass', 'fail', 'partial', 'unknown')][string]$Outcome = 'unknown',
        [string[]]$Tags = @(),
        [hashtable]$Refs = @{},
        [string]$Source = 'conductor-ledger',
        [ValidateSet('project', 'universal')][string]$Scope = 'project'
    )
    return [pscustomobject]@{
        problem  = $Problem
        approach = $Approach
        outcome  = $Outcome
        tags     = @($Tags)
        refs     = $Refs
        source   = $Source
        scope    = $Scope
    }
}

function ConvertFrom-RunLedger {
    <# Pure fold: run dir artifacts -> list of field-hashtables (no writes).
       Missing/corrupt pieces yield fewer rows + optional warnings via -WarningAction;
       never throws. #>
    param(
        [Parameter(Mandatory)][string]$RunDir
    )
    $rows = [System.Collections.ArrayList]@()
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
        Write-Warning "memory-ingest: run dir not found: $RunDir"
        return ([object[]]@())
    }

    $plan = Read-MemoryIngestJson -Path (Join-Path $RunDir 'plan.json')
    $events = @(Read-MemoryIngestJsonl -Path (Join-Path $RunDir 'events.jsonl'))
    $decisions = @(Read-MemoryIngestJsonl -Path (Join-Path $RunDir 'decisions.jsonl'))
    $acceptance = Read-MemoryIngestJson -Path (Join-Path $RunDir 'acceptance.json')

    if (-not $plan) {
        Write-Warning "memory-ingest: missing or corrupt plan.json under $RunDir — skip fold"
        return ([object[]]@())
    }

    $runId = [string]$plan.run_id
    if ([string]::IsNullOrWhiteSpace($runId)) { $runId = Split-Path -Leaf $RunDir }
    $goal = [string]$plan.goal
    $status = Get-MemoryIngestRunStatus -RunDir $RunDir -Acceptance $acceptance -Events $events
    $runOutcome = ConvertTo-MemoryOutcomeFromRun -Status $status -Acceptance $acceptance
    $taskMap = Get-MemoryIngestTaskMap -Plan $plan
    $decMap = Get-MemoryIngestDecisionMap -Decisions $decisions

    # ---- per-task fail rows (error / verification-failed / scope-violation) ----
    $failedTaskIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ev in $events) {
        if ($null -eq $ev) { continue }
        $kind = [string]$ev.kind
        if ($script:MemoryIngestRoutingNoiseKinds -contains $kind) { continue }
        if ($kind -notin @('error', 'task-verification-failed', 'task-scope-violation')) { continue }
        $tid = [string]$ev.task_id
        if ([string]::IsNullOrWhiteSpace($tid)) { continue }
        if ($failedTaskIds.Contains($tid)) { continue }
        [void]$failedTaskIds.Add($tid)

        $task = $taskMap[$tid]
        $problem = if ($task -and $task.desc) { [string]$task.desc } else { [string]$ev.message }
        if ([string]::IsNullOrWhiteSpace($problem)) { $problem = "task $tid failed" }
        $dec = $decMap[$tid]
        $approach = if ($dec -and $dec.chose) {
            $why = if ($dec.why) { " — $([string]$dec.why)" } else { '' }
            "chose $([string]$dec.chose)$why"
        } elseif ($ev.message) {
            [string]$ev.message
        } else {
            "task $tid ($kind)"
        }
        $refs = @{ run = $runId; task_id = $tid }
        if ($dec -and $dec.stakes_basis) { $refs['stakes_basis'] = [string]$dec.stakes_basis }
        $tags = @('conductor-ledger', 'task-fail', $kind)
        if ($status) { $tags += $status }
        [void]$rows.Add((New-MemoryIngestRowFields -Problem $problem -Approach $approach -Outcome 'fail' -Tags $tags -Refs $refs))
    }

    # ---- run-level summary row (goal + terminal status) ----
    # Always when we have a goal and a mappable outcome (skip pure unknown).
    if (-not [string]::IsNullOrWhiteSpace($goal) -and $runOutcome -ne 'unknown') {
        $choseParts = @()
        foreach ($d in @($decisions)) {
            if ($d -and $d.chose) {
                $piece = [string]$d.chose
                if ($d.task_id) { $piece = "$([string]$d.task_id):$piece" }
                $choseParts += $piece
            }
        }
        $approach = if ($choseParts.Count) {
            'conductor walk via ' + (($choseParts | Select-Object -Unique) -join ', ')
        } else {
            "conductor run ($status)"
        }
        $refs = @{ run = $runId }
        # Prefer stakes_basis / task_id from a failed task decision, else first decision.
        $anchorDec = $null
        if ($failedTaskIds.Count -gt 0) {
            foreach ($ft in $failedTaskIds) {
                if ($decMap.ContainsKey($ft)) { $anchorDec = $decMap[$ft]; break }
            }
        }
        if (-not $anchorDec -and @($decisions).Count -gt 0) { $anchorDec = $decisions[0] }
        if ($anchorDec) {
            if ($anchorDec.task_id) { $refs['task_id'] = [string]$anchorDec.task_id }
            if ($anchorDec.stakes_basis) { $refs['stakes_basis'] = [string]$anchorDec.stakes_basis }
        }
        $tags = @('conductor-ledger', 'run')
        if ($status) { $tags += $status }
        if ($acceptance -and $acceptance.verdict) { $tags += "verdict:$([string]$acceptance.verdict)" }
        [void]$rows.Add((New-MemoryIngestRowFields -Problem $goal -Approach $approach -Outcome $runOutcome -Tags $tags -Refs $refs))
    }

    # Bare object[] return (not unary-comma / -NoEnumerate): callers use
    # `$rows = @(ConvertFrom-RunLedger ...)` which flattens correctly for 0/1/N.
    # Never return bare hashtables (they enumerate key/value pairs).
    return [object[]]$rows.ToArray()
}

function Get-MemoryIngestRefValue {
    <# Read a refs key from hashtable or PSCustomObject. #>
    param($Refs, [Parameter(Mandatory)][string]$Key)
    if ($null -eq $Refs) { return $null }
    if ($Refs -is [hashtable]) {
        if ($Refs.ContainsKey($Key)) { return $Refs[$Key] }
        return $null
    }
    $prop = $Refs.PSObject.Properties[$Key]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-MemoryIngestDuplicate {
    <# True when journal already has a row with same refs.run + signature. #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Signature,
        [object[]]$ExistingRows = @()
    )
    if ([string]::IsNullOrWhiteSpace($Signature)) { return $false }
    foreach ($r in @($ExistingRows)) {
        if ($null -eq $r) { continue }
        $sig = [string]$r.signature
        if ($sig -ne $Signature) { continue }
        $runRef = $null
        if ($r.refs) {
            if ($r.refs -is [hashtable]) { $runRef = $r.refs['run'] }
            else { $runRef = $r.refs.run }
        }
        if ([string]$runRef -eq $RunId) { return $true }
    }
    return $false
}

function Invoke-MemoryIngest {
    <# Fold a run ledger into the memory journal. Returns a result object:
         written, skipped_duplicate, dry_run, run_id, run_dir, rows (preview), warnings.
       Never throws on corrupt ledger (fail-soft). Throws only on hard caller errors
       (empty -Run) when the path cannot be resolved? Actually fail-soft with warning. #>
    param(
        [Parameter(Mandatory)][string]$Run,
        [string]$BatonHome = (Get-BatonHome),
        [string]$MemoryPath = $(Join-Path (Get-BatonHome) 'memory-journal.jsonl'),
        [switch]$DryRun
    )
    $result = [ordered]@{
        written            = 0
        skipped_duplicate  = 0
        dry_run            = [bool]$DryRun
        run_id             = ''
        run_dir            = ''
        rows               = @()
        warnings           = @()
    }

    $runDir = $null
    try {
        $runDir = Resolve-MemoryIngestRunDir -Run $Run -BatonHome $BatonHome
    } catch {
        Write-Warning "memory-ingest: resolve failed: $($_.Exception.Message)"
        $result.warnings += "resolve failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    if (-not $runDir) {
        Write-Warning "memory-ingest: run not found: $Run"
        $result.warnings += "run not found: $Run"
        return [pscustomobject]$result
    }
    $result.run_dir = $runDir
    $result.run_id = Split-Path -Leaf $runDir

    $candidates = @()
    try {
        $candidates = @(ConvertFrom-RunLedger -RunDir $runDir)
    } catch {
        Write-Warning "memory-ingest: fold failed (fail-soft): $($_.Exception.Message)"
        $result.warnings += "fold failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    # Prefer plan.run_id when present on first candidate refs.
    if (@($candidates).Count -gt 0) {
        $firstRun = Get-MemoryIngestRefValue -Refs $candidates[0].refs -Key 'run'
        if ($firstRun) { $result.run_id = [string]$firstRun }
    }

    $existing = @(Read-MemoryJournal -Path $MemoryPath)
    $preview = [System.Collections.ArrayList]@()
    $runId = [string]$result.run_id

    foreach ($cand in @($candidates)) {
        if ($null -eq $cand) { continue }
        $sig = Get-MemorySignature -Text ([string]$cand.problem)
        $dup = Test-MemoryIngestDuplicate -RunId $runId -Signature $sig -ExistingRows $existing
        $refTable = @{}
        if ($cand.refs -is [hashtable]) { $refTable = $cand.refs }
        elseif ($cand.refs) {
            foreach ($p in $cand.refs.PSObject.Properties) { $refTable[$p.Name] = $p.Value }
        }
        $item = [ordered]@{
            problem   = [string]$cand.problem
            approach  = [string]$cand.approach
            outcome   = [string]$cand.outcome
            signature = $sig
            tags      = @($cand.tags)
            refs      = $refTable
            source    = [string]$cand.source
            duplicate = $dup
            written   = $false
        }
        if ($dup) {
            $result.skipped_duplicate++
            [void]$preview.Add([pscustomobject]$item)
            continue
        }
        if ($DryRun) {
            [void]$preview.Add([pscustomobject]$item)
            continue
        }
        try {
            $res = Add-MemoryEvent `
                -Problem ([string]$cand.problem) `
                -Approach ([string]$cand.approach) `
                -Outcome ([string]$cand.outcome) `
                -Tags @($cand.tags) `
                -Scope $(if ($cand.scope) { [string]$cand.scope } else { 'project' }) `
                -Source $(if ($cand.source) { [string]$cand.source } else { 'conductor-ledger' }) `
                -Refs $refTable `
                -Path $MemoryPath
            $item.written = $true
            $item.id = $res.id
            $item.signature = $res.signature
            $result.written++
            # Keep subsequent dups in the same batch from double-writing.
            $existing += [pscustomobject]@{
                signature = $res.signature
                refs      = [pscustomobject]@{ run = $runId }
            }
        } catch {
            Write-Warning "memory-ingest: append failed (fail-soft): $($_.Exception.Message)"
            $result.warnings += "append failed: $($_.Exception.Message)"
        }
        [void]$preview.Add([pscustomobject]$item)
    }

    $result.rows = @($preview.ToArray())
    return [pscustomobject]$result
}
