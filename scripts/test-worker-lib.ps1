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
    Check 'T10 reason set on a limit' ((Get-RateLimitState -Output 'rate limit hit').reason -eq 'rate limit')
    Check 'T11 api-hit true on success' (Test-WorkerApiHit -ExitCode 0 -LimitState @{ state='available' })
    Check 'T12 api-hit true on 429' (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='limited' })
    Check 'T13 api-hit false on local error' (-not (Test-WorkerApiHit -ExitCode 1 -LimitState @{ state='available' }))
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
