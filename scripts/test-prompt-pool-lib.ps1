#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Tests for prompt-pool-lib.ps1 (house Check/PASS-FAIL style, exit-code gated).
.DESCRIPTION
  Hermetic: temp pool dirs only; never touches the real ~/.baton or ~/.claude.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'prompt-pool-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

function New-TempDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("pool-lib-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

# Helper: minimal active candidate for Pareto/gate tests.
function New-TestCand($id, $status, $wr, $tokens) {
    $c = New-PoolCandidateRecord -Id $id -Parent $null -Origin 'mutation' -Status $status -PromptTokens $tokens
    $c.offline.minibatch.win_rate_vs_champion = $wr
    return $c
}

# ---- Token estimate ----
Check 'P1 empty text -> 0 tokens' ((Get-PromptTokenEstimate '') -eq 0)
Check 'P2 4 chars -> 1 token' ((Get-PromptTokenEstimate 'abcd') -eq 1)
Check 'P3 5 chars -> 2 tokens (ceil)' ((Get-PromptTokenEstimate 'abcde') -eq 2)

# ---- Get-PromptPool: absent ----
$absentDir = Join-Path (New-TempDir) 'nope'
$resAbsent = Get-PromptPool -PoolDir $absentDir
Check 'P4 absent pool -> ok=false, reason=absent' ((-not $resAbsent.ok) -and ($resAbsent.reason -eq 'absent'))

# ---- Initialize-PromptPool: seed ----
$seedDir = New-TempDir
$seedPath = Join-Path $seedDir 'conductor-planner.txt'
Set-Content -LiteralPath $seedPath -Value "SEED {{schema}} {{evi}} {{Goal}}" -Encoding utf8NoBOM
$poolDir = Join-Path $seedDir 'pool'
$init = Initialize-PromptPool -SeedPromptPath $seedPath -PoolDir $poolDir
Check 'P5 seed init ok' ($init.ok)
Check 'P6 champion is p001' ($init.pool.champion -eq 'p001')
Check 'P7 seed candidate status champion, origin seed' (($init.pool.candidates[0].status -eq 'champion') -and ($init.pool.candidates[0].origin -eq 'seed'))
Check 'P8 champion win rate is 0.5 by definition' (([double]$init.pool.candidates[0].offline.minibatch.win_rate_vs_champion) -eq 0.5)
Check 'P9 p001.txt written with seed text' ((Get-Content -Raw (Join-Path $poolDir 'p001.txt')) -match 'SEED \{\{schema\}\}')
Check 'P10 live fields present at zero' (([int]$init.pool.candidates[0].live.runs) -eq 0)

# ---- Initialize-PromptPool: missing seed ----
$initMiss = Initialize-PromptPool -SeedPromptPath (Join-Path $seedDir 'missing.txt') -PoolDir (Join-Path $seedDir 'pool2')
Check 'P11 missing seed prompt -> ok=false' (-not $initMiss.ok)

# ---- Round trip ----
$rt = Get-PromptPool -PoolDir $poolDir
Check 'P12 round trip loads seeded pool' ($rt.ok -and ($rt.pool.champion -eq 'p001'))

# ---- Corrupt manifest ----
$corruptDir = New-TempDir
Set-Content -LiteralPath (Join-Path $corruptDir 'pool.json') -Value '{ not json !!!' -Encoding utf8NoBOM
$resCorrupt = Get-PromptPool -PoolDir $corruptDir
Check 'P13 corrupt manifest -> ok=false, corrupt reason' ((-not $resCorrupt.ok) -and ($resCorrupt.reason -match 'corrupt'))
Check 'P14 corrupt manifest untouched on load' ((Get-Content -Raw (Join-Path $corruptDir 'pool.json')) -match 'not json')

# ---- Get-NextCandidateId ----
Check 'P15 next id after p001 is p002' ((Get-NextCandidateId -Pool $rt.pool) -eq 'p002')
$gapPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p007' 'retired' 0.4 90)) }
Check 'P16 next id skips past highest (p007 -> p008)' ((Get-NextCandidateId -Pool $gapPool) -eq 'p008')

# ---- Get-ParetoFront ----
$a = New-TestCand 'p001' 'champion' 0.6 100
$b = New-TestCand 'p002' 'candidate' 0.5 120
$c = New-TestCand 'p003' 'candidate' 0.7 80
$front1 = Get-ParetoFront -Candidates @($a, $b, $c)
Check 'P17 dominated members excluded (only p003 survives)' ((@($front1).Count -eq 1) -and (@($front1)[0].id -eq 'p003'))
$d = New-TestCand 'p004' 'candidate' 0.7 150
$front2 = Get-ParetoFront -Candidates @($a, $d)
Check 'P18 trade-off pair both on front' (@($front2).Count -eq 2)
$r = New-TestCand 'p005' 'retired' 0.9 10
$front3 = Get-ParetoFront -Candidates @($a, $r)
Check 'P19 retired members excluded from front' ((@($front3).Count -eq 1) -and (@($front3)[0].id -eq 'p001'))
$u = New-TestCand 'p006' 'candidate' $null 10
$front4 = Get-ParetoFront -Candidates @($a, $u)
Check 'P20 unscored (null win rate) members excluded' ((@($front4).Count -eq 1) -and (@($front4)[0].id -eq 'p001'))
Check 'P21 empty input -> empty front (Count 0, not 1)' (@((Get-ParetoFront -Candidates @())).Count -eq 0)

# ---- Select-ParentCandidate ----
$selPool = @{ schema = 1; champion = 'p001'; candidates = @($a, $d) }   # both on front
$pick0 = Select-ParentCandidate -Pool $selPool -Draw { param($total) 0.0 }
Check 'P22 draw 0.0 picks first front member' ($pick0.id -eq 'p001')
$a2 = New-TestCand 'p001' 'champion' 0.6 100
$a2.offline.times_selected = 9   # weight 0.1 vs p004 weight 1.0
$selPool2 = @{ schema = 1; champion = 'p001'; candidates = @($a2, $d) }
$pickW = Select-ParentCandidate -Pool $selPool2 -Draw { param($total) 0.5 }
Check 'P23 frequency weighting shifts pick to less-selected member' ($pickW.id -eq 'p004')
$unscored = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' $null 100)) }
$pickFallback = Select-ParentCandidate -Pool $unscored -Draw { param($total) 0.0 }
Check 'P24 empty front falls back to champion' ($pickFallback.id -eq 'p001')

# ---- Test-DualGate ----
$gatePool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
$childGood = New-TestCand 'p002' 'candidate' 0.8 90
$g1 = Test-DualGate -Child $childGood -WinRateVsParent 0.8 -Pool $gatePool
Check 'P25 beats parent + non-dominated -> pass' ($g1.pass)
$childDom = New-TestCand 'p003' 'candidate' 0.4 110   # champion dominates: 0.5>0.4, 100<110
$g2 = Test-DualGate -Child $childDom -WinRateVsParent 0.6 -Pool $gatePool
Check 'P26 dominated child -> fail with Pareto reason' ((-not $g2.pass) -and ((@($g2.reasons) -join ';') -match 'dominated'))
$g3 = Test-DualGate -Child $childGood -WinRateVsParent 0.5 -Pool $gatePool
Check 'P27 exactly 0.5 vs parent -> fail (must BEAT parent)' (-not $g3.pass)
$g4 = Test-DualGate -Child $childGood -WinRateVsParent $null -Pool $gatePool
Check 'P28 null vs parent (all ties) -> fail, no-evidence reason' ((-not $g4.pass) -and ((@($g4.reasons) -join ';') -match 'no evidence'))
$childUnscored = New-TestCand 'p004' 'candidate' $null 90
$g5 = Test-DualGate -Child $childUnscored -WinRateVsParent 0.9 -Pool $gatePool
Check 'P29 null vs champion -> fail, no-evidence reason' ((-not $g5.pass) -and ((@($g5.reasons) -join ';') -match 'no evidence'))

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) FAILED"; exit 1 }
Write-Host "`nAll checks passed."
exit 0
