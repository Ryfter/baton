#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Coordination Layer v1 — resource facet. Cross-process admission control for local
  model capacity (spec: docs/superpowers/specs/2026-08-02-coordination-layer-design.md §3).
.DESCRIPTION
  Library + store ONLY. Nothing here is wired into Select-Capability, the executor, or
  any dispatch path — that integration is a separate change.

  The problem: nothing stops two Baton runs from both deciding to load a large local
  model on the same box. This is the admission control that makes that impossible.

  Design rules that are load-bearing (do not "simplify" these away):
    * FAIL CLOSED. Store/lock/config unavailable, or any exception -> granted = $false.
      An exception must never become an implicit grant.
    * Declared capacity only (config.json). Absent or 0 VRAM means "I don't know",
      NOT "infinite" -> deny. Never probe NVML/CIM/WMI.
    * Stack exclusivity: one model server per box. A claim for stack A is denied while
      any live claim for a different stack exists on that host.
    * No preemption. Weight annotates a claim and orders nothing in v1.
    * Unknown process start-time -> TTL-only reclaim. Never early-steal a claim you
      cannot prove is dead; a wrong steal is worse than a slow reclaim.
    * One locking scheme only: the portable [System.IO.FileMode]::CreateNew file claim
      already shipped in window-service-lib.ps1 (Request-ProjectServiceClaim). No named
      mutex, no flock, no SQLite — that rejection is recorded in two specs.

  Naming hazard: $host and $pid are PowerShell automatic variables and this file is full
  of both concepts. Parameters are $HostName / $HolderPid throughout.
#>
. "$PSScriptRoot/baton-home.ps1"

$script:CoordSchema                 = 1
$script:CoordLockTtlSec             = 5     # admission lock is NOT the lease
$script:CoordClaimTtlSec            = 60    # lease default
$script:CoordDefaultWeight          = 100
$script:CoordSafetyFactor           = 0.90  # governor §: sum(distinct profiles) <= vram_gb * factor
$script:CoordLockPollMs             = 40
$script:CoordStartTimeToleranceSec  = 2
$script:CoordLockTimeoutTag         = 'coord-lock-timeout'

# Injectable process table so tests stay hermetic (spec §9: "fake process table").
# Contract: takes a pid, returns $null when the process is NOT running, otherwise a
# map with `started_at` (ISO-8601 UTC string, or $null when the OS won't tell us).
$script:CoordProcessProbe = $null

# ---------------------------------------------------------------------------
# Store layout
# ---------------------------------------------------------------------------

function Get-CoordinationRoot {
    <# $BATON_HOME/coordination — box-private, never the knowledge repo or a project
       tree. Creates the tree on demand; THROWS when it cannot, so every caller in the
       grant path fails closed instead of silently continuing. #>
    param([string]$BatonHome = (Get-BatonHome))
    $root = Join-Path $BatonHome 'coordination'
    $live = Join-Path $root 'live'
    $dirs = @(
        $root,
        (Join-Path $root 'locks'),
        $live,
        (Join-Path $live 'claims'),
        (Join-Path $root 'journal')
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null
        }
        # -Force can quietly no-op on some providers when a FILE sits at the path;
        # verify rather than trust, because "root exists" gates every grant.
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            throw "coordination store unavailable: not a directory: $d"
        }
    }
    return $root
}

function Get-CoordClaimsDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path (Join-Path (Get-CoordinationRoot -BatonHome $BatonHome) 'live') 'claims')
}

function Get-CoordClaimPath {
    param(
        [Parameter(Mandatory)][string]$ClaimId,
        [string]$BatonHome = (Get-BatonHome)
    )
    return (Join-Path (Get-CoordClaimsDir -BatonHome $BatonHome) ("{0}.json" -f $ClaimId))
}

function ConvertTo-CoordKeySegment {
    <# Lock/claim file names must be filesystem-safe AND unambiguous: '_' collapses to
       '-' so a host name can never forge the '__' separator and collide with a
       different (host, stack) key. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
    return ([regex]::Replace($Value, '[^A-Za-z0-9.-]', '-'))
}

function Get-CoordResourceLockKey {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$Stack
    )
    if ([string]::IsNullOrWhiteSpace($Stack)) {
        return ("admit__resource__{0}" -f (ConvertTo-CoordKeySegment $HostName))
    }
    return ("admit__resource__{0}__{1}" -f (ConvertTo-CoordKeySegment $HostName), (ConvertTo-CoordKeySegment $Stack))
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function ConvertTo-CoordTimeString {
    <# ConvertFrom-Json silently coerces ISO-8601 strings into [datetime] with Kind=Local.
       Casting that back with [string] yields a localized, sub-second-truncated form
       ("08/03/2026 04:50:03") which then re-parses as LOCAL time — a several-hour skew
       that would make live claims look expired and live locks look stealable. Every
       timestamp read out of JSON goes through here first. #>
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToUniversalTime().ToString('o') }
    return [string]$Value
}

