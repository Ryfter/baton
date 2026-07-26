#!/usr/bin/env pwsh
# Hermetic tests for heartbeat-lib.ps1 + fleet-heartbeat.ps1.
# Never calls a model (anchor transport is injected), never touches the real
# ~/.baton or ~/.claude, never registers a scheduled task.
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("heartbeat-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = $tmp

try {
    . "$PSScriptRoot/heartbeat-lib.ps1"

    # ---- anchor parsing ----
    $now = [datetimeoffset]::Parse('2026-07-26T16:00:00-06:00')
    $a1 = Resolve-HeartbeatAnchor -Anchor '3:50' -Now $now
    Check 'A1 bare clock time resolves to TODAY when already past' (
        $a1.Hour -eq 3 -and $a1.Minute -eq 50 -and $a1.Day -eq 26)
    # A bare time still ahead must stay on TODAY. Rolling back a day would shift the
    # grid phase by 4h (24 mod 5) and put every later boundary on the wrong schedule.
    $a2 = Resolve-HeartbeatAnchor -Anchor '23:50' -Now $now
    Check 'A2 bare clock time still ahead stays on today (no 24h rollback / no 4h phase shift)' (
        $a2.Hour -eq 23 -and $a2.Day -eq 26)
    $a2b = Resolve-HeartbeatAnchor -Anchor '3:50' -Now ([datetimeoffset]::Parse('2026-07-26T03:49:00-06:00'))
    $a2bNext = Get-NextHeartbeatBoundary -Anchor $a2b -Now ([datetimeoffset]::Parse('2026-07-26T03:49:00-06:00')) -EpsilonSeconds 60
    Check 'A2c seeding one minute BEFORE the reset schedules that same reset, not +4h' (
        $a2bNext.boundary_at -eq [datetimeoffset]::Parse('2026-07-26T03:51:00-06:00'))
    Check 'A3 full timestamp passes through' (
        (Resolve-HeartbeatAnchor -Anchor '2026-07-20T08:15:00-06:00' -Now $now).Day -eq 20)
    Check 'A4 junk -> null (never guess a boundary)' ($null -eq (Resolve-HeartbeatAnchor -Anchor 'lunchtime' -Now $now))
    Check 'A5 empty -> null' ($null -eq (Resolve-HeartbeatAnchor -Anchor '   ' -Now $now))

    # ---- boundary arithmetic (fixed anchor + N*5h, never last-fire + 5h) ----
    $anchor = [datetimeoffset]::Parse('2026-07-26T03:50:00-06:00')
    $b1 = Get-NextHeartbeatBoundary -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T04:00:00-06:00')) -EpsilonSeconds 60
    Check 'B1 next boundary after a fresh beat is anchor+5h+60s' (
        $b1.boundary_at -eq [datetimeoffset]::Parse('2026-07-26T08:51:00-06:00'))
    $b2 = Get-NextHeartbeatBoundary -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-26T03:50:30-06:00')) -EpsilonSeconds 60
    Check 'B2 inside the epsilon gap the SAME boundary is still next' (
        $b2.boundary_at -eq [datetimeoffset]::Parse('2026-07-26T03:51:00-06:00'))
    # A skipped beat must not shift the cadence: boundaries stay on the anchor grid.
    $b3 = Get-NextHeartbeatBoundary -Anchor $anchor -Now ([datetimeoffset]::Parse('2026-07-27T02:00:00-06:00')) -EpsilonSeconds 60
    $deltaHours = ($b3.boundary_at - $anchor).TotalHours
    Check 'B3 after a long gap the boundary is still on the 5h grid (no creep)' (
        [math]::Abs(($deltaHours - 60.0/60.0) % 5) -lt 0.001 -or
        [math]::Abs((($b3.boundary_at.AddSeconds(-60) - $anchor).TotalHours) % 5) -lt 0.001)
    Check 'B4 boundary is strictly in the future' ($b3.boundary_at -gt [datetimeoffset]::Parse('2026-07-27T02:00:00-06:00'))
    Check 'B5 seconds_until is never negative' ($b3.seconds_until -ge 0)

    # ---- the anchor argv: correctness here is the whole point of the feature ----
    $argv = Get-AnchorHeartbeatArgv -Model 'haiku'
    Check 'C1 uses --print (non-interactive)' ($argv -contains '-p')
    Check 'C2 pins the cheap model' (($argv -join ' ') -match 'haiku')
    Check 'C3 replaces the system prompt rather than appending' ($argv -contains '--system-prompt')
    Check 'C4 no MCP servers load' ($argv -contains '--strict-mcp-config')
    Check 'C5 leaves no session behind' ($argv -contains '--no-session-persistence')
    Check 'C6 NEVER --bare (that flag forces API-key auth and would anchor no subscription window)' (
        -not ($argv -contains '--bare'))
    Check 'C7 does not ask for the time (model has no clock; burns output refusing)' (
        ($argv -join ' ') -notmatch '(?i)time')

    # ---- state round-trip ----
    $sp = Get-HeartbeatStatePath -BatonHome $tmp
    $empty = Read-HeartbeatState -Path $sp
    Check 'S1 missing state file -> empty state, no throw' ($null -eq $empty.anchor -and $empty.beats -eq 0)
    Set-Content -LiteralPath $sp -Value '{ not json' -Encoding utf8NoBOM
    Check 'S2 corrupt state file fails soft (a bad file must not wedge the schedule)' (
        (Read-HeartbeatState -Path $sp).beats -eq 0)
    [void](Write-HeartbeatState -State ([ordered]@{ anchor = $anchor.ToString('o'); last_fired_at = $null; beats = 3 }) -Path $sp)
    Check 'S3 state round-trips' ((Read-HeartbeatState -Path $sp).beats -eq 3)

    # ---- expired-lockout clearing (free half) ----
    $usage = Join-Path $tmp 'usage-journal.jsonl'
    @(
        (@{ ts = '2026-07-26T01:00:00.0000000Z'; event = 'lockout'; worker = 'worker-expired'; reason = 'cap'; reset_at = '2026-07-26T02:00:00.0000000Z' } | ConvertTo-Json -Compress)
        (@{ ts = '2026-07-26T01:00:00.0000000Z'; event = 'lockout'; worker = 'worker-still-out'; reason = 'cap'; reset_at = '2030-01-01T00:00:00.0000000Z' } | ConvertTo-Json -Compress)
        (@{ ts = '2026-07-26T01:00:00.0000000Z'; event = 'clear'; worker = 'worker-already-clear' } | ConvertTo-Json -Compress)
    ) -join "`n" | Set-Content -LiteralPath $usage -Encoding utf8NoBOM
    $cleared = @(Clear-ExpiredWorkerLockouts -UsagePath $usage -Now ([datetime]::Parse('2026-07-26T10:00:00Z')).ToUniversalTime())
    Check 'L1 expired lockout is explicitly cleared' ($cleared -contains 'worker-expired')
    Check 'L2 a live lockout is left alone' (-not ($cleared -contains 'worker-still-out'))
    Check 'L3 an already-clear worker is not re-cleared (no journal churn)' (-not ($cleared -contains 'worker-already-clear'))
    $rows = @(Get-Content -LiteralPath $usage | ForEach-Object { $_ | ConvertFrom-Json })
    Check 'L4 the clear row actually landed in the journal' (
        @($rows | Where-Object { $_.event -eq 'clear' -and $_.worker -eq 'worker-expired' }).Count -eq 1)
    Check 'L5 missing journal fails soft' (
        @(Clear-ExpiredWorkerLockouts -UsagePath (Join-Path $tmp 'no-such.jsonl')).Count -eq 0)

    # ---- liveness (free half) ----
    $live = Write-HeartbeatLiveness -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T16:00:00-06:00'))
    Check 'H1 liveness stamp written with a session count' (
        (Test-Path (Join-Path $tmp 'sessions/heartbeat.json')) -and $null -ne $live.live_sessions)

    # ---- full beat with an injected transport (no model call) ----
    $fakeOk = { param($argv) (@{ usage = @{ input_tokens = 12; cache_read_input_tokens = 20000; cache_creation_input_tokens = 6000; output_tokens = 5 }; total_cost_usd = 0.01; result = 'ok' } | ConvertTo-Json -Depth 5) }
    $beat = Invoke-UsageHeartbeat -Transport $fakeOk -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T08:51:00-06:00'))
    Check 'F1 anchor reports summed input tokens' ($beat.anchor.ok -and $beat.anchor.input_tokens -eq 26012)
    Check 'F2 beat schedules a next boundary' ($null -ne $beat.next -and $beat.next.boundary_at -gt [datetimeoffset]::Parse('2026-07-26T08:51:00-06:00'))
    Check 'F3 a beat AT a boundary re-anchors state to the fire time' (
        ([datetimeoffset](Read-HeartbeatState -Path $sp).anchor).Hour -eq 8)
    Check 'F4 beat counter advanced' ((Read-HeartbeatState -Path $sp).beats -eq 4)

    # A manual MID-window beat spends quota but does not restart the window, so it must
    # NOT move the anchor — doing so would corrupt every later boundary.
    $midAnchorBefore = (Read-HeartbeatState -Path $sp).anchor
    $midBeat = Invoke-UsageHeartbeat -Transport $fakeOk -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T11:30:00-06:00'))
    Check 'F3b mid-window beat does NOT re-anchor' ((Read-HeartbeatState -Path $sp).anchor -eq $midAnchorBefore)
    Check 'F3c mid-window beat says it did not open a window' (
        (Read-HeartbeatState -Path $sp).last_beat_started_window -eq $false)
    # No epsilon creep: the anchor came from a beat (already a window START), so the next
    # boundary is exactly +5h, NOT +5h+60s. A minute per beat would drift an hour a month.
    Check 'F3d mid-window beat reports the boundary at anchor+5h exactly (no epsilon creep)' (
        $midBeat.next.boundary_at -eq [datetimeoffset]::Parse('2026-07-26T13:51:00-06:00'))
    Check 'F3e beat-set anchors take epsilon 0; operator-set anchors keep it' (
        (Get-HeartbeatEpsilon -State ([ordered]@{ anchor_from_beat = $true }) -Requested 60) -eq 0 -and
        (Get-HeartbeatEpsilon -State ([ordered]@{ anchor_from_beat = $false }) -Requested 60) -eq 60)

    # A failed anchor must NOT stop the free housekeeping, and must NOT move the anchor.
    $anchorBefore = (Read-HeartbeatState -Path $sp).anchor
    $fakeFail = { param($argv) throw 'not logged in' }
    $beatFail = Invoke-UsageHeartbeat -Transport $fakeFail -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T09:00:00-06:00'))
    Check 'F5 failed anchor is reported, not swallowed' (-not $beatFail.anchor.ok -and $beatFail.anchor.reason -match 'not logged in')
    Check 'F6 free housekeeping still ran on anchor failure' ($null -ne $beatFail.liveness)
    Check 'F7 failed anchor leaves the anchor untouched (no phantom window start)' (
        (Read-HeartbeatState -Path $sp).anchor -eq $anchorBefore)

    $beatSkip = Invoke-UsageHeartbeat -SkipAnchor -BatonHome $tmp -Now ([datetimeoffset]::Parse('2026-07-26T09:10:00-06:00'))
    Check 'F8 -SkipAnchor spends nothing and says so' (
        $beatSkip.anchor.reason -eq 'skipped' -and $beatSkip.anchor.input_tokens -eq 0)

    # ---- phantom-anchor guards (Grok review high): a beat that never opened a window
    # must not seed one, or every later boundary sits on a schedule nothing ran on ----
    $freshFail = Join-Path $tmp 'fresh-fail'
    New-Item -ItemType Directory -Force -Path $freshFail | Out-Null
    $fpath = Get-HeartbeatStatePath -BatonHome $freshFail
    $failBeat = Invoke-UsageHeartbeat -Transport { param($argv) throw 'not logged in' } -BatonHome $freshFail -Now ([datetimeoffset]::Parse('2026-07-26T09:00:00-06:00'))
    Check 'P1 FAILED first beat with no prior anchor plants NO anchor' (
        [string]::IsNullOrWhiteSpace([string](Read-HeartbeatState -Path $fpath).anchor))
    Check 'P2 failed first beat reports no schedulable boundary' ($null -eq $failBeat.next)
    $freshSkip = Join-Path $tmp 'fresh-skip'
    New-Item -ItemType Directory -Force -Path $freshSkip | Out-Null
    [void](Invoke-UsageHeartbeat -SkipAnchor -BatonHome $freshSkip -Now ([datetimeoffset]::Parse('2026-07-26T09:00:00-06:00')))
    Check 'P3 --skip-anchor with no prior anchor plants NO anchor either' (
        [string]::IsNullOrWhiteSpace([string](Read-HeartbeatState -Path (Get-HeartbeatStatePath -BatonHome $freshSkip)).anchor))
    $freshOk = Join-Path $tmp 'fresh-ok'
    New-Item -ItemType Directory -Force -Path $freshOk | Out-Null
    [void](Invoke-UsageHeartbeat -Transport $fakeOk -BatonHome $freshOk -Now ([datetimeoffset]::Parse('2026-07-26T09:00:00-06:00')))
    Check 'P4 a SUCCESSFUL first beat does anchor' (
        -not [string]::IsNullOrWhiteSpace([string](Read-HeartbeatState -Path (Get-HeartbeatStatePath -BatonHome $freshOk)).anchor))
    Check 'P5 failed beat does not claim it started a window' (
        (Read-HeartbeatState -Path $fpath).last_beat_started_window -eq $false)

    # ---- sleep-through: the machine was asleep at the boundary and the task ran late.
    # That late request IS the window's first, so it MUST re-anchor or the schedule
    # desyncs from reality permanently (Grok review medium) ----
    $slept = Test-HeartbeatOpensWindow -PriorAnchor ([datetimeoffset]::Parse('2026-07-26T03:51:00-06:00')) `
        -LastFiredAt ([datetimeoffset]::Parse('2026-07-26T03:51:00-06:00')) -Now ([datetimeoffset]::Parse('2026-07-26T09:05:00-06:00'))
    Check 'W1 a beat 74 min past the boundary still counts as opening the window' ($slept -eq $true)
    $midw = Test-HeartbeatOpensWindow -PriorAnchor ([datetimeoffset]::Parse('2026-07-26T08:51:00-06:00')) `
        -LastFiredAt ([datetimeoffset]::Parse('2026-07-26T08:51:00-06:00')) -Now ([datetimeoffset]::Parse('2026-07-26T11:30:00-06:00'))
    Check 'W2 a manual mid-window beat does NOT count as opening one' ($midw -eq $false)
    $second = Test-HeartbeatOpensWindow -PriorAnchor ([datetimeoffset]::Parse('2026-07-26T03:51:00-06:00')) `
        -LastFiredAt ([datetimeoffset]::Parse('2026-07-26T09:05:00-06:00')) -Now ([datetimeoffset]::Parse('2026-07-26T09:10:00-06:00'))
    Check 'W3 a SECOND beat in the same window does not re-open it' ($second -eq $false)
    Check 'W4 no prior anchor -> the first beat opens a window' (
        (Test-HeartbeatOpensWindow -PriorAnchor $null -LastFiredAt $null -Now $now) -eq $true)

    # ---- spend honesty: unknown must never be reported as zero (Grok review medium) ----
    $unk = Invoke-AnchorHeartbeat -Transport { param($argv) 'not json at all' }
    Check 'U1 unparseable response reports spend UNKNOWN, not zero' (
        (-not $unk.ok) -and ($null -eq $unk.input_tokens) -and ($unk.spend_known -eq $false))
    Check 'U2 unparseable reason says the request may still have billed' ($unk.reason -match 'may still have billed')
    Check 'U3 a successful call marks spend known' (
        (Invoke-AnchorHeartbeat -Transport $fakeOk).spend_known -eq $true)

    # ---- schedule command shape (built, never executed here) ----
    $cmd = @(Get-HeartbeatScheduleCommand -At ([datetimeoffset]::Parse('2026-07-26T08:51:00-06:00')) -TaskName 'TestHb' -ScriptPath 'C:/x/fleet-heartbeat.ps1')
    Check 'K1 registers a ONE-SHOT task (5h does not divide 24h; no daily time can express it)' (
        ($cmd -contains '/SC') -and ($cmd -contains 'ONCE'))
    Check 'K2 task re-registers itself after firing' (($cmd -join ' ') -match '-Reschedule')
    Check 'K3 names the task and forces replacement' (($cmd -contains '/F') -and ($cmd -join ' ') -match 'TestHb')
    # Culture-proof: '/' and ':' are culture-REPLACED separators in .NET custom formats,
    # so a de-DE box would otherwise emit '07.26.2026' and schtasks would misread the day.
    $sdIdx = [array]::IndexOf($cmd, '/SD')
    $stIdx = [array]::IndexOf($cmd, '/ST')
    Check 'K4 /SD is invariant MM/dd/yyyy regardless of host culture' ($cmd[$sdIdx + 1] -eq '07/26/2026')
    Check 'K5 /ST is invariant HH:mm' ($cmd[$stIdx + 1] -eq '08:51')

    # ---- CLI surface (hermetic: --status and --print-schedule only) ----
    $cli = Join-Path $PSScriptRoot 'fleet-heartbeat.ps1'
    $noAnchorHome = Join-Path $tmp 'fresh'
    New-Item -ItemType Directory -Force -Path $noAnchorHome | Out-Null
    $out1 = & pwsh -NoProfile -File $cli -Status -BatonHome $noAnchorHome 2>&1 | Out-String
    Check 'CLI1 no anchor -> tells the operator how to seed one, exit 0' (
        $LASTEXITCODE -eq 0 -and $out1 -match 'anchor')
    $out2 = & pwsh -NoProfile -File $cli -Anchor '3:50' -BatonHome $noAnchorHome 2>&1 | Out-String
    Check 'CLI2 --anchor seeds and confirms' ($LASTEXITCODE -eq 0 -and $out2 -match 'anchored to')
    $out3 = & pwsh -NoProfile -File $cli -Status -Json -BatonHome $noAnchorHome 2>&1 | Out-String
    $status = $out3 | ConvertFrom-Json
    Check 'CLI3 --status --json reports anchor + next boundary' (
        $null -ne $status.next_at -and $null -ne $status.anchor)
    Check 'CLI4 next boundary is in the future' (([datetimeoffset]$status.next_at) -gt [datetimeoffset]::Now)
    & pwsh -NoProfile -File $cli -Anchor 'lunchtime' -BatonHome $noAnchorHome 2>$null | Out-Null
    Check 'CLI5 unparseable anchor exits 2' ($LASTEXITCODE -eq 2)
    $out6 = & pwsh -NoProfile -File $cli -Install -PrintSchedule -BatonHome $noAnchorHome 2>&1 | Out-String
    Check 'CLI6 --print-schedule prints schtasks WITHOUT registering anything' (
        $LASTEXITCODE -eq 0 -and $out6 -match 'schtasks' -and $out6 -match 'ONCE')
    & pwsh -NoProfile -File $cli -Install -PrintSchedule -BatonHome (Join-Path $tmp 'never-anchored') 2>$null | Out-Null
    Check 'CLI7 scheduling without an anchor refuses (exit 2)' ($LASTEXITCODE -eq 2)
}
catch {
    Write-Host "FAIL: suite threw — $($_.Exception.Message)"
    $script:fail++
}
finally {
    if ($null -eq $prevHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue } else { $env:BATON_HOME = $prevHome }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
