#!/usr/bin/env pwsh
<# Deterministic tests for the autonomous backlog driver (fleet-backlog.ps1).
   Uses a fake implementer (no model calls) to prove DAG ordering, the merge gate,
   dependency-blocking, no-implementer handling, and live-status emission. #>

. (Join-Path $PSScriptRoot 'fleet-backlog.ps1')

$script:fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fail++ }
}

# --- topo unit test ---
Write-Host "[topo order]" -ForegroundColor Cyan
$order = Get-TopoOrder -Tasks @(
    @{ id = 'B'; depends_on = @('A') }, @{ id = 'A'; depends_on = @() }, @{ id = 'D'; depends_on = @('C') }, @{ id = 'C'; depends_on = @() }
)
Assert ($order.IndexOf('A') -lt $order.IndexOf('B')) "A before B"
Assert ($order.IndexOf('C') -lt $order.IndexOf('D')) "C before D"
try { Get-TopoOrder -Tasks @(@{ id='X'; depends_on=@('Y') }, @{ id='Y'; depends_on=@('X') }) | Out-Null; Assert $false "cycle should throw" }
catch { Assert $true "cycle detected and thrown" }

# --- end-to-end driver test on a throwaway repo ---
Write-Host "`n[backlog driver e2e]" -ForegroundColor Cyan
$root = Join-Path $env:TEMP ("cao-bk-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$wtRoot = Join-Path $env:TEMP ("cao-bkwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$out = Join-Path $env:TEMP ("cao-bkout-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $root, $out | Out-Null
Push-Location $root
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Fake implementer keyed by item id; writes INTO the worktree path it is handed.
$fake = {
    param($wtPath, $item)
    switch ($item.id) {
        'A' { Set-Content (Join-Path $wtPath 'scripts/a.ps1') "A" -Encoding utf8NoBOM }
        # B only produces output if A's change is visible — proves dep ordering (B's
        # worktree was branched off integration AFTER A merged).
        'B' { if (Test-Path (Join-Path $wtPath 'scripts/a.ps1')) { Set-Content (Join-Path $wtPath 'scripts/b.ps1') "B" -Encoding utf8NoBOM } }
        'C' { Set-Content (Join-Path $wtPath 'README.md') "out of scope" -Encoding utf8NoBOM }  # violates scripts/* scope
        default { }
    }
}

$tasks = @(
    @{ id='A'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='B'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('A') },
    @{ id='C'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='D'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('C') },
    @{ id='E'; model='textonly'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() }
)

$results = Invoke-Backlog -RepoRoot $root -Tasks $tasks -Implementers @{ fake = $fake } `
    -Integration 'integration/backlog' -IntegrationBase 'master' -OutputDir $out -WorktreeRoot $wtRoot
$byId = @{}; foreach ($r in $results) { $byId[$r.id] = $r }

Assert ($byId['A'].merged -eq $true)  "A merged"
Assert ($byId['B'].merged -eq $true)  "B merged (saw A's change -> dependency ordering correct)"
Assert ($byId['C'].merged -eq $false -and (@($byId['C'].reasons) -join ' ') -like '*scope*') "C blocked on scope"
Assert ($byId['D'].merged -eq $false -and (@($byId['D'].reasons) -join ' ') -like '*dep-blocked*') "D dep-blocked by C"
Assert ($byId['E'].merged -eq $false -and (@($byId['E'].reasons) -join ' ') -like '*no-implementer*') "E blocked: no implementer for text-only model"

Push-Location $root
try {
    Assert ((git show "integration/backlog:scripts/a.ps1" 2>$null) -match 'A') "a.ps1 on integration"
    Assert ((git show "integration/backlog:scripts/b.ps1" 2>$null) -match 'B') "b.ps1 on integration"
    $masterFiles = git ls-tree --name-only -r master
    Assert (-not ($masterFiles -match 'a\.ps1')) "master untouched (no a.ps1)"
} finally { Pop-Location }

# live status emission
Assert (Test-Path (Join-Path $out '_ensemble.json')) "_ensemble.json written"
$bLive = Get-Content (Join-Path $out 'B.live.json') -Raw | ConvertFrom-Json
Assert ($bLive.state -eq 'done') "B.live.json state == done"
$dLive = Get-Content (Join-Path $out 'D.live.json') -Raw | ConvertFrom-Json
Assert ($dLive.state -eq 'blocked') "D.live.json state == blocked"

# cleanup
Push-Location $root; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $root, $wtRoot, $out -ErrorAction SilentlyContinue

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL BACKLOG DRIVER TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail ASSERTION(S) FAILED" -ForegroundColor Red; exit 1 }
