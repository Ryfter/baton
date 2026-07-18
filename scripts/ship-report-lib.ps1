#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Per-PR ship report (slice 1) — pure aggregation over fleet journal, usage journal,
  run-dir decisions, git, and gh. No new instrumentation.
.DESCRIPTION
  Assembles a Build/Review/Fix/Verification/Wall-clock/Conductor/Outcome card for one
  shipped (or in-flight) PR. Token bases exact vs estimate are never summed silently
  (d059). PR-comment post is the caller's concern (observe-first, d078).
  See docs/superpowers/specs/2026-07-16-ship-report-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"

# Injectable invokers so hermetic tests never call real git/gh.
$script:ShipReportGitInvoker = $null   # scriptblock(RepoRoot, GitArgs[]) -> string[]
$script:ShipReportGhInvoker  = $null   # scriptblock(GhArgs[]) -> string[]

function Invoke-ShipReportGit {
    <# Thin git wrapper. Override $script:ShipReportGitInvoker in tests. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$GitArgs
    )
    if ($script:ShipReportGitInvoker) {
        return @(& $script:ShipReportGitInvoker $RepoRoot $GitArgs)
    }
    if (-not (Test-Path -LiteralPath $RepoRoot)) {
        throw "ship-report git: repo root not found: $RepoRoot"
    }
    $prev = Get-Location
    try {
        Set-Location -LiteralPath $RepoRoot
        $out = & git @GitArgs 2>&1
        $code = $LASTEXITCODE
        $lines = @($out | ForEach-Object { "$_" })
        if ($code -ne 0) {
            throw "ship-report git failed (exit $code): $($GitArgs -join ' ') :: $($lines -join ' ')"
        }
        return $lines
    } finally {
        Set-Location $prev
    }
}

function Invoke-ShipReportGh {
    <# Thin gh wrapper. Override $script:ShipReportGhInvoker in tests. #>
    param([Parameter(Mandatory)][string[]]$GhArgs)
    if ($script:ShipReportGhInvoker) {
        return @(& $script:ShipReportGhInvoker $GhArgs)
    }
    $out = & gh @GhArgs 2>&1
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw "ship-report gh failed (exit $code): $($GhArgs -join ' ') :: $($lines -join ' ')"
    }
    return $lines
}

function ConvertTo-ShipReportDateTime {
    <# Parse ISO-8601 (with or without offset) to UTC DateTime; junk -> $null. #>
    param([string]$Ts)
    if ([string]::IsNullOrWhiteSpace($Ts)) { return $null }
    try {
        return ([datetimeoffset]::Parse(
            $Ts.Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )).UtcDateTime
    } catch { return $null }
}

function ConvertTo-ShipReportUtc {
    <# Normalize a DateTime/DateTimeOffset/string to UTC DateTime, or $null. #>
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Utc) { return $Value }
        if ($Value.Kind -eq [System.DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        # Unspecified: treat as already-UTC instant (callers parse ISO with Z/offset first).
        return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
    }
    return (ConvertTo-ShipReportDateTime -Ts ([string]$Value))
}

function Format-ShipReportDuration {
    <# Human wall-clock: "~2.5h", "~45m", "~3d 2h". Invariant culture. #>
    param($From, $To)
    $fromUtc = ConvertTo-ShipReportUtc -Value $From
    $toUtc = ConvertTo-ShipReportUtc -Value $To
    if (-not $fromUtc -or -not $toUtc) { return 'n/a' }
    $span = $toUtc - $fromUtc
    if ($span.TotalSeconds -lt 0) { $span = -$span }
    if ($span.TotalSeconds -lt 60) { return '~<1m' }
    if ($span.TotalHours -lt 1) {
        return ('~{0}m' -f [int][math]::Round($span.TotalMinutes))
    }
    if ($span.TotalHours -lt 48) {
        $h = [math]::Round($span.TotalHours, 1)
        if ([math]::Abs($h - [math]::Round($h)) -lt 0.05) {
            return ('~{0}h' -f [int][math]::Round($h))
        }
        return ('~{0}h' -f $h.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))
    }
    $days = [int][math]::Floor($span.TotalDays)
    $hours = [int][math]::Round($span.TotalHours - ($days * 24))
    if ($hours -le 0) { return ('~{0}d' -f $days) }
    return ('~{0}d {1}h' -f $days, $hours)
}

function Format-ShipReportTokenCount {
    <# Compact token display: 1234, 25k, 439k. #>
    param([long]$Tokens)
    if ($Tokens -lt 0) { $Tokens = 0 }
    if ($Tokens -ge 1000) {
        $k = [math]::Round($Tokens / 1000.0, 0)
        if ($k -ge 10) { return ('{0}k' -f [int]$k) }
        $k1 = [math]::Round($Tokens / 1000.0, 1)
        if (($k1 % 1) -eq 0) { return ('{0}k' -f [int]$k1) }
        return ('{0}k' -f $k1)
    }
    return "$Tokens"
}

