#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Script-root resolution for the baton CLI. Dot-source from the dispatcher
  (and tests). Does not invoke runners.

.DESCRIPTION
  Resolution order for engine scripts:
    1. $env:BATON_REPO_ROOT/scripts   — source checkout / dev
    2. $env:BATON_HOME/scripts        — optional local overrides
    3. directory of the running baton entry (install / dispatch location)
    4. legacy ~/.claude/scripts (or $env:BATON_CLAUDE_DIR/scripts) — warn once

  $env:BATON_CLAUDE_DIR overrides the legacy base for hermetic tests and the
  existing migration tooling (see baton-home.ps1).
#>

# Process-scoped: legacy fallback warned at most once per process.
if (-not (Get-Variable -Name BatonLegacyPathWarned -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BatonLegacyPathWarned = $false
}

# Set by scripts/baton.ps1 to $PSScriptRoot so install-location resolution
# points at the dispatcher scripts dir even when this file is dot-sourced
# from elsewhere (tests).
if (-not (Get-Variable -Name BatonEntryScriptRoot -Scope Script -ErrorAction SilentlyContinue)) {
    $script:BatonEntryScriptRoot = $null
}

function Get-BatonLegacyScriptsDir {
    if ($env:BATON_CLAUDE_DIR) {
        return (Join-Path $env:BATON_CLAUDE_DIR 'scripts')
    }
    return (Join-Path $HOME '.claude' 'scripts')
}

function Get-BatonScriptCandidateRoots {
    <# Ordered candidate script directories (may or may not exist). #>
    $roots = [System.Collections.Generic.List[string]]::new()
    if ($env:BATON_REPO_ROOT) {
        $roots.Add((Join-Path $env:BATON_REPO_ROOT 'scripts'))
    }
    if ($env:BATON_HOME) {
        $roots.Add((Join-Path $env:BATON_HOME 'scripts'))
    }
    $entry = $script:BatonEntryScriptRoot
    if (-not $entry -and $PSScriptRoot) { $entry = $PSScriptRoot }
    if ($entry) { $roots.Add($entry) }
    $roots.Add((Get-BatonLegacyScriptsDir))
    return $roots.ToArray()
}

function Write-BatonLegacyPathWarning {
    param([Parameter(Mandatory)][string]$Path)
    if ($script:BatonLegacyPathWarned) { return }
    $script:BatonLegacyPathWarned = $true
    $msg = "baton: warning: resolved script via deprecated path '$Path'. Prefer BATON_REPO_ROOT/scripts, BATON_HOME/scripts, or the baton install location."
    [Console]::Error.WriteLine($msg)
}

function Get-BatonScriptRoot {
    <# Return the first candidate script directory that exists on disk. #>
    $tried = [System.Collections.Generic.List[string]]::new()
    $legacy = Get-BatonLegacyScriptsDir
    foreach ($root in (Get-BatonScriptCandidateRoots)) {
        $tried.Add($root)
        if (Test-Path -LiteralPath $root -PathType Container) {
            if ($root -eq $legacy) {
                Write-BatonLegacyPathWarning -Path $root
            }
            return $root
        }
    }
    $list = ($tried | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "No Baton scripts directory found. Tried:`n$list"
}

function Resolve-BatonScript {
    <# Resolve a script file name against the candidate roots; return full path. #>
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    $tried = [System.Collections.Generic.List[string]]::new()
    $legacy = Get-BatonLegacyScriptsDir
    foreach ($root in (Get-BatonScriptCandidateRoots)) {
        $candidate = Join-Path $root $Name
        $tried.Add($candidate)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            if ($root -eq $legacy) {
                Write-BatonLegacyPathWarning -Path $root
            }
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    $list = ($tried | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    throw "Baton script '$Name' not found. Tried:`n$list"
}