function ConvertFrom-CoordTimestamp {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime]) { return ([datetimeoffset]([datetime]$Value).ToUniversalTime()) }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return [datetimeoffset]::Parse(
            $text,
            [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        return $null
    }
}

function Write-CoordFileAtomic {
    <# Rule: claim files are written temp + rename AFTER the decision, so a reader can
       never observe a half-written claim row. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    $tmp = Join-Path $dir ('.tmp-' + [guid]::NewGuid().ToString('n'))
    try {
        Set-Content -LiteralPath $tmp -Value $Content -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CoordJournalPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path (Join-Path (Get-CoordinationRoot -BatonHome $BatonHome) 'journal') 'coord.jsonl')
}

function Write-CoordJournalEntry {
    <# Append-only JSONL, LOCK-FREE by design (same discipline as usage-journal).
       Best-effort: a journal failure must never change an admission outcome. #>
    param(
        [Parameter(Mandatory)]$Entry,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $path = Get-CoordJournalPath -BatonHome $BatonHome
        $row = [ordered]@{ ts = [datetimeoffset]::UtcNow.ToString('o') }
        foreach ($k in $Entry.Keys) { $row[$k] = $Entry[$k] }
        $line = ($row | ConvertTo-Json -Compress -Depth 6) + "`n"
        [System.IO.File]::AppendAllText($path, $line, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        return $false
    }
}

function Get-CoordJournal {
    <# Readers skip malformed lines — a torn append must not blind the audit trail. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [int]$Tail = 0
    )
    $rows = [System.Collections.ArrayList]@()
    try {
        $path = Get-CoordJournalPath -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $path)) { return @() }
        foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { [void]$rows.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { continue }
        }
    } catch {
        return @()
    }
    $all = $rows.ToArray()
    if ($Tail -gt 0 -and $all.Count -gt $Tail) { return @($all[($all.Count - $Tail)..($all.Count - 1)]) }
    return @($all)
}

# ---------------------------------------------------------------------------
# Process liveness — "provably dead" only
# ---------------------------------------------------------------------------

function Get-CoordProcessInfo {
    <# $null => not running. Otherwise @{ started_at = <iso|$null> }. #>
    param([Parameter(Mandatory)][int]$HolderPid)
    if ($script:CoordProcessProbe) { return (& $script:CoordProcessProbe $HolderPid) }
    $proc = $null
    try { $proc = Get-Process -Id $HolderPid -ErrorAction Stop } catch { return $null }
    if (-not $proc) { return $null }
    $startedAt = $null
    try { $startedAt = $proc.StartTime.ToUniversalTime().ToString('o') } catch { $startedAt = $null }
    return @{ started_at = $startedAt }
}

function Test-CoordHolderAlive {
    <# Returns $false ONLY when the holder is provably dead: the pid is not running, or
       the pid is running but its start time contradicts the recorded one (pid reuse).
       Everything else — no pid, probe failure, and above all an UNKNOWN start time —
       returns $true, which falls back to TTL-only reclaim. Never early-steal. #>
    param(
        [int]$HolderPid = 0,
        [string]$HolderStartedAt
    )
    if ($HolderPid -le 0) { return $true }
    $info = $null
    try {
        $info = Get-CoordProcessInfo -HolderPid $HolderPid
    } catch {
        return $true   # cannot see the process table -> assume alive
    }
    if ($null -eq $info) { return $false }
    $observed = [string]$info.started_at
    if ([string]::IsNullOrWhiteSpace($observed) -or [string]::IsNullOrWhiteSpace($HolderStartedAt)) {
        return $true   # start time unknown on either side -> TTL-only reclaim
    }
    $a = ConvertFrom-CoordTimestamp $observed
    $b = ConvertFrom-CoordTimestamp $HolderStartedAt
    if ($null -eq $a -or $null -eq $b) { return $true }
    if ([math]::Abs(($a - $b).TotalSeconds) -gt $script:CoordStartTimeToleranceSec) { return $false }
    return $true
}

function Get-CoordSelfIdentity {
    $selfPid = $PID
    $info = $null
    try { $info = Get-CoordProcessInfo -HolderPid $selfPid } catch { $info = $null }
    $startedAt = if ($info) { [string]$info.started_at } else { $null }
    return [ordered]@{ holder_pid = $selfPid; holder_started_at = $startedAt }
}