function Get-ShipReportConfirmedRate {
    <# findings_confirmed / findings_total. Zero denom or missing -> 'n/a'. Never divides. #>
    param(
        $FindingsTotal,
        $FindingsConfirmed
    )
    if ($null -eq $FindingsTotal -or $null -eq $FindingsConfirmed) { return 'n/a' }
    $total = 0
    $confirmed = 0
    if (-not [int]::TryParse([string]$FindingsTotal, [ref]$total)) { return 'n/a' }
    if (-not [int]::TryParse([string]$FindingsConfirmed, [ref]$confirmed)) { return 'n/a' }
    if ($total -le 0) { return 'n/a' }
    if ($confirmed -lt 0) { $confirmed = 0 }
    return [math]::Round(([double]$confirmed / [double]$total), 4)
}

function Parse-FleetJournalLine {
    <# Derive structured row from Write-FleetJournalLine format (fleet-lib.ps1).
       Fields: ts | fleet | provider | Ns | exit:N | "summary" | host:X
               [| job:…] [| phase:…] [| tier:…] | tok:N(exact|estimate) #>
    param([Parameter(Mandatory)][string]$Line)
    $trim = $Line.Trim()
    if ([string]::IsNullOrWhiteSpace($trim) -or $trim.StartsWith('#')) { return $null }
    $fields = @($trim -split '\s*\|\s*')
    if ($fields.Count -lt 6) { return $null }
    if ($fields[1] -ne 'fleet') { return $null }

    $ts = ConvertTo-ShipReportDateTime -Ts $fields[0]
    $provider = [string]$fields[2]
    $durationS = 0
    if ($fields[3] -match '^(\d+)s$') { $durationS = [int]$Matches[1] }
    $exitCode = 0
    if ($fields[4] -match '^exit:(-?\d+)$') { $exitCode = [int]$Matches[1] }

    $summary = [string]$fields[5]
    if ($summary.StartsWith('"') -and $summary.EndsWith('"') -and $summary.Length -ge 2) {
        $summary = $summary.Substring(1, $summary.Length - 2)
    }

    $hostName = ''
    $job = ''
    $phase = ''
    $tier = ''
    $tokens = [long]0
    $tokensBasis = 'estimate'

    for ($i = 6; $i -lt $fields.Count; $i++) {
        $f = [string]$fields[$i]
        if ($f -match '^host:(.+)$') { $hostName = $Matches[1]; continue }
        if ($f -match '^job:(.+)$') { $job = $Matches[1]; continue }
        if ($f -match '^phase:(.+)$') { $phase = $Matches[1]; continue }
        if ($f -match '^tier:(.+)$') { $tier = $Matches[1]; continue }
        if ($f -match '^tok:(\d+)\((exact|estimate)\)$') {
            $tokens = [long]$Matches[1]
            $tokensBasis = $Matches[2]
            continue
        }
    }

    return [ordered]@{
        ts           = $ts
        kind         = 'fleet'
        provider     = $provider
        duration_s   = $durationS
        exit_code    = $exitCode
        summary      = $summary
        host         = $hostName
        job          = $job
        phase        = $phase
        tier         = $tier
        tokens       = $tokens
        tokens_basis = $tokensBasis
        raw          = $trim
    }
}

function Read-FleetJournalRows {
    <# Read model-routing-log.md fleet lines into structured rows. Missing -> @(). #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $rows = foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $parsed = Parse-FleetJournalLine -Line $line
        if ($null -ne $parsed) { $parsed }
    }
    return @($rows)
}

function Get-ShipReportStage {
    <# Classify a fleet row into build|review|fix|verification.
       Summary text is the REAL signal: fix and verification have no phase in the
       real model (job-lib LinearPhases = research|design|code.sprint-N|review), so
       Write-FleetJournalLine never emits phase:fix / phase:verification. Match the
       summary MOST-SPECIFIC-FIRST (fix, verification, review, build) with anchored
       keywords so shared tokens ('findings', 'test') don't collide. Phase tags are a
       SECONDARY hint mapped to the real vocabulary (review -> review;
       code.sprint-N / research / design -> build). Default build. #>
    param($Row)
    $sum = ([string]$Row.summary).ToLowerInvariant()
    if ($sum) {
        # fix before review: "fix pass ... review findings" must land on fix.
        if ($sum -match '\b(fix[- ]?pass|polish|repair finding|address(?:es|ing)? findings?)\b') { return 'fix' }
        if ($sum -match '\b(verification|verif|acceptance.?gate|pytest|test suite|full local gate)\b') { return 'verification' }
        if ($sum -match '\b(review|lens|adversarial|findings?|verdict)\b') { return 'review' }
        if ($sum -match '\b(build|implement|implementation|sprint|scaffold)\b') { return 'build' }
    }
    # Secondary hint: REAL phase vocabulary only (no fictional fix/verification phases).
    $phase = ([string]$Row.phase).ToLowerInvariant()
    if ($phase) {
        if ($phase -match 'review') { return 'review' }
        if ($phase -match 'code|sprint|research|design|build|implement') { return 'build' }
    }
    return 'build'
}

