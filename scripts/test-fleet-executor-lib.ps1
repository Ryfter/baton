#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-TempRepo {
    param([string]$Root)
    $p = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q
    & git -C $p config user.email 'test@test.local'
    & git -C $p config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $p 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m 'init' 2>$null | Out-Null
    return $p
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exec-lib-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
try {
    $repo = New-TempRepo -Root $tmpRoot

    # ---- New-RunWorktree ----
    $wt = New-RunWorktree -RepoPath $repo -RunId 'go-t1'
    Check 'W1 worktree dir exists' (Test-Path $wt.worktree)
    Check 'W2 worktree lives under sibling .baton-worktrees' ($wt.worktree -like (Join-Path $tmpRoot '.baton-worktrees\*'))
    Check 'W3 branch named baton/run-<id>' ($wt.branch -eq 'baton/run-go-t1')
    Check 'W4 base_sha is repo HEAD' ($wt.base_sha -eq ([string](& git -C $repo rev-parse HEAD)).Trim())
    Check 'W5 worktree checked out on the run branch' ((([string](& git -C $wt.worktree branch --show-current)).Trim()) -eq 'baton/run-go-t1')

    $notRepo = Join-Path $tmpRoot 'plain'; New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $threw = $false; try { New-RunWorktree -RepoPath $notRepo -RunId 'x' | Out-Null } catch { $threw = $true }
    Check 'W6 non-repo throws' $threw

    # ---- Get-RunDiff ----
    Check 'D1 fresh worktree diff is empty' ((Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha) -eq '')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'a.txt') -Value 'changed' -Encoding utf8NoBOM
    $d1 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D2 edited file appears in diff' ($d1 -match 'changed')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'brand-new.txt') -Value 'i am new' -Encoding utf8NoBOM
    $d2 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D3 NEW (untracked) file captured in diff' ($d2 -match 'brand-new\.txt')
    Check 'D4 diff grew with the new file' ($d2.Length -gt $d1.Length)
    Check 'D5 user repo tree untouched by worktree edits' (-not (Test-Path (Join-Path $repo 'brand-new.txt')))

    # ---- Get-WorktreeTreeSha ----
    $t1 = Get-WorktreeTreeSha -Worktree $wt.worktree
    $t2 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S1 stable tree sha when nothing changes' (($null -ne $t1) -and ($t1 -eq $t2))
    Set-Content -LiteralPath (Join-Path $wt.worktree 'another.txt') -Value 'x' -Encoding utf8NoBOM
    $t3 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S2 tree sha changes when a file lands' ($t3 -ne $t1)
    Check 'S3 non-repo path -> $null' ($null -eq (Get-WorktreeTreeSha -Worktree $notRepo))

    # ---- Test-ProviderAgentic ----
    Check 'A1 agentic:true is authoritative' (Test-ProviderAgentic -Provider @{ agentic = $true; platform = 'local' })
    Check 'A2 agentic:false is authoritative' (-not (Test-ProviderAgentic -Provider @{ agentic = $false; platform = 'codex' }))
    Check 'A3 platform codex inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'codex' })
    Check 'A4 platform claude inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'claude' })
    Check 'A5 platform gemini inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'gemini' })
    Check 'A6 platform local not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'local' }))
    Check 'A7 platform github not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'github' }))
    Check 'A8 no platform, no marker -> not agentic' (-not (Test-ProviderAgentic -Provider @{ name = 'mystery' }))

    # ---- Remove-RunWorktree ----
    Remove-RunWorktree -Worktree $wt.worktree -RepoPath $repo -Force
    Check 'R1 worktree dir removed' (-not (Test-Path $wt.worktree))
    $branches = [string](& git -C $repo branch --list 'baton/run-go-t1')
    Check 'R2 run branch KEPT after removal' ($branches -match 'baton/run-go-t1')
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
