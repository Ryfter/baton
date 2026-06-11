#!/usr/bin/env pwsh
# Library for the /idea front door. Job-less: creates an idea workspace, scaffolds
# the concept doc, builds GitHub issue payloads (pure), and publishes them via gh.

. "$PSScriptRoot/baton-home.ps1"

function Get-IdeasRoot([string]$IdeasRoot) {
    if ($IdeasRoot) { return $IdeasRoot }
    if ($env:IDEAS_ROOT) { return $env:IDEAS_ROOT }
    return (Join-Path (Get-BatonHome) 'ideas')
}

function ConvertTo-IdeaSlug([string]$Text) {
    if (-not $Text) { return 'idea' }
    $s = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
    if (-not $s) { return 'idea' }
    return $s
}

function New-IdeaWorkspace {
    param(
        [Parameter(Mandatory)][string]$Idea,
        [string]$IdeasRoot,
        [string]$Timestamp
    )
    $root = Get-IdeasRoot $IdeasRoot
    $slug = ConvertTo-IdeaSlug $Idea
    if (-not $Timestamp) { $Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss') }
    $path = Join-Path $root "$slug-$Timestamp"
    foreach ($sub in @('', 'research', 'council')) {
        $d = if ($sub) { Join-Path $path $sub } else { $path }
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    return [pscustomobject]@{ path = $path; slug = $slug }
}

function New-IdeaConceptDoc {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Title,
        [string]$Idea,
        [string]$Date
    )
    if (-not $Date) { $Date = (Get-Date -Format 'yyyy-MM-dd') }
    $ideaLine = if ($Idea) { $Idea } else { '(raw idea)' }
    $doc = @"
---
title: $Title
date: $Date
status: draft
source: /idea
---

# $Title

> Raw idea: $ideaLine

## Problem

_What hurts, and for whom._

## Viability verdict

_The debate's go / no-go / go-if, with confidence._

## Proposed approach

_The strongest version of the idea._

## Risks & open questions

_What could sink this; what we still don't know._

## Decomposition

_Epic-level tasks — each becomes a GitHub Issue._

## Out of scope

_What this explicitly does not include._
"@
    Set-Content -Path $Path -Value $doc -Encoding utf8
}

function Build-IdeaIssues {
    # Pure: turn epic-level task objects into GitHub issue payloads. No network.
    param(
        [object[]]$Tasks,
        [Parameter(Mandatory)][string]$ConceptPath,
        [string[]]$ExtraLabels
    )
    $out = @()
    foreach ($t in @($Tasks)) {
        $title = "$($t.title)".Trim()
        if (-not $title) { Write-Warning "Skipping task with no title."; continue }
        $bodyParts = @()
        if ($t.description) { $bodyParts += "$($t.description)".Trim() }
        if ($t.acceptance)  { $bodyParts += "## Acceptance criteria`n`n$("$($t.acceptance)".Trim())" }
        $bodyParts += "From concept: $ConceptPath"
        $body = ($bodyParts -join "`n`n")
        $labels = @('from:idea')
        if ($t.tier) { $labels += "$($t.tier)".Trim() }
        if ($ExtraLabels) { $labels += $ExtraLabels }
        $labels = @($labels | Where-Object { $_ } | Select-Object -Unique)
        $out += [pscustomobject]@{ title = $title; body = $body; labels = $labels }
    }
    return ,([object[]]$out)
}

function Ensure-IdeaIssueLabels {
    # Ensure labels used by /idea exist before issue creation. This keeps the
    # publishing step from failing on a fresh repository with only default labels.
    param(
        [string[]]$Labels,
        [string]$Repo
    )
    $want = @($Labels | Where-Object { $_ } | Select-Object -Unique)
    if ($want.Count -eq 0) { return }

    $listArgs = @('label', 'list', '--limit', '1000')
    if ($Repo) { $listArgs += @('--repo', $Repo) }
    $existingOut = (& gh @listArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "gh label list failed: $($existingOut -join "`n")" }
    $existing = @{}
    foreach ($line in @($existingOut)) {
        $name = ("$line" -split "`t| {2,}", 2)[0].Trim()
        if ($name) { $existing[$name] = $true }
    }

    $defaults = @{
        'from:idea' = @{ color = '5319E7'; description = 'Created by the /idea front door' }
        'Tier-1'    = @{ color = 'D73A4A'; description = 'Highest-priority implementation tier' }
        'Tier-2'    = @{ color = 'FBCA04'; description = 'Medium-priority implementation tier' }
        'Tier-3'    = @{ color = '0E8A16'; description = 'Lower-priority implementation tier' }
    }
    foreach ($label in $want) {
        if ($existing.ContainsKey($label)) { continue }
        $meta = if ($defaults.ContainsKey($label)) { $defaults[$label] } else { @{ color = 'C5DEF5'; description = 'Created by /idea' } }
        $createArgs = @('label', 'create', $label, '--color', $meta.color, '--description', $meta.description)
        if ($Repo) { $createArgs += @('--repo', $Repo) }
        $created = (& gh @createArgs 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "gh label create failed for ${label}: $($created -join "`n")" }
    }
}

function Publish-IdeaIssues {
    # Thin gh wrapper. Pre-flight auth check stops before creating anything;
    # then best-effort per issue so one failure never aborts the rest.
    param(
        [object[]]$Issues,
        [string]$Project,
        [string]$Repo
    )
    $authOk = $true
    try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $authOk = $false } }
    catch { $authOk = $false }
    if (-not $authOk) {
        return ,([object[]]@([pscustomobject]@{ title = '(preflight)'; number = $null; ok = $false; error = 'gh not authenticated' }))
    }
    try {
        $allLabels = foreach ($iss in @($Issues)) { foreach ($l in @($iss.labels)) { $l } }
        Ensure-IdeaIssueLabels -Labels ([string[]]$allLabels) -Repo $Repo
    }
    catch {
        return ,([object[]]@([pscustomobject]@{ title = '(preflight)'; number = $null; ok = $false; error = "$_" }))
    }
    $results = @()
    foreach ($iss in @($Issues)) {
        $tmp = $null
        try {
            $tmp = New-TemporaryFile
            Set-Content -Path $tmp -Value $iss.body -Encoding utf8
            $ghArgs = @('issue', 'create', '--title', $iss.title, '--body-file', "$tmp")
            foreach ($l in @($iss.labels)) { $ghArgs += @('--label', $l) }
            if ($Repo)    { $ghArgs += @('--repo', $Repo) }
            if ($Project) { $ghArgs += @('--project', $Project) }
            $url = (& gh @ghArgs 2>&1 | Select-Object -Last 1)
            if ($LASTEXITCODE -ne 0) { throw "gh issue create failed: $url" }
            $num = if ("$url" -match '/(\d+)\s*$') { [int]$Matches[1] } else { $null }
            $results += [pscustomobject]@{ title = $iss.title; number = $num; ok = $true; error = $null }
        }
        catch {
            $results += [pscustomobject]@{ title = $iss.title; number = $null; ok = $false; error = "$_" }
        }
        finally {
            if ($tmp -and (Test-Path $tmp)) { Remove-Item -Force $tmp }
        }
    }
    return ,([object[]]$results)
}