function Select-FleetRowsInWindow {
    <# Keep rows whose ts falls in [From, To] inclusive. Null bounds = open. #>
    param(
        [object[]]$Rows = @(),
        $From,
        $To
    )
    $fromUtc = ConvertTo-ShipReportUtc -Value $From
    $toUtc = ConvertTo-ShipReportUtc -Value $To
    $out = foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $ts = ConvertTo-ShipReportUtc -Value $r.ts
        if ($null -eq $ts) { continue }
        if ($fromUtc -and $ts -lt $fromUtc) { continue }
        if ($toUtc -and $ts -gt $toUtc) { continue }
        $r
    }
    return @($out)
}

function Fold-ShipReportTokens {
    <# Per-provider token fold that NEVER mixes exact+estimate.
       Returns @{ by_provider = @[{provider; exact; estimate}]; exact_total; estimate_total }. #>
    param([object[]]$Rows = @())
    $map = [ordered]@{}
    $exactTotal = [long]0
    $estimateTotal = [long]0
    foreach ($r in @($Rows)) {
        $prov = [string]$r.provider
        if ([string]::IsNullOrWhiteSpace($prov)) { continue }
        if (-not $map.Contains($prov)) {
            $map[$prov] = @{ provider = $prov; exact = [long]0; estimate = [long]0 }
        }
        $tok = [long]$r.tokens
        if ($tok -lt 0) { $tok = 0 }
        $basis = [string]$r.tokens_basis
        if ($basis -eq 'exact') {
            $map[$prov].exact += $tok
            $exactTotal += $tok
        } else {
            $map[$prov].estimate += $tok
            $estimateTotal += $tok
        }
    }
    $byProv = @($map.Values | ForEach-Object {
        [ordered]@{
            provider = $_.provider
            exact    = [long]$_.exact
            estimate = [long]$_.estimate
        }
    })
    return [ordered]@{
        by_provider    = @($byProv)
        exact_total    = $exactTotal
        estimate_total = $estimateTotal
    }
}

function Format-ShipReportTokenFold {
    <# "worker-a 1234 tok (exact), worker-b 500 tok (estimate)" — both bases if mixed. #>
    param($Fold)
    if ($null -eq $Fold) { return 'n/a' }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($Fold.by_provider)) {
        $name = [string]$p.provider
        if ([long]$p.exact -gt 0) {
            $tokLabel = Format-ShipReportTokenCount -Tokens ([long]$p.exact)
            $parts.Add("$name $tokLabel tok (exact)")
        }
        if ([long]$p.estimate -gt 0) {
            $tokLabel = Format-ShipReportTokenCount -Tokens ([long]$p.estimate)
            $parts.Add("$name $tokLabel tok (estimate)")
        }
        if ([long]$p.exact -eq 0 -and [long]$p.estimate -eq 0) {
            $parts.Add("$name 0 tok")
        }
    }
    if ($parts.Count -eq 0) { return 'n/a' }
    return ($parts -join ', ')
}

function Read-UsageJournalRows {
    <# JSONL usage journal (same shape as usage-lib Read-UsageJournal). Missing -> @(). #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Get-ShipReportCapDeaths {
    <# Count DISTINCT cap-deaths in window for workers seen in fleet rows.
       A real cap-death emits a `lockout` event AND a matching `failover` event
       (Add-UsageFailoverEvent, worker=original_worker) — the failover is the
       RECOVERY of that lockout, not a second death. Counting both double-counts,
       so count `lockout` events only. #>
    param(
        [object[]]$UsageRows = @(),
        [object[]]$FleetRows = @(),
        $From,
        $To
    )
    $fromUtc = ConvertTo-ShipReportUtc -Value $From
    $toUtc = ConvertTo-ShipReportUtc -Value $To
    $workers = @{}
    foreach ($r in @($FleetRows)) {
        $w = [string]$r.provider
        if ($w) { $workers[$w] = $true }
    }
    $count = 0
    $events = [System.Collections.ArrayList]@()
    foreach ($u in @($UsageRows)) {
        $kind = [string]$u.event
        if ($kind -ne 'lockout') { continue }
        $worker = [string]$u.worker
        if (-not $worker) { $worker = [string]$u.original_worker }
        if ($workers.Count -gt 0 -and $worker -and -not $workers.ContainsKey($worker)) { continue }
        $ts = ConvertTo-ShipReportUtc -Value ([string]$u.ts)
        if ($fromUtc -and $ts -and $ts -lt $fromUtc) { continue }
        if ($toUtc -and $ts -and $ts -gt $toUtc) { continue }
        $count++
        [void]$events.Add([ordered]@{
            ts     = $ts
            event  = $kind
            worker = $worker
        })
    }
    return [ordered]@{ count = $count; events = @($events.ToArray()) }
}

