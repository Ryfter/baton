#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Hard merge gate + worktree isolation for unattended multi-model code dispatch (decision d008).

.DESCRIPTION
  The safety core of set-and-forget backlog execution. Models only ever commit to their
  own isolated branch in their own git worktree; ONLY the orchestrator merges, and only
  into an INTEGRATION branch (never master), and only after a hard gate passes:

    1. clean      — the worktree has no uncommitted changes after the model's run
                    (dirty trees are auto-committed to the item branch first).
    2. scope      — every changed file matches an allowed path pattern for the item.
    3. budget     — changed-file count is within MaxChangedFiles (a model can't rewrite
                    half the repo while "fixing" one item).
    4. tests      — the item's test command exits 0 inside the worktree.

  A blocked item never touches the integration branch; unrelated items keep flowing.
  Live status is emitted via the same _ensemble.json / <label>.live.json files the
  dashboard cockpit polls, so gated merges are visible in real time.

  This module is git-mechanics + verification only — deterministic and unit-testable
  WITHOUT calling any model. Model dispatch is layered on top via Invoke-ItemImplementation.
#>

. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

function Initialize-IntegrationBranch {
    <# Ensure an integration branch exists off the given base; return its name. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$Base = 'master',
        [string]$Name = 'integration/backlog'
    )
    Push-Location $RepoRoot
    try {
        $exists = (git rev-parse --verify --quiet "refs/heads/$Name")
        if (-not $exists) {
            git branch $Name $Base | Out-Null
        }
        return $Name
    } finally { Pop-Location }
}

function New-ItemWorktree {
    <# Create an isolated worktree + branch for one backlog item/model. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ItemId,       # e.g. 'issue-19'
        [Parameter(Mandatory)][string]$Model,        # e.g. 'codex'
        [string]$Base = 'integration/backlog',
        [string]$WorktreeRoot
    )
    if (-not $WorktreeRoot) { $WorktreeRoot = Join-Path (Split-Path $RepoRoot -Parent) 'cao-worktrees' }
    if (-not (Test-Path $WorktreeRoot)) { New-Item -ItemType Directory -Force -Path $WorktreeRoot | Out-Null }
    $branch = "auto/$ItemId-$Model"
    $path   = Join-Path $WorktreeRoot "$ItemId-$Model"
    Push-Location $RepoRoot
    try {
        if (Test-Path $path) { git worktree remove --force $path 2>&1 | Out-Null }
        git branch -D $branch 2>&1 | Out-Null
        git worktree add -b $branch $path $Base 2>&1 | Out-Null
    } finally { Pop-Location }
    return [pscustomobject]@{ item = $ItemId; model = $Model; branch = $branch; path = $path; base = $Base }
}

function Get-ChangedFiles {
    <# Files changed in the worktree branch vs its merge-base with the integration branch,
       PLUS any uncommitted working-tree changes. #>
    param([Parameter(Mandatory)][string]$WorktreePath, [string]$Base = 'integration/backlog')
    Push-Location $WorktreePath
    try {
        $committed = @(git diff --name-only "$Base...HEAD" 2>$null)
        $uncommitted = @(git status --porcelain 2>$null | ForEach-Object { ($_ -replace '^...').Trim() })
        return @($committed + $uncommitted | Where-Object { $_ } | Sort-Object -Unique)
    } finally { Pop-Location }
}

function Invoke-MergeGate {
    <#
    .SYNOPSIS  Run the hard gate against an item worktree. No side effects on the integration branch.
    .OUTPUTS   @{ pass=bool; reasons=@(); changed=@(); tests_exit=int }
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$Branch,
        [string]$Base = 'integration/backlog',
        [string[]]$AllowedPathPatterns = @('*'),
        [int]$MaxChangedFiles = 20,
        [string]$TestCommand,
        [switch]$AutoCommit
    )
    $reasons = @()
    Push-Location $WorktreePath
    try {
        # 1. clean — auto-commit any dirty working tree to the item branch so the gate
        #    judges a real commit (Codex: "models claiming success without a real commit").
        $dirty = @(git status --porcelain 2>$null)
        if ($dirty.Count -gt 0) {
            if ($AutoCommit) {
                git add -A 2>&1 | Out-Null
                git commit -q -m "auto: $Branch work-in-progress" 2>&1 | Out-Null
            } else {
                $reasons += "dirty: $($dirty.Count) uncommitted change(s)"
            }
        }

        # changed files vs base
        $changed = @(git diff --name-only "$Base...HEAD" 2>$null | Where-Object { $_ })

        # nothing changed = nothing to merge (a no-op model run is a soft failure)
        if ($changed.Count -eq 0) { $reasons += 'no-change: model produced no committed diff' }

        # 2. scope — every changed file must match an allowed pattern
        $outOfScope = @($changed | Where-Object {
            $f = $_; -not ($AllowedPathPatterns | Where-Object { $f -like $_ })
        })
        if ($outOfScope.Count -gt 0) { $reasons += "scope: out-of-scope edits -> $($outOfScope -join ', ')" }

        # 3. budget
        if ($changed.Count -gt $MaxChangedFiles) {
            $reasons += "budget: $($changed.Count) files > limit $MaxChangedFiles"
        }

        # 4. tests — run in a CHILD process so a test's `exit` can't terminate the
        #    orchestrator, and so the suite runs in the worktree's cwd in isolation.
        $testsExit = 0
        if ($TestCommand) {
            & pwsh -NoProfile -Command $TestCommand 2>&1 | Out-Null
            $testsExit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
            if ($testsExit -ne 0) { $reasons += "tests: exit $testsExit" }
        }

        return @{ pass = ($reasons.Count -eq 0); reasons = $reasons; changed = $changed; tests_exit = $testsExit }
    } finally { Pop-Location }
}

function Merge-ItemToIntegration {
    <#
    .SYNOPSIS  Gate, then merge the item branch into the integration branch IFF it passes.
               The only place a merge happens. Master is never touched.
    .OUTPUTS   @{ merged=bool; gate=<gate result> }
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$Branch,
        [string]$Integration = 'integration/backlog',
        [string[]]$AllowedPathPatterns = @('*'),
        [int]$MaxChangedFiles = 20,
        [string]$TestCommand,
        [switch]$AutoCommit
    )
    $gate = Invoke-MergeGate -WorktreePath $WorktreePath -Branch $Branch -Base $Integration `
        -AllowedPathPatterns $AllowedPathPatterns -MaxChangedFiles $MaxChangedFiles `
        -TestCommand $TestCommand -AutoCommit:$AutoCommit

    if (-not $gate.pass) { return @{ merged = $false; gate = $gate } }

    # Merge happens in the MAIN repo checkout (not the worktree), into integration only.
    Push-Location $RepoRoot
    try {
        $cur = (git rev-parse --abbrev-ref HEAD).Trim()
        git checkout $Integration 2>&1 | Out-Null
        git merge --no-ff -m "merge $Branch into $Integration (gate passed)" $Branch 2>&1 | Out-Null
        $mergeExit = $LASTEXITCODE
        if ($mergeExit -ne 0) {
            git merge --abort 2>&1 | Out-Null
            git checkout $cur 2>&1 | Out-Null
            $gate.reasons += "merge-conflict: aborted"
            return @{ merged = $false; gate = $gate }
        }
        git checkout $cur 2>&1 | Out-Null
        return @{ merged = $true; gate = $gate }
    } finally { Pop-Location }
}
