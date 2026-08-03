#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Close the routing-learning loop: turn terminal verification outcomes into
  capability ratings so Select-Capability's existing quality path stops starving.
.DESCRIPTION
  Write-on-observe. Reuses Add-CapabilityRating (routing-learn.ps1) — never a second
  writer. Machine-observed rows use source=heuristic so they fold into the Wh=0.25
  channel rather than drowning a model at Wu=1.0.

  Availability failures (quota, provider down, failover substitute failed) produce
  NO rating — that is the #156 misclassification guard. Quality outcomes only.

  Dot-sourced by fleet-executor-lib.ps1 and fleet-routing-observe.ps1.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-learn.ps1"

function Test-RoutingObserveEnabled {
    <# Gate: BATON_ROUTING_OBSERVE defaults ON. Explicit off/0/false/no/disabled silences. #>
    $raw = [string]$env:BATON_ROUTING_OBSERVE
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    switch -Regex ($raw.Trim()) {
        '^(?i:0|false|off|no|disabled)$' { return $false }
        default { return $true }
    }
}

function Test-AvailabilityOutcome {
    <# True when the terminal outcome is availability (or infrastructure-not-quality),
       not model quality. Matches failure_category tokens and free-text why/events. #>
    param(
        [string]$FailureCategory = '',
        [string]$Why = '',
        [string]$Labor = '',
        [string]$Verdict = ''
    )
    if ([string]$Labor -eq 'unavailable') { return $true }

    $cat = ([string]$FailureCategory).Trim().ToLowerInvariant() -replace '_', '-'
    $availCats = @(
        'quota-exhausted'
        'rate-limit'
        'rate-limit-burst'
        'provider-unavailable'
        'labor-unavailable'
        'server-overload'
        'auth-config'
        'failover-substitute-failed'
        'spawn-failed'
    )
    if ($cat -and $availCats -contains $cat) { return $true }
    # raw underscore forms already normalized above; also accept un-normalized input
    if ($FailureCategory -match '^(?i:quota_exhausted|rate_limit(_burst)?|provider_unavailable|labor_unavailable|server_overload|auth_config|failover_substitute_failed|spawn-failed|spawn_failed)$') {
        return $true
    }

    $text = ('{0} {1} {2}' -f $Why, $FailureCategory, $Verdict)
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    $patterns = @(
        'quota_exhausted'
        'quota[\s_-]+exhausted'
        'rate_limit'
        'session\s+limit'
        'usage\s+failover'
        'labor[\s_-]+unavailable'
        'provider[\s_-]+unavailable'
        'no\s+peer\s+available'
        'preflight\s+hold'
        'soft_cap'
        'credits?\s+exhausted'
        'hit\s+your\s+(?:session\s+)?limit'
        'insufficient_quota'
        'weekly\s+(?:usage\s+)?limit'
    )
    foreach ($pat in $patterns) {
        if ($text -match $pat) { return $true }
    }
    return $false
}

function Resolve-OutcomeRatingValue {
    <# Map a terminal verification outcome to 'good', 'bad', or $null (skip). #>
    param(
        [string]$Verdict = '',
        [string]$FailureCategory = '',
        [string]$Why = '',
        [string]$Labor = ''
    )
    if (Test-AvailabilityOutcome -FailureCategory $FailureCategory -Why $Why -Labor $Labor -Verdict $Verdict) {
        return $null
    }

    $v = ([string]$Verdict).Trim().ToLowerInvariant()
    $cat = ([string]$FailureCategory).Trim().ToLowerInvariant()

    if ($v -eq 'pass') { return 'good' }

    if ($v -eq 'scope-violation' -or $cat -eq 'scope-violation' -or $cat -eq 'protected-path-mutated') {
        return 'bad'
    }

    # Oracle / check failure family after the engine has finished rework (caller is
    # always at a terminal verdict when this runs).
    if ($v -eq 'fail') { return 'bad' }

    # infrastructure-error with non-availability categories (e.g. check-timeout graded
    # that way) still reflects that the model did not produce passing work.
    if ($v -eq 'infrastructure-error') {
        if ($cat -eq 'spawn-failed') { return $null }
        return 'bad'
    }

    return $null
}