function Read-RunDecisions {
    <# Parse run-dir decisions.jsonl. Missing/malformed lines skipped. #>
    param([string]$RunDir)
    if ([string]::IsNullOrWhiteSpace($RunDir)) { return @() }
    $path = Join-Path $RunDir 'decisions.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Read-RunEffectiveCost {
    <# Optional effective-cost.json from the run dir. #>
    param([string]$RunDir)
    if ([string]::IsNullOrWhiteSpace($RunDir)) { return $null }
    $path = Join-Path $RunDir 'effective-cost.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Parse-ReviewRecordText {
    <# Extract VERDICT / FINDINGS-COUNT / CONFIRMED-COUNT from conductor review text.
       Absent lines stay $null (render as n/a); never guessed. #>
    param([string]$Text)
    $result = [ordered]@{
        verdict            = $null
        findings_count     = $null
        confirmed_count    = $null
        has_verdict_line   = $false
        has_findings_line  = $false
        has_confirmed_line = $false
    }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -match '(?i)^VERDICT\s*:\s*(.+)$') {
            $result.verdict = $Matches[1].Trim()
            $result.has_verdict_line = $true
            continue
        }
        # Also accept bare "VERDICT SHIP-AS-IS" style
        if ($t -match '(?i)^VERDICT\s+(SHIP-AS-IS|SHIP-WITH-TWEAKS|DO-NOT-SHIP)\b') {
            $result.verdict = $Matches[1].Trim()
            $result.has_verdict_line = $true
            continue
        }
        if ($t -match '(?i)^FINDINGS-COUNT\s*:\s*(\d+)\s*$') {
            $result.findings_count = [int]$Matches[1]
            $result.has_findings_line = $true
            continue
        }
        if ($t -match '(?i)^CONFIRMED-COUNT\s*:\s*(\d+)\s*$') {
            $result.confirmed_count = [int]$Matches[1]
            $result.has_confirmed_line = $true
            continue
        }
    }
    return $result
}

function Merge-ReviewRecords {
    <# Fold multiple review-record parses into totals. Missing confirmed stays null. #>
    param([object[]]$Records = @())
    $findings = 0
    $confirmed = 0
    $hasFindings = $false
    $hasConfirmed = $false
    $verdicts = [System.Collections.Generic.List[string]]::new()
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        if ($r.has_verdict_line -and $r.verdict) { $verdicts.Add([string]$r.verdict) }
        if ($r.has_findings_line -and $null -ne $r.findings_count) {
            $findings += [int]$r.findings_count
            $hasFindings = $true
        }
        if ($r.has_confirmed_line -and $null -ne $r.confirmed_count) {
            $confirmed += [int]$r.confirmed_count
            $hasConfirmed = $true
        }
    }
    return [ordered]@{
        verdicts         = @($verdicts)
        findings_count   = $(if ($hasFindings) { $findings } else { $null })
        confirmed_count  = $(if ($hasConfirmed) { $confirmed } else { $null })
        confirmed_rate   = (Get-ShipReportConfirmedRate `
            -FindingsTotal $(if ($hasFindings) { $findings } else { $null }) `
            -FindingsConfirmed $(if ($hasConfirmed) { $confirmed } else { $null }))
    }
}

function Get-ShipReportPrMeta {
    <# Resolve PR metadata via gh. Returns ordered dict; throws on hard failure. #>
    param(
        [int]$PrNumber,
        [string]$Repo = ''
    )
    if ($PrNumber -le 0) { throw "ship-report: PR number must be > 0" }
    $ghArgs = [System.Collections.Generic.List[string]]::new()
    $ghArgs.Add('pr'); $ghArgs.Add('view'); $ghArgs.Add("$PrNumber")
    if ($Repo) { $ghArgs.Add('--repo'); $ghArgs.Add($Repo) }
    $ghArgs.Add('--json')
    $ghArgs.Add('number,title,state,headRefName,baseRefName,mergedAt,mergeCommit,url,closingIssuesReferences,commits,comments,body')
    $raw = (Invoke-ShipReportGh -GhArgs @($ghArgs.ToArray())) -join "`n"
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop

    $mergeSha = $null
    if ($obj.mergeCommit -and $obj.mergeCommit.oid) { $mergeSha = [string]$obj.mergeCommit.oid }
    elseif ($obj.mergeCommit -is [string]) { $mergeSha = [string]$obj.mergeCommit }

    $linked = $null
    $refs = @($obj.closingIssuesReferences)
    if ($refs.Count -gt 0 -and $refs[0].number) { $linked = [int]$refs[0].number }

    $commentBodies = @()
    foreach ($c in @($obj.comments)) {
        if ($c.body) { $commentBodies += [string]$c.body }
    }

    $commitCount = @($obj.commits).Count
    $firstCommitAt = $null
    foreach ($c in @($obj.commits)) {
        $ct = $null
        if ($c.committedDate) { $ct = ConvertTo-ShipReportDateTime -Ts ([string]$c.committedDate) }
        elseif ($c.authoredDate) { $ct = ConvertTo-ShipReportDateTime -Ts ([string]$c.authoredDate) }
        if ($ct -and (-not $firstCommitAt -or $ct -lt $firstCommitAt)) { $firstCommitAt = $ct }
    }

    $mergedAt = ConvertTo-ShipReportDateTime -Ts ([string]$obj.mergedAt)

    return [ordered]@{
        pr_number       = [int]$obj.number
        title           = [string]$obj.title
        state           = [string]$obj.state
        branch          = [string]$obj.headRefName
        base_branch     = [string]$obj.baseRefName
        merged_at       = $mergedAt
        merge_sha       = $mergeSha
        url             = [string]$obj.url
        linked_issue    = $linked
        commit_count    = $commitCount
        first_commit_at = $firstCommitAt
        comment_bodies  = @($commentBodies)
        body            = [string]$obj.body
    }
}

