#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Lazy per-project window service: hygiene + candidates + briefing, keyed on the
  heartbeat's 5h grid (issue #147).
.DESCRIPTION
  Machine-scoped free work lives in the beat (heartbeat-lib). Project-scoped work
  runs once per window per *active* project — activity is the trigger (PostToolUse
  claim), not a project ranking. Fail-open everywhere; never throws to a hook.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/heartbeat-lib.ps1"   # $script:HeartbeatWindowHours + anchor state

# Injected into Claude at every SessionStart — keep it short (token tax on every instance).
$script:ProjectBriefingMaxBytes = 2000

function Get-WindowServiceDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'window-service')
}

function Get-ProjectPathKey {
    <# Stable filesystem-safe key for a project dir. Paths contain ':' and '\';
       same project must always hash the same, case-insensitively on Windows. #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    $full = try {
        [System.IO.Path]::GetFullPath($ProjectDir)
    } catch {
        $ProjectDir
    }
    $norm = $full.TrimEnd('\', '/').ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant().Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Get-WindowSerial {
    <# Window identity: floor((Now - Anchor) / windowLength). Reuses the heartbeat
       window length so project stamps and the beat never drift relative to each other. #>
    param(
        [Parameter(Mandatory)][datetimeoffset]$Anchor,
        [Parameter(Mandatory)][datetimeoffset]$Now
    )
    # Fallback when the heartbeat constant is missing/non-positive: serial 0 forever
    # would silently service each project once and never again.
    $windowHours = $script:HeartbeatWindowHours
    if ($null -eq $windowHours -or [double]$windowHours -le 0) { $windowHours = 5 }
    $windowSeconds = [double]($windowHours * 3600)
    $elapsed = ($Now - $Anchor).TotalSeconds
    return [int][math]::Floor($elapsed / $windowSeconds)
}

function Get-ProjectServiceStampPath {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $key = Get-ProjectPathKey -ProjectDir $ProjectDir
    return (Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) "$key.json")
}

function Get-ProjectBriefingPath {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $key = Get-ProjectPathKey -ProjectDir $ProjectDir
    return (Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) "$key.briefing.md")
}

function Get-ProjectServiceClaimPath {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][int]$Serial,
        [string]$BatonHome = (Get-BatonHome)
    )
    $key = Get-ProjectPathKey -ProjectDir $ProjectDir
    return (Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) ("{0}.{1}.claimed" -f $key, $Serial))
}

function Get-ProjectServiceSentinelPath {
    <# Hot-path short-circuit for the tool-call hook: exists + future boundary => skip
       all lib loading until the next window. Beside the stamp; same project key. #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $key = Get-ProjectPathKey -ProjectDir $ProjectDir
    return (Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) "$key.sentinel")
}

function Get-ProjectServiceConfigPath {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $key = Get-ProjectPathKey -ProjectDir $ProjectDir
    return (Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) "$key.config.json")
}

function Read-WindowServiceConfig {
    <# Global knobs under BATON_HOME/window-service/config.json; optional per-project
       override beside the stamp. Absent file => both ON. Present-but-unparseable =>
       free work stays ON, paid candidates go OFF (fail-open is wrong for spend). #>
    param(
        [string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $cfg = [ordered]@{
        enabled             = $true
        candidates_enabled  = $true
        config_error        = $null
    }
    $globalPath = Join-Path (Get-WindowServiceDir -BatonHome $BatonHome) 'config.json'
    foreach ($path in @($globalPath, $(if ($ProjectDir) { Get-ProjectServiceConfigPath -ProjectDir $ProjectDir -BatonHome $BatonHome } else { $null }))) {
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
        try {
            $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $doc.PSObject.Properties['enabled']) { $cfg.enabled = [bool]$doc.enabled }
            if ($null -ne $doc.PSObject.Properties['candidates_enabled']) { $cfg.candidates_enabled = [bool]$doc.candidates_enabled }
        } catch {
            # Present but unreadable: keep free work; disable the only paid call.
            $cfg.candidates_enabled = $false
            $cfg.config_error = ("unreadable config: {0}" -f [IO.Path]::GetFileName($path))
        }
    }
    return $cfg
}

function Read-ProjectServiceStamp {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{
            serial     = [int]$doc.serial
            claimed_at = [string]$doc.claimed_at
        }
    } catch {
        return $null
    }
}