# ---------------------------------------------------------------------------
# Admission lock (CreateNew, and nothing else)
# ---------------------------------------------------------------------------

function Get-CoordLockPath {
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$BatonHome = (Get-BatonHome)
    )
    return (Join-Path (Join-Path (Get-CoordinationRoot -BatonHome $BatonHome) 'locks') ("{0}.lock" -f $Key))
}

function Test-CoordLockStale {
    <# Provably reclaimable? expires_at in the past, OR holder provably dead. An
       unparseable payload only becomes reclaimable once the file is older than the
       lock TTL: a torn write should block admission briefly, not wedge it forever. #>
    param([Parameter(Mandatory)][string]$Path)
    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($Path) } catch { return $false }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $doc = $null }
    if ($null -eq $doc) {
        try {
            $age = ([datetimeoffset]::UtcNow - [datetimeoffset](Get-Item -LiteralPath $Path -ErrorAction Stop).LastWriteTimeUtc).TotalSeconds
            return ($age -gt $script:CoordLockTtlSec)
        } catch {
            return $false
        }
    }
    $expires = ConvertFrom-CoordTimestamp $doc.expires_at
    if ($expires -and $expires -lt [datetimeoffset]::UtcNow) { return $true }
    $lockPid = 0
    try { $lockPid = [int]$doc.holder_pid } catch { $lockPid = 0 }
    if (-not (Test-CoordHolderAlive -HolderPid $lockPid -HolderStartedAt (ConvertTo-CoordTimeString $doc.holder_started_at))) { return $true }
    return $false
}

function Invoke-WithAdmissionLock {
    <# Runs $Script under an exclusive CreateNew lock file named <Key>.lock. The lock is
       a short critical section (TTL 5s), NOT the lease. Released in a finally, so a
       throwing scriptblock never leaks the lock. Stale locks are reclaimed at most ONCE
       per call (delete + retry), then we simply wait out the timeout and throw — and a
       throw here is a DENY at the call site, never a grant. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$TimeoutSec = 5,
        [string]$BatonHome = (Get-BatonHome)
    )
    $lockPath = Get-CoordLockPath -Key $Key -BatonHome $BatonHome
    $deadline = [datetimeoffset]::UtcNow.AddSeconds([math]::Max(0, $TimeoutSec))
    $reclaimed = $false
    $acquired = $false

    while (-not $acquired) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read)   # Read, not None: contenders must be able
                                               # to read the payload to judge staleness.
            $self = Get-CoordSelfIdentity
            $now = [datetimeoffset]::UtcNow
            $payload = ([ordered]@{
                schema            = $script:CoordSchema
                key               = $Key
                holder_pid        = $self.holder_pid
                holder_started_at = $self.holder_started_at
                acquired_at       = $now.ToString('o')
                expires_at        = $now.AddSeconds($script:CoordLockTtlSec).ToString('o')
                ttl_sec           = $script:CoordLockTtlSec
            } | ConvertTo-Json -Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
            $acquired = $true
        } catch [System.IO.IOException] {
            # Only an existing lock file counts as contention; anything else (missing
            # dir, unwritable store) is a real failure and must propagate -> deny.
            if (-not (Test-Path -LiteralPath $lockPath)) { throw }
            if (-not $reclaimed -and (Test-CoordLockStale -Path $lockPath)) {
                $reclaimed = $true
                try { Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop } catch { }
                continue
            }
            if ([datetimeoffset]::UtcNow -ge $deadline) {
                throw ("{0}: {1}" -f $script:CoordLockTimeoutTag, $Key)
            }
            Start-Sleep -Milliseconds $script:CoordLockPollMs
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }

    try {
        $out = & $Script
        return $out
    } finally {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Config + weights (declared capacity only — never probe the hardware)
# ---------------------------------------------------------------------------

function Get-CoordinationConfigPath {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path (Get-CoordinationRoot -BatonHome $BatonHome) 'config.json')
}