function Get-ShipReportGitBranchStats {
    <# Commits + first/last timestamps on a branch vs base (default master). #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [string]$Base = 'master'
    )
    $range = "{0}..{1}" -f $Base, $Branch
    $lines = @()
    try {
        $lines = @(Invoke-ShipReportGit -RepoRoot $RepoRoot -GitArgs @('log', $range, '--format=%H%x09%cI%x09%s'))
    } catch {
        # Branch may only exist as remote or commits may be on the branch tip alone.
        try {
            $lines = @(Invoke-ShipReportGit -RepoRoot $RepoRoot -GitArgs @('log', $Branch, '--format=%H%x09%cI%x09%s', '--not', $Base))
        } catch {
            $lines = @()
        }
    }
    $commits = [System.Collections.ArrayList]@()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 2) { continue }
        $ts = ConvertTo-ShipReportDateTime -Ts $parts[1]
        [void]$commits.Add([ordered]@{
            sha     = $parts[0]
            ts      = $ts
            subject = $(if ($parts.Count -ge 3) { $parts[2] } else { '' })
        })
    }
    $first = $null
    $last = $null
    foreach ($c in $commits) {
        if ($c.ts -and (-not $first -or $c.ts -lt $first)) { $first = $c.ts }
        if ($c.ts -and (-not $last -or $c.ts -gt $last)) { $last = $c.ts }
    }
    return [ordered]@{
        commit_count    = $commits.Count
        commits         = @($commits.ToArray())
        first_commit_at = $first
        last_commit_at  = $last
        branch          = $Branch
        base            = $Base
    }
}

function Get-ShipReportDepthLabel {
    <# Map decisions.jsonl depth_tier values to a short review label. #>
    param([object[]]$Decisions = @())
    $tiers = @()
    foreach ($d in @($Decisions)) {
        $t = [string]$d.depth_tier
        if ($t) { $tiers += $t.ToLowerInvariant() }
    }
    if ($tiers -contains 'high') { return 'deep' }
    if ($tiers -contains 'med') { return 'med' }
    if ($tiers -contains 'low') { return 'low' }
    return $null
}

function Format-ShipReportFindingsBit {
    <# "8 findings / 8 confirmed" or "8 findings / n/a confirmed" or "n/a". #>
    param($FindingsCount, $ConfirmedCount)
    if ($null -eq $FindingsCount) { return 'n/a' }
    $conf = if ($null -eq $ConfirmedCount) { 'n/a' } else { "$ConfirmedCount" }
    return ('{0} findings / {1} confirmed' -f $FindingsCount, $conf)
}

