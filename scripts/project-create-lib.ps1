#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Scaffold a new Baton project: dev folder, private GitHub repo, registry, Grimdex + Grimlore tiers.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/registry-lib.ps1"
. "$PSScriptRoot/start-lib.ps1"             # New-CharterContent
. "$PSScriptRoot/maestro-session-lib.ps1"

function Resolve-GrimdexDataRoot {
    if ($env:GRIMDEX_ROOT -and (Test-Path -LiteralPath $env:GRIMDEX_ROOT)) {
        return (Resolve-Path -LiteralPath $env:GRIMDEX_ROOT).Path
    }
    foreach ($c in @(
        (Join-Path $HOME 'Dev/Grimdex'),
        'D:\Dev\Grimdex'
    )) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Resolve-GrimloreRoot {
    if ($env:GRIMLORE_ROOT -and (Test-Path -LiteralPath $env:GRIMLORE_ROOT)) {
        return (Resolve-Path -LiteralPath $env:GRIMLORE_ROOT).Path
    }
    foreach ($c in @(
        (Join-Path $HOME 'Dev/Grimlore'),
        'D:\Dev\Grimlore'
    )) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function ConvertTo-ProjectSlug {
    param([Parameter(Mandatory)][string]$Text)
    $s = $Text.Trim().ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    return $s.Trim('-')
}

function New-PlanMdSkeleton {
    <# AgentTrail PLAN.md convention stub — do not run npx agenttrail init. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Folder,
        [string]$Description = ''
    )
    $plan = Join-Path $Folder 'PLAN.md'
    if (Test-Path -LiteralPath $plan) { return $false }
    $compId = ConvertTo-ProjectSlug -Text $Name
    if ([string]::IsNullOrWhiteSpace($compId)) { $compId = 'core' }
    $descLine = if ($Description) { "tech: $Description" } else { 'tech: scaffold — replace with real components' }
    @"
# $Name

## Build the core {#$compId}
$descLine
files: []
- [ ] Define the first real component {#$compId-first}
  from: roadmap

## decisions
- $(Get-Date -Format 'yyyy-MM-dd'): PLAN.md scaffolded by Baton project create (AgentTrail convention). Run ``npx agenttrail init`` when the repo earns a live map.
"@ | Set-Content -LiteralPath $plan -Encoding utf8NoBOM
    return $true
}

function Test-GhCliReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
    $auth = & gh auth status 2>&1 | Out-String
    return ($LASTEXITCODE -eq 0) -and ($auth -notmatch 'not logged in')
}

function New-GrimdexProjectTier {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$GrimdexRoot
    )
    $dir = Join-Path $GrimdexRoot "projects/$ProjectId"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $guidance = Join-Path $dir 'decision-guidance.md'
    if (-not (Test-Path -LiteralPath $guidance)) {
        @"
# Decision guidance — $ProjectId

_Project tier scaffolded by Baton $(Get-Date -Format 'yyyy-MM-dd')._

## Established patterns

- **Back up every project to a private GitHub repo** — see universal / cross-project d001 pattern.

## Known mistakes

_None yet._

## Open / under-feedback

- $Description

## Deviations from universal

_None recorded yet._
"@ | Set-Content -LiteralPath $guidance -Encoding utf8NoBOM
    }
    $log = Join-Path $dir 'compact-state-log.md'
    if (-not (Test-Path -LiteralPath $log)) {
        "# Compact state — $ProjectId`n`n_$(Get-Date -Format 'yyyy-MM-dd') scaffolded by Baton._`n" |
            Set-Content -LiteralPath $log -Encoding utf8NoBOM
    }
    return $dir
}

function New-GrimloreProjectBundle {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$RepoSlug,
        [Parameter(Mandatory)][string]$GrimloreRoot
    )
    $dir = Join-Path $GrimloreRoot "projects/$ProjectId"
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'why') | Out-Null
    $index = Join-Path $dir 'index.md'
    if (-not (Test-Path -LiteralPath $index)) {
        $today = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        @"
---
type: Index
title: $Name context bundle
description: $Description
okf_version: "0.2"
tags: [bundle, $ProjectId]
generated: { by: "baton/project-create", at: "$today" }
status: draft
stale_after: $((Get-Date).AddMonths(3).ToString('yyyy-MM-dd'))
x-grimdex:
  project: $ProjectId
  repo: Ryfter/$RepoSlug
---

# $Name

Project-scoped Grimlore. Governance decisions stay in Grimdex ``projects/$ProjectId/``.
This bundle is the *why* and *who* — not dispatch rules or API contracts.

## Code home

``$Folder``

## History

[`log.md`](log.md)
"@ | Set-Content -LiteralPath $index -Encoding utf8NoBOM
    }
    $logPath = Join-Path $dir 'log.md'
    if (-not (Test-Path -LiteralPath $logPath)) {
        "# $Name — log`n`n- $(Get-Date -Format 'yyyy-MM-dd') — scaffolded by Baton.`n" |
            Set-Content -LiteralPath $logPath -Encoding utf8NoBOM
    }
    return $dir
}

