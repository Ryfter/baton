#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/memory-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: signature + journal Read/Add (pure) ----
    Check 'T1 lowercases + token-set' ((Get-MemorySignature -Text 'Auth Test') -eq 'auth test')
    Check 'T2 strips unix path' (((Get-MemorySignature -Text 'error in src/app/login.ts handler') -split ' ') -notcontains 'src')
    Check 'T3 strips windows path' (((Get-MemorySignature -Text 'fault at C:\repo\x\y.ps1 line') -split ' ') -notcontains 'repo')
    Check 'T4 strips line-number ref' (((Get-MemorySignature -Text 'boom at handler:123 today') -split ' ') -notcontains '123')
    Check 'T5 strips hex/uuid hash' (((Get-MemorySignature -Text 'commit deadbeef0 broke build') -split ' ') -notcontains 'deadbeef')
    $a = Get-MemorySignature -Text 'fix the flaky auth test'
    $b = Get-MemorySignature -Text 'test auth flaky fix'
    Check 'T6 order-independent, stopwords dropped' ($a -eq $b)
    Check 'T7 empty -> empty' ((Get-MemorySignature -Text '   ') -eq '')

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "mem-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $jp = Join-Path $tmpDir 'memory-journal.jsonl'

    Check 'T8 read missing path -> empty' (@(Read-MemoryJournal -Path $jp).Count -eq 0)
    $r1 = Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock the clock' -Outcome fail -Path $jp
    Check 'T9 add returns id + signature' ($r1.id -like 'mem-*' -and $r1.signature -match 'auth')
    $rows = Read-MemoryJournal -Path $jp
    Check 'T10 row round-trips with computed fields' (@($rows).Count -eq 1 -and $rows[0].outcome -eq 'fail' -and $rows[0].promoted -eq $false)
    Add-Content -LiteralPath $jp -Value 'this is not json' -Encoding utf8
    Check 'T11 malformed line skipped' (@(Read-MemoryJournal -Path $jp).Count -eq 1)

    # ---- Task 2: matching + promotion candidates (pure) ----
    # Rows 1 & 2 share a signature (same problem text) so the fail-threshold can fire;
    # row 4 partially overlaps so ranking is observable.
    $mp = Join-Path $tmpDir 'match-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $mp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $mp)
    [void](Add-MemoryEvent -Problem 'docker build is slow' -Approach 'cache layers' -Outcome pass -Path $mp)
    [void](Add-MemoryEvent -Problem 'auth dashboard work' -Approach 'css-grid' -Outcome pass -Path $mp)
    $mrows = Read-MemoryJournal -Path $mp

    # Rows 1 & 2 share the signature; overlaps tie at 1.0 so assert membership, not position.
    $exact = Find-MemoryMatches -Query 'auth test is flaky in ci' -Rows $mrows
    Check 'T12 exact signature match found' (@($exact | Where-Object { $_.approach -eq 'mock clock' }).Count -eq 1)
    $partial = Find-MemoryMatches -Query 'auth test timeout' -MinOverlap 0.5 -Rows $mrows
    Check 'T13 token-overlap match above floor' (@($partial).Count -ge 2)
    $miss = Find-MemoryMatches -Query 'kubernetes ingress config' -Rows $mrows
    Check 'T14 below-floor miss returns none' (@($miss).Count -eq 0)
    # Query {auth,flaky}: rows 1&2 overlap 1.0, dashboard row overlap 0.5 -> ranks last.
    $ranked = Find-MemoryMatches -Query 'auth flaky' -MinOverlap 0.5 -Rows $mrows
    Check 'T15 ranked overlap desc (partial ranks last)' (@($ranked).Count -ge 3 -and $ranked[-1].approach -eq 'css-grid' -and $ranked[0].approach -ne 'css-grid')

    $cands = Get-PromotionCandidates -FailThreshold 2 -WinThreshold 2 -Rows $mrows
    $authCand = @($cands | Where-Object { $_.signature -match 'auth' -and $_.kind -eq 'avoid' }) | Select-Object -First 1
    Check 'T16 fail-threshold fires (avoid)' ($null -ne $authCand -and $authCand.fail_count -ge 2)
    [void](Add-MemoryEvent -Problem 'speed up jest suite' -Approach 'shard' -Outcome pass -Path (Join-Path $tmpDir 'win.jsonl'))
    [void](Add-MemoryEvent -Problem 'speed up jest suite' -Approach 'shard' -Outcome pass -Path (Join-Path $tmpDir 'win.jsonl'))
    $winCands = Get-PromotionCandidates -Rows (Read-MemoryJournal -Path (Join-Path $tmpDir 'win.jsonl'))
    Check 'T17 win-threshold fires (prefer)' (@($winCands | Where-Object { $_.kind -eq 'prefer' }).Count -ge 1)
    $promotedRows = @($mrows | ForEach-Object { $h=@{}; $_.PSObject.Properties | ForEach-Object { $h[$_.Name]=$_.Value }; $h['promoted']=$true; [pscustomobject]$h })
    Check 'T18 promoted rows excluded' (@(Get-PromotionCandidates -Rows $promotedRows).Count -eq 0)
    $single = @(Add-MemoryEvent -Problem 'one off thing' -Approach 'x' -Outcome fail -Path (Join-Path $tmpDir 'single.jsonl'))
    Check 'T19 below threshold -> none' (@(Get-PromotionCandidates -Rows (Read-MemoryJournal -Path (Join-Path $tmpDir 'single.jsonl'))).Count -eq 0)

    # ---- Task 3: formatting (pure) ----
    $fmtMatches = @(
        [pscustomobject]@{ approach='mock clock'; outcome='fail'; problem='auth test flaky'; refs=[pscustomobject]@{ job='j-0042' } },
        [pscustomobject]@{ approach='raise timeout'; outcome='fail'; problem='auth test flaky'; refs=[pscustomobject]@{ job='j-0051' } }
    )
    $fmtCands = @([pscustomobject]@{ signature='auth flaky test'; reason='failed 2x'; kind='avoid' })
    $report = Format-RecallReport -Query 'fix flaky auth test' -Matches $fmtMatches -Candidates $fmtCands
    Check 'T20 report leads with failed count + lists match' ($report -match '2 prior attempt' -and $report -match '2 FAILED' -and $report -match 'mock clock')
    Check 'T21 report includes promotion candidate line' ($report -match 'PROMOTION CANDIDATE' -and $report -match 'memory-promote')
    $emptyReport = Format-RecallReport -Query 'brand new task' -Matches @() -Candidates @()
    Check 'T22a empty report says no matches' ($emptyReport -match 'No prior memory')

    $promoCand = [pscustomobject]@{ signature='auth flaky test'; reason='failed 2x'; kind='avoid'
        problem='auth test is flaky'; rows=@(
            [pscustomobject]@{ approach='mock clock'; outcome='fail' },
            [pscustomobject]@{ approach='raise timeout'; outcome='fail' }) }
    $memo = Format-PromotionMemo -Candidate $promoCand
    Check 'T22b promotion memo renders AVOID + attempts' ($memo -match 'AVOID' -and $memo -match 'mock clock' -and $memo -match 'raise timeout')

    # ---- Task 4: seamed recall ----
    $rp = Join-Path $tmpDir 'recall-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $rp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $rp)
    $script:semCalls = 0
    $stubSearcher = { param($q) $script:semCalls++; @([pscustomobject]@{ source='kb'; text='prior auth note' }) }

    $rec = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Searcher $stubSearcher
    Check 'T23 offline recall: matches found, zero searcher calls' (@($rec.matches).Count -eq 2 -and $rec.semantic.Count -eq 0 -and $script:semCalls -eq 0)
    Check 'T23b touched candidate surfaced' (@($rec.candidates | Where-Object { $_.kind -eq 'avoid' }).Count -ge 1)
    $recDeep = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Deep -Searcher $stubSearcher
    Check 'T24 deep recall invokes searcher + appends semantic' ($recDeep.semantic.Count -eq 1 -and $script:semCalls -eq 1)
    $throwSearcher = { param($q) throw 'kb index down' }
    $recErr = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Deep -Searcher $throwSearcher
    Check 'T25 searcher throw degrades to empty (no throw)' (@($recErr.semantic).Count -eq 0 -and @($recErr.matches).Count -eq 2)

    # ---- Task 5: capture source + promotion (seamed -Writer) ----
    $sp = Join-Path $tmpDir 'source-journal.jsonl'
    $ids = Invoke-MemorySource -Source manual -Fields @{ problem='db migration failed'; approach='down then up'; outcome='fail'; tags=@('db') } -Path $sp
    Check 'T26 source appends a manual row + returns id' (@($ids).Count -eq 1 -and $ids[0] -like 'mem-*' -and @(Read-MemoryJournal -Path $sp).Count -eq 1)

    $pp = Join-Path $tmpDir 'promote-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $pp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $pp)
    $cand = (Get-PromotionCandidates -Rows (Read-MemoryJournal -Path $pp))[0]
    $script:writeCalls = 0
    $stubWriter = { param($memo,$c) $script:writeCalls++; "stub-target" }
    $res = Invoke-MemoryPromote -Candidate $cand -Path $pp -Writer $stubWriter
    Check 'T27 promote (watch) calls writer + stamps rows' ($res.promoted -eq $true -and $script:writeCalls -eq 1 -and @(Read-MemoryJournal -Path $pp | Where-Object { $_.promoted -eq $true }).Count -eq 2)

    $fp = Join-Path $tmpDir 'flag-journal.jsonl'
    $fr1 = Add-MemoryEvent -Problem 'cache invalidation bug' -Approach 'ttl bump' -Outcome fail -Path $fp
    $script:writeCalls2 = 0
    $stubWriter2 = { param($memo,$c) $script:writeCalls2++; "t2" }
    $resFlag = Invoke-MemoryPromote -Id $fr1.id -Path $fp -Writer $stubWriter2
    Check 'T28 promote (flag by id) calls writer + stamps' ($resFlag.promoted -eq $true -and $script:writeCalls2 -eq 1 -and @(Read-MemoryJournal -Path $fp | Where-Object { $_.promoted -eq $true }).Count -eq 1)
    $threw = $false
    try { Invoke-MemoryPromote -Id 'mem-nope-0000' -Path $fp -Writer $stubWriter2 } catch { $threw = $true }
    Check 'T28b unknown id throws' ($threw)

    $wf = Join-Path $tmpDir 'writefault-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'x problem here' -Approach 'a' -Outcome fail -Path $wf)
    [void](Add-MemoryEvent -Problem 'x problem here' -Approach 'b' -Outcome fail -Path $wf)
    $candWf = (Get-PromotionCandidates -Rows (Read-MemoryJournal -Path $wf))[0]
    $faultWriter = { param($memo,$c) throw 'grimdex unavailable' }
    $resWf = Invoke-MemoryPromote -Candidate $candWf -Path $wf -Writer $faultWriter
    Check 'T29 writer fault -> promoted false, rows not stamped' ($resWf.promoted -eq $false -and @(Read-MemoryJournal -Path $wf | Where-Object { $_.promoted -eq $true }).Count -eq 0)
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
