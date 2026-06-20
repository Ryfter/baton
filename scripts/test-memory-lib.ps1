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
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
