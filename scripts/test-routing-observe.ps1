#!/usr/bin/env pwsh
<# Hermetic tests for the routing-observe write-on-observe loop (#159).
   Points BATON_HOME + ratings path at temp dirs; never touches real ~/.baton,
   ~/.claude, or the knowledge repo. #>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$savedObserve = $env:BATON_ROUTING_OBSERVE
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-observe-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $env:BATON_HOME = Join-Path $tmp 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    Remove-Item Env:BATON_ROUTING_OBSERVE -ErrorAction SilentlyContinue

    $ratings = Join-Path $tmp 'knowledge/universal/routing-ratings.jsonl'
    $journal = Join-Path $tmp 'routing-journal.jsonl'
    $runsRoot = Join-Path $env:BATON_HOME 'runs'
    $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'

    # Placeholder fleet — no real model ids / endpoints.
    Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-worker
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    model_default: placeholder-model-v1
    command_template: 'echo "{{prompt}}"'
  - name: fake-auto
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    model_default: auto
    command_template: 'echo "{{prompt}}"'
'@

    . (Join-Path $here 'routing-observe-lib.ps1')
    . (Join-Path $here 'fleet-lib.ps1')

    # ---------- 1. pass → one good rating with routed model as candidate ----------
    $r1 = Add-OutcomeRating `
        -RunId 'run-pass-1' -TaskId 't1' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'pass'; failure_category = ''; grade = 'bounded' } `
        -Why 'routed code-gen -> fake-worker; verified (grade bounded)' `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:01Z'
    Assert '1a pass writes one rating' ($r1.written -eq $true -and $r1.rating -eq 'good')
    $rows1 = @(Get-CapabilityRatings -RatingsPath $ratings)
    Assert '1b file has exactly one row' ($rows1.Count -eq 1)
    Assert '1c candidate is routed model' ($rows1[0].candidate -eq 'fake-worker')
    Assert '1d rating is good' ($rows1[0].rating -eq 'good')
    Assert '1e source is heuristic' ($rows1[0].source -eq 'heuristic')
    Assert '1f run_id/task_id provenance' ($rows1[0].run_id -eq 'run-pass-1' -and $rows1[0].task_id -eq 't1')

    # ---------- 2. scope-violation → one bad rating ----------
    $r2 = Add-OutcomeRating `
        -RunId 'run-scope-1' -TaskId 't2' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'scope-violation'; failure_category = 'scope-violation'; grade = 'invalid' } `
        -Why 'routed code-gen -> fake-worker; verification scope-violation: scope-violation' `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:02Z'
    Assert '2a scope-violation writes bad' ($r2.written -eq $true -and $r2.rating -eq 'bad')
    $rows2 = @(Get-CapabilityRatings -RatingsPath $ratings)
    Assert '2b two rows after scope' ($rows2.Count -eq 2)
    $scopeRow = @($rows2 | Where-Object { $_.run_id -eq 'run-scope-1' })[0]
    Assert '2c failure_category recorded' ($scopeRow.failure_category -eq 'scope-violation')

    # ---------- 3. quota-exhausted → NO rating (file unchanged) ----------
    $beforeQuota = Get-Content -LiteralPath $ratings -Raw
    $r3a = Add-OutcomeRating `
        -RunId 'run-quota-1' -TaskId 't3' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'fail'; failure_category = 'quota-exhausted'; grade = 'invalid' } `
        -Why 'usage failover' `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:03Z'
    Assert '3a quota category writes nothing' ($r3a.written -eq $false)
    # Same no-change grade as #156, but why carries quota_exhausted — still no rating.
    $r3b = Add-OutcomeRating `
        -RunId 'run-quota-2' -TaskId 't3b' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'fail'; failure_category = 'no-change'; grade = 'invalid' } `
        -Why 'usage failover: fake-a -> fake-b (quota_exhausted; reset unknown); substitute exit 1; verification fail: no-change' `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:04Z'
    Assert '3b quota-in-why writes nothing' ($r3b.written -eq $false)
    $afterQuota = Get-Content -LiteralPath $ratings -Raw
    Assert '3c ratings file unchanged after quota' ($beforeQuota -eq $afterQuota)

    # ---------- 4. same (run_id, task_id) twice → still exactly one rating ----------
    $countBefore = @(Get-CapabilityRatings -RatingsPath $ratings).Count
    $r4 = Add-OutcomeRating `
        -RunId 'run-pass-1' -TaskId 't1' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:05Z'
    Assert '4a second call skipped as already' ($r4.written -eq $false -and $r4.skipped -eq 'already')
    Assert '4b row count unchanged' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq $countBefore)

    # ---------- 5. model_version discoverable vs unknown — never invented ----------
    $r5a = Add-OutcomeRating `
        -RunId 'run-mv-1' -TaskId 't5a' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:06Z'
    $mvRow = @((Get-CapabilityRatings -RatingsPath $ratings) | Where-Object { $_.run_id -eq 'run-mv-1' })[0]
    Assert '5a model_version from fleet pin' ($mvRow.model_version -eq 'placeholder-model-v1')
    Assert '5a written' ($r5a.written -eq $true)

    $r5b = Add-OutcomeRating `
        -RunId 'run-mv-2' -TaskId 't5b' -Capability 'code-gen' -Candidate 'fake-auto' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:07Z'
    $mvAuto = @((Get-CapabilityRatings -RatingsPath $ratings) | Where-Object { $_.run_id -eq 'run-mv-2' })[0]
    Assert '5b model_default auto → unknown' ($mvAuto.model_version -eq 'unknown')
    Assert '5b written' ($r5b.written -eq $true)

    $r5c = Add-OutcomeRating `
        -RunId 'run-mv-3' -TaskId 't5c' -Capability 'code-gen' -Candidate 'no-such-provider' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:08Z'
    $mvUnk = @((Get-CapabilityRatings -RatingsPath $ratings) | Where-Object { $_.run_id -eq 'run-mv-3' })[0]
    Assert '5c missing provider → unknown (not invented)' ($mvUnk.model_version -eq 'unknown')
    Assert '5c written' ($r5c.written -eq $true)

    # Explicit pin wins over fleet.
    $r5d = Add-OutcomeRating `
        -RunId 'run-mv-4' -TaskId 't5d' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -ModelVersion 'explicit-pin-9.9' `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:09Z'
    $mvEx = @((Get-CapabilityRatings -RatingsPath $ratings) | Where-Object { $_.run_id -eq 'run-mv-4' })[0]
    Assert '5d explicit ModelVersion used' ($mvEx.model_version -eq 'explicit-pin-9.9')
    Assert '5d written' ($r5d.written -eq $true)

    # ---------- 6. write fault does not throw and does not fail the caller ----------
    $badPath = Join-Path $tmp 'locked-as-file'
    Set-Content -LiteralPath $badPath -Value 'not-a-dir' -Encoding utf8NoBOM
    # Ratings path whose parent is a FILE → cannot create directory → write fault.
    $unwritable = Join-Path $badPath 'child/ratings.jsonl'
    $threw = $false
    $r6 = $null
    try {
        $r6 = Add-OutcomeRating `
            -RunId 'run-fault-1' -TaskId 'tf' -Capability 'code-gen' -Candidate 'fake-worker' `
            -Verification @{ verdict = 'pass'; failure_category = '' } `
            -RatingsPath $unwritable -FleetPath $fleetPath `
            -Timestamp '2026-08-03T00:00:10Z'
    } catch {
        $threw = $true
    }
    Assert '6a write fault does not throw' (-not $threw)
    # Add-CapabilityRating warns and returns; Add-OutcomeRating still reports written=$true
    # because the writer swallows the fault. Either "no throw" is the contract — confirm
    # we did not surface an exception and the caller can continue.
    Assert '6b caller got a result object' ($null -ne $r6)

    # ---------- 7. BATON_ROUTING_OBSERVE=off writes nothing ----------
    $env:BATON_ROUTING_OBSERVE = 'off'
    $beforeOff = @(Get-CapabilityRatings -RatingsPath $ratings).Count
    $r7 = Add-OutcomeRating `
        -RunId 'run-off-1' -TaskId 'toff' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $ratings -FleetPath $fleetPath `
        -Timestamp '2026-08-03T00:00:11Z'
    Assert '7a observe-off skips' ($r7.written -eq $false -and $r7.skipped -eq 'observe-off')
    Assert '7b no new row' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq $beforeOff)
    Remove-Item Env:BATON_ROUTING_OBSERVE -ErrorAction SilentlyContinue

    # ---------- 8. backfill --dry-run writes nothing but reports count ----------
    # Seed a mini run tree with one pass + one scope-violation + one quota (#156-shaped).
    $seedRun = Join-Path $runsRoot 'go-seed-1'
    foreach ($tid in @('t-pass', 't-scope', 't-quota')) {
        $td = Join-Path $seedRun "tasks/$tid"
        New-Item -ItemType Directory -Force -Path $td | Out-Null
    }
    ConvertTo-Json -InputObject @{
        verdict = 'pass'; grade = 'bounded'; failure_category = ''; retried = $false
    } -Compress | Set-Content -LiteralPath (Join-Path $seedRun 'tasks/t-pass/verification.json') -Encoding utf8NoBOM
    ConvertTo-Json -InputObject @{
        verdict = 'scope-violation'; grade = 'invalid'; failure_category = 'scope-violation'; retried = $false
    } -Compress | Set-Content -LiteralPath (Join-Path $seedRun 'tasks/t-scope/verification.json') -Encoding utf8NoBOM
    ConvertTo-Json -InputObject @{
        verdict = 'fail'; grade = 'invalid'; failure_category = 'no-change'; retried = $true
    } -Compress | Set-Content -LiteralPath (Join-Path $seedRun 'tasks/t-quota/verification.json') -Encoding utf8NoBOM

    foreach ($pair in @(
        @{ id = 't-pass'; worker = 'fake-worker' }
        @{ id = 't-scope'; worker = 'fake-worker' }
        @{ id = 't-quota'; worker = 'fake-worker' }
    )) {
        $att = [ordered]@{
            attempt = 1; worker = $pair.worker; worker_ok = $true; diff_grew = $true
            verdict = 'pass'; grade = 'bounded'; failure_category = ''; first_try = $true; duration_ms = 1
        }
        Add-Content -LiteralPath (Join-Path $seedRun "tasks/$($pair.id)/attempts.jsonl") `
            -Value ($att | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    }

    ConvertTo-Json -InputObject @{
        tasks = @(
            @{ id = 't-pass'; capability = 'code-gen' }
            @{ id = 't-scope'; capability = 'code-gen' }
            @{ id = 't-quota'; capability = 'code-gen' }
        )
    } -Depth 4 | Set-Content -LiteralPath (Join-Path $seedRun 'plan.json') -Encoding utf8NoBOM

    $evQuota = [ordered]@{
        ts = '2026-08-03T00:00:00Z'; task_id = 't-quota'; kind = 'error'
        message = 'usage failover: fake-a -> fake-worker (quota_exhausted; reset unknown); substitute exit 1; verification fail: no-change'
    }
    Add-Content -LiteralPath (Join-Path $seedRun 'events.jsonl') `
        -Value ($evQuota | ConvertTo-Json -Compress) -Encoding utf8NoBOM

    $bfRatings = Join-Path $tmp 'backfill-ratings.jsonl'
    $beforeBf = if (Test-Path $bfRatings) { Get-Content -LiteralPath $bfRatings -Raw } else { '' }
    $bf = Invoke-RoutingObserveBackfill -RunsRoot $runsRoot -RatingsPath $bfRatings `
        -FleetPath $fleetPath -DryRun
    $afterBf = if (Test-Path $bfRatings) { Get-Content -LiteralPath $bfRatings -Raw } else { '' }
    Assert '8a dry-run writes nothing' ($beforeBf -eq $afterBf -and -not (Test-Path $bfRatings))
    Assert '8b dry-run flag set' ($bf.dry_run -eq $true)
    # pass + scope = 2; quota skipped
    Assert '8c would_write is 2 (pass+scope, not quota)' ($bf.would_write -eq 2)
    Assert '8d examined is 3' ($bf.examined -eq 3)

    # Actual write path also works and is idempotent.
    $bfW = Invoke-RoutingObserveBackfill -RunsRoot $runsRoot -RatingsPath $bfRatings `
        -FleetPath $fleetPath -Write
    Assert '8e write mode wrote 2' ($bfW.written -eq 2 -and $bfW.dry_run -eq $false)
    $bfW2 = Invoke-RoutingObserveBackfill -RunsRoot $runsRoot -RatingsPath $bfRatings `
        -FleetPath $fleetPath -Write
    Assert '8f second write is idempotent (0 new)' ($bfW2.written -eq 0)

    # ---------- 9. quality moves below prior for bad, above for good ----------
    $qRatings = Join-Path $tmp 'quality-ratings.jsonl'
    $qJournal = Join-Path $tmp 'quality-journal.jsonl'  # empty
    Add-OutcomeRating -RunId 'q-good' -TaskId 't1' -Capability 'code-gen' -Candidate 'model-good' `
        -Verification @{ verdict = 'pass'; failure_category = '' } `
        -RatingsPath $qRatings -FleetPath $fleetPath -Timestamp '2026-08-03T01:00:00Z' | Out-Null
    Add-OutcomeRating -RunId 'q-bad' -TaskId 't1' -Capability 'code-gen' -Candidate 'model-bad' `
        -Verification @{ verdict = 'scope-violation'; failure_category = 'scope-violation' } `
        -RatingsPath $qRatings -FleetPath $fleetPath -Timestamp '2026-08-03T01:00:01Z' | Out-Null

    $qGood = Get-CapabilityQualityDetail -Capability 'code-gen' -Candidate 'model-good' `
        -RatingsPath $qRatings -JournalPath $qJournal
    $qBad = Get-CapabilityQualityDetail -Capability 'code-gen' -Candidate 'model-bad' `
        -RatingsPath $qRatings -JournalPath $qJournal
    Assert '9a good quality above 0.5 prior' ($qGood.quality -gt 0.5)
    Assert '9b bad quality below 0.5 prior' ($qBad.quality -lt 0.5)
    Assert '9c heuristic channel received the rows' ($qGood.heuristic.n -ge 1 -and $qBad.heuristic.n -ge 1)

    # ---------- 10. learn status --json emits valid JSON ----------
    $status = Get-RoutingObserveStatus -RatingsPath $qRatings -JournalPath $qJournal
    $jsonText = ConvertTo-Json -InputObject ([pscustomobject]$status) -Depth 8
    $parsed = $null
    $jsonOk = $false
    try {
        $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
        $jsonOk = $true
    } catch { $jsonOk = $false }
    Assert '10a status JSON parses' $jsonOk
    Assert '10b status has total + pairs' ($null -ne $parsed.total -and $null -ne $parsed.pairs)
    Assert '10c status total matches rows' ([int]$parsed.total -eq 2)

    # CLI smoke: fleet-routing-observe.ps1 status -Json
    $cliOut = & pwsh -NoProfile -File (Join-Path $here 'fleet-routing-observe.ps1') status `
        -Json -RatingsPath $qRatings -JournalPath $qJournal 2>&1
    $cliText = (@($cliOut) -join "`n")
    $cliParsed = $null
    $cliOk = $false
    try {
        $cliParsed = $cliText | ConvertFrom-Json -ErrorAction Stop
        $cliOk = $true
    } catch { $cliOk = $false }
    Assert '10d CLI status --json valid' $cliOk
    Assert '10e CLI total is 2' ($cliOk -and [int]$cliParsed.total -eq 2)

    # Extra: oracle/check fail after rework maps to bad
    $rCheck = Add-OutcomeRating `
        -RunId 'run-check-1' -TaskId 'tc' -Capability 'code-gen' -Candidate 'fake-worker' `
        -Verification @{ verdict = 'fail'; failure_category = 'check-failed'; grade = 'invalid' } `
        -Why 'verification fail: check-failed; rework halted (max_rework)' `
        -RatingsPath $ratings -FleetPath $fleetPath -Timestamp '2026-08-03T00:00:12Z'
    Assert 'X1 check-failed after rework → bad' ($rCheck.written -eq $true -and $rCheck.rating -eq 'bad')

    # ---------- 11. d103: an over-envelope diff-apply task produces NO rating ----------
    # The task was refused for SIZE before the model ever saw it — that is not
    # evidence about model quality (the #156 principle, applied to size).
    $envelopeWhy = 'local-host-a: dispatch error: task exceeds diff-apply envelope: 30002 bytes > limit 24000 (ambiguous)'
    Assert '11a diff-apply envelope failure yields no rating' (
        $null -eq (Resolve-OutcomeRatingValue -Verdict 'fail' -FailureCategory 'dispatch-error' -Why $envelopeWhy))
    Assert '11b ordinary fail verdict still rates bad' (
        (Resolve-OutcomeRatingValue -Verdict 'fail' -FailureCategory 'check-failed' `
            -Why 'verification fail: check-failed') -eq 'bad')
    $rEnvelope = Add-OutcomeRating `
        -RunId 'run-envelope-1' -TaskId 'te' -Capability 'code-gen' -Candidate 'local-host-a' `
        -Verification @{ verdict = 'fail'; failure_category = 'dispatch-error'; grade = 'invalid' } `
        -Why $envelopeWhy `
        -RatingsPath $ratings -FleetPath $fleetPath -Timestamp '2026-08-03T00:00:13Z'
    Assert '11c envelope failure writes nothing through Add-OutcomeRating' (
        $rEnvelope.written -eq $false -and $rEnvelope.skipped -eq 'availability-or-unmapped')

} finally {
    if ($null -ne $savedHome) { $env:BATON_HOME = $savedHome }
    else { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $savedObserve) { $env:BATON_ROUTING_OBSERVE = $savedObserve }
    else { Remove-Item Env:BATON_ROUTING_OBSERVE -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Host "`nFAILED: $failures assertion(s)" -ForegroundColor Red
    exit 1
}
Write-Host "`nAll routing-observe tests passed." -ForegroundColor Green
exit 0
