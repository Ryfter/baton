#!/usr/bin/env pwsh
# Hermetic tests for window-budget-lib.ps1 + fleet-window-budget.ps1 + routing pressure seam.
# Never touches real ~/.baton, ~/.claude, or any real project tree.
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$prevHome = $env:BATON_HOME
$prevPressure = $env:BATON_WINDOW_PRESSURE
$prevSoft = $env:BATON_WINDOW_SOFT_PCT
$prevHard = $env:BATON_WINDOW_HARD_PCT
$env:BATON_HOME = $tmp
Remove-Item Env:BATON_WINDOW_PRESSURE -ErrorAction SilentlyContinue
Remove-Item Env:BATON_WINDOW_SOFT_PCT -ErrorAction SilentlyContinue
Remove-Item Env:BATON_WINDOW_HARD_PCT -ErrorAction SilentlyContinue

try {
    . "$PSScriptRoot/window-budget-lib.ps1"
    . "$PSScriptRoot/routing-lib.ps1"

    # Fixed clock for accounting assertions. Routing pressure uses wall-clock Now
    # (Select-Capability has no -Now), so pressure cases re-seed journals near real Now later.
    $now = [datetimeoffset]::Parse('2026-08-02T12:00:00-06:00')
    # Anchor at 2026-08-02 03:00 local (-06) so 5h grid boundaries are 03:00, 08:00, 13:00, …
    # At Now=12:00, current 5h window is 08:00 → 13:00.
    $anchor = [datetimeoffset]::Parse('2026-08-02T03:00:00-06:00')
    $hbPath = Join-Path $tmp 'heartbeat.json'
    @{
        anchor = $anchor.ToString('o')
        anchor_from_beat = $false
        last_fired_at = $null
        beats = 1
        last_beat_started_window = $true
    } | ConvertTo-Json | Set-Content -LiteralPath $hbPath -Encoding utf8NoBOM

    $journal = Join-Path $tmp 'model-routing-log.md'
    # Lines inside the 5h window (08:00–13:00 on 2026-08-02 -06), and outside.
    # Placeholders only — no real model ids / hostnames.
    $journalBody = @'
# Model Routing Log
# --- entries below this line ---
2026-08-02T09:00:00-06:00 | fleet | worker-alpha | 10s | exit:0 | "alpha one" | host:TESTBOX | tok:100(exact)
2026-08-02T10:00:00-06:00 | fleet | worker-alpha | 20s | exit:0 | "alpha two" | host:TESTBOX | tok:50(estimate)
2026-08-02T11:00:00-06:00 | fleet | worker-beta | 5s | exit:0 | "beta one" | host:TESTBOX | tok:200(exact)
2026-08-02T06:00:00-06:00 | fleet | worker-alpha | 1s | exit:0 | "before 5h window" | host:TESTBOX | tok:999(exact)
2026-07-20T10:00:00-06:00 | fleet | worker-alpha | 1s | exit:0 | "outside 7d" | host:TESTBOX | tok:5000(exact)
2026-08-02T10:30:00-06:00 | note | worker-alpha | "qualitative observation — skip me"
2026-08-02T10:45:00-06:00 | fleet | worker-gamma | 3s | exit:0 | "no token field here" | host:TESTBOX
not-a-timestamp | fleet | worker-alpha | 1s | exit:0 | "bad ts" | host:TESTBOX | tok:1(exact)
2026-08-01T12:00:00-06:00 | fleet | worker-alpha | 2s | exit:0 | "in 7d not 5h" | host:TESTBOX | tok:30(estimate)
'@
    Set-Content -LiteralPath $journal -Value $journalBody -Encoding utf8NoBOM

    function Write-LivePressureJournal {
        <# Seed consumption so wall-clock pressure sees soft (alpha 75%) / hard (beta 100%).
           Anchor = Now-4h so current 5h window is [Now-4h, Now+1h]; dispatches sit inside it. #>
        param([string]$HomeDir, [string]$JournalPath)
        $liveNow = [datetimeoffset]::Now
        $liveAnchor = $liveNow.AddHours(-4)
        @{
            anchor = $liveAnchor.ToString('o')
            anchor_from_beat = $true
            last_fired_at = $liveNow.ToString('o')
            beats = 1
            last_beat_started_window = $true
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $HomeDir 'heartbeat.json') -Encoding utf8NoBOM
        $t1 = $liveNow.AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $t2 = $liveNow.AddMinutes(-20).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $t3 = $liveNow.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz')
        $body = @(
            '# Model Routing Log'
            "$t1 | fleet | worker-alpha | 10s | exit:0 | `"alpha live`" | host:TESTBOX | tok:100(exact)"
            "$t2 | fleet | worker-alpha | 20s | exit:0 | `"alpha live2`" | host:TESTBOX | tok:50(estimate)"
            "$t3 | fleet | worker-beta | 5s | exit:0 | `"beta live`" | host:TESTBOX | tok:200(exact)"
        ) -join "`n"
        Set-Content -LiteralPath $JournalPath -Value $body -Encoding utf8NoBOM
    }
    # ------------------------------------------------------------------
    # 1. 5h window bounds follow the anchor grid, not the last dispatch
    # ------------------------------------------------------------------
    $wins = Get-UsageWindows -Now $now -BatonHome $tmp
    $w5 = $wins['5h']
    $expectedStart = [datetimeoffset]::Parse('2026-08-02T08:00:00-06:00').UtcDateTime
    $expectedEnd = [datetimeoffset]::Parse('2026-08-02T13:00:00-06:00').UtcDateTime
    Assert '1a 5h start is anchor-grid boundary (08:00), not last dispatch' (
        $w5.start -eq $expectedStart -and $w5.kind -eq 'anchored')
    Assert '1b 5h end is start+5h (13:00)' ($w5.end -eq $expectedEnd)
    Assert '1c 5h is not rolling fallback when anchor present' (-not [bool]$w5.fallback)

    # Last dispatch at 11:00 must NOT move the window
    Assert '1d window start independent of last dispatch time' (
        $w5.start -ne [datetimeoffset]::Parse('2026-08-02T11:00:00-06:00').UtcDateTime)

    # ------------------------------------------------------------------
    # 2. 7d window is rolling 168h
    # ------------------------------------------------------------------
    $w7 = $wins['7d']
    $expected7Start = $now.UtcDateTime.AddHours(-168)
    Assert '2a 7d kind is rolling' ($w7.kind -eq 'rolling')
    Assert '2b 7d spans 168 hours' ([math]::Abs(($w7.end - $w7.start).TotalHours - 168.0) -lt 0.001)
    Assert '2c 7d ends at Now' ($w7.end -eq $now.UtcDateTime)
    Assert '2d 7d starts Now-168h' ([math]::Abs(($w7.start - $expected7Start).TotalSeconds) -lt 1)

    # ------------------------------------------------------------------
    # 3. Token folding sums per model correctly across many lines
    # ------------------------------------------------------------------
    # Do NOT wrap unary-comma array returns in @() — that re-nests them.
    $c5 = Get-WindowConsumption -Window '5h' -Now $now -BatonHome $tmp
    $alpha5 = $c5 | Where-Object { $_.model -eq 'worker-alpha' } | Select-Object -First 1
    $beta5 = $c5 | Where-Object { $_.model -eq 'worker-beta' } | Select-Object -First 1
    Assert '3a alpha tokens in 5h = 100+50 (not the pre-window 999)' (
        $null -ne $alpha5 -and [long]$alpha5.tokens -eq 150)
    Assert '3b alpha dispatches in 5h = 2' ([int]$alpha5.dispatches -eq 2)
    Assert '3c alpha seconds in 5h = 30' ([long]$alpha5.seconds -eq 30)
    Assert '3d beta tokens in 5h = 200' (
        $null -ne $beta5 -and [long]$beta5.tokens -eq 200)

    $c7 = Get-WindowConsumption -Window '7d' -Now $now -BatonHome $tmp
    $alpha7 = $c7 | Where-Object { $_.model -eq 'worker-alpha' } | Select-Object -First 1
    # 5h lines (150) + 7d-only estimate 30; outside-7d 5000 excluded; pre-5h-but-in-7d 999 included
    # 06:00 is before 5h window start (08:00) but within 7d → +999
    Assert '3e alpha 7d tokens include in-7d out-of-5h lines' (
        $null -ne $alpha7 -and [long]$alpha7.tokens -eq (150 + 999 + 30))

    # ------------------------------------------------------------------
    # 4. exact and estimate reported separately, not blended
    # ------------------------------------------------------------------
    Assert '4a alpha exact_tokens = 100' ([long]$alpha5.exact_tokens -eq 100)
    Assert '4b alpha estimated_tokens = 50' ([long]$alpha5.estimated_tokens -eq 50)
    Assert '4c tokens = exact + estimated (auditable sum)' (
        [long]$alpha5.tokens -eq ([long]$alpha5.exact_tokens + [long]$alpha5.estimated_tokens))
    Assert '4d beta all exact' (
        [long]$beta5.exact_tokens -eq 200 -and [long]$beta5.estimated_tokens -eq 0)

    # ------------------------------------------------------------------
    # 5. note lines and no-tok lines skipped without error
    # ------------------------------------------------------------------
    $threwSkip = $false
    try {
        $all = Get-WindowConsumption -Window '5h' -Now $now -BatonHome $tmp
        $gamma = @($all | Where-Object { $_.model -eq 'worker-gamma' })
    } catch {
        $threwSkip = $true
        $gamma = @()
    }
    Assert '5a note/no-tok lines do not throw' (-not $threwSkip)
    Assert '5b worker-gamma (no tok) absent from consumption' ($gamma.Count -eq 0)

    $diag = $null
    [void](Read-ModelRoutingDispatchRows -Path $journal -Diagnostics ([ref]$diag))
    Assert '5c diagnostics count note lines' ([int]$diag.lines_note -ge 1)
    Assert '5d diagnostics count no-tok lines' ([int]$diag.lines_no_tok -ge 1)

    # ------------------------------------------------------------------
    # 6. malformed timestamp does not throw
    # ------------------------------------------------------------------
    $threwTs = $false
    try {
        [void](Get-WindowConsumption -Window '5h' -Now $now -BatonHome $tmp)
    } catch { $threwTs = $true }
    Assert '6a bad timestamp does not throw' (-not $threwTs)
    Assert '6b bad timestamp counted unparsable' ([int]$diag.lines_bad_ts -ge 1 -or [int]$diag.lines_unparsable -ge 1)

    # ------------------------------------------------------------------
    # 7. No budgets file → headroom_pct null, pressure none
    # ------------------------------------------------------------------
    $bp = Get-WindowBudgetsPath -BatonHome $tmp
    Assert '7a budgets file absent' (-not (Test-Path -LiteralPath $bp))
    $hNo = Get-ModelHeadroom -Model 'worker-alpha' -Now $now -BatonHome $tmp
    Assert '7b budget is null without file' ($null -eq $hNo.budget)
    Assert '7c headroom_pct is null without file' ($null -eq $hNo.headroom_pct)
    Assert '7d pressure is none without budget' ((Get-WindowPressure -Model 'worker-alpha' -Now $now -BatonHome $tmp) -eq 'none')

    # ------------------------------------------------------------------
    # Budgets for pressure tests (placeholder model names only)
    # ------------------------------------------------------------------
    # worker-alpha: 5h budget 200 → used 150/200 = 75% → soft
    # worker-beta:  5h budget 200 → used 200/200 = 100% → hard
    # worker-local: no budget → none
    @{
        'worker-alpha' = @{ tokens_5h = 200; tokens_7d = 10000 }
        'worker-beta'  = @{ tokens_5h = 200; tokens_7d = 10000 }
    } | ConvertTo-Json | Set-Content -LiteralPath $bp -Encoding utf8NoBOM

    Assert '7e with budget, soft pressure when used >= 70%' (
        (Get-WindowPressure -Model 'worker-alpha' -Now $now -BatonHome $tmp) -eq 'soft')
    Assert '7f with budget, hard pressure when used >= 90%' (
        (Get-WindowPressure -Model 'worker-beta' -Now $now -BatonHome $tmp) -eq 'hard')
    Assert '7g unbudgeted model still none' (
        (Get-WindowPressure -Model 'worker-local' -Now $now -BatonHome $tmp) -eq 'none')

    $hYes = Get-ModelHeadroom -Model 'worker-alpha' -Now $now -BatonHome $tmp
    Assert '7h headroom_pct populated when budget exists' (
        $null -ne $hYes.headroom_pct -and $null -ne $hYes.headroom_pct['5h'])

    # ------------------------------------------------------------------
    # Routing fixtures (placeholder providers only)
    # ------------------------------------------------------------------
    $toolsFx = Join-Path $tmp 'tools.yaml'
    Set-Content -LiteralPath $toolsFx -Encoding utf8NoBOM -Value "tools: []"
    $ratingsFx = Join-Path $tmp 'ratings.jsonl'
    Set-Content -LiteralPath $ratingsFx -Encoding utf8NoBOM -Value ''
    $routeJournal = Join-Path $tmp 'routing-journal.jsonl'
    Set-Content -LiteralPath $routeJournal -Encoding utf8NoBOM -Value ''
    $usageFx = Join-Path $tmp 'usage-journal.jsonl'
    Set-Content -LiteralPath $usageFx -Encoding utf8NoBOM -Value ''

    $fleetTwo = Join-Path $tmp 'fleet-two.yaml'
    Set-Content -LiteralPath $fleetTwo -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: worker-alpha
    kind: cli
    enabled: true
    cost_tier: free
  - name: worker-local
    kind: http
    enabled: true
    cost_tier: local
'@

    $fleetOnlyAlpha = Join-Path $tmp 'fleet-only-alpha.yaml'
    Set-Content -LiteralPath $fleetOnlyAlpha -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: worker-alpha
    kind: cli
    enabled: true
    cost_tier: free
'@

    $fleetOnlyBeta = Join-Path $tmp 'fleet-only-beta.yaml'
    Set-Content -LiteralPath $fleetOnlyBeta -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: worker-beta
    kind: cli
    enabled: true
    cost_tier: free
'@

    function Invoke-Sel {
        param([string]$Fleet, [string]$Mode = 'economy')
        # Unary-comma array: assign directly, do not re-wrap with @().
        Select-Capability -Capability 'code-gen' -SelectionMode $Mode `
            -ToolsPath $toolsFx -FleetPath $Fleet `
            -RatingsPath $ratingsFx -JournalPath $routeJournal -UsagePath $usageFx
    }

    # ------------------------------------------------------------------
    # 10. BATON_WINDOW_PRESSURE=off leaves ranking byte-identical to today
    #     (run BEFORE enabling pressure so we capture the baseline)
    # ------------------------------------------------------------------
    # Live journal so wall-clock pressure (Select-Capability has no -Now) sees real headroom.
    Write-LivePressureJournal -HomeDir $tmp -JournalPath $journal

    $env:BATON_WINDOW_PRESSURE = 'off'
    $offA = Invoke-Sel -Fleet $fleetTwo
    $offNames = @($offA | ForEach-Object { $_.name })
    Assert '10a pressure=off: local ranks before free (economy)' (
        $offNames[0] -eq 'worker-local' -and $offNames -contains 'worker-alpha')
    # No window_pressure property applied when off (or adjust stays absent/zero)
    $alphaOff = $offA | Where-Object { $_.name -eq 'worker-alpha' } | Select-Object -First 1
    $hasAdj = $null -ne $alphaOff.PSObject.Properties['window_pressure_adjust']
    Assert '10b pressure=off: no nonzero window_pressure_adjust on candidates' (
        (-not $hasAdj) -or ([double]$alphaOff.window_pressure_adjust -eq 0.0))

    # Unset vs off both mean disabled
    Remove-Item Env:BATON_WINDOW_PRESSURE -ErrorAction SilentlyContinue
    $unsetA = Invoke-Sel -Fleet $fleetTwo
    $unsetNames = @($unsetA | ForEach-Object { $_.name })
    Assert '10c pressure unset: same order as off' (
        ($unsetNames -join ',') -eq ($offNames -join ','))

    # ------------------------------------------------------------------
    # 8. Soft pressure de-ranks but still selects when only capable candidate
    # ------------------------------------------------------------------
    $env:BATON_WINDOW_PRESSURE = 'on'
    # Clear prior pressure journal noise
    Set-Content -LiteralPath $routeJournal -Encoding utf8NoBOM -Value ''

    Assert '8pre alpha live pressure is soft' (
        (Get-WindowPressure -Model 'worker-alpha' -BatonHome $tmp) -eq 'soft')
    Assert '8pre beta live pressure is hard' (
        (Get-WindowPressure -Model 'worker-beta' -BatonHome $tmp) -eq 'hard')

    $softTwo = Invoke-Sel -Fleet $fleetTwo
    $softNames = @($softTwo | ForEach-Object { $_.name })
    Assert '8a soft: local still first (cheaper, unpressured)' ($softNames[0] -eq 'worker-local')
    $alphaSoft = $softTwo | Where-Object { $_.name -eq 'worker-alpha' } | Select-Object -First 1
    Assert '8b soft: alpha still present (not dropped)' ($null -ne $alphaSoft)
    Assert '8c soft: alpha tagged window_pressure=soft' (
        [string]$alphaSoft.window_pressure -eq 'soft')

    $softOnly = Invoke-Sel -Fleet $fleetOnlyAlpha
    Assert '8d soft: only-capable alpha still selected' (
        @($softOnly).Count -ge 1 -and $softOnly[0].name -eq 'worker-alpha')

    # ------------------------------------------------------------------
    # 9. Hard pressure never makes a capability unroutable
    # ------------------------------------------------------------------
    Set-Content -LiteralPath $routeJournal -Encoding utf8NoBOM -Value ''
    $hardOnly = Invoke-Sel -Fleet $fleetOnlyBeta
    Assert '9a hard: only-capable beta still selected (not unroutable)' (
        @($hardOnly).Count -ge 1 -and $hardOnly[0].name -eq 'worker-beta')
    Assert '9b hard: beta tagged window_pressure=hard' (
        [string]$hardOnly[0].window_pressure -eq 'hard')
    # With local + hard-pressured free: local wins, beta still listed
    $fleetHardTwo = Join-Path $tmp 'fleet-hard-two.yaml'
    Set-Content -LiteralPath $fleetHardTwo -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: worker-beta
    kind: cli
    enabled: true
    cost_tier: free
  - name: worker-local
    kind: http
    enabled: true
    cost_tier: local
'@
    $hardTwo = Invoke-Sel -Fleet $fleetHardTwo
    Assert '9c hard: local preferred over hard-pressured free' ($hardTwo[0].name -eq 'worker-local')
    Assert '9d hard: beta still in candidate list' (
        $null -ne ($hardTwo | Where-Object { $_.name -eq 'worker-beta' } | Select-Object -First 1))
    # Pressure journal lines written
    $jLines = @()
    if (Test-Path -LiteralPath $routeJournal) {
        $jLines = @(Get-Content -LiteralPath $routeJournal | Where-Object { $_ -match 'window_pressure' })
    }
    Assert '9e pressure adjustments journaled' ($jLines.Count -ge 1)

    # ------------------------------------------------------------------
    # 11. budget status --json emits valid JSON with documented fields
    # ------------------------------------------------------------------
    $runner = Join-Path $PSScriptRoot 'fleet-window-budget.ps1'
    $jsonOut = & pwsh -NoProfile -File $runner status --window both --json 2>&1 | Out-String
    $jsonCode = $LASTEXITCODE
    Assert '11a budget status --json exit 0' ($jsonCode -eq 0)
    $parsed = $null
    $jsonOk = $false
    try {
        $parsed = $jsonOut | ConvertFrom-Json -ErrorAction Stop
        $jsonOk = $true
    } catch { $jsonOk = $false }
    Assert '11b budget status --json is valid JSON' $jsonOk
    Assert '11c has models array' ($null -ne $parsed.models)
    Assert '11d has windows.5h and windows.7d' (
        $null -ne $parsed.windows.'5h' -and $null -ne $parsed.windows.'7d')
    Assert '11e has now / budgets_configured / pressure_enabled' (
        $null -ne $parsed.now -and $null -ne $parsed.budgets_configured -and $null -ne $parsed.pressure_enabled)

    $modelSample = @($parsed.models) | Select-Object -First 1
    if ($null -ne $modelSample) {
        Assert '11f model row has tokens/dispatches/exact/estimated fields' (
            $null -ne $modelSample.tokens_5h -and
            $null -ne $modelSample.dispatches_5h -and
            $null -ne $modelSample.exact_tokens_5h -and
            $null -ne $modelSample.estimated_tokens_5h -and
            $null -ne $modelSample.tokens_7d)
        Assert '11g model row has headroom_pct and pressure' (
            $modelSample.PSObject.Properties.Name -contains 'headroom_pct' -and
            $modelSample.PSObject.Properties.Name -contains 'pressure')
    } else {
        Assert '11f model row present' $false
        Assert '11g model row present' $false
    }

    # doctor runs cleanly
    $docOut = & pwsh -NoProfile -File $runner doctor --json 2>&1 | Out-String
    Assert '11h budget doctor --json exit 0' ($LASTEXITCODE -eq 0)
    $docParsed = $null
    try { $docParsed = $docOut | ConvertFrom-Json -ErrorAction Stop } catch { }
    Assert '11i doctor JSON has issues array' ($null -ne $docParsed -and $null -ne $docParsed.issues)

    # bad usage → exit 2
    & pwsh -NoProfile -File $runner totally-bogus 2>&1 | Out-Null
    Assert '11j unknown subcommand exit 2' ($LASTEXITCODE -eq 2)

    # verbs.yaml registers budget
    $verbsPath = Join-Path $PSScriptRoot 'verbs.yaml'
    $verbsText = Get-Content -LiteralPath $verbsPath -Raw
    Assert '11k verbs.yaml registers budget verb' ($verbsText -match '(?m)^\s*-\s+name:\s*budget\s*$')

    # Fallback when no anchor
    $tmp2 = Join-Path $tmp 'no-anchor-home'
    New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
    $winsFb = Get-UsageWindows -Now $now -BatonHome $tmp2
    Assert 'extra: no anchor → 5h rolling fallback' (
        [bool]$winsFb['5h'].fallback -and $winsFb['5h'].kind -eq 'rolling')

} finally {
    if ($null -ne $prevHome) { $env:BATON_HOME = $prevHome }
    else { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $prevPressure) { $env:BATON_WINDOW_PRESSURE = $prevPressure }
    else { Remove-Item Env:BATON_WINDOW_PRESSURE -ErrorAction SilentlyContinue }
    if ($null -ne $prevSoft) { $env:BATON_WINDOW_SOFT_PCT = $prevSoft }
    else { Remove-Item Env:BATON_WINDOW_SOFT_PCT -ErrorAction SilentlyContinue }
    if ($null -ne $prevHard) { $env:BATON_WINDOW_HARD_PCT = $prevHard }
    else { Remove-Item Env:BATON_WINDOW_HARD_PCT -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -gt 0) {
    Write-Host ""
    Write-Host "FAILED: $($script:Fail) assertion(s)"
    exit 1
}
Write-Host ""
Write-Host 'ALL PASS'
exit 0