function Read-CoordinationConfig {
    <# Absent config is legal (and yields NO declared capacity, i.e. no local grant).
       Present-but-unreadable sets .error, which the grant path treats as a deny. #>
    param([string]$BatonHome = (Get-BatonHome))
    $cfg = [ordered]@{
        error         = $null
        safety_factor = $script:CoordSafetyFactor
        lock_ttl_sec  = $script:CoordLockTtlSec
        claim_ttl_sec = $script:CoordClaimTtlSec
        hosts         = @{}
        profiles      = @{}
    }
    $path = Get-CoordinationConfigPath -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { return $cfg }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $cfg.error = 'config unreadable'
        return $cfg
    }
    try {
        if ($null -ne $doc.PSObject.Properties['safety_factor']) {
            $sf = [double]$doc.safety_factor
            if ($sf -gt 0 -and $sf -le 1) { $cfg.safety_factor = $sf }
        }
        if ($null -ne $doc.PSObject.Properties['lock_ttl_sec'] -and [int]$doc.lock_ttl_sec -gt 0) { $cfg.lock_ttl_sec = [int]$doc.lock_ttl_sec }
        if ($null -ne $doc.PSObject.Properties['claim_ttl_sec'] -and [int]$doc.claim_ttl_sec -gt 0) { $cfg.claim_ttl_sec = [int]$doc.claim_ttl_sec }
        if ($doc.hosts) {
            foreach ($p in $doc.hosts.PSObject.Properties) { $cfg.hosts[$p.Name] = $p.Value }
        }
        if ($doc.profiles) {
            foreach ($p in $doc.profiles.PSObject.Properties) { $cfg.profiles[$p.Name] = $p.Value }
        }
    } catch {
        $cfg.error = 'config unreadable'
    }
    return $cfg
}

function Get-CoordDeclaredCapacity {
    <# 0 means UNKNOWN, and unknown means deny. It never means "infinite". #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$HostName
    )
    try {
        foreach ($k in $Config.hosts.Keys) {
            if ([string]$k -eq $HostName) {
                $entry = $Config.hosts[$k]
                if ($null -eq $entry) { return 0.0 }
                if ($null -eq $entry.PSObject.Properties['vram_gb']) { return 0.0 }
                $v = [double]$entry.vram_gb
                if ($v -le 0) { return 0.0 }
                return $v
            }
        }
    } catch {
        return 0.0
    }
    return 0.0
}

function Get-CoordProfileEntry {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$LoadProfile
    )
    try {
        foreach ($k in $Config.profiles.Keys) {
            if ([string]$k -eq $LoadProfile) { return $Config.profiles[$k] }
        }
    } catch { }
    return $null
}

function Get-ProjectWeight {
    <# Precedence: explicit -> project entry -> default (100). Weight ANNOTATES a claim.
       It orders nothing and preempts nothing in v1. #>
    param(
        [string]$Project,
        [int]$Explicit = 0,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($Explicit -gt 0) { return $Explicit }
    $fallback = $script:CoordDefaultWeight
    try {
        $path = Join-Path (Get-CoordinationRoot -BatonHome $BatonHome) 'weights.json'
        if (-not (Test-Path -LiteralPath $path)) { return $fallback }
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $doc.PSObject.Properties['default'] -and [int]$doc.default -gt 0) { $fallback = [int]$doc.default }
        if ($Project -and $doc.projects) {
            foreach ($p in $doc.projects.PSObject.Properties) {
                if ([string]$p.Name -eq $Project -and [int]$p.Value -gt 0) { return [int]$p.Value }
            }
        }
    } catch {
        return $script:CoordDefaultWeight
    }
    return $fallback
}

# ---------------------------------------------------------------------------
# Claim rows
# ---------------------------------------------------------------------------

function ConvertTo-CoordClaimRow {
    <# The 15-field claim row, in spec order. #>
    param([Parameter(Mandatory)]$Doc)
    return [ordered]@{
        claim_id          = [string]$Doc.claim_id
        host              = [string]$Doc.host
        stack             = [string]$Doc.stack
        load_profile      = [string]$Doc.load_profile
        vram_gb           = $(try { [double]$Doc.vram_gb } catch { 0.0 })
        class             = [string]$Doc.class
        run_id            = [string]$Doc.run_id
        project           = [string]$Doc.project
        weight            = $(try { [int]$Doc.weight } catch { 0 })
        holder_pid        = $(try { [int]$Doc.holder_pid } catch { 0 })
        holder_started_at = (ConvertTo-CoordTimeString $Doc.holder_started_at)
        acquired_at       = (ConvertTo-CoordTimeString $Doc.acquired_at)
        renewed_at        = (ConvertTo-CoordTimeString $Doc.renewed_at)
        expires_at        = (ConvertTo-CoordTimeString $Doc.expires_at)
        ttl_sec           = $(try { [int]$Doc.ttl_sec } catch { 0 })
    }
}

