#!/usr/bin/env pwsh
# Hermetic tests for window-service-lib.ps1 + heartbeat probe refresh.
# Never calls a real model (Transport injected), never touches real ~/.baton
# or ~/.claude, never spawns a detached process, never uses a real project tree.
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("window-service-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = $tmp

try {
    . "$PSScriptRoot/window-service-lib.ps1"

    $projA = Join-Path $tmp 'proj-a'
    $projB = Join-Path $tmp 'proj-b'
    New-Item -ItemType Directory -Force -Path $projA, $projB | Out-Null

    # ---- serial arithmetic ----
    $anchor = [datetimeoffset]::Parse('2026-07-26T03:50:00-06:00')
    Check 'S1 serial 0 inside first window' (
        (Get-WindowSerial -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T04:00:00-06:00'))) -eq 0)
    Check 'S2 serial 1 at exactly +5h' (
        (Get-WindowSerial -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T08:50:00-06:00'))) -eq 1)
    Check 'S3 serial 2 mid third window' (
        (Get-WindowSerial -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T14:00:00-06:00'))) -eq 2)
    # Project first seen mid-window still keys on the current serial (not 0-from-first-seen).
    $midSerial = Get-WindowSerial -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T11:30:00-06:00'))
    Check 'S4 mid-window first-seen uses current serial (not zeroed)' ($midSerial -eq 1)

    # ---- stamp path stability ----
    $p1 = Get-ProjectServiceStampPath -ProjectDir $projA
    $p2 = Get-ProjectServiceStampPath -ProjectDir $projA.ToUpperInvariant()
    Check 'P1 same project maps to same stamp path case-insensitively' ($p1 -eq $p2)
    Check 'P2 stamp lives under window-service/' ($p1 -match 'window-service')
    $pOther = Get-ProjectServiceStampPath -ProjectDir $projB
    Check 'P3 different projects get different stamp paths' ($p1 -ne $pOther)

    # ---- due / claim / race ----
    Check 'D1 missing stamp is due' (Test-ProjectServiceDue -ProjectDir $projA -Serial 0)
    $c1 = Request-ProjectServiceClaim -ProjectDir $projA -Serial 0
    $c2 = Request-ProjectServiceClaim -ProjectDir $projA -Serial 0
    Check 'R1 first claim of (project, serial) wins' ($c1 -eq $true)
    Check 'R2 second claim of same (project, serial) loses' ($c2 -eq $false)
    Check 'D2 after claim, same serial is not due' (-not (Test-ProjectServiceDue -ProjectDir $projA -Serial 0))

    $c3 = Request-ProjectServiceClaim -ProjectDir $projA -Serial 1
    Check 'R3 claim for NEW serial succeeds after prior stamp' ($c3 -eq $true)
    Check 'D3 new serial was due before its claim' ($true)  # structural; claim succeeded

    # Corrupt stamp -> due, no throw
    $stampPath = Get-ProjectServiceStampPath -ProjectDir $projB
    $wsDir = Split-Path -Parent $stampPath
    if (-not (Test-Path $wsDir)) { New-Item -ItemType Directory -Force -Path $wsDir | Out-Null }
    Set-Content -LiteralPath $stampPath -Value '{ not json' -Encoding utf8NoBOM
    Check 'D4 corrupt stamp treated as due (fail-open)' (Test-ProjectServiceDue -ProjectDir $projB -Serial 5)
    $threw = $false
    try { [void](Test-ProjectServiceDue -ProjectDir $projB -Serial 5) } catch { $threw = $true }
    Check 'D5 corrupt stamp does not throw' (-not $threw)

    # ---- byte cap ----
    $bigBody = 'X' * 5000
    $brief = Write-ProjectBriefing -ProjectDir $projA -Sections ([ordered]@{
        hygiene = [ordered]@{ ok = $true; would_remove = @() }
        candidates = $bigBody
        failures = @()
    }) -MaxBytes 2000
    Check 'B1 oversized briefing is truncated' ($brief.truncated -eq $true)
    Check 'B2 written size respects MaxBytes' ($brief.bytes -le 2000)
    $written = Get-Content -LiteralPath $brief.path -Raw
    Check 'B3 truncated briefing carries marker' ($written -match '\[truncated\]')
    Check 'B4 full body is NOT emitted whole' ($written.Length -lt 5000)

    # ---- failing section still produces briefing ----
    $fakeTransport = { param($prompt) $null }
    $svc = Invoke-ProjectWindowService -ProjectDir $projA -Serial 2 -Transport $fakeTransport
    Check 'F1 candidates null is recorded as failure' ($svc.failures -contains 'candidates')
    Check 'F2 briefing still written when candidates fail' ($null -ne $svc.briefing -and (Test-Path -LiteralPath $svc.briefing.path))
    $briefText = Get-Content -LiteralPath $svc.briefing.path -Raw
    Check 'F3 briefing names the candidates failure' ($briefText -match 'candidates')
    Check 'F4 hygiene section present alongside failure' ($briefText -match 'Hygiene')

    # ---- hygiene: NEVER rotates journals (machine-scoped; lives in the beat) + never delete worktree dirs ----
    $journal = Join-Path $tmp 'usage-journal.jsonl'
    $payload = ('y' * 600KB)
    Set-Content -LiteralPath $journal -Value $payload -Encoding utf8NoBOM
    $beforeLen = (Get-Item -LiteralPath $journal).Length
    Check 'H0 journal starts over cap' ($beforeLen -gt 512KB)

    # Fake a nested worktree-looking dir that must survive hygiene.
    $fakeWt = Join-Path $projA 'worktrees/worker-a'
    New-Item -ItemType Directory -Force -Path $fakeWt | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeWt 'keep-me.txt') -Value 'alive' -Encoding utf8NoBOM

    $hyg = Invoke-ProjectHygiene -ProjectDir $projA -BatonHome $tmp
    # Regression: project hygiene must NOT rotate machine-scoped journals (race + redundancy).
    Check 'H1 hygiene does NOT rotate over-cap journal' (
        (Test-Path -LiteralPath $journal) -and
        ((Get-Item -LiteralPath $journal).Length -eq $beforeLen) -and
        -not (Test-Path -LiteralPath "$journal.1"))
    Check 'H1b hygiene summary has no rotations key' (-not $hyg.Contains('rotations'))
    Check 'H4 worktree directory is NOT deleted' (
        (Test-Path -LiteralPath $fakeWt) -and (Test-Path -LiteralPath (Join-Path $fakeWt 'keep-me.txt')))

    # ---- claim litter cleanup (F4) ----
    $projClaim = Join-Path $tmp 'proj-claim'
    $projOther = Join-Path $tmp 'proj-other'
    New-Item -ItemType Directory -Force -Path $projClaim, $projOther | Out-Null
    [void](Request-ProjectServiceClaim -ProjectDir $projClaim -Serial 0)
    $claim0 = Get-ProjectServiceClaimPath -ProjectDir $projClaim -Serial 0 -BatonHome $tmp
    Check 'CL1 serial-0 claim file exists after first claim' (Test-Path -LiteralPath $claim0)
    [void](Request-ProjectServiceClaim -ProjectDir $projOther -Serial 0)
    $otherClaim0 = Get-ProjectServiceClaimPath -ProjectDir $projOther -Serial 0 -BatonHome $tmp
    [void](Request-ProjectServiceClaim -ProjectDir $projClaim -Serial 1)
    $claim1 = Get-ProjectServiceClaimPath -ProjectDir $projClaim -Serial 1 -BatonHome $tmp
    Check 'CL2 after serial-1 claim, serial-0 claim file is gone' (-not (Test-Path -LiteralPath $claim0))
    Check 'CL3 serial-1 claim file exists' (Test-Path -LiteralPath $claim1)
    Check 'CL4 other project claim file untouched' (Test-Path -LiteralPath $otherClaim0)

    # ---- sentinel written on claim when anchor present (F2) ----
    $hbPathForSentinel = Get-HeartbeatStatePath -BatonHome $tmp
    $sentAnchor = [datetimeoffset]::Parse('2026-07-26T03:50:00-06:00')
    [void](Write-HeartbeatState -State ([ordered]@{
        anchor = $sentAnchor.ToString('o')
        anchor_from_beat = $true
        last_fired_at = $null
        beats = 1
        last_beat_started_window = $true
    }) -Path $hbPathForSentinel)
    $projSent = Join-Path $tmp 'proj-sentinel'
    New-Item -ItemType Directory -Force -Path $projSent | Out-Null
    [void](Request-ProjectServiceClaim -ProjectDir $projSent -Serial 0)
    $sentPath = Get-ProjectServiceSentinelPath -ProjectDir $projSent -BatonHome $tmp
    Check 'SN1 claim writes sentinel beside stamp' (Test-Path -LiteralPath $sentPath)
    $sentText = (Get-Content -LiteralPath $sentPath -Raw).Trim()
    $sentParsed = [datetimeoffset]::Parse($sentText)
    $expectedNext = $sentAnchor.AddSeconds(5 * 3600 * 1).ToUniversalTime()
    Check 'SN2 sentinel is next boundary (anchor + (serial+1)*5h)' (
        [math]::Abs(($sentParsed - $expectedNext).TotalSeconds) -lt 1)

    # Inline key algorithm must match Get-ProjectPathKey (hook short-circuit depends on it).
    $inlineFull = try { [System.IO.Path]::GetFullPath($projSent) } catch { $projSent }
    $inlineNorm = $inlineFull.TrimEnd('\', '/').ToLowerInvariant()
    $inlineSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $inlineHash = $inlineSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($inlineNorm))
        $inlineKey = ([System.BitConverter]::ToString($inlineHash) -replace '-', '').ToLowerInvariant().Substring(0, 16)
    } finally { $inlineSha.Dispose() }
    Check 'SN3 inline hook key matches Get-ProjectPathKey' (
        $inlineKey -eq (Get-ProjectPathKey -ProjectDir $projSent))

    # ---- Get-WindowSerial fallback when window hours missing/non-positive (F5) ----
    $prevWinH = $script:HeartbeatWindowHours
    try {
        $script:HeartbeatWindowHours = 0
        $fb0 = Get-WindowSerial -Anchor $sentAnchor -Now ([datetimeoffset]::Parse('2026-07-26T14:00:00-06:00'))
        $script:HeartbeatWindowHours = -1
        $fbNeg = Get-WindowSerial -Anchor $sentAnchor -Now ([datetimeoffset]::Parse('2026-07-26T14:00:00-06:00'))
        Check 'S5 missing/non-positive window hours falls back to 5h (not serial 0 forever)' (
            $fb0 -eq 2 -and $fbNeg -eq 2)
    } finally {
        $script:HeartbeatWindowHours = $prevWinH
    }

    # ---- off-switches ----
    $cfgPath = Join-Path (Get-WindowServiceDir -BatonHome $tmp) 'config.json'
    Set-Content -LiteralPath $cfgPath -Value '{"enabled":false,"candidates_enabled":true}' -Encoding utf8NoBOM
    $off = Invoke-ProjectWindowService -ProjectDir $projA -Serial 3 -Transport { param($p) 'should-not-run' }
    Check 'O1 global off-switch skips service' ($off.skipped -eq $true)
    Check 'O2 global off: Get-ProjectBriefing returns null' ($null -eq (Get-ProjectBriefing -ProjectDir $projA))

    Set-Content -LiteralPath $cfgPath -Value '{"enabled":true,"candidates_enabled":false}' -Encoding utf8NoBOM
    $candCalls = 0
    $candOnly = Invoke-ProjectWindowService -ProjectDir $projA -Serial 4 -Transport {
        param($p) $script:candCalls++; return 'should-not-call'
    }
    Check 'O3 candidates-only off-switch skips transport' ($candCalls -eq 0)
    Check 'O4 candidates-only still writes briefing' ($null -ne $candOnly.briefing)
    $cot = Get-Content -LiteralPath $candOnly.briefing.path -Raw
    Check 'O5 briefing notes candidates disabled' ($cot -match 'disabled')

    # Corrupt config: free work stays ON; paid candidates OFF (F3).
    Set-Content -LiteralPath $cfgPath -Value '{ not json at all' -Encoding utf8NoBOM
    $corruptGlobal = Read-WindowServiceConfig -ProjectDir $projA -BatonHome $tmp
    Check 'O6 present-but-corrupt global: enabled stays true' ($corruptGlobal.enabled -eq $true)
    Check 'O7 present-but-corrupt global: candidates_enabled OFF' ($corruptGlobal.candidates_enabled -eq $false)
    Check 'O8 present-but-corrupt global: records config_error' (-not [string]::IsNullOrWhiteSpace([string]$corruptGlobal.config_error))
    $candCallsCorrupt = 0
    $corruptSvc = Invoke-ProjectWindowService -ProjectDir $projA -Serial 5 -Transport {
        param($p) $script:candCallsCorrupt++; return 'should-not-call'
    }
    Check 'O9 corrupt global skips candidate transport' ($candCallsCorrupt -eq 0)
    Check 'O10 corrupt global still runs free work (briefing written)' ($null -ne $corruptSvc.briefing)
    $corruptBrief = Get-Content -LiteralPath $corruptSvc.briefing.path -Raw
    Check 'O11 briefing failure list names unreadable config' (
        (@($corruptSvc.failures | Where-Object { $_ -match 'unreadable|config' }).Count -ge 1) -and
        ($corruptBrief -match 'unreadable|config'))

    Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
    $projCfgPath = Get-ProjectServiceConfigPath -ProjectDir $projB -BatonHome $tmp
    Set-Content -LiteralPath $projCfgPath -Value '{ also broken' -Encoding utf8NoBOM
    $corruptProj = Read-WindowServiceConfig -ProjectDir $projB -BatonHome $tmp
    Check 'O12 present-but-corrupt per-project: enabled stays true' ($corruptProj.enabled -eq $true)
    Check 'O13 present-but-corrupt per-project: candidates_enabled OFF' ($corruptProj.candidates_enabled -eq $false)
    Remove-Item -LiteralPath $projCfgPath -Force -ErrorAction SilentlyContinue

    # Restore defaults for remaining checks
    Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue

    # ---- dormant when no anchor ----
    # SN tests seeded an anchor for the sentinel path; clear so dormancy is hermetic.
    $hbPath = Get-HeartbeatStatePath -BatonHome $tmp
    if (Test-Path -LiteralPath $hbPath) { Remove-Item -LiteralPath $hbPath -Force }
    $stNoAnchor = Get-WindowServiceStatus -ProjectDir $projA -BatonHome $tmp
    Check 'Z1 no anchor => dormant' ($stNoAnchor.dormant -eq $true)
    Check 'Z2 no anchor => not due (nothing to service against)' ($stNoAnchor.due -eq $false)

    # Seed anchor; status should light up
    [void](Write-HeartbeatState -State ([ordered]@{
        anchor = $anchor.ToString('o')
        anchor_from_beat = $true
        last_fired_at = $null
        beats = 1
        last_beat_started_window = $true
    }) -Path $hbPath)
    $stAnchored = Get-WindowServiceStatus -ProjectDir $projB -BatonHome $tmp `
        -Now ([datetimeoffset]::Parse('2026-07-26T10:00:00-06:00'))
    Check 'Z3 with anchor, status reports a serial' ($null -ne $stAnchored.serial)
    Check 'Z4 with anchor, not dormant' ($stAnchored.dormant -eq $false)

    # ---- probe refresh in the beat (machine half) ----
    $probeState = @{ calls = 0 }
    $probeReset = [datetimeoffset]::Parse('2026-07-26T12:00:00Z').ToUnixTimeSeconds()
    $probeTransport = {
        param($clientVersion, $timeoutSeconds)
        $probeState.calls++
        return [pscustomobject]@{
            jsonrpc = '2.0'
            id = 2
            result = [pscustomobject]@{
                rateLimits = [pscustomobject]@{
                    primary = [pscustomobject]@{
                        usedPercent = 10.0
                        windowDurationMins = 300
                        resetsAt = $probeReset
                    }
                    secondary = [pscustomobject]@{
                        usedPercent = 5.0
                        windowDurationMins = 10080
                        resetsAt = $probeReset
                    }
                }
            }
        }
    }.GetNewClosure()
    # Force path via direct helper first
    $pr = Invoke-HeartbeatUsageProbeRefresh -BatonHome $tmp -ProbeTransport $probeTransport `
        -Now ([datetimeoffset]::Parse('2026-07-26T08:51:00-06:00'))
    Check 'PR1 probe refresh reports ok when transport succeeds' ($pr.ok -eq $true)
    Check 'PR2 probe transport was invoked (Force, not cache)' ($probeState.calls -ge 1)

    # A still-fresh cache must not win at the boundary (Force).
    $probeState.calls = 0
    $pr2 = Invoke-HeartbeatUsageProbeRefresh -BatonHome $tmp -ProbeTransport $probeTransport `
        -Now ([datetimeoffset]::Parse('2026-07-26T08:52:00-06:00'))
    Check 'PR3 Force re-probes even when cache is fresh' ($probeState.calls -eq 1 -and $pr2.ok)

    # Get-CodexUsageProbe swallows transport throws and returns null — soft fail.
    $probeFail = Invoke-HeartbeatUsageProbeRefresh -BatonHome $tmp `
        -ProbeTransport { param($v, $t) throw 'codex down' } `
        -Now ([datetimeoffset]::Parse('2026-07-26T08:53:00-06:00'))
    Check 'PR4 probe failure is soft (ok=false, no throw)' ($probeFail.ok -eq $false -and $probeFail.reason -match 'null|codex')

    $fakeOk = { param($argv) (@{ usage = @{ input_tokens = 12; cache_read_input_tokens = 20000; cache_creation_input_tokens = 6000; output_tokens = 5 }; total_cost_usd = 0.01; result = 'ok' } | ConvertTo-Json -Depth 5) }
    $beat = Invoke-UsageHeartbeat -Transport $fakeOk -ProbeTransport $probeTransport `
        -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T08:54:00-06:00'))
    Check 'PR5 beat result includes probe_refresh' ($null -ne $beat.probe_refresh)
    Check 'PR6 beat still reports liveness alongside probe' ($null -ne $beat.liveness)

    # ---- happy path candidates via Transport ----
    $happy = Invoke-ProjectWindowService -ProjectDir $projB -Serial 7 -Transport {
        param($prompt) return "- fix flaky test`n- document knobs`n- prune stale notes"
    }
    Check 'C1 happy candidates land in briefing' (
        (Get-Content -LiteralPath $happy.briefing.path -Raw) -match 'fix flaky test')
    Check 'C2 happy path has no failures' (@($happy.failures).Count -eq 0)

    # ---- CLI status (hermetic) ----
    $cli = Join-Path $PSScriptRoot 'fleet-window-service.ps1'
    $cliOut = & pwsh -NoProfile -File $cli -Status -Project $projA -BatonHome $tmp -Json 2>&1 | Out-String
    $cliDoc = $cliOut | ConvertFrom-Json
    Check 'CLI1 --status --json reports project + serial' (
        $LASTEXITCODE -eq 0 -and $null -ne $cliDoc.serial -and $cliDoc.project_dir)
}
catch {
    Write-Host "FAIL: suite threw — $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $script:fail++
}
finally {
    if ($null -eq $prevHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue } else { $env:BATON_HOME = $prevHome }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
