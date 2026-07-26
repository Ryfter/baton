#!/usr/bin/env pwsh
# Issue #144 — session marker coverage: last_seen_at, kind, throttle, hooks matcher.
# Hermetic: uses a temp $env:BATON_HOME; never touches real ~/.baton or ~/.claude.

$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$here = $PSScriptRoot
. "$here/session-markers-lib.ps1"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("smk-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$oldHome = $env:BATON_HOME
$env:BATON_HOME = $tmp

try {
    # --- kind is recorded ---
    Write-SessionMarker -Agent 'claude' -SessionId 'sess-kind' -Cwd 'D:\dev\A' -Kind 'resume' -BatonHome $tmp
    $act = @(Get-ActiveSessions -BatonHome $tmp)
    $kRec = $act | Where-Object { $_.session_id -eq 'sess-kind' } | Select-Object -First 1
    Check 'kind is recorded on marker' ($null -ne $kRec -and [string]$kRec.kind -eq 'resume')
    Check 'last_seen_at present on new marker' ($null -ne $kRec.last_seen_at)

    # --- re-stamp preserves started_at, advances last_seen_at ---
    $sdir = Get-SessionsDir -BatonHome $tmp
    $fixedStart = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
    $oldSeen = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('o')
    $hand = [ordered]@{
        agent        = 'claude'
        session_id   = 'sess-restamp'
        cwd          = 'D:\dev\B'
        started_at   = $fixedStart
        last_seen_at = $oldSeen
        kind         = 'startup'
    }
    $hand | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'sess-restamp.json') -Encoding utf8NoBOM
    Start-Sleep -Milliseconds 50
    Write-SessionMarker -Agent 'claude' -SessionId 'sess-restamp' -Cwd 'D:\dev\B' -Kind 'resume' -BatonHome $tmp
    $re = Get-Content -Raw -LiteralPath (Join-Path $sdir 'sess-restamp.json') | ConvertFrom-Json
    $reStart = ([datetime]$re.started_at).ToUniversalTime().ToString('o')
    $reSeen = ([datetime]$re.last_seen_at).ToUniversalTime()
    $fixedStartDt = ([datetime]$fixedStart).ToUniversalTime().ToString('o')
    $oldSeenDt = ([datetime]$oldSeen).ToUniversalTime()
    Check 're-stamp preserves started_at' ($reStart -eq $fixedStartDt)
    Check 're-stamp advances last_seen_at' ($reSeen -gt $oldSeenDt)
    Check 're-stamp records new kind' ([string]$re.kind -eq 'resume')

    # --- Get-ActiveSessions ages out on last_seen_at ---
    $staleSeen = [ordered]@{
        agent        = 'claude'
        session_id   = 'sess-stale-seen'
        cwd          = 'D:\dev\C'
        started_at   = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')  # recent start
        last_seen_at = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o') # stale last-seen
        kind         = 'startup'
    }
    $staleSeen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'sess-stale-seen.json') -Encoding utf8NoBOM
    $afterStale = @(Get-ActiveSessions -TtlHours 24 -BatonHome $tmp)
    $staleHit = $afterStale | Where-Object { $_.session_id -eq 'sess-stale-seen' }
    Check 'ages out on last_seen_at (stale last_seen, recent started_at)' ($null -eq $staleHit)

    $freshSeen = [ordered]@{
        agent        = 'claude'
        session_id   = 'sess-fresh-seen'
        cwd          = 'D:\dev\D'
        started_at   = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o') # old start
        last_seen_at = (Get-Date).ToUniversalTime().ToString('o')              # fresh last-seen
        kind         = 'refresh'
    }
    $freshSeen | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'sess-fresh-seen.json') -Encoding utf8NoBOM
    $afterFresh = @(Get-ActiveSessions -TtlHours 24 -BatonHome $tmp)
    $freshHit = $afterFresh | Where-Object { $_.session_id -eq 'sess-fresh-seen' }
    Check 'keeps alive when last_seen_at is fresh (even if started_at old)' ($null -ne $freshHit)

    # --- legacy marker with only started_at still works ---
    $legacy = @{
        agent      = 'claude'
        session_id = 'sess-legacy'
        cwd        = 'D:\dev\Legacy'
        started_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $legacy | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'sess-legacy.json') -Encoding utf8NoBOM
    $legacyAct = @(Get-ActiveSessions -BatonHome $tmp)
    $legacyHit = $legacyAct | Where-Object { $_.session_id -eq 'sess-legacy' }
    Check 'legacy marker (started_at only) still active' ($null -ne $legacyHit)

    $legacyStale = @{
        agent      = 'claude'
        session_id = 'sess-legacy-old'
        cwd        = 'D:\dev\Old'
        started_at = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
    }
    $legacyStale | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'sess-legacy-old.json') -Encoding utf8NoBOM
    $legacyStaleHit = @(Get-ActiveSessions -TtlHours 24 -BatonHome $tmp) | Where-Object { $_.session_id -eq 'sess-legacy-old' }
    Check 'legacy marker ages out on started_at when last_seen_at absent' ($null -eq $legacyStaleHit)

    # --- corrupt marker JSON is skipped without throwing ---
    Set-Content -LiteralPath (Join-Path $sdir 'sess-corrupt.json') -Value '{not valid json!!!' -Encoding utf8NoBOM
    $threw = $false
    try {
        $null = @(Get-ActiveSessions -BatonHome $tmp)
    } catch {
        $threw = $true
    }
    Check 'corrupt marker JSON skipped without throwing' (-not $threw)

    # --- throttle: no rewrite within window; does rewrite after ---
    Write-SessionMarker -Agent 'claude' -SessionId 'sess-throttle' -Cwd 'D:\dev\T' -Kind 'startup' -BatonHome $tmp
    $beforePath = Join-Path $sdir 'sess-throttle.json'
    $before = Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json
    $beforeSeen = ([datetime]$before.last_seen_at).ToUniversalTime().ToString('o')
    Start-Sleep -Milliseconds 30
    $wroteWithin = Update-SessionMarkerLastSeen -SessionId 'sess-throttle' -BatonHome $tmp -MinIntervalMinutes 5 -Kind 'refresh'
    $mid = Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json
    $midSeen = ([datetime]$mid.last_seen_at).ToUniversalTime().ToString('o')
    Check 'throttle skips rewrite within window' (($wroteWithin -eq $false) -and ($midSeen -eq $beforeSeen))

    # Force outside the window by backdating last_seen_at on disk
    $aged = [ordered]@{
        agent        = 'claude'
        session_id   = 'sess-throttle'
        cwd          = 'D:\dev\T'
        started_at   = ([datetime]$before.started_at).ToUniversalTime().ToString('o')
        last_seen_at = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
        kind         = 'startup'
    }
    $aged | ConvertTo-Json | Set-Content -LiteralPath $beforePath -Encoding utf8NoBOM
    $wroteAfter = Update-SessionMarkerLastSeen -SessionId 'sess-throttle' -BatonHome $tmp -MinIntervalMinutes 5 -Kind 'refresh'
    $after = Get-Content -Raw -LiteralPath $beforePath | ConvertFrom-Json
    $afterSeen = ([datetime]$after.last_seen_at).ToUniversalTime()
    $agedSeen = ([datetime]$aged.last_seen_at).ToUniversalTime()
    Check 'throttle rewrites after window' (($wroteAfter -eq $true) -and ($afterSeen -gt $agedSeen))
    Check 'throttle refresh preserves started_at' (
        ([datetime]$after.started_at).ToUniversalTime().ToString('o') -eq
        ([datetime]$before.started_at).ToUniversalTime().ToString('o')
    )
    Check 'throttle refresh records kind=refresh' ([string]$after.kind -eq 'refresh')

    # --- hooks.json registers session-start for resume/compact (the actual regression) ---
    $hooksPath = Join-Path (Split-Path $here -Parent) 'hooks/hooks.json'
    if (-not (Test-Path $hooksPath)) {
        # plugin layout: scripts/ is under repo root; hooks/ is sibling of scripts/
        $hooksPath = Join-Path $here '../hooks/hooks.json'
    }
    $hooksRaw = Get-Content -Raw -LiteralPath $hooksPath
    $hooksObj = $hooksRaw | ConvertFrom-Json
    $ss = @($hooksObj.hooks.SessionStart)
    $markerMatchers = @()
    foreach ($entry in $ss) {
        $cmds = @($entry.hooks | ForEach-Object { $_.command })
        if ($cmds -match 'baton-session-start') {
            $markerMatchers += [string]$entry.matcher
        }
    }
    $joined = ($markerMatchers -join ' ')
    Check 'hooks.json session-start matcher covers resume' ($joined -match 'resume')
    Check 'hooks.json session-start matcher covers compact' ($joined -match 'compact')
    Check 'hooks.json session-start matcher covers clear' ($joined -match 'clear')
    Check 'hooks.json session-start matcher covers startup' ($joined -match 'startup')

    # init/coach stay on startup-only (do not broaden their matcher)
    $initMatchers = @()
    $coachMatchers = @()
    foreach ($entry in $ss) {
        $cmds = @($entry.hooks | ForEach-Object { $_.command })
        if ($cmds -match 'baton-init') { $initMatchers += [string]$entry.matcher }
        if ($cmds -match 'baton-coach') { $coachMatchers += [string]$entry.matcher }
    }
    Check 'hooks.json baton-init stays on startup-only matcher' (
        ($initMatchers.Count -ge 1) -and ($initMatchers | ForEach-Object { $_ -eq 'startup' } | Where-Object { $_ } | Measure-Object).Count -eq $initMatchers.Count
    )
    Check 'hooks.json baton-coach stays on startup-only matcher' (
        ($coachMatchers.Count -ge 1) -and ($coachMatchers | ForEach-Object { $_ -eq 'startup' } | Where-Object { $_ } | Measure-Object).Count -eq $coachMatchers.Count
    )
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $oldHome }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) {
    Write-Host "$script:fail CHECK(S) FAILED"
    exit 1
}
Write-Host 'ALL CHECKS PASS'