function Test-ProjectServiceDue {
    <# True when no stamp exists or stamp serial is older than Serial. Corrupt/unreadable
       stamps count as due (fail-open toward work, never toward throwing). #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][int]$Serial,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $path = Get-ProjectServiceStampPath -ProjectDir $ProjectDir -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $path)) { return $true }
        $stamp = Read-ProjectServiceStamp -Path $path
        if ($null -eq $stamp) { return $true }
        return ([int]$stamp.serial -lt $Serial)
    } catch {
        return $true
    }
}

function Request-ProjectServiceClaim {
    <# Atomic claim: exactly one caller per (project, serial) wins. Exclusive create of
       a serial-tagged claim file is the mutex (CreateNew, not Test-Path-then-write).
       On success the durable stamp is written with the serial + UTC time. #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][int]$Serial,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $dir = Get-WindowServiceDir -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $claimPath = Get-ProjectServiceClaimPath -ProjectDir $ProjectDir -Serial $Serial -BatonHome $BatonHome
        $stampPath = Get-ProjectServiceStampPath -ProjectDir $ProjectDir -BatonHome $BatonHome
        $stream = $null
        try {
            $stream = [System.IO.File]::Open(
                $claimPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $claimedAt = [datetime]::UtcNow.ToString('o')
            $payload = (@{ serial = $Serial; claimed_at = $claimedAt } | ConvertTo-Json -Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } finally {
            if ($stream) { $stream.Dispose() }
        }
        # Durable stamp for Due checks (claim file is the mutex; stamp is the summary).
        Set-Content -LiteralPath $stampPath -Value (@{
            serial     = $Serial
            claimed_at = [datetime]::UtcNow.ToString('o')
            project    = $ProjectDir
        } | ConvertTo-Json -Compress) -Encoding utf8NoBOM

        # Hot-path sentinel: next boundary so the tool-call hook can skip lib loading
        # until this window ends (anchor + (serial+1)*window). Best-effort.
        try {
            $hbState = Read-HeartbeatState -Path (Get-HeartbeatStatePath -BatonHome $BatonHome)
            if ($hbState.anchor) {
                $nowOff = [datetimeoffset]::Now
                $anchorAt = Resolve-HeartbeatAnchor -Anchor ([string]$hbState.anchor) -Now $nowOff
                if ($anchorAt) {
                    $windowHours = $script:HeartbeatWindowHours
                    if ($null -eq $windowHours -or [double]$windowHours -le 0) { $windowHours = 5 }
                    $nextBoundary = $anchorAt.AddSeconds([double]$windowHours * 3600 * ($Serial + 1)).ToUniversalTime()
                    $sentinelPath = Get-ProjectServiceSentinelPath -ProjectDir $ProjectDir -BatonHome $BatonHome
                    # UTC ISO-8601; hook compares against [datetime]::UtcNow without loading libs.
                    Set-Content -LiteralPath $sentinelPath -Value $nextBoundary.ToString('o') -Encoding utf8NoBOM
                }
            }
        } catch { }

        # Hygiene: drop older claim files for THIS project only (serial litter otherwise).
        try {
            $key = Get-ProjectPathKey -ProjectDir $ProjectDir
            $prefix = "$key."
            $suffix = '.claimed'
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name.StartsWith($prefix) -and $_.Name.EndsWith($suffix)
                } |
                ForEach-Object {
                    $mid = $_.Name.Substring($prefix.Length, $_.Name.Length - $prefix.Length - $suffix.Length)
                    $oldSerial = 0
                    if ([int]::TryParse($mid, [ref]$oldSerial) -and $oldSerial -lt $Serial) {
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
        } catch { }

        return $true
    } catch {
        return $false
    }
}

function Invoke-ProjectHygiene {
    <# Conservative, non-destructive: git worktree prune (stale registrations only) and
       a report-only would_remove list. Journal rotation is machine-scoped and lives in
       the beat (heartbeat-lib) — never here (N projects would race Move-Item). #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    $summary = [ordered]@{
        ok              = $true
        worktree_prune  = $null
        would_remove    = @()
        errors          = @()
    }

    try {
        if (Test-Path -LiteralPath (Join-Path $ProjectDir '.git')) {
            $pruneOut = & git -C $ProjectDir worktree prune 2>&1 | Out-String
            $summary.worktree_prune = [ordered]@{
                ok     = ($LASTEXITCODE -eq 0)
                output = $pruneOut.Trim()
            }
            if ($LASTEXITCODE -ne 0) {
                $summary.errors += "worktree prune exit $LASTEXITCODE"
            }
        } else {
            $summary.worktree_prune = [ordered]@{ ok = $true; output = 'not a git repo'; skipped = $true }
        }
    } catch {
        $summary.worktree_prune = [ordered]@{ ok = $false; output = $_.Exception.Message }
        $summary.errors += $_.Exception.Message
    }

    # Report-only: list registered worktrees that look stale without removing dirs.
    try {
        if (Test-Path -LiteralPath (Join-Path $ProjectDir '.git')) {
            $porcelain = & git -C $ProjectDir worktree list --porcelain 2>$null
            if ($LASTEXITCODE -eq 0 -and $porcelain) {
                $wtPath = $null
                foreach ($line in @($porcelain)) {
                    $wtMatch = [regex]::Match([string]$line, '^worktree\s+(.+)$')
                    if ($wtMatch.Success) {
                        $wtPath = $wtMatch.Groups[1].Value
                    } elseif (([string]$line).StartsWith('prunable') -and $wtPath) {
                        $summary.would_remove += $wtPath
                        $wtPath = $null
                    } elseif ([string]::IsNullOrWhiteSpace([string]$line)) {
                        $wtPath = $null
                    }
                }
            }
        }
    } catch { }

    if (@($summary.errors).Count -gt 0) { $summary.ok = $false }
    return $summary
}

function Get-ProjectLocalFacts {
    <# Cheap local facts only — never whole files (token + latency budget for the
       candidate prompt). #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    $bits = [System.Collections.ArrayList]@()
    try {
        $log = & git -C $ProjectDir log -5 --pretty=format:'%s' 2>$null
        if ($LASTEXITCODE -eq 0 -and $log) {
            [void]$bits.Add('Recent commits:')
            foreach ($line in @($log)) { [void]$bits.Add("  - $line") }
        }
    } catch { }
    try {
        $prev = Get-Location
        try {
            Set-Location -LiteralPath $ProjectDir
            $rawIssues = & gh issue list --limit 5 --json number,title 2>$null
            if ($LASTEXITCODE -eq 0 -and $rawIssues) {
                $arr = $rawIssues | ConvertFrom-Json
                if (@($arr).Count -gt 0) {
                    [void]$bits.Add('Open issues:')
                    foreach ($iss in @($arr)) {
                        [void]$bits.Add(("  - #{0} {1}" -f $iss.number, $iss.title))
                    }
                }
            }
        } finally {
            Set-Location $prev
        }
    } catch { }
    if ($bits.Count -eq 0) {
        [void]$bits.Add('(no local git/gh facts available)')
    }
    return ($bits -join "`n")
}