function Resolve-OutcomeModelVersion {
    <# Exact version identifier when discoverable from an explicit pin or the fleet
       provider's model_default. Never fabricates — returns 'unknown' otherwise. #>
    param(
        [string]$Candidate = '',
        [string]$Explicit = '',
        [string]$FleetPath = ''
    )
    $ex = ([string]$Explicit).Trim()
    if ($ex -and $ex -ne 'auto' -and $ex -ne 'unknown') { return $ex }

    if (-not $Candidate) { return 'unknown' }
    if (-not $FleetPath) {
        try { $FleetPath = Join-Path (Get-BatonHome) 'fleet.yaml' } catch { $FleetPath = '' }
    }
    if (-not $FleetPath -or -not (Test-Path -LiteralPath $FleetPath)) { return 'unknown' }

    try {
        if (-not (Get-Command Get-FleetProvider -ErrorAction SilentlyContinue)) {
            . "$PSScriptRoot/fleet-lib.ps1"
        }
        $provider = Get-FleetProvider -Name $Candidate -Path $FleetPath
        if ($null -eq $provider) { return 'unknown' }
        $md = [string]$provider.model_default
        if ($md -and $md.Trim() -and $md.Trim() -ne 'auto') { return $md.Trim() }
    } catch {
        # discoverability failed — never invent
    }
    return 'unknown'
}

function Test-OutcomeRatingExists {
    <# True when a rating already exists for this (run_id, task_id). #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    $rows = @(Get-CapabilityRatings -RatingsPath $RatingsPath | Where-Object {
        [string]$_.run_id -eq $RunId -and [string]$_.task_id -eq $TaskId
    })
    return ($rows.Count -gt 0)
}

