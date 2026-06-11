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

# Isolate the legibility feed: the driver publishes run records best-effort via
# Publish-ItemRun, which defaults to the REAL runs root ($BATON_HOME/runs, or
# $env:ROUTING_RUNS_ROOT when set). Redirect to a temp dir for the duration so
# test runs never leak backlog-* dirs into the live feed.
$realRunsRoot   = Get-RunsRoot
$realRunsBefore = @(if (Test-Path $realRunsRoot) { Get-ChildItem $realRunsRoot -Name })
$prevRunsRoot   = $env:ROUTING_RUNS_ROOT
$tmpRunsRoot    = Join-Path $env:TEMP ("cao-bkruns-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$env:ROUTING_RUNS_ROOT = $tmpRunsRoot
try {
# (body intentionally not re-indented under the isolation try)

# --- topo unit test ---
Write-Host "[topo order]" -ForegroundColor Cyan
$order = Get-TopoOrder -Tasks @(
    @{ id = 'B'; depends_on = @('A') }, @{ id = 'A'; depends_on = @() }, @{ id = 'D'; depends_on = @('C') }, @{ id = 'C'; depends_on = @() }
)
Assert ($order.IndexOf('A') -lt $order.IndexOf('B')) "A before B"
Assert ($order.IndexOf('C') -lt $order.IndexOf('D')) "C before D"
try { Get-TopoOrder -Tasks @(@{ id='X'; depends_on=@('Y') }, @{ id='Y'; depends_on=@('X') }) | Out-Null; Assert $false "cycle should throw" }
catch { Assert $true "cycle detected and thrown" }

# ===== Slice A: effective-rank prereq inheritance =====
Write-Host "`n[effective ranks]" -ForegroundColor Cyan
$effTasks = @(
    @{ id='a'; depends_on=@();        rank=5 }
    @{ id='b'; depends_on=@('a');     rank=1 }   # b is urgent; a is its prereq
    @{ id='c'; depends_on=@();        rank=4 }
)
$eff = Get-EffectiveRanks -Tasks $effTasks
Assert ($eff['a'] -eq 1) 'prereq inherits dependent rank'
Assert ($eff['c'] -eq 4) 'own rank kept when no urgent dependent'
Assert ($eff['b'] -eq 1) 'urgent task keeps its rank'

# ===== Slice C: pure helpers =====
Write-Host "`n[cascade helpers]" -ForegroundColor Cyan
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$true; output_file='docs/x.md' }) -eq 'full')     'mode: full'
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$true })                          -eq 'advisory') 'mode: advisory'
Assert ((Get-BacklogCascadeMode -Item @{ id='x' })                                 -eq 'none')     'mode: none (no field)'
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$false; output_file='y' })        -eq 'none')     'mode: none (cascade false)'
Assert ((Get-BacklogCascadeMode -Item ([pscustomobject]@{ cascade=$true; output_file='d.md' })) -eq 'full') 'mode: full (pscustomobject)'

$adv = Get-AdvisoryPrompt -Prompt 'ORIGINAL TASK' -Draft 'DRAFT BODY'
Assert ($adv -like '*ORIGINAL TASK*' -and $adv -like '*DRAFT BODY*') 'advisory prompt embeds both'
Assert ($adv.IndexOf('ORIGINAL TASK') -lt $adv.IndexOf('DRAFT BODY')) 'original precedes draft'
Assert ($adv -like '*Verify it independently*') 'advisory prompt carries the verify framing'

$cp = Copy-BacklogItem -Item @{ id='a'; prompt='p'; rank=2 }
$cp.prompt = 'changed'
Assert ($cp.id -eq 'a' -and $cp.rank -eq 2) 'hashtable copy keeps fields'
$src = [pscustomobject]@{ id='b'; prompt='orig' }
$cp2 = Copy-BacklogItem -Item $src
$cp2.prompt = 'changed'
Assert ($src.prompt -eq 'orig' -and $cp2.id -eq 'b') 'pscustomobject copy does not mutate source'

Assert ((Get-EffectiveMaxParallel -MaxParallel 0 -Capacity @{ surge=$true;  concurrency_factor=2 }) -eq 0) 'cap: 0 stays unbounded'
Assert ((Get-EffectiveMaxParallel -MaxParallel 2 -Capacity @{ surge=$false; concurrency_factor=2 }) -eq 2) 'cap: no surge -> unchanged'
Assert ((Get-EffectiveMaxParallel -MaxParallel 2 -Capacity @{ surge=$true;  concurrency_factor=2 }) -eq 4) 'cap: surge multiplies'
Assert ((Get-EffectiveMaxParallel -MaxParallel 3 -Capacity @{ surge=$true;  concurrency_factor=1.5 }) -eq 5) 'cap: ceil(3*1.5)=5'

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