function Build-ShipReportCard {
    <# Fold journals + git/gh meta into one ship-report card (ordered dict). #>
    param(
        [object[]]$FleetRows = @(),
        [object[]]$UsageRows = @(),
        [object[]]$Decisions = @(),
        $PrMeta,
        $GitStats,
        $EffectiveCost,
        [string]$RunId = '',
        $WindowFrom,
        $WindowTo
    )

    # Resolve window from PR/git meta when not explicit. Always normalize to UTC.
    $from = ConvertTo-ShipReportUtc -Value $WindowFrom
    $to = ConvertTo-ShipReportUtc -Value $WindowTo
    if (-not $from) {
        if ($GitStats -and $GitStats.first_commit_at) { $from = ConvertTo-ShipReportUtc -Value $GitStats.first_commit_at }
        elseif ($PrMeta -and $PrMeta.first_commit_at) { $from = ConvertTo-ShipReportUtc -Value $PrMeta.first_commit_at }
    }
    if (-not $to) {
        if ($PrMeta -and $PrMeta.merged_at) { $to = ConvertTo-ShipReportUtc -Value $PrMeta.merged_at }
        elseif ($GitStats -and $GitStats.last_commit_at) { $to = ConvertTo-ShipReportUtc -Value $GitStats.last_commit_at }
    }

    $windowed = Select-FleetRowsInWindow -Rows $FleetRows -From $from -To $to
    if (@($windowed).Count -eq 0 -and @($FleetRows).Count -gt 0 -and -not $from -and -not $to) {
        $windowed = @($FleetRows)
    }

    $byStage = @{
        build        = [System.Collections.ArrayList]@()
        review       = [System.Collections.ArrayList]@()
        fix          = [System.Collections.ArrayList]@()
        verification = [System.Collections.ArrayList]@()
    }
    foreach ($r in @($windowed)) {
        $stage = Get-ShipReportStage -Row $r
        if (-not $byStage.ContainsKey($stage)) { $stage = 'build' }
        [void]$byStage[$stage].Add($r)
    }

    $buildFold = Fold-ShipReportTokens -Rows @($byStage.build)
    $reviewFold = Fold-ShipReportTokens -Rows @($byStage.review)
    $fixFold = Fold-ShipReportTokens -Rows @($byStage.fix)
    $verifyFold = Fold-ShipReportTokens -Rows @($byStage.verification)
    $allFold = Fold-ShipReportTokens -Rows @($windowed)

    $cap = Get-ShipReportCapDeaths -UsageRows $UsageRows -FleetRows $windowed -From $from -To $to

    $reviewTexts = @()
    if ($PrMeta -and $PrMeta.comment_bodies) { $reviewTexts = @($PrMeta.comment_bodies) }
    $parsedReviews = @($reviewTexts | ForEach-Object { Parse-ReviewRecordText -Text $_ })
    $reviewAgg = Merge-ReviewRecords -Records $parsedReviews

    $depthLabel = Get-ShipReportDepthLabel -Decisions $Decisions

    # --- dimension strings ---
    $buildParts = [System.Collections.Generic.List[string]]::new()
    $buildTok = Format-ShipReportTokenFold -Fold $buildFold
    if ($buildTok -ne 'n/a') { $buildParts.Add($buildTok) }
    if ([int]$cap.count -gt 0) {
        if ([int]$cap.count -eq 1) {
            $buildParts.Add('1 cap-death recovery')
        } else {
            $buildParts.Add("$([int]$cap.count) cap-death recoveries")
        }
    }
    $commitCount = 0
    if ($GitStats -and $null -ne $GitStats.commit_count) { $commitCount = [int]$GitStats.commit_count }
    elseif ($PrMeta -and $null -ne $PrMeta.commit_count) { $commitCount = [int]$PrMeta.commit_count }
    if ($commitCount -gt 0) {
        $commitLabel = if ($commitCount -eq 1) { '1 commit' } else { "$commitCount commits" }
        $buildParts.Add($commitLabel)
    }
    $buildText = if ($buildParts.Count -gt 0) { $buildParts -join ', ' } else { 'n/a' }

    $reviewParts = [System.Collections.Generic.List[string]]::new()
    if ($depthLabel) { $reviewParts.Add("${depthLabel}:") }
    $reviewTok = Format-ShipReportTokenFold -Fold $reviewFold
    if ($reviewTok -ne 'n/a') { $reviewParts.Add($reviewTok) }
    $findingsBit = Format-ShipReportFindingsBit -FindingsCount $reviewAgg.findings_count -ConfirmedCount $reviewAgg.confirmed_count
    if ($findingsBit -ne 'n/a') { $reviewParts.Add($findingsBit) }
    elseif (@($reviewAgg.verdicts).Count -gt 0) {
        $verdictJoin = $reviewAgg.verdicts -join ', '
        $reviewParts.Add("verdict $verdictJoin")
    }
    $reviewText = if ($reviewParts.Count -gt 0) { ($reviewParts -join ' ').Trim() } else { 'n/a' }

    $fixParts = [System.Collections.Generic.List[string]]::new()
    $fixTok = Format-ShipReportTokenFold -Fold $fixFold
    if ($fixTok -ne 'n/a') { $fixParts.Add($fixTok) }
    $fixCommits = @($byStage.fix).Count
    # Prefer git subject heuristic for fix commits when available
    $fixCommitCount = 0
    if ($GitStats -and $GitStats.commits) {
        $fixCommitCount = @($GitStats.commits | Where-Object {
            ([string]$_.subject) -match '(?i)\b(fix|polish|address)\b'
        }).Count
    }
    if ($fixCommitCount -gt 0) {
        $fixCommitLabel = if ($fixCommitCount -eq 1) { '1 commit' } else { "$fixCommitCount commits" }
        $fixParts.Add($fixCommitLabel)
    } elseif ($fixCommits -gt 0 -and $fixTok -ne 'n/a') {
        # leave commit count off if we only have dispatch rows
    }
    $fixText = if ($fixParts.Count -gt 0) { $fixParts -join ', ' } else { 'n/a' }

    $verifyParts = [System.Collections.Generic.List[string]]::new()
    $vCount = @($byStage.verification).Count
    if ($vCount -gt 0) {
        $vLabel = if ($vCount -eq 1) { '1 verification dispatch' } else { "$vCount verification dispatches" }
        $verifyParts.Add($vLabel)
    }
    $verifyTok = Format-ShipReportTokenFold -Fold $verifyFold
    if ($verifyTok -ne 'n/a') { $verifyParts.Add($verifyTok) }
    $verifyText = if ($verifyParts.Count -gt 0) { $verifyParts -join ', ' } else { 'n/a' }

    $wallText = Format-ShipReportDuration -From $from -To $to
    if ($wallText -ne 'n/a') { $wallText = "$wallText dispatch→merge" }

    $mergeSha = $null
    if ($PrMeta -and $PrMeta.merge_sha) { $mergeSha = $PrMeta.merge_sha }
    $shortSha = if ($mergeSha -and $mergeSha.Length -ge 7) { $mergeSha.Substring(0, 7) } elseif ($mergeSha) { $mergeSha } else { $null }
    $state = if ($PrMeta) { [string]$PrMeta.state } else { '' }
    $outcomeParts = [System.Collections.Generic.List[string]]::new()
    if ($shortSha -and ($state -eq 'MERGED' -or $PrMeta.merged_at)) {
        $outcomeParts.Add("merged ``$shortSha``")
    } elseif ($state) {
        $outcomeParts.Add($state.ToLowerInvariant())
    } else {
        $outcomeParts.Add('n/a')
    }
    $outcomeParts.Add('post-merge defects: (fills in later)')
    $outcomeText = $outcomeParts -join '; '

    $prNumber = if ($PrMeta) { $PrMeta.pr_number } else { $null }
    $branch = if ($PrMeta -and $PrMeta.branch) { $PrMeta.branch } elseif ($GitStats) { $GitStats.branch } else { $null }
    $linked = if ($PrMeta) { $PrMeta.linked_issue } else { $null }

    $card = [ordered]@{
        schema_version       = 1
        pr_number            = $prNumber
        branch               = $branch
        run_id               = $RunId
        merge_sha            = $mergeSha
        linked_issue         = $linked
        window_from          = if ($from) { $from.ToString('o') } else { $null }
        window_to            = if ($to) { $to.ToString('o') } else { $null }
        dimensions           = [ordered]@{
            build               = $buildText
            review              = $reviewText
            fix                 = $fixText
            verification        = $verifyText
            wall_clock          = $wallText
            conductor_overhead  = 'not tracked'
            outcome             = $outcomeText
        }
        tokens               = [ordered]@{
            exact_total    = [long]$allFold.exact_total
            estimate_total = [long]$allFold.estimate_total
            by_stage       = [ordered]@{
                build        = $buildFold
                review       = $reviewFold
                fix          = $fixFold
                verification = $verifyFold
            }
        }
        review               = [ordered]@{
            verdicts        = @($reviewAgg.verdicts)
            findings_count  = $reviewAgg.findings_count
            confirmed_count = $reviewAgg.confirmed_count
            confirmed_rate  = $reviewAgg.confirmed_rate
            depth_label     = $depthLabel
        }
        cap_deaths           = [int]$cap.count
        commit_count         = $commitCount
        wall_clock_seconds   = $(
            if ($from -and $to) { [int][math]::Max(0, ($to - $from).TotalSeconds) } else { $null }
        )
        effective_cost       = $EffectiveCost
        decisions_count      = @($Decisions).Count
    }
    return $card
}