function Get-CoordClaimEntries {
    <# Every claim file on a host, with an EFFECTIVE expiry. A claim whose expires_at is
       missing/garbage falls back to file mtime + ttl, so a corrupt row still blocks
       admission for a bounded window instead of being silently ignored. #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$Stack,
        [string]$BatonHome = (Get-BatonHome)
    )
    $entries = [System.Collections.ArrayList]@()
    $dir = Get-CoordClaimsDir -BatonHome $BatonHome
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $row = $null
        try {
            $doc = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (-not $doc.claim_id) { continue }
            $row = ConvertTo-CoordClaimRow -Doc $doc
        } catch {
            continue
        }
        if ([string]$row.host -ne $HostName) { continue }
        if ($Stack -and ([string]$row.stack -ne $Stack)) { continue }
        $exp = ConvertFrom-CoordTimestamp $row.expires_at
        if ($null -eq $exp) {
            $ttl = if ($row.ttl_sec -gt 0) { $row.ttl_sec } else { $script:CoordClaimTtlSec }
            try { $exp = ([datetimeoffset]$f.LastWriteTimeUtc).AddSeconds($ttl) } catch { $exp = [datetimeoffset]::UtcNow }
        }
        [void]$entries.Add([ordered]@{ path = $f.FullName; row = $row; expires = $exp })
    }
    return @($entries.ToArray())
}

function Get-ResourceClaims {
    <# Live (non-expired) claim rows. Lock-free: reading for display/status is allowed
       without the admission lock; every read-modify-WRITE is not. #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$Stack,
        [string]$BatonHome = (Get-BatonHome)
    )
    $now = [datetimeoffset]::UtcNow
    $rows = [System.Collections.ArrayList]@()
    foreach ($e in (Get-CoordClaimEntries -HostName $HostName -Stack $Stack -BatonHome $BatonHome)) {
        if ($e.expires -le $now) { continue }
        [void]$rows.Add($e.row)
    }
    return @($rows.ToArray())
}

function Remove-CoordStaleClaimsUnlocked {
    <# MUST already be under the matching admission lock. Reclaims expired claims and
       claims whose holder is PROVABLY dead. Unknown start time is not proof. #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$Stack,
        [string]$BatonHome = (Get-BatonHome)
    )
    $now = [datetimeoffset]::UtcNow
    $removed = [System.Collections.ArrayList]@()
    foreach ($e in (Get-CoordClaimEntries -HostName $HostName -Stack $Stack -BatonHome $BatonHome)) {
        $why = $null
        if ($e.expires -le $now) {
            $why = 'expired'
        } elseif (-not (Test-CoordHolderAlive -HolderPid $e.row.holder_pid -HolderStartedAt $e.row.holder_started_at)) {
            $why = 'holder_dead'
        }
        if (-not $why) { continue }
        try { Remove-Item -LiteralPath $e.path -Force -ErrorAction Stop } catch { continue }
        [void]$removed.Add($e.row)
        [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
            event        = 'reclaim'
            reason       = $why
            claim_id     = $e.row.claim_id
            host         = $e.row.host
            stack        = $e.row.stack
            load_profile = $e.row.load_profile
            run_id       = $e.row.run_id
        }))
    }
    return @($removed.ToArray())
}

function Remove-StaleResourceClaims {
    <# Public entry point: takes the matching lock, then reclaims. Returns the reclaimed
       rows (empty array when the store/lock is unavailable — never throws at callers). #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [string]$Stack,
        [int]$TimeoutSec = 5,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        [void](Get-CoordinationRoot -BatonHome $BatonHome)
        $key = Get-CoordResourceLockKey -HostName $HostName -Stack $Stack
        $body = {
            Remove-CoordStaleClaimsUnlocked -HostName $HostName -Stack $Stack -BatonHome $BatonHome
        }
        return @(Invoke-WithAdmissionLock -Key $key -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $body)
    } catch {
        return @()
    }
}

# ---------------------------------------------------------------------------
# Admission
# ---------------------------------------------------------------------------

function New-CoordDenial {
    <# `reason` stays a bare machine code (existing callers and tests match on it
       exactly). `remedy` is optional operator-facing text: a denial that does not
       say what to DO about it reads as a malfunction, and the most common denial
       here — capacity_unknown — is not a malfunction at all but an unconfigured
       box. Empty when there is nothing actionable to say. #>
    param(
        [Parameter(Mandatory)][string]$Reason,
        [string]$Remedy = ''
    )
    return [ordered]@{ granted = $false; reason = $Reason; claim = $null; remedy = $Remedy }
}

