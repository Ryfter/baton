#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/usage-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("usg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$U = Join-Path $tmp 'usage-journal.jsonl'   # per-test journal; deleted in finally
$T0 = [datetime]::Parse('2026-06-16T00:00:00Z').ToUniversalTime()

try {
    # ---- Task 1: journal I/O + ConvertTo-UsageInstant ----
    Add-UsageEvent -Kind 'tick' -Worker 'claude-haiku' -Fields @{ count = 5; unit = 'requests' } -Path $U -Timestamp '2026-06-16T00:00:00.000Z'
    $rows = Read-UsageJournal -Path $U
    Check 'T1 append+read round-trips a row' (@($rows).Count -eq 1 -and $rows[0].event -eq 'tick' -and [int]$rows[0].count -eq 5)

    $missing = Join-Path $tmp 'does-not-exist.jsonl'
    Check 'T2 missing journal reads empty, no throw' (@(Read-UsageJournal -Path $missing).Count -eq 0)

    Add-Content -LiteralPath $U -Value 'this is not json' -Encoding utf8
    Check 'T3 malformed line skipped' (@(Read-UsageJournal -Path $U).Count -eq 1)

    $badPath = Join-Path $tmp 'nested\deep\u.jsonl'
    Add-UsageEvent -Kind 'clear' -Worker 'x' -Path $badPath -Timestamp $T0.ToString('o')
    Check 'T4 writer creates dirs, does not throw' (Test-Path $badPath)

    Check 'T20a instant parses +5h' ((ConvertTo-UsageInstant -When '+5h' -Now $T0) -eq $T0.AddHours(5).ToString('o'))
    Check 'T20b instant parses +2d' ((ConvertTo-UsageInstant -When '+2d' -Now $T0) -eq $T0.AddDays(2).ToString('o'))
    Check 'T20c instant parses +90m' ((ConvertTo-UsageInstant -When '+90m' -Now $T0) -eq $T0.AddMinutes(90).ToString('o'))
    Check 'T20d instant parses ISO-8601' ((ConvertTo-UsageInstant -When '2026-06-16T05:00:00Z' -Now $T0) -eq $T0.AddHours(5).ToString('o'))
