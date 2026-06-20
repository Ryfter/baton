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
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