# ===== Slice A: prime-hours gate (unattended) — paid items gated by effective rank =====
# No real model/clock dependence: injected dispatcher records calls, injected paid
# provider via a fixture fleet.yaml, all-day peak prime-hours.yaml + a fixed GateNow.
Write-Host "`n[prime-hours gate]" -ForegroundColor Cyan
$groot  = Join-Path $env:TEMP ("cao-gk-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$gwtRoot= Join-Path $env:TEMP ("cao-gkwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$gout   = Join-Path $env:TEMP ("cao-gkout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $groot, $gout | Out-Null
Push-Location $groot
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Fixture fleet.yaml: one PAID provider named 'paidmodel'.
$fleetCfg = Join-Path $gout 'fleet.yaml'
Set-Content -LiteralPath $fleetCfg -Encoding utf8NoBOM -Value @"
providers:
  - name: paidmodel
    kind: cli
    cost_tier: paid
"@
# All-day peak prime-hours.yaml: a paid dispatch in this window is rank-gated.
$phCfg = Join-Path $gout 'prime-hours.yaml'
Set-Content -LiteralPath $phCfg -Encoding utf8NoBOM -Value @"
timezone: local
default_rank: 3
windows:
  - name: all-day-peak
    days: [mon, tue, wed, thu, fri]
    kind: peak
"@
$gateNow = [datetime]'2026-06-10T12:00:00'   # a Wednesday inside the all-day weekday peak

# Injected dispatcher records which item ids it was actually called for (no model calls).
$script:dispatched = @()
$gateImpl = {
    param($wtPath, $item)
    $script:dispatched += $item.id
    Set-Content (Join-Path $wtPath "scripts/$($item.id).ps1") $item.id -Encoding utf8NoBOM
}
$gateTasks = @(
    @{ id='hi';  model='paidmodel'; rank=1; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() }  # rank-1 -> ask/run -> proceeds
    @{ id='lo';  model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() }  # rank-3 -> defer -> skipped
)
$gateRes = Invoke-Backlog -RepoRoot $groot -Tasks $gateTasks -Implementers @{ paidmodel = $gateImpl } `
    -Integration 'integration/backlog' -IntegrationBase 'master' -OutputDir $gout -WorktreeRoot $gwtRoot `
    -FleetPath $fleetCfg -PrimeHoursConfig $phCfg -GateNow $gateNow
$gById = @{}; foreach ($r in $gateRes) { $gById[$r.id] = $r }

Assert ($gById['lo'].deferred -eq $true -and $gById['lo'].merged -eq $false) "rank-3 paid task deferred (not dispatched)"
Assert ($script:dispatched -notcontains 'lo') "deferred task never reached the dispatcher"
Assert ($script:dispatched -contains 'hi') "rank-1 paid task dispatched (proceeds in peak)"
Assert ($gById['hi'].merged -eq $true -and -not $gById['hi'].deferred) "rank-1 paid task ran + merged"
$loLive = Get-Content (Join-Path $gout 'lo.live.json') -Raw | ConvertFrom-Json
Assert ($loLive.state -eq 'deferred') "lo.live.json state == deferred"

Push-Location $groot; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $groot, $gwtRoot, $gout -ErrorAction SilentlyContinue

# cleanup
Push-Location $root; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $root, $wtRoot, $out -ErrorAction SilentlyContinue

# ===== legibility-feed isolation =====
Write-Host "`n[runs-root isolation]" -ForegroundColor Cyan
$tmpRuns = @(Get-ChildItem $tmpRunsRoot -Name -ErrorAction SilentlyContinue | Where-Object { $_ -like 'backlog-*' })
Assert ($tmpRuns.Count -gt 0) "driver publishes captured by temp runs root ($($tmpRuns.Count) backlog-* dirs)"
$realRunsAfter = @(if (Test-Path $realRunsRoot) { Get-ChildItem $realRunsRoot -Name })
$leaked = @($realRunsAfter | Where-Object { $realRunsBefore -notcontains $_ })
Assert ($leaked.Count -eq 0) "real runs root gained no entries ($realRunsRoot)"

} finally {
    if ($null -ne $prevRunsRoot) { $env:ROUTING_RUNS_ROOT = $prevRunsRoot }
    else { Remove-Item Env:ROUTING_RUNS_ROOT -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmpRunsRoot -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host "ALL BACKLOG DRIVER TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$script:fail ASSERTION(S) FAILED" -ForegroundColor Red; exit 1 }
