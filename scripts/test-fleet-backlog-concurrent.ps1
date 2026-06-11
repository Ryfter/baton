#!/usr/bin/env pwsh
<# Deterministic tests for the CONCURRENT backlog driver (Invoke-BacklogConcurrent).
   Fake model = a child pwsh that writes scripts/<worktree-leaf>.ps1 (in scope, unique
   per item). Proves wave-based dependency ordering, serial merge correctness, and the
   scope / no-implementer blocks — without any real model call. #>

. (Join-Path $PSScriptRoot 'fleet-backlog.ps1')

$script:fail = 0
function Assert($c, $m) { if ($c) { Write-Host "  PASS  $m" -ForegroundColor Green } else { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:fail++ } }

# Isolate the legibility feed: the driver publishes run records best-effort via
# Publish-ItemRun, which defaults to the REAL runs root ($BATON_HOME/runs, or
# $env:ROUTING_RUNS_ROOT when set). Redirect to a temp dir for the duration so
# test runs never leak backlog-* dirs into the live feed.
$realRunsRoot   = Get-RunsRoot
$realRunsBefore = @(if (Test-Path $realRunsRoot) { Get-ChildItem $realRunsRoot -Name })
$prevRunsRoot   = $env:ROUTING_RUNS_ROOT
$tmpRunsRoot    = Join-Path $env:TEMP ("cao-ccruns-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$env:ROUTING_RUNS_ROOT = $tmpRunsRoot
try {
# (body intentionally not re-indented under the isolation try)

Write-Host "[concurrent driver e2e]" -ForegroundColor Cyan
$root   = Join-Path $env:TEMP ("cao-cc-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$wtRoot = Join-Path $env:TEMP ("cao-ccwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$out    = Join-Path $env:TEMP ("cao-ccout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $root, $out | Out-Null
Push-Location $root
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts','docs' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Fake implementer: write scripts/<cwd-leaf>.ps1 (worktree leaf == "<id>-fake"), in scope.
$fakeScript = '$leaf = Split-Path (Get-Location) -Leaf; Set-Content (Join-Path "scripts" "$leaf.ps1") "x" -Encoding utf8NoBOM'
$specs = @{ fake = @{ exe = 'pwsh'; args = @('-NoProfile','-Command', $fakeScript) } }

$tasks = @(
    @{ id='A'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='B'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('A') },
    @{ id='C'; model='fake'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('A') },
    @{ id='D'; model='none'; allowed_paths=@('scripts/*'); depends_on=@() },                 # no implementer
    @{ id='E'; model='fake'; allowed_paths=@('docs/*');    depends_on=@() }                  # writes scripts/ -> out of scope
)

$results = Invoke-BacklogConcurrent -RepoRoot $root -Tasks $tasks -ModelSpecs $specs `
    -Integration 'master' -IntegrationBase 'master' -OutputDir $out -WorktreeRoot $wtRoot -TimeoutS 120
$byId = @{}; foreach ($r in $results) { if ($r) { $byId[$r.id] = $r } }

Assert ($byId['A'].merged -eq $true) "A merged (wave 1)"
Assert ($byId['B'].merged -eq $true) "B merged (wave 2, after A)"
Assert ($byId['C'].merged -eq $true) "C merged (wave 2, concurrent with B)"
Assert ($byId['D'].merged -eq $false -and (@($byId['D'].reasons) -join ' ') -like '*no-implementer*') "D blocked: no implementer"
Assert ($byId['E'].merged -eq $false -and (@($byId['E'].reasons) -join ' ') -like '*scope*') "E blocked: out of scope"

Push-Location $root
try {
    $tree = git ls-tree --name-only -r master
    Assert ($tree -match 'A-fake\.ps1') "A's file on master"
    Assert ($tree -match 'B-fake\.ps1') "B's file on master"
    Assert ($tree -match 'C-fake\.ps1') "C's file on master"
    Assert (-not ($tree -match 'E-fake\.ps1')) "E's out-of-scope file NOT on master"
} finally { Pop-Location }

$meta = Get-Content (Join-Path $out '_ensemble.json') -Raw | ConvertFrom-Json
Assert ($meta.kind -eq 'backlog-concurrent') "_ensemble.json kind == backlog-concurrent"

Push-Location $root; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $root, $wtRoot, $out -ErrorAction SilentlyContinue

# ===== legibility-feed isolation =====
Write-Host "`n[runs-root isolation]" -ForegroundColor Cyan
$tmpRuns = @(Get-ChildItem $tmpRunsRoot -Name -ErrorAction SilentlyContinue | Where-Object { $_ -like 'backlog-*' })
Assert ($tmpRuns.Count -gt 0) "driver publishes captured by temp runs root ($($tmpRuns.Count) backlog-* dirs)"
$realRunsAfter = @(if (Test-Path $realRunsRoot) { Get-ChildItem $realRunsRoot -Name })
$leaked = @($realRunsAfter | Where-Object { $realRunsBefore -notcontains $_ })
Assert ($leaked.Count -eq 0) "real runs root gained no entries ($realRunsRoot)"

# ===== Slice C: rank order + paid-peak gate + MaxParallel =====
Write-Host "`n[rank + gate + cap]" -ForegroundColor Cyan
$groot  = Join-Path $env:TEMP ("cao-ccg-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$gwt    = Join-Path $env:TEMP ("cao-ccgwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$gout   = Join-Path $env:TEMP ("cao-ccgout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $groot, $gout | Out-Null
Push-Location $groot
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Ledger records DISPATCH ORDER: each child appends its worktree leaf ("<id>-<model>").
$ledger = Join-Path $gout 'ledger.txt'
$env:CC_LEDGER = $ledger
$ledgerScript = '$leaf = Split-Path (Get-Location) -Leaf; Add-Content -Path $env:CC_LEDGER -Value $leaf; Set-Content (Join-Path "scripts" "$leaf.ps1") "x" -Encoding utf8NoBOM'
$gspecs = @{ paidmodel = @{ exe = 'pwsh'; args = @('-NoProfile','-Command', $ledgerScript) } }

$gfleet = Join-Path $gout 'fleet.yaml'
Set-Content -LiteralPath $gfleet -Encoding utf8NoBOM -Value @"
providers:
  - name: paidmodel
    kind: cli
    cost_tier: paid
"@
$gph = Join-Path $gout 'prime-hours.yaml'
Set-Content -LiteralPath $gph -Encoding utf8NoBOM -Value @"
timezone: local
default_rank: 3
windows:
  - name: all-day-peak
    days: [mon, tue, wed, thu, fri]
    kind: peak
"@
$gnow = [datetime]'2026-06-10T12:00:00'   # Wednesday inside the all-day weekday peak

# r3 deferred (paid+peak+rank3); prereq3 is rank-3 BUT inherits rank 1 from dep1 -> runs;
# rank ordering observable with MaxParallel 1: prereq3 (eff 1) then dep1 then r2.
$gtasks = @(
    @{ id='r2';      model='paidmodel'; rank=2; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='r3';      model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='r3dep';   model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('r3') },
    @{ id='prereq3'; model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='dep1';    model='paidmodel'; rank=1; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('prereq3') }
)
# NOTE: rank 2 unattended default = defer (parent spec rank table) -> r2 also defers.
$gres = Invoke-BacklogConcurrent -RepoRoot $groot -Tasks $gtasks -ModelSpecs $gspecs `
    -Integration 'master' -IntegrationBase 'master' -OutputDir $gout -WorktreeRoot $gwt -TimeoutS 120 `
    -MaxParallel 1 -FleetPath $gfleet -PrimeHoursConfig $gph -GateNow $gnow
$gById = @{}; foreach ($r in $gres) { if ($r) { $gById[$r.id] = $r } }

Assert ($gById['r3'].deferred -eq $true -and $gById['r3'].merged -eq $false) 'paid rank-3 deferred at peak'
Assert ($gById['r2'].deferred -eq $true) 'paid rank-2 deferred (unattended ask->defer)'
Assert ($gById['r3dep'].merged -eq $false -and (@($gById['r3dep'].reasons) -join ' ') -like '*dep-blocked*') 'deferred prereq dep-blocks dependent'
Assert ($gById['prereq3'].merged -eq $true) 'rank-3 prereq inherits rank 1 -> runs at peak'
Assert ($gById['dep1'].merged -eq $true) 'rank-1 dependent runs'
$gOrder = @(Get-Content -LiteralPath $ledger | ForEach-Object { ($_ -split '-paidmodel')[0] })
Assert ($gOrder.Count -eq 2 -and $gOrder[0] -eq 'prereq3' -and $gOrder[1] -eq 'dep1') "dispatch order ascending effective rank ($($gOrder -join ','))"
$r3Live = Get-Content (Join-Path $gout 'r3.live.json') -Raw | ConvertFrom-Json
Assert ($r3Live.state -eq 'deferred') 'r3.live.json state == deferred'

Remove-Item Env:CC_LEDGER -ErrorAction SilentlyContinue
Push-Location $groot; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $groot, $gwt, $gout -ErrorAction SilentlyContinue

} finally {
    if ($null -ne $prevRunsRoot) { $env:ROUTING_RUNS_ROOT = $prevRunsRoot }
    else { Remove-Item Env:ROUTING_RUNS_ROOT -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmpRunsRoot -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL CONCURRENT DRIVER TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail ASSERTION(S) FAILED" -ForegroundColor Red; exit 1 }