function Add-OutcomeRating {
    <# Turn one finished task's evidence into at most one rating.
       Returns a result hashtable: written, skipped, rating, candidate, ...
       Never throws — write faults warn and return skipped=write-fault. #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Capability,
        [string]$Candidate = '',
        [Parameter(Mandatory)]$Verification,
        [string]$Why = '',
        [string]$Labor = '',
        [string]$ModelVersion = '',
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$FleetPath = '',
        [string]$Timestamp
    )
    try {
        if (-not (Test-RoutingObserveEnabled)) {
            return @{ written = $false; skipped = 'observe-off'; run_id = $RunId; task_id = $TaskId }
        }

        $cand = [string]$Candidate
        if ([string]::IsNullOrWhiteSpace($cand)) {
            return @{ written = $false; skipped = 'no-candidate'; run_id = $RunId; task_id = $TaskId }
        }

        if (Test-OutcomeRatingExists -RunId $RunId -TaskId $TaskId -RatingsPath $RatingsPath) {
            return @{ written = $false; skipped = 'already'; run_id = $RunId; task_id = $TaskId; candidate = $cand }
        }

        $verdict = ''
        $failCat = ''
        if ($null -ne $Verification) {
            # Dynamic member access works for hashtables and PSCustomObjects alike.
            try { if ($null -ne $Verification.verdict) { $verdict = [string]$Verification.verdict } } catch { }
            try { if ($null -ne $Verification.failure_category) { $failCat = [string]$Verification.failure_category } } catch { }
        }

        $rating = Resolve-OutcomeRatingValue -Verdict $verdict -FailureCategory $failCat -Why $Why -Labor $Labor
        if (-not $rating) {
            return @{
                written           = $false
                skipped           = 'availability-or-unmapped'
                run_id            = $RunId
                task_id           = $TaskId
                candidate         = $cand
                verdict           = $verdict
                failure_category  = $failCat
            }
        }

        $mv = Resolve-OutcomeModelVersion -Candidate $cand -Explicit $ModelVersion -FleetPath $FleetPath
        $note = "observe run=$RunId task=$TaskId verdict=$verdict"
        if ($failCat) { $note += " fail=$failCat" }

        Add-CapabilityRating `
            -Capability $Capability `
            -Candidate $cand `
            -Source 'heuristic' `
            -Rating $rating `
            -Note $note `
            -RatingsPath $RatingsPath `
            -Timestamp $Timestamp `
            -ModelVersion $mv `
            -FailureCategory $failCat `
            -RunId $RunId `
            -TaskId $TaskId

        return @{
            written           = $true
            skipped           = ''
            rating            = $rating
            run_id            = $RunId
            task_id           = $TaskId
            candidate         = $cand
            capability        = $Capability
            model_version     = $mv
            verdict           = $verdict
            failure_category  = $failCat
            source            = 'heuristic'
        }
    } catch {
        Write-Warning "routing observe: $($_.Exception.Message)"
        return @{
            written = $false
            skipped = 'write-fault'
            run_id  = $RunId
            task_id = $TaskId
            error   = [string]$_.Exception.Message
        }
    }
}

function Get-TaskObserveContext {
    <# Pull candidate (last attempt worker), capability (plan), and why (events) for
       a finished task under a run dir. Fail-soft: missing pieces return empty strings. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$TaskId
    )
    $candidate = ''
    $capability = ''
    $why = ''
    $labor = ''
    $modelVersion = ''

    $attemptsPath = Join-Path $RunDir "tasks/$TaskId/attempts.jsonl"
    if (Test-Path -LiteralPath $attemptsPath) {
        try {
            $lines = @(Get-Content -LiteralPath $attemptsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($lines.Count -gt 0) {
                $last = $lines[-1] | ConvertFrom-Json -ErrorAction Stop
                if ($last.worker) { $candidate = [string]$last.worker }
            }
        } catch { }
    }

    $planPath = Join-Path $RunDir 'plan.json'
    if (Test-Path -LiteralPath $planPath) {
        try {
            $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
            $tasks = @($plan.tasks)
            $match = @($tasks | Where-Object { [string]$_.id -eq $TaskId } | Select-Object -First 1)
            if ($match.Count -gt 0 -and $match[0].capability) {
                $capability = [string]$match[0].capability
            }
        } catch { }
    }
    if (-not $capability) { $capability = 'code-gen' }

    $eventsPath = Join-Path $RunDir 'events.jsonl'
    if (Test-Path -LiteralPath $eventsPath) {
        try {
            $evLines = @(Get-Content -LiteralPath $eventsPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $taskMsgs = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $evLines) {
                try {
                    $ev = $line | ConvertFrom-Json -ErrorAction Stop
                    if ([string]$ev.task_id -ne $TaskId) { continue }
                    $msg = if ($ev.message) { [string]$ev.message } elseif ($ev.what) { [string]$ev.what } else { '' }
                    if ($msg) { [void]$taskMsgs.Add($msg) }
                    if ([string]$ev.kind -eq 'error' -and $msg) { $why = $msg }
                } catch { }
            }
            if (-not $why -and $taskMsgs.Count -gt 0) { $why = $taskMsgs[-1] }
            if ($why -match 'labor[\s_-]+unavailable' -or $why -match 'no\s+peer\s+available') {
                $labor = 'unavailable'
            }
        } catch { }
    }

    return @{
        candidate     = $candidate
        capability    = $capability
        why           = $why
        labor         = $labor
        model_version = $modelVersion
    }
}

function Invoke-RoutingObserveBackfill {
    <# Walk $RunsRoot/*/tasks/*/verification.json and append missing outcome ratings.
       Default is dry-run (report only). Pass -Write to actually append. #>
    param(
        [string]$RunsRoot = '',
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$FleetPath = '',
        [switch]$Write,
        [switch]$DryRun
    )
    if (-not $RunsRoot) {
        $RunsRoot = Join-Path (Get-BatonHome) 'runs'
    }
    # Default dry-run; -Write is the explicit opt-in. -DryRun forces report-only even with -Write.
    $doWrite = [bool]$Write -and -not [bool]$DryRun

    $would = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $written = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $RunsRoot)) {
        return @{
            dry_run       = (-not $doWrite)
            runs_root     = $RunsRoot
            examined      = 0
            would_write   = 0
            written       = 0
            skipped       = 0
            items         = @()
            skipped_items = @()
        }
    }

    $verFiles = @(Get-ChildItem -LiteralPath $RunsRoot -Recurse -Filter 'verification.json' -File -ErrorAction SilentlyContinue)
    foreach ($vf in $verFiles) {
        # expect .../runs/<run_id>/tasks/<task_id>/verification.json
        $taskDir = $vf.Directory
        $tasksDir = $taskDir.Parent
        $runDir = if ($tasksDir) { $tasksDir.Parent } else { $null }
        if (-not $runDir -or [string]$tasksDir.Name -ne 'tasks') {
            [void]$skipped.Add([ordered]@{ path = $vf.FullName; reason = 'unexpected-layout' })
            continue
        }
        $runId = $runDir.Name
        $taskId = $taskDir.Name

        try {
            $ver = Get-Content -LiteralPath $vf.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            [void]$skipped.Add([ordered]@{ run_id = $runId; task_id = $taskId; reason = 'bad-verification-json' })
            continue
        }

        $ctx = Get-TaskObserveContext -RunDir $runDir.FullName -TaskId $taskId
        if (-not $ctx.candidate) {
            [void]$skipped.Add([ordered]@{ run_id = $runId; task_id = $taskId; reason = 'no-candidate' })
            continue
        }

        if (Test-OutcomeRatingExists -RunId $runId -TaskId $taskId -RatingsPath $RatingsPath) {
            [void]$skipped.Add([ordered]@{ run_id = $runId; task_id = $taskId; reason = 'already'; candidate = $ctx.candidate })
            continue
        }

        $rating = Resolve-OutcomeRatingValue -Verdict ([string]$ver.verdict) `
            -FailureCategory ([string]$ver.failure_category) -Why $ctx.why -Labor $ctx.labor
        if (-not $rating) {
            [void]$skipped.Add([ordered]@{
                run_id = $runId; task_id = $taskId; reason = 'availability-or-unmapped'
                verdict = [string]$ver.verdict; failure_category = [string]$ver.failure_category
                candidate = $ctx.candidate
            })
            continue
        }

        $item = [ordered]@{
            run_id           = $runId
            task_id          = $taskId
            capability       = $ctx.capability
            candidate        = $ctx.candidate
            rating           = $rating
            verdict          = [string]$ver.verdict
            failure_category = [string]$ver.failure_category
        }

        if ($doWrite) {
            $result = Add-OutcomeRating `
                -RunId $runId `
                -TaskId $taskId `
                -Capability $ctx.capability `
                -Candidate $ctx.candidate `
                -Verification $ver `
                -Why $ctx.why `
                -Labor $ctx.labor `
                -ModelVersion $ctx.model_version `
                -RatingsPath $RatingsPath `
                -FleetPath $FleetPath
            if ($result.written) {
                [void]$written.Add($item)
            } else {
                [void]$skipped.Add([ordered]@{
                    run_id = $runId; task_id = $taskId; reason = $result.skipped
                    candidate = $ctx.candidate
                })
            }
        } else {
            [void]$would.Add($item)
        }
    }

    return @{
        dry_run       = (-not $doWrite)
        runs_root     = $RunsRoot
        examined      = $verFiles.Count
        would_write   = $would.Count
        written       = $written.Count
        skipped       = $skipped.Count
        items         = @($would.ToArray()) + @($written.ToArray())
        skipped_items = @($skipped.ToArray())
    }
}