function Get-ProjectCandidates {
    <# Ask grok-cli for a short "what's next" list. Prompt goes in a FILE (965-byte
       shell-arg ceiling). Transport injects a fake for hermetic tests. Failure -> $null. #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [scriptblock]$Transport,
        [string]$BatonHome = (Get-BatonHome)
    )
    $promptFile = $null
    try {
        $facts = Get-ProjectLocalFacts -ProjectDir $ProjectDir
        $prompt = @"
Project: $ProjectDir
List 3-5 short, concrete things worth working on next here. Bullet list only. No preamble.

$facts
"@
        $promptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-ws-cand-" + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content -LiteralPath $promptFile -Value $prompt -Encoding utf8NoBOM

        if ($Transport) {
            $text = [string](& $Transport $prompt)
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text.Trim()
        }

        $ask = Join-Path $PSScriptRoot 'fleet-ask.ps1'
        if (-not (Test-Path -LiteralPath $ask)) { return $null }
        $prev = Get-Location
        try {
            Set-Location -LiteralPath $ProjectDir
            $raw = & pwsh -NoProfile -File $ask -Provider 'grok-cli' -PromptFile $promptFile 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
            # Drop the fleet-ask footer line ("-- provider | ...").
            $lines = @($raw -split "`r?`n" | Where-Object { $_ -notmatch '^--\s' })
            $body = ($lines -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($body)) { return $null }
            return $body
        } finally {
            Set-Location $prev
        }
    } catch {
        return $null
    } finally {
        if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
            Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-ProjectBriefing {
    <# Assemble and write the short briefing. Enforces MaxBytes at write time —
       oversized digests are truncated and marked (recurring SessionStart token tax). #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)]$Sections,
        [int]$MaxBytes = $script:ProjectBriefingMaxBytes,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($MaxBytes -le 0) { $MaxBytes = $script:ProjectBriefingMaxBytes }
    $parts = [System.Collections.ArrayList]@()
    [void]$parts.Add('# Window service briefing')
    [void]$parts.Add(("Generated: {0}" -f [datetime]::UtcNow.ToString('o')))
    [void]$parts.Add(("Project: {0}" -f $ProjectDir))
    [void]$parts.Add('')

    if ($Sections.hygiene) {
        [void]$parts.Add('## Hygiene')
        $h = $Sections.hygiene
        if ($h.ok -eq $false -and $h.error) {
            [void]$parts.Add(("FAILED: {0}" -f $h.error))
        } else {
            $hygLines = [System.Collections.ArrayList]@()
            if ($h.worktree_prune -and -not $h.worktree_prune.skipped) {
                [void]$hygLines.Add('- git worktree prune ran')
            }
            if (@($h.would_remove).Count -gt 0) {
                [void]$hygLines.Add('- would remove (not removed):')
                foreach ($w in @($h.would_remove)) { [void]$hygLines.Add("  - $w") }
            }
            if ($hygLines.Count -eq 0) {
                [void]$parts.Add('- nothing to do (no prune; no stale worktrees reported)')
            } else {
                foreach ($line in $hygLines) { [void]$parts.Add($line) }
            }
        }
        [void]$parts.Add('')
    }

    $hasCandidates = $false
    if ($Sections -is [System.Collections.IDictionary]) {
        $hasCandidates = $Sections.Contains('candidates')
    } elseif ($Sections -and $Sections.PSObject.Properties['candidates']) {
        $hasCandidates = $true
    }
    if ($hasCandidates) {
        [void]$parts.Add('## Candidates')
        $c = if ($Sections -is [System.Collections.IDictionary]) { $Sections['candidates'] } else { $Sections.candidates }
        if ($null -eq $c) {
            [void]$parts.Add('FAILED: candidates unavailable')
        } elseif ([string]$c -eq '__disabled__') {
            [void]$parts.Add('(candidates disabled)')
        } else {
            [void]$parts.Add([string]$c)
        }
        [void]$parts.Add('')
    }

    if ($Sections.failures -and @($Sections.failures).Count -gt 0) {
        [void]$parts.Add('## Failures')
        foreach ($f in @($Sections.failures)) { [void]$parts.Add("- $f") }
        [void]$parts.Add('')
    }

    $text = ($parts -join "`n").TrimEnd() + "`n"
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($text)
    $truncated = $false
    if ($bytes.Length -gt $MaxBytes) {
        # Leave room for the truncation marker.
        $marker = "`n[truncated]`n"
        $markerBytes = $utf8.GetBytes($marker)
        $keep = [math]::Max(0, $MaxBytes - $markerBytes.Length)
        # Truncate on a UTF-8 boundary.
        while ($keep -gt 0 -and ($bytes[$keep - 1] -band 0xC0) -eq 0x80) { $keep-- }
        $slice = New-Object byte[] ($keep + $markerBytes.Length)
        [Array]::Copy($bytes, 0, $slice, 0, $keep)
        [Array]::Copy($markerBytes, 0, $slice, $keep, $markerBytes.Length)
        $bytes = $slice
        $text = $utf8.GetString($bytes)
        $truncated = $true
    }

    $path = Get-ProjectBriefingPath -ProjectDir $ProjectDir -BatonHome $BatonHome
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return [ordered]@{
        path       = $path
        bytes      = $bytes.Length
        truncated  = $truncated
        max_bytes  = $MaxBytes
    }
}

function Get-ProjectBriefing {
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $cfg = Read-WindowServiceConfig -ProjectDir $ProjectDir -BatonHome $BatonHome
        if (-not $cfg.enabled) { return $null }
        $path = Get-ProjectBriefingPath -ProjectDir $ProjectDir -BatonHome $BatonHome
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return $text
    } catch {
        return $null
    }
}