function New-BatonProject {
    <# Create dev folder, private GitHub repo, Baton registry record, Grimdex + Grimlore tiers. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [string]$Goal = '',
        [string]$GitHubOrg = $(if ($env:BATON_GITHUB_ORG) { $env:BATON_GITHUB_ORG } else { 'Ryfter' }),
        [string]$BatonHome = (Get-BatonHome),
        [string]$ProjectsRoot = (Get-ProjectHomeRoot),
        [switch]$SkipGitHub,
        [switch]$SkipGrimdex,
        [switch]$SkipGrimlore
    )
    $displayName = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($displayName)) { throw 'project name is required' }
    $projectId = ConvertTo-ProjectSlug -Text $displayName
    if ([string]::IsNullOrWhiteSpace($projectId)) { throw "could not derive project id from '$displayName'" }

    $repoLeaf = ($displayName -replace '\s+', '')
    if ([string]::IsNullOrWhiteSpace($repoLeaf)) { $repoLeaf = $projectId }
    $folder = Join-Path $ProjectsRoot $repoLeaf
    if (Test-Path -LiteralPath $folder) { throw "folder already exists: $folder" }

    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    $desc = if ($Description) { $Description.Trim() } else { "Baton project $displayName" }
    $goalText = if ($Goal) { $Goal.Trim() } else { $desc }

    $readme = Join-Path $folder 'README.md'
    "# $displayName`n`n$desc`n`nLiving map: ``PLAN.md`` (AgentTrail convention).`n" | Set-Content -LiteralPath $readme -Encoding utf8NoBOM

    $charter = New-CharterContent -Name $displayName -Goal $goalText -Audience '' -Done '' -Reasoning ''
    if ($charter -notmatch 'PLAN\.md') {
        $charter = $charter.TrimEnd() + "`n`n## Living map`n`nAgents maintain ``PLAN.md`` (AgentTrail declared-vs-observed). Maestro jobs remain canonical for labor.`n"
    }
    Set-Content -LiteralPath (Join-Path $folder 'CHARTER.md') -Value $charter -Encoding utf8NoBOM
    [void](New-PlanMdSkeleton -Name $displayName -Folder $folder -Description $desc)

    & git -C $folder init -b main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git init failed in $folder" }

    $github = [ordered]@{ ok = $false; url = $null; skipped = $true; error = $null }
    if (-not $SkipGitHub) {
        if (Test-GhCliReady) {
            $ghArgs = @(
                'repo', 'create', "$GitHubOrg/$repoLeaf",
                '--private',
                '--description', $desc,
                '--source', $folder,
                '--remote', 'origin'
            )
            $ghOut = & gh @ghArgs 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $github.ok = $true
                $github.skipped = $false
                $github.url = "https://github.com/$GitHubOrg/$repoLeaf"
            } else {
                $github.skipped = $false
                $github.error = $ghOut.Trim()
                & git -C $folder add -A 2>&1 | Out-Null
                & git -C $folder commit -m "Initial commit — scaffolded by Baton" 2>&1 | Out-Null
            }
        } else {
            $github.error = 'gh not available or not authenticated — local git only'
            & git -C $folder add -A 2>&1 | Out-Null
            & git -C $folder commit -m "Initial commit — scaffolded by Baton" 2>&1 | Out-Null
        }
    } else {
        & git -C $folder add -A 2>&1 | Out-Null
        & git -C $folder commit -m "Initial commit — scaffolded by Baton" 2>&1 | Out-Null
    }

    $projectsDir = Join-Path $BatonHome 'projects'
    Write-ProjectRecord -ProjectsRoot $projectsDir -Record @{
        id          = $projectId
        name        = $displayName
        folder      = $folder
        blurb       = $desc
        archived    = $false
        hidden      = $false
        created_at  = (Get-Date).ToUniversalTime().ToString('o')
        github_repo = if ($github.url) { "$GitHubOrg/$repoLeaf" } else { $null }
    }

    Set-MaestroProjectSession -Project $projectId -Provider 'openrouter-glm' -Kind 'openrouter' -BatonHome $BatonHome | Out-Null

    $grimdexPath = $null
    if (-not $SkipGrimdex) {
        $gx = Resolve-GrimdexDataRoot
        if ($gx) {
            $grimdexPath = New-GrimdexProjectTier -ProjectId $projectId -Description $desc -GrimdexRoot $gx
        }
    }

    $grimlorePath = $null
    if (-not $SkipGrimlore) {
        $gl = Resolve-GrimloreRoot
        if ($gl) {
            $grimlorePath = New-GrimloreProjectBundle -ProjectId $projectId -Name $displayName `
                -Description $desc -Folder $folder -RepoSlug $repoLeaf -GrimloreRoot $gl
        }
    }

    return [pscustomobject]@{
        ok           = $true
        id           = $projectId
        name         = $displayName
        folder       = $folder
        blurb        = $desc
        github       = [pscustomobject]$github
        grimdex_path = $grimdexPath
        grimlore_path = $grimlorePath
    }
}

function Invoke-MaestroNewProjectLine {
    <# Parse: "new project foo — bar" / "create project foo: bar" #>
    param(
        [Parameter(Mandatory)][string]$Line,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($Line -notmatch '^(?i)(?:new|create)\s+project\s+(.+)$') {
        throw 'usage: new project <name> — <what it is>'
    }
    $rest = $Matches[1].Trim()
    $name = $rest
    $desc = ''
    if ($rest -match '^(.+?)\s*(?:—|--|:|-\s)\s*(.+)$') {
        $name = $Matches[1].Trim()
        $desc = $Matches[2].Trim()
    }
    if ([string]::IsNullOrWhiteSpace($desc)) {
        $desc = "Baton project $name"
    }
    return New-BatonProject -Name $name -Description $desc -Goal $desc -BatonHome $BatonHome
}