function Get-CoordCapacityRemedy {
    <# Exact, copy-pasteable instructions for the capacity_unknown denial. Names the
       real file path on THIS box so the operator does not have to derive it. #>
    param([string]$BatonHome = (Get-BatonHome), [string]$HostName = '')
    $path = Get-CoordinationConfigPath -BatonHome $BatonHome
    $h = if ([string]::IsNullOrWhiteSpace($HostName)) { '<host>' } else { $HostName }
    return ("declare this host's capacity in {0} — e.g. {{ `"hosts`": {{ `"{1}`": {{ `"vram_gb`": 24 }} }} }}. " +
            "Capacity is never guessed: 0 or absent means unknown, and unknown denies.") -f $path, $h
}

function Request-ResourceClaim {
    <# The whole point of this library. Returns
         [ordered]@{ granted = <bool>; reason = <string>; claim = <row|$null> }
       and returns granted=$false for EVERY failure mode. It does not throw. #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Stack,
        [Parameter(Mandatory)][string]$LoadProfile,
        [double]$VramGb = 0,
        [string]$Class = '',
        [string]$RunId = '',
        [string]$Project = '',
        [int]$Weight = 0,
        [int]$TtlSec = 60,
        [int]$TimeoutSec = 5,
        [string]$BatonHome = (Get-BatonHome)
    )

    # --- store must exist and be writable, or we deny (rule 1) ---
    try {
        [void](Get-CoordinationRoot -BatonHome $BatonHome)
    } catch {
        return (New-CoordDenial 'store_unavailable')
    }

    try {
        $cfg = Read-CoordinationConfig -BatonHome $BatonHome
        if ($cfg.error) {
            [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
                event = 'deny'; reason = 'config_unreadable'; host = $HostName; stack = $Stack; load_profile = $LoadProfile
            }))
            return (New-CoordDenial 'config_unreadable')
        }

        if ($TtlSec -le 0) { $TtlSec = $cfg.claim_ttl_sec }
        $profileEntry = Get-CoordProfileEntry -Config $cfg -LoadProfile $LoadProfile

        # Declared capacity. Absent / 0 = "I don't know" = deny (rule 2).
        $declared = Get-CoordDeclaredCapacity -Config $cfg -HostName $HostName
        if ($declared -le 0) {
            [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
                event = 'deny'; reason = 'capacity_unknown'; host = $HostName; stack = $Stack; load_profile = $LoadProfile
            }))
            return (New-CoordDenial 'capacity_unknown' (Get-CoordCapacityRemedy -BatonHome $BatonHome -HostName $HostName))
        }

        # Requested footprint: explicit wins, else the declared profile, else unknown -> deny.
        $requested = [double]$VramGb
        if ($requested -le 0 -and $profileEntry -and $null -ne $profileEntry.PSObject.Properties['vram_gb']) {
            try { $requested = [double]$profileEntry.vram_gb } catch { $requested = 0 }
        }
        if ($requested -le 0) {
            [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
                event = 'deny'; reason = 'profile_vram_unknown'; host = $HostName; stack = $Stack; load_profile = $LoadProfile
            }))
            return (New-CoordDenial 'profile_vram_unknown')
        }

        $resolvedClass = $Class
        if ([string]::IsNullOrWhiteSpace($resolvedClass) -and $profileEntry -and $null -ne $profileEntry.PSObject.Properties['class']) {
            $resolvedClass = [string]$profileEntry.class
        }
        if ([string]::IsNullOrWhiteSpace($resolvedClass)) { $resolvedClass = 'broad' }

        $maxInflight = if ($resolvedClass -eq 'tight') { 2 } else { 1 }
        if ($profileEntry -and $null -ne $profileEntry.PSObject.Properties['max_inflight']) {
            try { if ([int]$profileEntry.max_inflight -gt 0) { $maxInflight = [int]$profileEntry.max_inflight } } catch { }
        }

        $resolvedWeight = Get-ProjectWeight -Project $Project -Explicit $Weight -BatonHome $BatonHome
        $budget = [double]$declared * [double]$cfg.safety_factor

        $decide = {
            $now = [datetimeoffset]::UtcNow
            # Reclaim across ALL stacks on this host first: a dead claim on stack-a must
            # not permanently lock out stack-b via stack exclusivity.
            [void](Remove-CoordStaleClaimsUnlocked -HostName $HostName -BatonHome $BatonHome)
            $liveAll = @(Get-ResourceClaims -HostName $HostName -BatonHome $BatonHome)

            # Rule 3: stack exclusivity. One model server per box.
            $foreign = @($liveAll | Where-Object { [string]$_.stack -ne $Stack })
            if ($foreign.Count -gt 0) { return (New-CoordDenial 'stack_exclusive') }

            $live = @($liveAll | Where-Object { [string]$_.stack -eq $Stack })
            $same = @($live | Where-Object { [string]$_.load_profile -eq $LoadProfile })

            if ($same.Count -gt 0) {
                # Weights are already loaded: no new VRAM, but respect the inflight cap.
                if ($same.Count -ge $maxInflight) { return (New-CoordDenial 'profile_inflight') }
            } else {
                # Capacity over DISTINCT loaded profiles (two claims on one profile share
                # the same weights in VRAM).
                $byProfile = @{}
                foreach ($c in $live) {
                    $p = [string]$c.load_profile
                    $v = [double]$c.vram_gb
                    if (-not $byProfile.ContainsKey($p) -or $byProfile[$p] -lt $v) { $byProfile[$p] = $v }
                }
                $sum = 0.0
                foreach ($v in $byProfile.Values) {
                    if ([double]$v -le 0) { return (New-CoordDenial 'capacity_unknown') }  # a live row with an unknown footprint
                    $sum += [double]$v
                }
                if (($sum + $requested) -gt $budget) { return (New-CoordDenial 'capacity') }
            }

            $self = Get-CoordSelfIdentity
            $claimId = ("{0}-{1}-{2}" -f (ConvertTo-CoordKeySegment $HostName), (ConvertTo-CoordKeySegment $Stack), [guid]::NewGuid().ToString('n').Substring(0, 12))
            $row = [ordered]@{
                claim_id          = $claimId
                host              = $HostName
                stack             = $Stack
                load_profile      = $LoadProfile
                vram_gb           = $requested
                class             = $resolvedClass
                run_id            = $RunId
                project           = $Project
                weight            = $resolvedWeight
                holder_pid        = $self.holder_pid
                holder_started_at = $self.holder_started_at
                acquired_at       = $now.ToString('o')
                renewed_at        = $now.ToString('o')
                expires_at        = $now.AddSeconds($TtlSec).ToString('o')
                ttl_sec           = $TtlSec
            }
            Write-CoordFileAtomic -Path (Get-CoordClaimPath -ClaimId $claimId -BatonHome $BatonHome) `
                -Content ($row | ConvertTo-Json -Depth 4)
            return [ordered]@{ granted = $true; reason = 'granted'; claim = $row }
        }

        # Host lock OUTER, (host, stack) lock INNER — always this order, so the pair can
        # never deadlock. The host-level lock is what makes stack exclusivity real: two
        # different stacks would otherwise take two different locks and both grant.
        $hostKey  = Get-CoordResourceLockKey -HostName $HostName
        $stackKey = Get-CoordResourceLockKey -HostName $HostName -Stack $Stack
        $inner = {
            Invoke-WithAdmissionLock -Key $stackKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $decide
        }

        $outcome = Invoke-WithAdmissionLock -Key $hostKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $inner

        if ($null -eq $outcome) { return (New-CoordDenial 'error: empty decision') }

        [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
            event        = $(if ($outcome.granted) { 'grant' } else { 'deny' })
            reason       = [string]$outcome.reason
            host         = $HostName
            stack        = $Stack
            load_profile = $LoadProfile
            vram_gb      = $requested
            run_id       = $RunId
            project      = $Project
            weight       = $resolvedWeight
            claim_id     = $(if ($outcome.claim) { [string]$outcome.claim.claim_id } else { $null })
        }))
        return $outcome
    } catch {
        $msg = [string]$_.Exception.Message
        $reason = if ($msg -like ("{0}*" -f $script:CoordLockTimeoutTag)) { 'lock_unavailable' } else { ('error: ' + $msg) }
        [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
            event = 'deny'; reason = $reason; host = $HostName; stack = $Stack; load_profile = $LoadProfile
        }))
        return (New-CoordDenial $reason)
    }
}

function Update-ResourceClaim {
    <# Renew: extend expires_at and stamp renewed_at. Only the holder may renew, and an
       already-expired claim may not be renewed (it may already have been reclaimed and
       the capacity regranted). Returns @{ ok; reason; claim }. Never throws. #>
    param(
        [Parameter(Mandatory)][string]$ClaimId,
        [int]$TtlSec = 0,
        [int]$TimeoutSec = 5,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        [void](Get-CoordinationRoot -BatonHome $BatonHome)
    } catch {
        return [ordered]@{ ok = $false; reason = 'store_unavailable'; claim = $null }
    }
    try {
        $path = Get-CoordClaimPath -ClaimId $ClaimId -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{ ok = $false; reason = 'not_found'; claim = $null } }
        $seed = $null
        try {
            $seed = ConvertTo-CoordClaimRow -Doc (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            return [ordered]@{ ok = $false; reason = 'unreadable'; claim = $null }
        }

        $hostKey  = Get-CoordResourceLockKey -HostName ([string]$seed.host)
        $stackKey = Get-CoordResourceLockKey -HostName ([string]$seed.host) -Stack ([string]$seed.stack)
        $body = {
            if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{ ok = $false; reason = 'not_found'; claim = $null } }
            $row = $null
            try {
                $row = ConvertTo-CoordClaimRow -Doc (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            } catch {
                return [ordered]@{ ok = $false; reason = 'unreadable'; claim = $null }
            }
            $self = Get-CoordSelfIdentity
            if ([int]$row.holder_pid -ne [int]$self.holder_pid) {
                return [ordered]@{ ok = $false; reason = 'not_holder'; claim = $row }
            }
            if ($row.holder_started_at -and $self.holder_started_at) {
                $a = ConvertFrom-CoordTimestamp ([string]$row.holder_started_at)
                $b = ConvertFrom-CoordTimestamp ([string]$self.holder_started_at)
                if ($a -and $b -and [math]::Abs(($a - $b).TotalSeconds) -gt $script:CoordStartTimeToleranceSec) {
                    return [ordered]@{ ok = $false; reason = 'not_holder'; claim = $row }
                }
            }
            $now = [datetimeoffset]::UtcNow
            $exp = ConvertFrom-CoordTimestamp ([string]$row.expires_at)
            if ($null -eq $exp -or $exp -le $now) {
                return [ordered]@{ ok = $false; reason = 'expired'; claim = $row }
            }
            $ttl = if ($TtlSec -gt 0) { $TtlSec } elseif ([int]$row.ttl_sec -gt 0) { [int]$row.ttl_sec } else { $script:CoordClaimTtlSec }
            $row.renewed_at = $now.ToString('o')
            $row.expires_at = $now.AddSeconds($ttl).ToString('o')
            $row.ttl_sec = $ttl
            Write-CoordFileAtomic -Path $path -Content ($row | ConvertTo-Json -Depth 4)
            return [ordered]@{ ok = $true; reason = 'renewed'; claim = $row }
        }

        $inner = {
            Invoke-WithAdmissionLock -Key $stackKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $body
        }
        $out = Invoke-WithAdmissionLock -Key $hostKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $inner

        [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
            event = 'renew'; reason = [string]$out.reason; claim_id = $ClaimId; ok = [bool]$out.ok
        }))
        return $out
    } catch {
        $msg = [string]$_.Exception.Message
        $reason = if ($msg -like ("{0}*" -f $script:CoordLockTimeoutTag)) { 'lock_unavailable' } else { ('error: ' + $msg) }
        return [ordered]@{ ok = $false; reason = $reason; claim = $null }
    }
}

function Remove-ResourceClaim {
    <# Release. Freeing capacity is always safe, so this does not require holdership —
       that is what makes crash recovery possible without a human deleting files. #>
    param(
        [Parameter(Mandatory)][string]$ClaimId,
        [int]$TimeoutSec = 5,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        [void](Get-CoordinationRoot -BatonHome $BatonHome)
    } catch {
        return [ordered]@{ ok = $false; reason = 'store_unavailable'; claim = $null }
    }
    try {
        $path = Get-CoordClaimPath -ClaimId $ClaimId -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{ ok = $false; reason = 'not_found'; claim = $null } }
        $seed = $null
        try {
            $seed = ConvertTo-CoordClaimRow -Doc (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            $seed = $null
        }
        $lockHost  = if ($seed) { [string]$seed.host } else { 'unknown' }
        $lockStack = if ($seed) { [string]$seed.stack } else { 'unknown' }
        $hostKey  = Get-CoordResourceLockKey -HostName $lockHost
        $stackKey = Get-CoordResourceLockKey -HostName $lockHost -Stack $lockStack
        $body = {
            if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{ ok = $false; reason = 'not_found'; claim = $null } }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return [ordered]@{ ok = $true; reason = 'released'; claim = $seed }
        }
        $inner = {
            Invoke-WithAdmissionLock -Key $stackKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $body
        }
        $out = Invoke-WithAdmissionLock -Key $hostKey -TimeoutSec $TimeoutSec -BatonHome $BatonHome -Script $inner

        [void](Write-CoordJournalEntry -BatonHome $BatonHome -Entry ([ordered]@{
            event = 'release'; reason = [string]$out.reason; claim_id = $ClaimId; ok = [bool]$out.ok
        }))
        return $out
    } catch {
        $msg = [string]$_.Exception.Message
        $reason = if ($msg -like ("{0}*" -f $script:CoordLockTimeoutTag)) { 'lock_unavailable' } else { ('error: ' + $msg) }
        return [ordered]@{ ok = $false; reason = $reason; claim = $null }
    }
}