function Invoke-ProjectWindowService {
    <# Orchestrate hygiene -> candidates -> briefing. Each step isolated: one failure
       must not block the others; the briefing is written from whatever succeeded and
       names failed sections honestly. #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [Parameter(Mandatory)][int]$Serial,
        [scriptblock]$Transport,
        [string]$BatonHome = (Get-BatonHome),
        [int]$MaxBytes = $script:ProjectBriefingMaxBytes
    )
    $cfg = Read-WindowServiceConfig -ProjectDir $ProjectDir -BatonHome $BatonHome
    $result = [ordered]@{
        project_dir = $ProjectDir
        serial      = $Serial
        enabled     = [bool]$cfg.enabled
        hygiene     = $null
        candidates  = $null
        briefing    = $null
        failures    = @()
        skipped     = $false
    }
    if (-not $cfg.enabled) {
        $result.skipped = $true
        $result.failures = @('window-service disabled')
        return $result
    }

    $failures = [System.Collections.ArrayList]@()
    $hygiene = $null
    try {
        $hygiene = Invoke-ProjectHygiene -ProjectDir $ProjectDir -BatonHome $BatonHome
        if (-not $hygiene.ok) { [void]$failures.Add('hygiene reported errors') }
    } catch {
        $hygiene = [ordered]@{ ok = $false; error = $_.Exception.Message; would_remove = @() }
        [void]$failures.Add('hygiene')
    }
    $result.hygiene = $hygiene

    $candidates = $null
    if (-not $cfg.candidates_enabled) {
        $candidates = '__disabled__'
        if ($cfg.config_error) {
            # Paid call skipped because config was present but unreadable — say so.
            [void]$failures.Add(("candidates skipped: {0}" -f $cfg.config_error))
        }
    } else {
        try {
            $candidates = Get-ProjectCandidates -ProjectDir $ProjectDir -Transport $Transport -BatonHome $BatonHome
            if ($null -eq $candidates) { [void]$failures.Add('candidates') }
        } catch {
            $candidates = $null
            [void]$failures.Add('candidates')
        }
    }
    $result.candidates = $candidates

    $sections = [ordered]@{
        hygiene    = $hygiene
        candidates = $candidates
        failures   = @($failures.ToArray())
    }
    try {
        $result.briefing = Write-ProjectBriefing -ProjectDir $ProjectDir -Sections $sections `
            -MaxBytes $MaxBytes -BatonHome $BatonHome
    } catch {
        [void]$failures.Add('briefing')
        $result.briefing = $null
    }
    $result.failures = @($failures.ToArray())
    return $result
}

function Get-WindowServiceStatus {
    <# Status for -Status CLI: anchor serial, due?, last stamp — spends nothing. #>
    param(
        [Parameter(Mandatory)][string]$ProjectDir,
        [string]$BatonHome = (Get-BatonHome),
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $cfg = Read-WindowServiceConfig -ProjectDir $ProjectDir -BatonHome $BatonHome
    $state = Read-HeartbeatState -Path (Get-HeartbeatStatePath -BatonHome $BatonHome)
    $anchorAt = $null
    $serial = $null
    if ($state.anchor) {
        $anchorAt = Resolve-HeartbeatAnchor -Anchor ([string]$state.anchor) -Now $Now
        if ($anchorAt) { $serial = Get-WindowSerial -Anchor $anchorAt -Now $Now }
    }
    $stampPath = Get-ProjectServiceStampPath -ProjectDir $ProjectDir -BatonHome $BatonHome
    $stamp = if (Test-Path -LiteralPath $stampPath) { Read-ProjectServiceStamp -Path $stampPath } else { $null }
    $due = if ($null -eq $serial) { $false } else { Test-ProjectServiceDue -ProjectDir $ProjectDir -Serial $serial -BatonHome $BatonHome }
    $briefingPath = Get-ProjectBriefingPath -ProjectDir $ProjectDir -BatonHome $BatonHome
    return [ordered]@{
        project_dir         = $ProjectDir
        enabled             = [bool]$cfg.enabled
        candidates_enabled  = [bool]$cfg.candidates_enabled
        anchor              = if ($anchorAt) { $anchorAt.ToString('o') } else { $null }
        serial              = $serial
        due                 = $due
        dormant             = ($null -eq $anchorAt)
        last_stamp_serial   = if ($stamp) { $stamp.serial } else { $null }
        last_claimed_at     = if ($stamp) { $stamp.claimed_at } else { $null }
        briefing_exists     = (Test-Path -LiteralPath $briefingPath)
        briefing_path       = $briefingPath
    }
}
