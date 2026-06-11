#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/prime-hours.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("primehours-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $cfgYaml = @"
timezone: local
default_rank: 3
windows:
  - name: weekday-peak
    days: [Mon, Tue, Wed, Thu, Fri]
    start: "08:00"
    end: "18:00"
    kind: peak
  - name: weekend
    days: [Sat, Sun]
    kind: surge
    concurrency_factor: 2
"@
    $cfg = Join-Path $tmp 'prime-hours.yaml'
    Set-Content -Path $cfg -Value $cfgYaml -Encoding utf8

    # A Wednesday 10:00 (inside weekday-peak) and a Wednesday 20:00 (off-peak).
    $peakNow = [datetime]'2026-06-10T10:00:00'   # Wed
    $offNow  = [datetime]'2026-06-10T20:00:00'   # Wed
    $satNow  = [datetime]'2026-06-13T10:00:00'   # Sat

    # local/free always allow, even in a peak window.
    Check 'local allow in peak'  ((Test-PrimeHoursGate -Rank 5 -CostTier 'local' -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')
    Check 'free allow in peak'   ((Test-PrimeHoursGate -Rank 5 -CostTier 'free'  -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')

    # paid off-peak -> allow.
    Check 'paid allow off-peak'  ((Test-PrimeHoursGate -Rank 5 -CostTier 'paid' -Now $offNow -ConfigPath $cfg).decision -eq 'allow')
    # paid on a surge day (not a peak window) -> allow.
    Check 'paid allow on surge day' ((Test-PrimeHoursGate -Rank 5 -CostTier 'paid' -Now $satNow -ConfigPath $cfg).decision -eq 'allow')

    # paid in peak: rank policy.
    $r1 = Test-PrimeHoursGate -Rank 1 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg
    Check 'rank1 ask/run'  ($r1.decision -eq 'ask'   -and $r1.default -eq 'run')
    $r2 = Test-PrimeHoursGate -Rank 2 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg
    Check 'rank2 ask/defer'($r2.decision -eq 'ask'   -and $r2.default -eq 'defer')
    foreach ($rk in 3,4,5) {
        Check "rank$rk defer" ((Test-PrimeHoursGate -Rank $rk -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')
    }
    Check 'peak sets window name' ($r1.window -eq 'weekday-peak')

    # default_rank applies to unranked (no -Rank) -> rank 3 -> defer in peak.
    Check 'unranked uses default_rank' ((Test-PrimeHoursGate -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')

    # reserved ranks 0 and 6 resolve WITHOUT error (undocumented; table rows present).
    Check 'rank0 reserved allow' ((Test-PrimeHoursGate -Rank 0 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')
    Check 'rank6 reserved defer' ((Test-PrimeHoursGate -Rank 6 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')

    # window boundaries: 08:00 inclusive start, 18:00 exclusive end.
    Check 'boundary start inclusive' ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now ([datetime]'2026-06-10T08:00:00') -ConfigPath $cfg).decision -eq 'defer')
    Check 'boundary end exclusive'   ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now ([datetime]'2026-06-10T18:00:00') -ConfigPath $cfg).decision -eq 'allow')

    # fail-open: missing config -> allow + (warning suppressed).
    $missing = Join-Path $tmp 'nope.yaml'
    Check 'fail-open missing config' ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now $peakNow -ConfigPath $missing 3>$null).decision -eq 'allow')

    # ===== Get-CapacityProfile: surge vs baseline =====
    $sat = [datetime]'2026-06-13T10:00:00'   # Sat -> weekend surge
    $wed = [datetime]'2026-06-10T10:00:00'   # Wed peak -> baseline (peak is not surge)
    $cap = Get-CapacityProfile -Now $sat -ConfigPath $cfg
    Check 'surge on weekend'        ($cap.surge -eq $true -and $cap.concurrency_factor -eq 2.0 -and $cap.window -eq 'weekend')
    $base = Get-CapacityProfile -Now $wed -ConfigPath $cfg
    Check 'baseline on weekday'     ($base.surge -eq $false -and $base.concurrency_factor -eq 1.0 -and $null -eq $base.window)
    Check 'capacity fail-open'      ((Get-CapacityProfile -Now $sat -ConfigPath (Join-Path $tmp 'nope.yaml') 3>$null).concurrency_factor -eq 1.0)

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail check(s) FAILED"; exit 1 }
    Write-Host "All prime-hours gate checks passed."; exit 0
}
finally { Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue }
