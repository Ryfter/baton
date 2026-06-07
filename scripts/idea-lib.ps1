#!/usr/bin/env pwsh
# Library for the /idea front door. Job-less: creates an idea workspace, scaffolds
# the concept doc, builds GitHub issue payloads (pure), and publishes them via gh.

function Get-IdeasRoot([string]$IdeasRoot) {
    if ($IdeasRoot) { return $IdeasRoot }
    if ($env:IDEAS_ROOT) { return $env:IDEAS_ROOT }
    return (Join-Path $HOME '.claude/ideas')
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
