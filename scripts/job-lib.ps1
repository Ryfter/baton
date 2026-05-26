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
