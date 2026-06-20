#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/worker-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: rate-limit parser + api-hit (pure) ----
    Check 'T1 clean output -> available' ((Get-RateLimitState -Output 'here is your answer' -ExitCode 0).state -eq 'available')
    Check 'T2 empty output -> available' ((Get-RateLimitState -Output '' -ExitCode 0).state -eq 'available')
    Check 'T3 429 -> limited' ((Get-RateLimitState -Output 'HTTP 429 Too Many Requests' -ExitCode 1).state -eq 'limited')
    Check 'T4 generic rate limit -> limited' ((Get-RateLimitState -Output 'You have hit the rate limit for this model').state -eq 'limited')
    Check 'T5 quota -> limited' ((Get-RateLimitState -Output 'monthly quota exceeded').state -eq 'limited')
    $cool = Get-RateLimitState -Output 'rate limit reached, try again in 60 seconds'
    Check 'T6 retry-in-seconds -> cooling_down +Ns' ($cool.state -eq 'cooling_down' -and $cool.until -eq '+60s')
    $coolm = Get-RateLimitState -Output 'too many requests; retry after 5 minutes'
    Check 'T7 retry-in-minutes -> cooling_down +Nm' ($coolm.state -eq 'cooling_down' -and $coolm.until -eq '+5m')
    $reset = Get-RateLimitState -Output 'rate limit; resets at 2026-06-20T05:00:00Z'
    Check 'T8 absolute reset -> waiting_for_reset + iso' ($reset.state -eq 'waiting_for_reset' -and $reset.until -eq '2026-06-20T05:00:00Z')
    Check 'T9 non-limit error -> available (fail-open)' ((Get-RateLimitState -Output 'connection refused' -ExitCode 1).state -eq 'available')
    Check 'T9b bare 429 in a normal answer -> available' ((Get-RateLimitState -Output 'the function returned 429 widgets in total' -ExitCode 0).state -eq 'available')
    Check 'T10 reason set on a limit' ((Get-RateLimitState -Output 'rate limit hit').reason -eq 'rate limit')
    Check 'T11 api-hit true on success' (Test-WorkerApiHit -ExitCode 0 -LimitState @{ state='available' })
    Check 'T12 api-hit true on 429' (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='limited' })
    Check 'T13 api-hit false on local error' (-not (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='available' }))

    # ---- Task 2: adapter registry + report (pure) ----
    $ghProv = @{ name='github-models'; adapter='github-models'; kind='cli' }
    $plainProv = @{ name='plain-cli'; kind='cli' }
    Check 'T14 adapter present -> name' ((Test-WorkerAdapter -Provider $ghProv) -eq 'github-models')
    Check 'T15 no adapter -> null' ($null -eq (Test-WorkerAdapter -Provider $plainProv))
    Check 'T16 null provider -> null' ($null -eq (Test-WorkerAdapter -Provider $null))
    $parser = Get-AdapterParser -Adapter 'github-models'
    Check 'T17 known adapter -> scriptblock' ($parser -is [scriptblock])
    Check 'T18 parser maps a 429' ((& $parser 'HTTP 429 rate limit' 1).state -eq 'limited')
    Check 'T19 unknown adapter -> null' ($null -eq (Get-AdapterParser -Adapter 'serf'))
    $rep = Format-WorkerReport -Result @{ name='github-models'; model='gpt-4o-mini'; metered=$true; tick=1; state='limited'; until=$null; exit=0 }
    Check 'T20 report shows worker + metered + state' ($rep -match 'github-models' -and $rep -match 'metered' -and $rep -match 'limited')

    # ---- Task 3: seamed Invoke-Worker + Get-WorkerStatus ----
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "worker-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $fleetFx = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -LiteralPath $fleetFx -Encoding utf8 -Value @'
providers:
  - name: github-models
    kind: cli
    enabled: true
    cost_tier: free
    adapter: github-models
    command_template: 'gh models run {{model}} "{{prompt}}"'
    budget: 100
  - name: plain-cli
    kind: cli
    enabled: true
    command_template: 'echo {{prompt}}'
