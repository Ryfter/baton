#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Project registry (d076): scan the D:\dev home base, fold the scan over
  start-lib's per-project project.json records, resolve a project name to a
  folder, and roster projects by active/inactive/archived lifecycle.
  Neutral core — no harness dependency. Fail-open throughout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/start-lib.ps1"             # Read-/Write-ProjectRecord
. "$PSScriptRoot/session-markers-lib.ps1"   # Get-ActiveSessions, Test-FolderActive

function Get-ProjectHomeRoot {
    if ($env:BATON_PROJECTS_ROOT) { return [string]$env:BATON_PROJECTS_ROOT }
    return 'D:\dev'
}

function Get-FolderSlug {
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $leaf = Split-Path -Leaf ([IO.Path]::GetFullPath($Folder))
        return ($leaf.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
    } catch { return '' }
}

function Get-ProjectId {
    <# Git-remote repo-name slug, else folder-name slug. Mirrors
       coach-lib's Get-CoachProjectId so registry records line up with what
       /baton:start and the coach already key by. #>
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $remote = (& git -C $Folder remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote) {
            $clean = "$remote" -replace '^(https?://|git@)', '' -replace ':', '/' -replace '\.git$', ''
            $parts = $clean -split '/' | Where-Object { $_ }
            if (@($parts).Count -ge 2) {
                $repo = [string]$parts[-1]
                return ($repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    } catch { }
    return (Get-FolderSlug -Folder $Folder)
}

function Get-ProjectBlurb {
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $charter = Join-Path $Folder 'CHARTER.md'
        if (Test-Path $charter) {
            $lines = Get-Content -LiteralPath $charter -ErrorAction Stop
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^##\s+What we''re building') {
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        $t = $lines[$j].Trim()
                        if ($t -and $t -notmatch '^#') { return $t }
                    }
                }
            }
        }
        $readme = Join-Path $Folder 'README.md'
        if (Test-Path $readme) {
            foreach ($line in (Get-Content -LiteralPath $readme -ErrorAction Stop)) {
                if ($line -match '^#\s+(.+)$') { return $Matches[1].Trim() }
            }
        }
    } catch { }
    return '(no description)'
}

function Test-IsProjectFolder {
    param([Parameter(Mandatory)][string]$Folder)
    return ((Test-Path (Join-Path $Folder '.git')) -or (Test-Path (Join-Path $Folder 'CHARTER.md')))
}

function Find-ProjectFolders {
    param([string]$Root = (Get-ProjectHomeRoot))
    $out = [System.Collections.ArrayList]@()
    try {
        if (-not (Test-Path $Root)) { return @() }
        foreach ($d in Get-ChildItem -Directory -Path $Root -ErrorAction SilentlyContinue) {
            if (-not (Test-IsProjectFolder -Folder $d.FullName)) { continue }
            [void]$out.Add([ordered]@{
                id     = (Get-ProjectId -Folder $d.FullName)
                slug   = (Get-FolderSlug -Folder $d.FullName)
                folder = $d.FullName
                blurb  = (Get-ProjectBlurb -Folder $d.FullName)
            })
        }
    } catch { Write-Debug "Find-ProjectFolders: $($_.Exception.Message)" }
    if ($out.Count -eq 0) { return @() }
    return [object[]]$out.ToArray()
}

$script:ResumeCommandMap = @{
    # Per-agent resume invocation. NOTE: verify exact CLI syntax at build time
    # against each tool (claude --resume vs --continue; codex resume subcommand).
    'claude' = 'claude --resume {0}'
    'codex'  = 'codex resume {0}'
}

function Get-ResumeCommand {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$SessionId
    )
    $key = $Agent.ToLowerInvariant()
    if (-not $script:ResumeCommandMap.ContainsKey($key)) { return $null }
    return ($script:ResumeCommandMap[$key] -f $SessionId)
}

function Get-ProjectRoster {
    param(
        [string]$Root = (Get-ProjectHomeRoot),
        [string]$BatonHome = (Get-BatonHome)
    )
    $projectsRoot = Join-Path $BatonHome 'projects'
    $active = [System.Collections.ArrayList]@()
    $inactive = [System.Collections.ArrayList]@()
    $archived = [System.Collections.ArrayList]@()
    $sessions = @(Get-ActiveSessions -BatonHome $BatonHome)

    foreach ($p in @(Find-ProjectFolders -Root $Root)) {
        $rec = Read-ProjectRecord -ProjectId $p.id -ProjectsRoot $projectsRoot
        $isArchived = ($null -ne $rec -and $rec.archived -eq $true)
        $isHidden   = ($null -ne $rec -and $rec.hidden -eq $true)
        if ($isHidden) { continue }
        $blurb = if ($rec -and $rec.blurb) { [string]$rec.blurb } else { [string]$p.blurb }
        $entry = [ordered]@{
            id              = $p.id
            slug            = $p.slug
            folder          = $p.folder
            blurb           = $blurb
            archived        = $isArchived
            resumable       = ($null -ne $rec -and -not [string]::IsNullOrWhiteSpace($rec.last_session_id))
            agent           = if ($rec) { [string]$rec.agent } else { $null }
            last_session_id = if ($rec) { [string]$rec.last_session_id } else { $null }
        }
        if ($isArchived) { [void]$archived.Add($entry) }
        elseif (Test-FolderActive -Folder $p.folder -Sessions $sessions) { [void]$active.Add($entry) }
        else { [void]$inactive.Add($entry) }
    }
    return @{
        active   = @($active.ToArray())
        inactive = @($inactive.ToArray())
        archived = @($archived.ToArray())
    }
}

function Resolve-ProjectTarget {
    param(
        [string]$Slug,
        [string]$Cwd,
        [string]$Root = (Get-ProjectHomeRoot),
        [string]$BatonHome = (Get-BatonHome)
    )
    $found = @(Find-ProjectFolders -Root $Root)
    # 1. Explicit --slug: match against folder slug first, then id (two-pass to avoid collision).
    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        $want = $Slug.ToLowerInvariant()
        # First pass: exact slug match
        foreach ($p in $found) {
            if ($p.slug -eq $want) {
                return @{ status = 'resolved'; folder = $p.folder }
            }
        }
        # Second pass: id match (fallback)
        foreach ($p in $found) {
            if ($p.id -eq $want) {
                return @{ status = 'resolved'; folder = $p.folder }
            }
        }
        return @{ status = 'unknown'; slug = $Slug }
    }
    # 2. cwd is itself a project folder.
    if (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-IsProjectFolder -Folder $Cwd)) {
        return @{ status = 'resolved'; folder = ([IO.Path]::GetFullPath($Cwd)) }
    }
    # 3. Home base / not a project → caller shows the picker.
    return @{ status = 'picker' }
}
