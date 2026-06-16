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

    # ---- Task 2: state fold + setters ----
    $U2 = Join-Path $tmp 'u2.jsonl'
    Check 'T5 unknown worker is available' ((Get-WorkerState -Worker 'nobody' -UsagePath $U2 -Now $T0).state -eq 'available')

    Set-WorkerLockout -Worker 'w-ex' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T6 lockout w/o reset_at -> exhausted' ((Get-WorkerState -Worker 'w-ex' -UsagePath $U2 -Now $T0).state -eq 'exhausted')

    Set-WorkerLockout -Worker 'w-wait' -ResetAt $T0.AddHours(5).ToString('o') -Reason 'cap' -UsagePath $U2 -Timestamp $T0.ToString('o')
    $sw = Get-WorkerState -Worker 'w-wait' -UsagePath $U2 -Now $T0
    Check 'T7 lockout w/ future reset -> waiting_for_reset + eta' ($sw.state -eq 'waiting_for_reset' -and $sw.eta_human)

    Check 'T8 lockout past reset -> available' ((Get-WorkerState -Worker 'w-wait' -UsagePath $U2 -Now $T0.AddHours(6)).state -eq 'available')

    Set-WorkerCooldown -Worker 'w-cool' -Until $T0.AddMinutes(30).ToString('o') -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T9a cooldown before until -> cooling_down' ((Get-WorkerState -Worker 'w-cool' -UsagePath $U2 -Now $T0).state -eq 'cooling_down')
    Check 'T9b cooldown after until -> available' ((Get-WorkerState -Worker 'w-cool' -UsagePath $U2 -Now $T0.AddHours(1)).state -eq 'available')

    Set-WorkerLimited -Worker 'w-lim' -Reason 'soft' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T10a limited -> limited' ((Get-WorkerState -Worker 'w-lim' -UsagePath $U2 -Now $T0).state -eq 'limited')
    Set-WorkerLimited -Worker 'w-lim2' -ResetAt $T0.AddHours(1).ToString('o') -UsagePath $U2 -Timestamp $T0.ToString('o')
    Check 'T10b limited past reset -> available' ((Get-WorkerState -Worker 'w-lim2' -UsagePath $U2 -Now $T0.AddHours(2)).state -eq 'available')

    Set-WorkerLockout -Worker 'w-clr' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Clear-Worker -Worker 'w-clr' -UsagePath $U2 -Timestamp $T0.AddMinutes(1).ToString('o')
    Check 'T11 clear supersedes earlier lockout' ((Get-WorkerState -Worker 'w-clr' -UsagePath $U2 -Now $T0.AddMinutes(2)).state -eq 'available')

    Set-WorkerLockout -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.ToString('o')
    Clear-Worker -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.AddMinutes(5).ToString('o')
    Set-WorkerLockout -Worker 'w-ord' -UsagePath $U2 -Timestamp $T0.AddMinutes(10).ToString('o')
    Check 'T12 latest-event-by-ts wins' ((Get-WorkerState -Worker 'w-ord' -UsagePath $U2 -Now $T0.AddMinutes(20)).state -eq 'exhausted')

    # ---- Task 3: conserve + aggregate ----
    $U3 = Join-Path $tmp 'u3.jsonl'
    Check 'T13a conserve defaults off' ((Get-ConserveMode -UsagePath $U3 -Now $T0) -eq $false)
    Set-ConserveMode -On $true  -UsagePath $U3 -Timestamp $T0.ToString('o')
    Set-ConserveMode -On $false -UsagePath $U3 -Timestamp $T0.AddMinutes(1).ToString('o')
    Set-ConserveMode -On $true  -UsagePath $U3 -Timestamp $T0.AddMinutes(2).ToString('o')
    Check 'T13b conserve latest-wins -> on' ((Get-ConserveMode -UsagePath $U3 -Now $T0.AddMinutes(5)) -eq $true)

    $U3b = Join-Path $tmp 'u3b.jsonl'
    Set-WorkerLockout -Worker 'aaa' -UsagePath $U3b -Timestamp $T0.ToString('o')
    Add-UsageTick -Worker 'bbb' -Count 1 -UsagePath $U3b -Timestamp $T0.ToString('o')
    $all = Get-AllWorkerStates -UsagePath $U3b -Now $T0
    $names = @($all | ForEach-Object { $_.worker }) | Sort-Object
    Check 'T14 all-states covers every journal worker (excl. conserve *)' ("$($names -join ',')" -eq 'aaa,bbb')

    # ---- Task 4: ticks + budget + forecast ----
    $U4 = Join-Path $tmp 'u4.jsonl'
    Add-UsageTick -Worker 'fc' -Count 10 -UsagePath $U4 -Timestamp $T0.ToString('o')
    $oneRow = (Read-UsageJournal -Path $U4)[0]
    Check 'T15 tick default unit is requests' ($oneRow.event -eq 'tick' -and $oneRow.unit -eq 'requests')

    Check 'T16 <2 days of ticks -> insufficient_data' ((Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddHours(1)).status -eq 'insufficient_data')

    # two days of ticks: day0=10, day1=20 -> run_rate 15
    Add-UsageTick -Worker 'fc' -Count 20 -UsagePath $U4 -Timestamp $T0.AddDays(1).ToString('o')
    $f17 = Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddDays(1).AddHours(1)
    Check 'T17 ticks, no budget -> rate_only + run_rate 15' ($f17.status -eq 'rate_only' -and [double]$f17.run_rate -eq 15)

    # budget from a stub fleet: worker fc, budget 300 -> consumed 30, remaining 270, /15 = 18 days
    $stubFleet = @"
providers:
  - name: fc
    kind: cli
    enabled: true
    cost_tier: paid
    budget: 300
"@
    $fleet4 = Join-Path $tmp 'fleet4.yaml'; Set-Content -Path $fleet4 -Value $stubFleet -Encoding utf8
    $f18 = Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $fleet4 -Now $T0.AddDays(1).AddHours(1)
    Check 'T18 budget -> ok + days_to_exhaustion 18' ($f18.status -eq 'ok' -and [double]$f18.days_to_exhaustion -eq 18)
    Check 'T26 Get-WorkerBudget reads field; absent -> null' ((Get-WorkerBudget -Worker 'fc' -FleetPath $fleet4) -eq 300 -and $null -eq (Get-WorkerBudget -Worker 'nope' -FleetPath $fleet4))

    # run_rate averages over days-with-data, not calendar days (2 days, not 7)
    Check 'T19 run_rate over days-with-data' ([double](Get-UsageForecast -Worker 'fc' -UsagePath $U4 -FleetPath $missing -Now $T0.AddDays(1).AddHours(1)).run_rate -eq 15)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
