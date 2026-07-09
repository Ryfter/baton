#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet Labor Slice 2 (d078): agentic-executor primitives. A throwaway git worktree
  receives the fleet's edits; proof that labor happened is the worktree's diff
  growing (proof-by-diff — no model prose is ever parsed). The run branch is always
  left for the human to merge; nothing here merges or touches the user's checkout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"     # Invoke-Fleet for the spawner dispatch
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability for the spawner routing

function New-RunWorktree {
    <# Throwaway worktree at <repo-parent>/.baton-worktrees/<run-id> on a new branch
       baton/run-<run-id> off the repo's current HEAD. Returns
       @{ worktree; branch; base_sha }. Throws with a clear message on any git
       failure — callers surface it and exit 2. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RunId
    )
    & git -C $RepoPath rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "execute: '$RepoPath' is not a git repository" }
    $base = [string](& git -C $RepoPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "execute: '$RepoPath' has no commits (HEAD does not resolve)"
    }
    $base = $base.Trim()
    $resolvedRepo = (Resolve-Path -LiteralPath $RepoPath).Path
    $wtRoot = Join-Path (Split-Path $resolvedRepo -Parent) '.baton-worktrees'
    New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null
    $wt = Join-Path $wtRoot $RunId
    $branch = "baton/run-$RunId"
    $out = & git -C $RepoPath worktree add -b $branch $wt HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree add failed: $(@($out) -join ' ')" }
    return @{ worktree = $wt; branch = $branch; base_sha = $base }
}

function Get-RunDiff {
    <# Cumulative unified diff of the worktree vs BaseSha, INCLUDING new/untracked
       files: everything is staged first (`add -A`) so `git diff <sha>` sees them —
       the worktree is throwaway, so staging is harmless (spec §7 mandates new files
       appear in changes.diff). Empty string when nothing changed or on git failure
       (fail-open: an unreadable diff means "no provable work", never a crash). #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha
    )
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return '' }
    $out = & git -C $Worktree diff $BaseSha 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join "`n")
}

function Get-WorktreeTreeSha {
    <# SHA of the worktree's current content tree (index tree after `add -A`, via
       `git write-tree` — plumbing only, no commit is created). Two equal shas =
       the tree did not change between calls; this is the spawner's "diff grew"
       primitive, robust even when an instrument makes its own commits. $null on
       git failure. #>
    param([Parameter(Mandatory)][string]$Worktree)
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $sha = [string](& git -C $Worktree write-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { return $null }
    return $sha.Trim()
}

function Test-ProviderAgentic {
    <# Edit-eligibility (d078, concept-anchored per d025): the optional `agentic`
       field is authoritative when present; absent, eligibility is inferred from
       platform ∈ {claude, codex, gemini}. Chat/local/github providers are filtered
       out of edit tasks (their diff-apply path is Slice 3). Accepts either a fleet
       provider hashtable or a Select-Capability candidate object. #>
    param([Parameter(Mandatory)]$Provider)
    if ($null -ne $Provider.agentic) { return [bool]$Provider.agentic }
    return (([string]$Provider.platform) -in @('claude', 'codex', 'gemini'))
}

function Remove-RunWorktree {
    <# Explicit discard of the worktree DIRECTORY only. The run branch is
       intentionally KEPT so the human can still inspect or merge the work.
       Throws on git failure. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$Force
    )
    $extra = @(); if ($Force) { $extra += '--force' }
    $out = & git -C $RepoPath worktree remove @extra $Worktree 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree remove failed: $(@($out) -join ' ')" }
}
