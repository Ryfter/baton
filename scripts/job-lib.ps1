#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for job lifecycle. Dot-source from slash command
  scripts and the hook.

.DESCRIPTION
  Functions:
    Read-CurrentJob   — returns @{ job_id; phase } from state file
    Write-CurrentJob  — writes state file
    Clear-CurrentJob  — deletes state file
    (more added in later tasks)
#>

$script:DefaultStatePath = (Join-Path $HOME '.claude/current-job.json')

function Read-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    $result = @{ job_id = $null; phase = $null }
    if (-not (Test-Path $StatePath)) { return $result }
    try {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $result.job_id = $obj.job_id
        $result.phase  = $obj.phase
    } catch {
        # Corrupted or unreadable → treat as no active job.
        # Contract: this function must never throw. Bare catch is intentional;
        # surface details to debug stream for callers who set $DebugPreference.
        Write-Debug "Read-CurrentJob: $($_.Exception.Message)"
    }
    return $result
}

function Write-CurrentJob {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Phase,
        [string]$StatePath = $script:DefaultStatePath
    )
    $dir = Split-Path -Parent $StatePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @{ job_id = $JobId; phase = $Phase } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding utf8NoBOM
}

function Clear-CurrentJob {
    param([string]$StatePath = $script:DefaultStatePath)
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force }
}

$script:StopWords = @('a','an','the','for','to','of','and','build','make','create','add','my','this','that')

function ConvertTo-JobSlug {
    param([Parameter(Mandatory)][string]$Brief)
    $lower = $Brief.ToLowerInvariant()
    # Replace any non-alphanumeric with space, then split on whitespace
    $cleaned = ($lower -replace '[^a-z0-9]+', ' ').Trim()
    $tokens = $cleaned -split '\s+' | Where-Object { $_ -and ($script:StopWords -notcontains $_) }
    $slugTokens = @($tokens | Select-Object -First 5)
    $slug = ($slugTokens -join '-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).TrimEnd('-') }
    if (-not $slug) { $slug = 'untitled' }
    return $slug
}

function Resolve-ProjectId {
    param([string]$Override)
    if ($Override) { return $Override }

    # Try git remote
    try {
        $remote = (& git remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote) {
            # Strip protocol, .git suffix; take host/repo
            $clean = $remote -replace '^(https?://|git@)', '' `
                              -replace ':', '/' `
                              -replace '\.git$', ''
            $parts = $clean -split '/' | Where-Object { $_ }
            if ($parts.Count -ge 2) {
                $repo = $parts[-1]
                return ($repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    } catch { }

    # Fallback: cwd folder name (slugified)
    $folder = Split-Path -Leaf (Get-Location).Path
    return ($folder.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
}

# Phase model — keep in lock-step with docs/superpowers/specs/2026-05-26-plan3-job-scaffold-design.md.
$script:LinearPhases = @('research', 'design', 'code.sprint-1', 'review')

function Get-NextPhase {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][int]$SprintCount
    )
    # `review` advances to the next sprint: code.sprint-(SprintCount+1).
    # All other phases follow the linear sequence (research → design → code.sprint-1 → review).
    if ($Current -eq 'review') {
        return "code.sprint-$($SprintCount + 1)"
    }
    if ($Current -match '^code\.sprint-\d+$') {
        return 'review'
    }
    $idx = $script:LinearPhases.IndexOf($Current)
    if ($idx -lt 0 -or $idx -ge ($script:LinearPhases.Count - 1)) { return $null }
    return $script:LinearPhases[$idx + 1]
}

function Get-PrevPhase {
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][int]$SprintCount
    )
    if ($Current -eq 'review' -and $SprintCount -ge 1) { return "code.sprint-$SprintCount" }
    if ($Current -match '^code\.sprint-(\d+)$') {
        $n = [int]$matches[1]
        if ($n -le 1) { return 'design' }
        return 'review'  # back from sprint-N goes to the review that preceded it
    }
    $idx = $script:LinearPhases.IndexOf($Current)
    if ($idx -le 0) { return $null }
    return $script:LinearPhases[$idx - 1]
}

function Read-Manifest {
    param([Parameter(Mandatory)][string]$JobDir)
    $path = Join-Path $JobDir 'manifest.yaml'
    if (-not (Test-Path $path)) { return $null }
    # Manifest is small + structured. Parse manually — no YAML module dependency.
    $manifest = @{}
    foreach ($line in (Get-Content $path)) {
        if ($line -match '^(\w+):\s*(.+?)\s*$') {
            $key = $matches[1]
            $val = $matches[2].Trim('"', "'")
            # Coerce numeric fields
            if ($key -in @('sprint_count')) { $val = [int]$val }
            $manifest[$key] = $val
        }
    }
    return $manifest
}

function Write-Manifest {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][hashtable]$Manifest
    )
    if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Force -Path $JobDir | Out-Null }
    $path = Join-Path $JobDir 'manifest.yaml'
    $lines = @()
    # Stable key order for readability
    foreach ($key in @('id','title','created_at','status','project','current_phase','phase_started_at','sprint_count','last_updated')) {
        if ($Manifest.ContainsKey($key) -and $null -ne $Manifest[$key]) {
            $v = $Manifest[$key]
            # Quote strings containing spaces or special chars; leave bare for safe values
            if ($v -is [string] -and $v -match '[\s:#"]' -and $v -notmatch '^[\d.+-]') {
                $lines += "$key`: `"$v`""
            } else {
                $lines += "$key`: $v"
            }
        }
    }
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8NoBOM
}

function Append-PhaseLog {
    param(
        [Parameter(Mandatory)][string]$JobDir,
        [Parameter(Mandatory)][string]$Kind,   # created | transition | loop-back
        [Parameter(Mandatory)][string]$Detail,
        [string]$Note
    )
    if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Force -Path $JobDir | Out-Null }
    $path = Join-Path $JobDir 'phase-log.md'
    if (-not (Test-Path $path)) {
        Set-Content -Path $path -Value "# Phase Log`n" -Encoding utf8NoBOM
    }
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $line = "$ts | $Kind | $Detail"
    if ($Note) { $line += " note: `"$Note`"" }
    Add-Content -Path $path -Value $line -Encoding utf8NoBOM
}
