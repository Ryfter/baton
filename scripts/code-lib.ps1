#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared library for the Plan 6 code phase (decompose / parallel / merge).

.DESCRIPTION
  Thin: most decision logic lives in the slash commands (Claude). This lib
  handles subtasks.json IO, parallel manifest IO, topological sort,
  worktree status probing, output-dir math, and journal append.
#>

function New-CodeSubtasksFile {
    <#
    .SYNOPSIS
      Write a subtasks.json (v1) from the decomposition Claude produced.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Feature,
        [Parameter(Mandatory)][string]$SpecPath,
        [Parameter(Mandatory)][array]$Tasks,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Sprint
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    foreach ($t in $Tasks) {
        if (-not $t.id)    { throw "Subtask missing 'id'." }
        if (-not $t.title) { throw "Subtask '$($t.id)' missing 'title'." }
        if (-not $t.PSObject.Properties['depends_on'] -and -not ($t -is [hashtable] -and $t.ContainsKey('depends_on'))) {
            # Accept both hashtables and pscustomobject; depends_on default = empty array
            if ($t -is [hashtable]) { $t['depends_on'] = @() }
        }
    }

    $ids = $Tasks | ForEach-Object { $_.id }
    if (($ids | Sort-Object -Unique).Count -ne $ids.Count) {
        throw "Subtask ids must be unique."
    }

    $obj = [ordered]@{
        version        = 1
        feature        = $Feature
        spec_path      = $SpecPath
        decomposed_at  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        job_id         = $JobId
        sprint         = $Sprint
        tasks          = $Tasks
    }
    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Read-CodeSubtasksFile {
    <# Parse a subtasks.json back to a hashtable. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "subtasks.json not found at $Path." }
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Resolve-CodeTaskOrder {
    <#
    .SYNOPSIS
      Topological-sort tasks by depends_on. Independent first. Throw on cycle.

    .PARAMETER Tasks
      Array of tasks with .id and .depends_on (array of ids).
    #>
    param([Parameter(Mandatory)][array]$Tasks)
    $ids = @($Tasks | ForEach-Object { $_.id })
    $byId = @{}
    foreach ($t in $Tasks) { $byId[$t.id] = $t }

    # Validate refs first
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if ($d -and -not $byId.ContainsKey($d)) {
                throw "Task '$($t.id)' depends_on unknown id '$d'."
            }
        }
    }

    $result = @()
    $remaining = [System.Collections.ArrayList]@($Tasks)
    $remainingIds = [System.Collections.ArrayList]@($ids)

    while ($remaining.Count -gt 0) {
        $ready = @()
        foreach ($t in $remaining) {
            $deps = @($t.depends_on | Where-Object { $_ })
            $unmet = @($deps | Where-Object { $remainingIds -contains $_ })
            if ($unmet.Count -eq 0) { $ready += $t }
        }
        if ($ready.Count -eq 0) {
            $stuck = ($remaining | ForEach-Object { $_.id }) -join ','
            throw "Cycle detected in subtask dependencies (stuck on: $stuck)."
        }
        foreach ($t in $ready) {
            $result += $t
            $null = $remaining.Remove($t)
            $null = $remainingIds.Remove($t.id)
        }
    }
    return $result
}

function Get-CodeOutputDir {
    <#
    .SYNOPSIS
      Compute the parallel-<ts>/ directory under a job's sprint.
    #>
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Sprint,
        [string]$Stamp = (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss')
    )
    return (Join-Path $HOME ".claude/jobs/$JobId/phases/$Sprint/parallel-$Stamp")
}

function Write-CodeParallelManifest {
    <# Write parallel-<ts>/manifest.json with per-task results. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][array]$Results
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj = [ordered]@{
        version    = 1
        written_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        results    = $Results
    }
    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Read-CodeParallelManifest {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "parallel manifest not found at $Path." }
    return (Get-Content $Path -Raw | ConvertFrom-Json)
}

function Get-CodeWorktreeStatus {
    <#
    .SYNOPSIS
      Probe a worktree's commits ahead of BaseBranch, files changed, dirty state.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [string]$BaseBranch = 'master'
    )
    if (-not (Test-Path $WorktreePath)) {
        throw "Worktree path '$WorktreePath' does not exist."
    }
    $commitsAhead = 0
    $filesChanged = 0
    $dirty = $false
    try {
        $ahead = & git -C $WorktreePath rev-list --count "$BaseBranch..HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and $ahead) { $commitsAhead = [int]$ahead.Trim() }
        $stat = & git -C $WorktreePath diff --name-only "$BaseBranch..HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and $stat) {
            $filesChanged = @($stat | Where-Object { $_ }).Count
        }
        $porcelain = & git -C $WorktreePath status --porcelain 2>$null
        if ($LASTEXITCODE -eq 0 -and $porcelain) {
            $dirty = @($porcelain | Where-Object { $_ }).Count -gt 0
        }
    } catch {
        Write-Debug "Get-CodeWorktreeStatus probe error: $($_.Exception.Message)"
    }
    return @{ commits_ahead = $commitsAhead; files_changed = $filesChanged; dirty = $dirty }
}

function Write-CodeJournalLine {
    <#
    .SYNOPSIS
      Append a `code | parallel | …` line to the journal. Picks up job/phase tags.
    #>
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Sprint,
        [Parameter(Mandatory)][int]$TaskCount,
        [Parameter(Mandatory)][int]$OkCount,
        [Parameter(Mandatory)][int]$ErrCount,
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
        [string]$StatePath = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path $HOME '.claude/current-job.json' })
    )
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $line = "$ts | code | parallel | $JobId | sprint:$Sprint | tasks:$TaskCount | ok:$OkCount | err:$ErrCount"

    try {
        if (Test-Path $StatePath) {
            $raw = Get-Content $StatePath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $state = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($state.job_id -and $state.phase) {
                    $line += " | job:$($state.job_id) | phase:$($state.phase)"
                }
            }
        }
    } catch { }

    $dir = Split-Path -Parent $JournalPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not (Test-Path $JournalPath)) {
        Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---" -Encoding utf8NoBOM
    }
    Add-Content -Path $JournalPath -Value $line -Encoding utf8NoBOM
}

function Get-CodeFilesTouchedConflicts {
    <#
    .SYNOPSIS
      Given ordered tasks, return pairs (i, j) where j's files_touched
      intersect any earlier task's files_touched. Surfaces likely conflicts.
    #>
    param([Parameter(Mandatory)][array]$OrderedTasks)
    $conflicts = @()
    for ($j = 1; $j -lt $OrderedTasks.Count; $j++) {
        $jFiles = @($OrderedTasks[$j].files_touched)
        if (-not $jFiles -or $jFiles.Count -eq 0) { continue }
        for ($i = 0; $i -lt $j; $i++) {
            $iFiles = @($OrderedTasks[$i].files_touched)
            if (-not $iFiles -or $iFiles.Count -eq 0) { continue }
            $overlap = @($jFiles | Where-Object { $iFiles -contains $_ })
            if ($overlap.Count -gt 0) {
                $conflicts += [pscustomobject]@{
                    earlier_task = $OrderedTasks[$i].id
                    later_task   = $OrderedTasks[$j].id
                    overlap      = $overlap
                }
            }
        }
    }
    return $conflicts
}