function Format-ShipReportCard {
    <# Markdown table for one card (spec §1 example shape). #>
    param([Parameter(Mandatory)]$Card)
    $sb = [System.Text.StringBuilder]::new()
    $titleBits = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Card.pr_number) { $titleBits.Add("PR #$($Card.pr_number)") }
    if ($Card.branch) { $titleBits.Add([string]$Card.branch) }
    if ($Card.run_id) { $titleBits.Add([string]$Card.run_id) }
    $heading = if ($titleBits.Count -gt 0) { ($titleBits -join ' · ') } else { 'ship report' }
    [void]$sb.AppendLine("# Ship report — $heading")
    [void]$sb.AppendLine('')
    if ($null -ne $Card.linked_issue) {
        [void]$sb.AppendLine(('Linked issue: #{0}' -f $Card.linked_issue))
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('| Dimension | Value |')
    [void]$sb.AppendLine('|---|---|')
    $dims = $Card.dimensions
    # Escape '|' in VALUE cells so verdict/summary text can't break the table row
    # (same treatment Format-ShipReportTrendTable applies to its own cells).
    $esc = { param($v) ([string]$v) -replace '\|', '/' }
    [void]$sb.AppendLine(('| Build | {0} |' -f (& $esc $dims.build)))
    [void]$sb.AppendLine(('| Review | {0} |' -f (& $esc $dims.review)))
    [void]$sb.AppendLine(('| Fix passes | {0} |' -f (& $esc $dims.fix)))
    [void]$sb.AppendLine(('| Verification | {0} |' -f (& $esc $dims.verification)))
    [void]$sb.AppendLine(('| Wall-clock | {0} |' -f (& $esc $dims.wall_clock)))
    [void]$sb.AppendLine(('| Conductor overhead | {0} |' -f (& $esc $dims.conductor_overhead)))
    [void]$sb.AppendLine(('| Outcome | {0} |' -f (& $esc $dims.outcome)))
    [void]$sb.AppendLine('')
    # Honesty note for mixed token bases (d059)
    $ex = [long]$Card.tokens.exact_total
    $est = [long]$Card.tokens.estimate_total
    if ($ex -gt 0 -and $est -gt 0) {
        $exLabel = Format-ShipReportTokenCount -Tokens $ex
        $estLabel = Format-ShipReportTokenCount -Tokens $est
        [void]$sb.AppendLine("> Token bases not combined: $exLabel exact + $estLabel estimate (d059).")
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd() + "`n"
}

function Format-ShipReportTrendTable {
    <# --all markdown: one row per card (cost, confirmed-rate, wall-clock). #>
    param([object[]]$Cards = @())
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Ship-report trend')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| PR | Branch | Tokens (exact) | Tokens (estimate) | Confirmed rate | Wall-clock | Outcome |')
    [void]$sb.AppendLine('|---|---|---:|---:|---:|---|---|')
    $sorted = @($Cards) | Sort-Object {
        if ($null -ne $_.pr_number) { [int]$_.pr_number } else { 0 }
    }
    if (@($sorted).Count -eq 0) {
        [void]$sb.AppendLine('| _(none)_ | | | | | | |')
        [void]$sb.AppendLine('')
        return $sb.ToString().TrimEnd() + "`n"
    }
    foreach ($c in $sorted) {
        $pr = if ($null -ne $c.pr_number) { "#{0}" -f $c.pr_number } else { 'n/a' }
        $br = if ($c.branch) { $c.branch } else { 'n/a' }
        $ex = [long]$c.tokens.exact_total
        $est = [long]$c.tokens.estimate_total
        $rate = $c.review.confirmed_rate
        if ($null -eq $rate) { $rate = 'n/a' }
        $wall = if ($c.dimensions) { $c.dimensions.wall_clock } else { 'n/a' }
        $out = if ($c.dimensions) { $c.dimensions.outcome } else { 'n/a' }
        # Escape pipes in cells
        $wall = ([string]$wall) -replace '\|', '/'
        $out = ([string]$out) -replace '\|', '/'
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
            $pr, $br, $ex, $est, $rate, $wall, $out))
    }
    [void]$sb.AppendLine('')
    return $sb.ToString().TrimEnd() + "`n"
}

