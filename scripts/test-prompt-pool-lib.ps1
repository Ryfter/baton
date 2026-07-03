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

# ---- Slice B: Set-CandidateRetired (the single retirement door) ----
function Set-TestLive($cand, $runs, $accept, $polish, $reject, $cost, $rework) {
    $cand.live.runs = $runs; $cand.live.accept = $accept; $cand.live.polish = $polish
    $cand.live.reject = $reject; $cand.live.realized_cost_usd = $cost; $cand.live.rework_cost_usd = $rework
    return $cand
}

$sbPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p002' 'candidate' 0.7 90)) }
$retOk = Set-CandidateRetired -Pool $sbPool -Id 'p002' -Reason 'test loss' -By 'p001'
$ret = @($sbPool.candidates | Where-Object { $_.id -eq 'p002' })[0]
Check 'P30 Set-CandidateRetired stamps status/reason/at/by' ($retOk -and ($ret.status -eq 'retired') -and ($ret.retired_reason -eq 'test loss') -and ($ret.retired_at -match 'Z$') -and ($ret.retired_by -eq 'p001'))
$sbPool2 = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100), (New-TestCand 'p002' 'candidate' 0.7 90)) }
[void](Set-CandidateRetired -Pool $sbPool2 -Id 'p002' -Reason 'mechanical')
Check 'P31 -By omitted -> retired_by null' ($null -eq @($sbPool2.candidates | Where-Object { $_.id -eq 'p002' })[0].retired_by)
Check 'P32 unknown id -> false' (-not (Set-CandidateRetired -Pool $sbPool2 -Id 'p999' -Reason 'x'))
Check 'P33 new records carry retired_at/retired_by null' ((($null -eq (New-TestCand 'p009' 'candidate' 0.5 10).retired_at)) -and ($null -eq (New-TestCand 'p010' 'candidate' 0.5 10).retired_by))

# ---- Slice B: Get-ShadowEnabled ----
Check 'P34 shadow key absent -> enabled' (Get-ShadowEnabled -Pool @{ schema = 1; champion = 'p001'; candidates = @() })
Check 'P35 shadow=false -> disabled' (-not (Get-ShadowEnabled -Pool @{ schema = 1; shadow = $false; champion = 'p001'; candidates = @() }))

# ---- Slice B: Resolve-ShadowVariant truth table ----
$svAbsent = Resolve-ShadowVariant -PoolDir (Join-Path (New-TempDir) 'nope')
Check 'P36 absent pool -> shadow=false reason=absent' ((-not $svAbsent.shadow) -and ($svAbsent.reason -eq 'absent'))

# a real seeded pool for the rest of the table
$svDir = New-TempDir
$svSeed = Join-Path $svDir 'conductor-planner.txt'
Set-Content -LiteralPath $svSeed -Value 'LIVE {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
$svPoolDir = Join-Path $svDir 'pool'
[void](Initialize-PromptPool -SeedPromptPath $svSeed -PoolDir $svPoolDir)

$svChampOnly = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P37 champion only -> shadow=false reason=no challenger' ((-not $svChampOnly.shadow) -and ($svChampOnly.reason -eq 'no challenger'))

# add a scored challenger + its text file
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svChall = New-TestCand 'p002' 'candidate' 0.8 80
$svLoaded.candidates = @($svLoaded.candidates) + @($svChall)
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'CHALL {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir

$svTie = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P38 tie on live runs -> challenger takes the run, template carried' ($svTie.shadow -and ($svTie.role -eq 'challenger') -and ($svTie.variant_id -eq 'p002') -and (([string]$svTie.template) -match 'CHALL') -and ($svTie.challenger_id -eq 'p002'))

# champion behind on runs -> champion takes the run, no template
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$c1 = @($svLoaded.candidates | Where-Object { $_.id -eq 'p002' })[0]
[void](Set-TestLive $c1 3 1 1 1 0.5 0.2)
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$svChampTurn = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P39 champion fewer runs -> champion role, null template' ($svChampTurn.shadow -and ($svChampTurn.role -eq 'champion') -and ($svChampTurn.variant_id -eq 'p001') -and ($null -eq $svChampTurn.template))

# disabled kill switch
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLoaded.shadow = $false
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$svOff = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P40 shadow=false -> disabled' ((-not $svOff.shadow) -and ($svOff.reason -eq 'disabled'))
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLoaded.shadow = $true
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir

# unreadable / invalid challenger text fails open
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'MISSING PLACEHOLDERS' -Encoding utf8NoBOM
$svBadText = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P41 placeholder-missing challenger text -> shadow=false reason=challenger unreadable' ((-not $svBadText.shadow) -and ($svBadText.reason -eq 'challenger unreadable'))
Remove-Item -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Force
$svNoFile = Resolve-ShadowVariant -PoolDir $svPoolDir
Check 'P42 missing challenger file -> shadow=false reason=challenger unreadable' ((-not $svNoFile.shadow) -and ($svNoFile.reason -eq 'challenger unreadable'))
Set-Content -LiteralPath (Join-Path $svPoolDir 'p002.txt') -Value 'CHALL {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM

# highest-win-rate challenger wins selection; stale (null wr) excluded
$svLoaded = (Get-PromptPool -PoolDir $svPoolDir).pool
$svLow = New-TestCand 'p003' 'candidate' 0.6 70
$svStale = New-TestCand 'p004' 'candidate' $null 60
$svLoaded.candidates = @($svLoaded.candidates) + @($svLow, $svStale)
Save-PromptPool -Pool $svLoaded -PoolDir $svPoolDir
$selChall = Select-ShadowChallenger -Pool (Get-PromptPool -PoolDir $svPoolDir).pool
Check 'P43 highest-wr scored candidate selected as challenger' ($selChall.id -eq 'p002')

# ---- Slice B: Add-LiveRunResult arithmetic ----
$arPool = @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.25 -Verdict accept)
$arC = $arPool.candidates[0]
Check 'P44 accept accrual: runs/accept/realized up, rework untouched' ((([int]$arC.live.runs) -eq 1) -and (([int]$arC.live.accept) -eq 1) -and (([double]$arC.live.realized_cost_usd) -eq 0.25) -and (([double]$arC.live.rework_cost_usd) -eq 0.0))
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.5 -Verdict reject)
Check 'P45 reject accrual doubles into rework' ((([int]$arC.live.reject) -eq 1) -and (([double]$arC.live.realized_cost_usd) -eq 0.75) -and (([double]$arC.live.rework_cost_usd) -eq 0.5))
[void](Add-LiveRunResult -Pool $arPool -VariantId 'p001' -CostUsd 0.1)
Check 'P46 ungated accrual: cost + runs only, no verdict counters' ((([int]$arC.live.runs) -eq 3) -and (([int]$arC.live.accept) -eq 1) -and (([int]$arC.live.polish) -eq 0) -and (([double]$arC.live.realized_cost_usd) -eq 0.85))
Check 'P47 unknown variant -> false' (-not (Add-LiveRunResult -Pool $arPool -VariantId 'p999' -CostUsd 1.0))

# ---- Slice B: Get-CostPerAccept + Get-ShadowVerdict ----
Check 'P48 cost per accept null at zero accepts' ($null -eq (Get-CostPerAccept -Live @{ accept = 0; realized_cost_usd = 5.0 }))
Check 'P49 cost per accept = realized/accepts' ((Get-CostPerAccept -Live @{ accept = 4; realized_cost_usd = 1.0 }) -eq 0.25)