'@

    $okDisp = { param($n,$p,$m) @{ stdout='all good'; stderr=''; exit_code=0; duration_s=1 } }
    $up1 = Join-Path $tmpDir 'u1.jsonl'
    $r = Invoke-Worker -Name 'github-models' -Prompt 'hi' -Model 'gpt-4o-mini' -UsagePath $up1 -FleetPath $fleetFx -Dispatcher $okDisp
    Check 'T21 success -> metered + tick, state available' ($r.metered -and $r.tick -eq 1 -and $r.state -eq 'available')
    Check 'T22 success writes exactly one tick' (@(Read-UsageJournal -Path $up1 | Where-Object { $_.event -eq 'tick' }).Count -eq 1)

    $limDisp = { param($n,$p,$m) @{ stdout='HTTP 429 rate limit, try again in 60 seconds'; stderr=''; exit_code=1; duration_s=1 } }
    $up2 = Join-Path $tmpDir 'u2.jsonl'
    $r2 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up2 -FleetPath $fleetFx -Dispatcher $limDisp
    Check 'T23 429 -> metered + cooling_down + iso until' ($r2.metered -and $r2.state -eq 'cooling_down' -and $r2.until -match '^\d{4}-')
    Check 'T24 429 writes tick + cooldown -> folded state cooling_down' ((Get-WorkerState -Worker 'github-models' -UsagePath $up2).state -eq 'cooling_down')

    $resetDisp = { param($n,$p,$m) @{ stdout='rate limit; resets at 2026-12-31T00:00:00Z'; stderr=''; exit_code=1; duration_s=1 } }
    $up2b = Join-Path $tmpDir 'u2b.jsonl'
    [void](Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up2b -FleetPath $fleetFx -Dispatcher $resetDisp)
    Check 'T25 absolute reset -> folded waiting_for_reset' ((Get-WorkerState -Worker 'github-models' -UsagePath $up2b).state -eq 'waiting_for_reset')

    $errDisp = { param($n,$p,$m) @{ stdout=''; stderr='connection refused'; exit_code=1; duration_s=1 } }
    $up3 = Join-Path $tmpDir 'u3.jsonl'
    $r3 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up3 -FleetPath $fleetFx -Dispatcher $errDisp
    Check 'T26 local error -> not metered, no tick' (-not $r3.metered -and @(Read-UsageJournal -Path $up3).Count -eq 0)

    $up4 = Join-Path $tmpDir 'u4.jsonl'
    $r4 = Invoke-Worker -Name 'github-models' -Prompt 'hi' -UsagePath $up4 -FleetPath $fleetFx -Dispatcher $okDisp -Dry
    Check 'T27 dry-run -> no journal writes' (@(Read-UsageJournal -Path $up4).Count -eq 0 -and $r4.metered)

    $up5 = Join-Path $tmpDir 'u5.jsonl'
    $r5 = Invoke-Worker -Name 'plain-cli' -Prompt 'hi' -UsagePath $up5 -FleetPath $fleetFx -Dispatcher $okDisp
    Check 'T28 unmetered provider -> pass-through, no writes' (-not $r5.metered -and @(Read-UsageJournal -Path $up5).Count -eq 0 -and $r5.output -eq 'all good')

    $up6 = Join-Path $tmpDir 'u6.jsonl'
    Add-UsageTick -Worker 'github-models' -Count 25 -UsagePath $up6
    $st = Get-WorkerStatus -Worker 'github-models' -UsagePath $up6 -FleetPath $fleetFx
    Check 'T29 status computes utilization from budget' ($st.budget -eq 100 -and $st.consumed -eq 25 -and $st.utilization_pct -eq 25.0 -and $st.remaining -eq 75)
    $st2 = Get-WorkerStatus -Worker 'plain-cli' -UsagePath $up6 -FleetPath $fleetFx
    Check 'T30 status no budget -> utilization null' ($null -eq $st2.utilization_pct)

    # ---- Task 4: CLI (child process; zero network/model) ----
    $cli = Join-Path $PSScriptRoot 'fleet-worker.ps1'
    $cliHome = Join-Path $tmpDir 'clihome'
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    Copy-Item -LiteralPath $fleetFx -Destination (Join-Path $cliHome 'fleet.yaml')
    $env:BATON_HOME = $cliHome

    $runJson = & pwsh -NoProfile -File $cli run github-models --prompt 'hi' --model gpt-4o-mini --dry --json 2>&1 | Out-String
    Check 'T31 CLI run --dry --json emits result shape' ($runJson -match '"metered"' -and $runJson -match 'github-models')
    Check 'T32 CLI run --dry wrote no journal' (-not (Test-Path (Join-Path $cliHome 'usage-journal.jsonl')))

    $statusJson = & pwsh -NoProfile -File $cli status --json 2>&1 | Out-String
    Check 'T33 CLI status --json lists adapter workers' ($statusJson -match 'github-models' -and $statusJson -match 'utilization_pct')
    $statusTxt = & pwsh -NoProfile -File $cli status 2>&1 | Out-String
    Check 'T34 CLI status text has header + worker' ($statusTxt -match 'WORKER' -and $statusTxt -match 'github-models')

    Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