function Write-ShipReportToRunDir {
    <# Write ship-report.md + ship-report.json under the run dir. Returns paths. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)]$Card,
        [string]$Markdown
    )
    if (-not (Test-Path -LiteralPath $RunDir)) {
        New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    }
    if (-not $Markdown) { $Markdown = Format-ShipReportCard -Card $Card }
    $mdPath = Join-Path $RunDir 'ship-report.md'
    $jsonPath = Join-Path $RunDir 'ship-report.json'
    Set-Content -LiteralPath $mdPath -Value $Markdown -Encoding utf8NoBOM
    $json = ConvertTo-Json -InputObject $Card -Depth 10
    Set-Content -LiteralPath $jsonPath -Value $json -Encoding utf8NoBOM
    return [ordered]@{ md = $mdPath; json = $jsonPath }
}

function Read-ShipReportCardsFromRuns {
    <# Load previously written ship-report.json files under a runs root. #>
    param([string]$RunsRoot)
    if ([string]::IsNullOrWhiteSpace($RunsRoot) -or -not (Test-Path -LiteralPath $RunsRoot)) {
        return @()
    }
    $files = @(Get-ChildItem -Path $RunsRoot -Filter 'ship-report.json' -Recurse -File -ErrorAction SilentlyContinue)
    $cards = foreach ($f in $files) {
        try {
            Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        } catch { continue }
    }
    return @($cards)
}

function Post-ShipReportPrComment {
    <# Post markdown as a PR comment via gh. No-op unless caller opts in. #>
    param(
        [Parameter(Mandatory)][int]$PrNumber,
        [Parameter(Mandatory)][string]$Body,
        [string]$Repo = ''
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ship-report-comment-{0}.md" -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $tmp -Value $Body -Encoding utf8NoBOM
        $ghArgs = [System.Collections.Generic.List[string]]::new()
        $ghArgs.Add('pr'); $ghArgs.Add('comment'); $ghArgs.Add("$PrNumber")
        if ($Repo) { $ghArgs.Add('--repo'); $ghArgs.Add($Repo) }
        $ghArgs.Add('--body-file'); $ghArgs.Add($tmp)
        $null = Invoke-ShipReportGh -GhArgs @($ghArgs.ToArray())
        return $true
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-ShipReportRunDir {
    <# Prefer explicit -RunDir; else runs/pr-<n>; else runs/<run-id>. #>
    param(
        [string]$RunDir,
        [string]$RunId,
        [int]$PrNumber,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($RunDir) { return $RunDir }
    $runsRoot = Join-Path $BatonHome 'runs'
    if ($RunId) { return (Join-Path $runsRoot $RunId) }
    if ($PrNumber -gt 0) { return (Join-Path $runsRoot ("pr-{0}" -f $PrNumber)) }
    return $null
}

function Get-ShipReportDefaults {
    <# Default journal paths under BATON_HOME. #>
    param([string]$BatonHome = (Get-BatonHome))
    return [ordered]@{
        baton_home     = $BatonHome
        fleet_journal  = Join-Path $BatonHome 'model-routing-log.md'
        usage_journal  = Join-Path $BatonHome 'usage-journal.jsonl'
        runs_root      = Join-Path $BatonHome 'runs'
    }
}