function New-VerdictPool($champLive, $challLive) {
    $ch = Set-TestLive (New-TestCand 'p001' 'champion' 0.5 100) @champLive
    $cl = Set-TestLive (New-TestCand 'p002' 'candidate' 0.8 90) @challLive
    return @{ schema = 1; champion = 'p001'; candidates = @($ch, $cl) }
}
# args to Set-TestLive after the record: runs accept polish reject cost rework
$vNoChall = Get-ShadowVerdict -Pool @{ schema = 1; champion = 'p001'; candidates = @((New-TestCand 'p001' 'champion' 0.5 100)) }
Check 'P50 no challenger -> state no-challenger' ($vNoChall.state -eq 'no-challenger')
$vIns = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(3,2,1,0,0.5,0.1))
Check 'P51 below threshold -> insufficient with counts' (($vIns.state -eq 'insufficient') -and ($vIns.challenger_gated -eq 3) -and ($vIns.champion_gated -eq 5))
$vPro = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,2.0,0.4) @(5,4,1,0,1.0,0.2))
Check 'P52 challenger cheaper per accept -> promote' (($vPro.state -eq 'promote') -and ($vPro.challenger_cpa -eq 0.25) -and ($vPro.champion_cpa -eq 0.5))
$vRet = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.2) @(5,4,1,0,2.0,0.4))
Check 'P53 challenger dearer per accept -> retire' ($vRet.state -eq 'retire')
$vAsym = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.2) @(5,0,3,2,2.0,2.0))
Check 'P54 challenger 0 accepts vs champion >0 -> retire' ($vAsym.state -eq 'retire')
$vAsym2 = Get-ShadowVerdict -Pool (New-VerdictPool @(5,0,3,2,1.0,1.0) @(5,4,1,0,1.0,0.2))
Check 'P54a champion 0 accepts vs challenger >0 -> promote' ($vAsym2.state -eq 'promote')
$vStale = Get-ShadowVerdict -Pool (New-VerdictPool @(5,0,3,2,1.0,1.0) @(5,0,4,1,1.0,1.0))
Check 'P55 both 0 accepts at threshold -> stalemate' ($vStale.state -eq 'stalemate')
$vEq = Get-ShadowVerdict -Pool (New-VerdictPool @(5,4,1,0,1.0,0.1) @(5,4,1,0,1.0,0.1))
Check 'P55a equal cost per accept -> stalemate' ($vEq.state -eq 'stalemate')

# ---- v1.7.1: promote_recommended_at field + round-trip ----
Check 'P56 new records carry promote_recommended_at null' ($null -eq (New-TestCand 'p011' 'candidate' 0.5 10).promote_recommended_at)
$prDir = New-TempDir
$prSeed = Join-Path $prDir 'seed.txt'
Set-Content -LiteralPath $prSeed -Value 'S {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
$prPool = Join-Path $prDir 'pool'
[void](Initialize-PromptPool -SeedPromptPath $prSeed -PoolDir $prPool)
$prP = (Get-PromptPool -PoolDir $prPool).pool
$prP.candidates[0].promote_recommended_at = '2026-07-03T01:02:03Z'
Save-PromptPool -Pool $prP -PoolDir $prPool
$prP2 = (Get-PromptPool -PoolDir $prPool).pool
Check 'P57 promote_recommended_at survives round-trip as Z string (DateTime trap)' (($prP2.candidates[0].promote_recommended_at -is [string]) -and ($prP2.candidates[0].promote_recommended_at -match 'Z$'))

# ---- v1.7.1: Get-ShadowVerdict -ChallengerId (assigned-challenger attribution) ----
function New-AttribPool {
    $ch = Set-TestLive (New-TestCand 'p001' 'champion' 0.5 100) 5 4 1 0 1.0 0.2
    $as = Set-TestLive (New-TestCand 'p002' 'candidate' 0.6 90) 5 1 2 2 3.0 2.5
    $nw = New-TestCand 'p003' 'candidate' 0.9 80   # newer, higher wr, 0 gated runs
    return @{ schema = 1; champion = 'p001'; candidates = @($ch, $as, $nw) }
}
$vAssign = Get-ShadowVerdict -Pool (New-AttribPool) -ChallengerId 'p002'
Check 'P58 -ChallengerId pins the verdict to the assigned candidate' (($vAssign.challenger_id -eq 'p002') -and ($vAssign.state -eq 'retire'))
$vDefault = Get-ShadowVerdict -Pool (New-AttribPool)
Check 'P59 no -ChallengerId keeps highest-wr selection' (($vDefault.challenger_id -eq 'p003') -and ($vDefault.state -eq 'insufficient'))
$goneAttrib = New-AttribPool
[void](Set-CandidateRetired -Pool $goneAttrib -Id 'p002' -Reason 'x')
$vGone = Get-ShadowVerdict -Pool $goneAttrib -ChallengerId 'p002'
Check 'P60 assigned challenger no longer active -> no-challenger (no action)' ($vGone.state -eq 'no-challenger')
$vEmptyId = Get-ShadowVerdict -Pool (New-AttribPool) -ChallengerId ''
Check 'P61 empty -ChallengerId degrades to selection path' ($vEmptyId.challenger_id -eq 'p003')

if ($script:fail -gt 0) { Write-Host "`n$script:fail check(s) FAILED"; exit 1 }
Write-Host "`nAll checks passed."
exit 0