function Get-RoutingObserveStatus {
    <# How many ratings exist, per capability x candidate, with current computed quality. #>
    param(
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$JournalPath = ''
    )
    if (-not $JournalPath) {
        try { $JournalPath = Join-Path (Get-BatonHome) 'routing-journal.jsonl' } catch {
            $JournalPath = Join-Path ([System.IO.Path]::GetTempPath()) 'routing-observe-no-journal.jsonl'
        }
    }

    $rows = @(Get-CapabilityRatings -RatingsPath $RatingsPath)
    $pairs = @{}
    foreach ($r in $rows) {
        $cap = [string]$r.capability
        $cand = [string]$r.candidate
        if (-not $cap -or -not $cand) { continue }
        $key = "$cap`0$cand"
        if (-not $pairs.ContainsKey($key)) {
            $pairs[$key] = [ordered]@{
                capability = $cap
                candidate  = $cand
                n          = 0
                good       = 0
                bad        = 0
                sources    = @{}
            }
        }
        $pairs[$key].n++
        if ([string]$r.rating -eq 'good') { $pairs[$key].good++ }
        elseif ([string]$r.rating -eq 'bad') { $pairs[$key].bad++ }
        $src = if ($r.source) { [string]$r.source } else { '(none)' }
        if (-not $pairs[$key].sources.ContainsKey($src)) { $pairs[$key].sources[$src] = 0 }
        $pairs[$key].sources[$src]++
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($pairs.Keys | Sort-Object)) {
        $p = $pairs[$key]
        $detail = Get-CapabilityQualityDetail -Capability $p.capability -Candidate $p.candidate `
            -RatingsPath $RatingsPath -JournalPath $JournalPath
        [void]$entries.Add([ordered]@{
            capability = $p.capability
            candidate  = $p.candidate
            n          = [int]$p.n
            good       = [int]$p.good
            bad        = [int]$p.bad
            sources    = $p.sources
            quality    = [double]$detail.quality
            prior      = [double]$detail.prior
        })
    }

    return @{
        ratings_path = $RatingsPath
        total        = $rows.Count
        pairs        = @($entries.ToArray())
        observe_on   = (Test-RoutingObserveEnabled)
    }
}
