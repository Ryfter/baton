#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reusable entry point for an unattended, concurrent, gated backlog run (Plan 10 / d008/d010).

.DESCRIPTION
  Wraps Invoke-BacklogConcurrent with the remote bookkeeping that keeps set-and-forget
  runs safe:
    - BEFORE the run: fetch origin and fast-forward the local target branch (and the
      merge worktree) to origin/<target>, so item worktrees branch off the true tip and
      the post-run push can't be rejected non-fast-forward.
    - AFTER the run: push <target>; on a (rare) rejection, fetch + merge origin and retry
      once.
  The fleet-* libraries stay remote-agnostic (local git mechanics only); all push/pull
  lives here.

.PARAMETER TasksPath
  JSON file: array of { id, model, prompt, allowed_paths[], max_files, test_command, depends_on[] }.
#>
param(
    [Parameter(Mandatory)][string]$TasksPath,
    [string]$RepoRoot = 'D:\Dev\baton',
    [string]$Target = 'master',
    [string]$WorktreeRoot = 'D:\Dev\cao-worktrees',
    [string]$OutputRoot,
    [int]$TimeoutS = 900,
    [switch]$NoPush
)

. (Join-Path $HOME '.claude/scripts/fleet-backlog.ps1')

if (-not $OutputRoot) { $OutputRoot = Join-Path $HOME '.claude/ensembles' }
$ts  = (Get-Date).ToString('yyyy-MM-ddTHH-mm-ss')
$out = Join-Path $OutputRoot "backlog-live-$ts"

$tasks = @(Get-Content -LiteralPath $TasksPath -Raw | ConvertFrom-Json)
$specs = @{ codex = @{ exe = 'codex'; args = @('exec', '-') } }

# --- pre-run sync: local target := origin/target ---
git -C $RepoRoot fetch -q origin 2>&1 | Out-Null
$mw = Join-Path $WorktreeRoot ('_merge-' + ($Target -replace '[\\/]', '-'))
if (-not (Test-Path (Join-Path $mw '.git'))) {
    if (Test-Path $mw) { git -C $RepoRoot worktree remove --force $mw 2>&1 | Out-Null }
    git -C $RepoRoot worktree add --force $mw $Target 2>&1 | Out-Null
}
$hasOrigin = git -C $mw rev-parse --verify --quiet "refs/remotes/origin/$Target"
if ($hasOrigin) {
    git -C $mw checkout $Target 2>&1 | Out-Null
    git -C $mw merge --ff-only "origin/$Target" 2>&1 | Out-Null
    Write-Host "synced local $Target -> origin/$Target ($(git -C $mw rev-parse --short HEAD))"
}

Write-Host "BACKLOG RUN ($($tasks.Count) item(s)) -> $Target | out: $out"
$results = Invoke-BacklogConcurrent -RepoRoot $RepoRoot -Tasks $tasks -ModelSpecs $specs `
    -Integration $Target -IntegrationBase $Target -OutputDir $out -WorktreeRoot $WorktreeRoot -TimeoutS $TimeoutS

foreach ($r in $results) {
    $tag = if ($r.merged) { 'MERGED ' } else { 'blocked' }
    Write-Host ("  [{0}] {1} {2}" -f $tag, $r.id, $r.model)
    if (-not $r.merged) { Write-Host ("      reasons: {0}" -f (($r.reasons) -join '; ')) }
    if ($r.changed)     { Write-Host ("      changed: {0}" -f (($r.changed) -join ', ')) }
}

# --- post-run push (with one fetch+merge fallback) ---
if (-not $NoPush -and ($results | Where-Object { $_.merged })) {
    $push = git -C $mw push origin $Target 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "push rejected; reconciling with origin and retrying..."
        git -C $mw fetch -q origin 2>&1 | Out-Null
        git -C $mw merge --no-edit "origin/$Target" 2>&1 | Out-Null
        $push = git -C $mw push origin $Target 2>&1
    }
    Write-Host ("push: {0}" -f (($push | Select-Object -Last 1)))
}
Write-Host "DONE -> $Target ($(git -C $mw rev-parse --short HEAD))"
