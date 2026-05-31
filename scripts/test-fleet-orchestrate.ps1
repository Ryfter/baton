#!/usr/bin/env pwsh
<# Deterministic unit tests for the hard merge gate (fleet-orchestrate.ps1).
   No model calls — sets up throwaway git repos and exercises accept/reject paths. #>

. (Join-Path $PSScriptRoot 'fleet-orchestrate.ps1')

$script:fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fail++ }
}

function New-TempRepo {
    $root = Join-Path $env:TEMP ("cao-gate-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Push-Location $root
    try {
        git init -q -b master 2>&1 | Out-Null
        git config user.email test@example.com; git config user.name test
        git config commit.gpgsign false
        New-Item -ItemType Directory -Force -Path 'scripts' | Out-Null
        Set-Content scripts/app.ps1 "function App { 'v1' }" -Encoding utf8NoBOM
        Set-Content README.md "# repo" -Encoding utf8NoBOM
        git add -A 2>&1 | Out-Null
        git commit -q -m "init" 2>&1 | Out-Null
    } finally { Pop-Location }
    return $root
}

function Run-Case($name, $mutate, $allowed, $testCmd, $expectMerged, $expectReasonLike) {
    Write-Host "`n[$name]" -ForegroundColor Cyan
    $repo = New-TempRepo
    try {
        Initialize-IntegrationBranch -RepoRoot $repo -Base master | Out-Null
        $wt = New-ItemWorktree -RepoRoot $repo -ItemId 'issue-x' -Model 'codex' -Base 'integration/backlog'
        & $mutate $wt.path
        $res = Merge-ItemToIntegration -RepoRoot $repo -WorktreePath $wt.path -Branch $wt.branch `
            -Integration 'integration/backlog' -AllowedPathPatterns $allowed -MaxChangedFiles 5 `
            -TestCommand $testCmd -AutoCommit
        Assert ($res.merged -eq $expectMerged) "merged == $expectMerged (got $($res.merged); reasons: $($res.gate.reasons -join '; '))"
        if ($expectReasonLike) {
            $hit = @($res.gate.reasons | Where-Object { $_ -like $expectReasonLike }).Count -gt 0
            Assert $hit "reason matches '$expectReasonLike'"
        }
        if ($expectMerged) {
            Push-Location $repo
            try {
                $onIntegration = git show "integration/backlog:scripts/app.ps1" 2>$null
                Assert ($onIntegration -match 'v2') "change is present on integration branch"
                $masterUntouched = git show "master:scripts/app.ps1" 2>$null
                Assert ($masterUntouched -match 'v1') "master is untouched"
            } finally { Pop-Location }
        }
    } finally {
        Push-Location $repo; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
        Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
        $wtdir = Join-Path (Split-Path $repo -Parent) 'cao-worktrees'
        Remove-Item -Recurse -Force (Join-Path $wtdir 'issue-x-codex') -ErrorAction SilentlyContinue
    }
}

# 1. ACCEPT: in-scope edit + passing tests -> merged to integration, master untouched.
Run-Case 'accept: in-scope + tests pass' {
    param($p) Set-Content (Join-Path $p 'scripts/app.ps1') "function App { 'v2' }" -Encoding utf8NoBOM
} @('scripts/*') 'exit 0' $true $null

# 2. REJECT scope: edits a file outside the allowed pattern.
Run-Case 'reject: out-of-scope edit' {
    param($p) Set-Content (Join-Path $p 'scripts/app.ps1') "function App { 'v2' }" -Encoding utf8NoBOM
              Set-Content (Join-Path $p 'README.md') "# hacked" -Encoding utf8NoBOM
} @('scripts/*') 'exit 0' $false 'scope:*'

# 3. REJECT tests: in-scope edit but the test command fails.
Run-Case 'reject: failing tests' {
    param($p) Set-Content (Join-Path $p 'scripts/app.ps1') "function App { 'v2' }" -Encoding utf8NoBOM
} @('scripts/*') 'exit 1' $false 'tests:*'

# 4. REJECT budget: too many files changed.
Run-Case 'reject: over file budget' {
    param($p) Set-Content (Join-Path $p 'scripts/app.ps1') "function App { 'v2' }" -Encoding utf8NoBOM
              1..6 | ForEach-Object { Set-Content (Join-Path $p "scripts/extra$_.ps1") "x" -Encoding utf8NoBOM }
} @('scripts/*') 'exit 0' $false 'budget:*'

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL GATE TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail ASSERTION(S) FAILED" -ForegroundColor Red; exit 1 }
