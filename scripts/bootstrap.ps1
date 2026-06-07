#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bootstraps the coding-agent-orchestrator observation layer into ~/.claude/.

.DESCRIPTION
  Idempotent. Re-runnable. Plan 1 scope: deploys hook, OTel env config, slash
  commands, catalog seed, journal seed. Verifies backends. Plan 2 will extend
  with Python venv and dashboard setup.
#>

param(
    [switch]$DryRun,
    [switch]$Force,           # overwrite the catalog without prompting
    [switch]$NonInteractive   # never prompt; differing files are kept as-is
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$claudeDir = Join-Path $HOME '.claude'

# Auto-detect non-interactive runs (CI, piped stdin, child process). Without this,
# a Copy-WithPrompt over a differing file would block on Read-Host forever — which
# is exactly how the dry-run smoke test used to hang.
if (-not $NonInteractive) {
    try { if ([Console]::IsInputRedirected) { $NonInteractive = $true } } catch { }
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    skip: $msg" -ForegroundColor Yellow }
function Write-Warn($msg) { Write-Host "    warn: $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    err: $msg" -ForegroundColor Red }

# --- Step 0: Report repo-vs-deployed version drift ---
# Surfaces at a glance whether ~/.claude/ is running an older deploy than the repo.
# Repo version = nearest v* tag (+ commits since); deployed version = marker written
# at the end of the last successful (non-dry-run) bootstrap.
Write-Step "Checking repo vs deployed version"
$repoVersion = (& git -C $repoRoot describe --tags --match 'v*' --always 2>$null | Select-Object -First 1)
if (-not $repoVersion) { $repoVersion = 'unknown' }
$versionMarker = Join-Path $claudeDir '.cao-version'
$deployedVersion = if (Test-Path $versionMarker) { (Get-Content $versionMarker -Raw).Trim() } else { '(none - first run)' }
if ($deployedVersion -eq $repoVersion) {
    Write-Ok "in sync: repo and deployed both at $repoVersion"
} else {
    Write-Warn "drift: repo $repoVersion vs deployed $deployedVersion (this run deploys $repoVersion)"
}

function Copy-IfMissing($src, $dst, $label) {
    if (Test-Path $dst) {
        Write-Skip "$label already exists at $dst"
        return $false
    }
    if ($DryRun) { Write-Ok "[dry-run] would copy $label -> $dst"; return $true }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item $src $dst
    Write-Ok "$label -> $dst"
    return $true
}

function Copy-WithPrompt($src, $dst, $label, [switch]$Force) {
    if (Test-Path $dst) {
        if ($Force) {
            if ($DryRun) { Write-Ok "[dry-run] would overwrite $label at $dst (--Force)"; return }
            Copy-Item $src $dst -Force
            Write-Ok "$label overwritten at $dst (--Force)"
            return
        }
        $srcHash = (Get-FileHash $src).Hash
        $dstHash = (Get-FileHash $dst).Hash
        if ($srcHash -eq $dstHash) { Write-Skip "$label already up-to-date at $dst"; return }
        # File differs and -Force was not given. Never block: in dry-run just report,
        # and in a non-interactive run keep the existing file rather than prompting.
        if ($DryRun) { Write-Ok "[dry-run] $label differs from repo; would prompt to overwrite"; return }
        if ($NonInteractive) { Write-Skip "$label differs from repo; kept existing (non-interactive)"; return }
        $ans = Read-Host "    $label at $dst differs from repo. Overwrite? [y/N]"
        if ($ans -ne 'y') { Write-Skip "kept existing $label"; return }
    }
    if ($DryRun) { Write-Ok "[dry-run] would copy $label -> $dst"; return }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item $src $dst -Force
    Write-Ok "$label -> $dst"
}

# --- Step 1: Verify Octopus is installed ---
Write-Step "Verifying claude-octopus is installed"
$octoCheck = & claude plugin list 2>&1 | Out-String
if ($octoCheck -match 'octo@nyldn-plugins') {
    Write-Ok "claude-octopus detected"
} else {
    Write-Warn "claude-octopus not detected. Install with:"
    Write-Host "      claude plugin marketplace add https://github.com/nyldn/plugins.git"
    Write-Host "      claude plugin install octo@nyldn-plugins"
    if ($DryRun) {
        Write-Warn "continuing dry-run despite missing Octopus (would exit 1 in real run)"
    } else {
        Write-Host "      Then re-run this bootstrap."
        exit 1
    }
}

# --- Step 2: Deploy the hooks ---
Write-Step "Deploying PostToolUse hook"
$hookSrc = Join-Path $repoRoot 'scripts\hooks\log-tool-call.ps1'
$hookDst = Join-Path $claudeDir 'hooks\log-tool-call.ps1'
Copy-WithPrompt $hookSrc $hookDst 'hook script'

# Decision-detect Stop hook: at the end of each turn it scans the final assistant
# message for decision phrasing and, on a hit, writes a decision-intake draft to
# TEMP + prints the suggested intake command. Always exits 0 (non-blocking).
$ddHookSrc = Join-Path $repoRoot 'scripts\hooks\decision-detect.ps1'
$ddHookDst = Join-Path $claudeDir 'hooks\decision-detect.ps1'
Copy-WithPrompt $ddHookSrc $ddHookDst 'decision-detect hook'

# Legibility-feed narration hook: appends a plain-English event for the active run
# on every tool use. No-ops when no current-run.json pointer exists. Always exits 0.
$runFeedHookSrc = Join-Path $repoRoot 'scripts\hooks\run-feed.ps1'
$runFeedHookDst = Join-Path $claudeDir 'hooks\run-feed.ps1'
Copy-WithPrompt $runFeedHookSrc $runFeedHookDst 'run-feed hook'

# --- Step 3: Register hooks in settings.json (PostToolUse + Stop) ---
Write-Step "Registering hooks in settings.json"
$settingsPath = Join-Path $claudeDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $settingsPath" }
    else { Set-Content $settingsPath '{}' -Encoding utf8; Write-Ok "created empty settings.json" }
}

# Ensure an event array contains a hook whose command references $Marker; returns
# $true if it added one. Idempotent: re-running never duplicates an entry.
function Add-HookEntry($SettingsObj, $Event, $Command, $Marker) {
    if (-not $SettingsObj.hooks.$Event) {
        $SettingsObj.hooks | Add-Member -NotePropertyName $Event -NotePropertyValue @() -Force
    }
    foreach ($e in $SettingsObj.hooks.$Event) {
        foreach ($h in $e.hooks) { if ($h.command -like "*$Marker*") { return $false } }
    }
    $SettingsObj.hooks.$Event += @{ matcher = '*'; hooks = @(@{ type = 'command'; command = $Command }) }
    return $true
}

if ($DryRun -and -not (Test-Path $settingsPath)) {
    # File doesn't exist and we're in dry-run; still surface the would-add message.
    Write-Ok "[dry-run] would register PostToolUse (log-tool-call) + Stop (decision-detect) hooks"
} else {
    # Tolerate zero-byte / whitespace-only settings.json (otherwise ConvertFrom-Json throws)
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    $settings = $raw | ConvertFrom-Json
    if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force }

    $addedPost    = Add-HookEntry $settings 'PostToolUse' "pwsh -NoProfile -File `"$hookDst`"" 'log-tool-call.ps1'
    $addedStop    = Add-HookEntry $settings 'Stop'        "pwsh -NoProfile -File `"$ddHookDst`"" 'decision-detect.ps1'
    $addedRunFeed = Add-HookEntry $settings 'PostToolUse' "pwsh -NoProfile -File `"$runFeedHookDst`"" 'run-feed.ps1'

    # statusLine: point at the legibility-feed status-line script (idempotent).
    $statusLineDst = Join-Path $claudeDir 'scripts\statusline-feed.ps1'
    $addedStatusLine = $false
    if (-not ($settings.PSObject.Properties.Name -contains 'statusLine') -or
        [string]::IsNullOrEmpty($settings.statusLine)) {
        $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue "pwsh -NoProfile -File `"$statusLineDst`"" -Force
        $addedStatusLine = $true
    }

    foreach ($r in @(
        @{ name = 'PostToolUse hook (log-tool-call)';  added = $addedPost },
        @{ name = 'Stop hook (decision-detect)';        added = $addedStop },
        @{ name = 'PostToolUse hook (run-feed)';        added = $addedRunFeed },
        @{ name = 'statusLine (statusline-feed)';       added = $addedStatusLine }
    )) {
        if (-not $r.added)  { Write-Skip "$($r.name) already registered" }
        elseif ($DryRun)    { Write-Ok "[dry-run] would register $($r.name)" }
    }

    if (($addedPost -or $addedStop -or $addedRunFeed -or $addedStatusLine) -and -not $DryRun) {
        # Backup before mutating: if write is interrupted, user can recover .bak
        $backupPath = "$settingsPath.bak"
        Copy-Item $settingsPath $backupPath -Force
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
        Write-Ok "registered hooks in settings.json (backup: $backupPath)"
    }
}

# --- Step 4: Deploy OTel env config helper ---
Write-Step "Deploying OTel env config helper"
$otelEnvSrc = Join-Path $repoRoot 'scripts\otel-env.ps1'
$otelEnvDst = Join-Path $claudeDir 'otel-env.ps1'
# Generate the helper inline if not present in repo
if (-not (Test-Path $otelEnvSrc)) {
    if (-not $DryRun) {
        @'
# Source this file in your PowerShell profile to enable Claude Code OTel export.
# Values verified against docs/superpowers/notes/otel-findings.md.
#
# To actually capture events to disk, run Claude Code with stdout/stderr redirected:
#   claude 2>&1 | Tee-Object -FilePath $env:CCO_TELEMETRY_PATH -Append
# (Or use a wrapper script that does the redirection -- see README.)

$env:CLAUDE_CODE_ENABLE_TELEMETRY = '1'
$env:OTEL_LOGS_EXPORTER = 'console'
$env:OTEL_LOG_TOOL_DETAILS = '1'

# Where the user redirects Claude Code's stdout (the console exporter target):
$env:CCO_TELEMETRY_PATH = (Join-Path $HOME '.claude/telemetry/events.jsonl')

# Optional: stricter export interval (default is generous; tighten for live dashboards)
# $env:OTEL_LOGS_EXPORT_INTERVAL = '5000'
'@ | Set-Content $otelEnvSrc
    }
}
Copy-WithPrompt $otelEnvSrc $otelEnvDst 'OTel env helper'

# Ensure telemetry dir exists
$telDir = Join-Path $claudeDir 'telemetry'
if (-not (Test-Path $telDir)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $telDir" }
    else { New-Item -ItemType Directory -Force -Path $telDir | Out-Null; Write-Ok "created $telDir" }
}

Write-Warn "Manual step: dot-source $otelEnvDst from your PowerShell profile, or run before each Claude Code session."

# --- Step 5: Deploy slash commands ---
Write-Step "Deploying slash commands"
foreach ($cmd in @(
    'log-routing.md','consolidate-routing.md',
    'job-start.md','job-status.md','job-list.md','job-phase.md',
    'job-resume.md','job-lesson.md','consolidate-lessons.md',
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md',
    'code-decompose.md','code-parallel.md','code-merge.md',
    'kb-index.md','kb-search.md',
    'decision-feedback.md','consolidate-decisions.md','project-init.md',
    'cost.md'
)) {
    $src = Join-Path $repoRoot "commands\$cmd"
    $dst = Join-Path $claudeDir "commands\$cmd"
    Copy-WithPrompt $src $dst "command: $cmd" -Force
}

# --- Step 5b: Deploy Plan 3 library scripts ---
Write-Step "Deploying Plan 3 scripts"
$scriptsDst = Join-Path $claudeDir 'scripts'
if (-not (Test-Path $scriptsDst)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $scriptsDst" }
    else { New-Item -ItemType Directory -Force -Path $scriptsDst | Out-Null; Write-Ok "created $scriptsDst" }
}
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'six-hats-lib.ps1', 'council-lib.ps1', 'code-lib.ps1', 'kb-lib.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1', 'cost-lib.ps1', 'runs-lib.ps1', 'statusline-feed.ps1')) {
    $src = Join-Path $repoRoot "scripts\$script"
    $dst = Join-Path $scriptsDst $script
    Copy-WithPrompt $src $dst "lib script: $script" -Force
}

# --- Step 5b2: Deploy fleet escape-hatch scripts ---
Write-Step "Deploying fleet escape-hatch scripts"
$fleetScriptsDst = Join-Path $claudeDir 'scripts/fleet'
if (-not (Test-Path $fleetScriptsDst)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $fleetScriptsDst" }
    else { New-Item -ItemType Directory -Force -Path $fleetScriptsDst | Out-Null; Write-Ok "created $fleetScriptsDst" }
}
# Deploy only real provider hatches — NOT the test stub (stub-http.ps1).
foreach ($hatch in @('lm-studio.ps1')) {
    $src = Join-Path $repoRoot "scripts\fleet\$hatch"
    $dst = Join-Path $fleetScriptsDst $hatch
    Copy-WithPrompt $src $dst "fleet hatch: $hatch" -Force
}

# --- Step 5b3: Deploy fleet.yaml seed ---
Write-Step "Deploying fleet.yaml seed"
$fleetSrc = Join-Path $repoRoot 'references\fleet.yaml'
$fleetDst = Join-Path $claudeDir 'fleet.yaml'
Copy-WithPrompt $fleetSrc $fleetDst 'fleet registry'

# --- Step 5c: Create jobs + knowledge dirs ---
Write-Step "Creating jobs + knowledge directories"
$dirsToCreate = @(
    (Join-Path $claudeDir 'jobs'),
    (Join-Path $claudeDir 'knowledge/universal'),
    (Join-Path $claudeDir 'knowledge/universal/topics'),
    (Join-Path $claudeDir 'knowledge/projects'),
    (Join-Path $claudeDir 'knowledge/.index')  # Plan 8 vector index lives here
)
foreach ($d in $dirsToCreate) {
    if (Test-Path $d) {
        Write-Skip "$d already exists"
    } elseif ($DryRun) {
        Write-Ok "[dry-run] would create $d"
    } else {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Write-Ok "created $d"
    }
}

# Seed empty KB headers
$kbSeeds = @{
    'knowledge/universal/routing.md'     = "# Routing (universal)`n`nWhich model for what — populated by /consolidate-lessons.`n"
    'knowledge/universal/user-prefs.md'  = "# User Preferences (universal)`n"
    'knowledge/universal/reasoning.md'   = "# Reasoning Patterns (universal)`n"
    'knowledge/universal/mistakes.md'    = "# Mistake Patterns (universal — cross-project)`n"
    'knowledge/universal/winners.md'     = "# Winners (universal — cross-project)`n"
}
foreach ($rel in $kbSeeds.Keys) {
    $dst = Join-Path $claudeDir $rel
    if (Test-Path $dst) { Write-Skip "$rel already seeded"; continue }
    if ($DryRun) { Write-Ok "[dry-run] would seed $rel"; continue }
    Set-Content -Path $dst -Value $kbSeeds[$rel] -Encoding utf8NoBOM
    Write-Ok "seeded $rel"
}

# --- Step 5e: Seed universal decision guidance ---
Write-Step "Seeding universal decision guidance"
$uniDecGuide = Join-Path $claudeDir 'knowledge/universal/decision-guidance.md'
if (-not (Test-Path $uniDecGuide)) {
    if ($DryRun) {
        Write-Ok "[dry-run] would seed $uniDecGuide"
    } else {
        # Ensure parent dir exists (it should from Plan 3, but be defensive)
        $uniDir = Split-Path -Parent $uniDecGuide
        if (-not (Test-Path $uniDir)) { New-Item -ItemType Directory -Force -Path $uniDir | Out-Null }
        Set-Content -Path $uniDecGuide -Value "# Universal Decision Guidance`n`n_Populated by /consolidate-decisions over time._`n" -Encoding utf8NoBOM
        Write-Ok "seeded universal/decision-guidance.md"
    }
} else {
    Write-Skip "universal decision guidance already present"
}

# --- Step 5f: Insert decision-capture rule into project root CLAUDE.md ---
Write-Step "Wiring decision-capture rule into project CLAUDE.md"
$claudeMd = Join-Path $repoRoot 'CLAUDE.md'
$ruleSrc = Join-Path $repoRoot 'references\CLAUDE-decision-capture-rule.md'
# Match ANY version of the marker, not just the version we currently ship.
# (Bug: hardcoding "v1" caused a duplicate v2 block to be appended on top of an existing v2.)
$ruleMarkerPattern = '<!--\s*decision-capture-rule:v\d+\s*-->'
if (-not (Test-Path $ruleSrc)) {
    Write-Warn "rule source $ruleSrc missing; skipping CLAUDE.md update"
} elseif (-not (Test-Path $claudeMd)) {
    if ($DryRun) {
        Write-Ok "[dry-run] would create $claudeMd and insert capture rule"
    } else {
        # Default (incl. non-interactive) is the documented [Y]: create it.
        $ans = if ($NonInteractive) { 'y' } else { Read-Host "    Project root has no CLAUDE.md. Create one with the decision-capture rule? [Y/n]" }
        if ($ans -ne 'n' -and $ans -ne 'N') {
            Copy-Item $ruleSrc $claudeMd
            Write-Ok "created CLAUDE.md with the capture rule"
        } else {
            Write-Skip "kept CLAUDE.md absent"
        }
    }
} else {
    $existing = Get-Content $claudeMd -Raw
    if ($existing -match $ruleMarkerPattern) {
        Write-Skip "capture rule already present in CLAUDE.md"
    } elseif ($DryRun) {
        Write-Ok "[dry-run] would append capture rule to $claudeMd"
    } else {
        $ruleText = Get-Content $ruleSrc -Raw
        Add-Content -Path $claudeMd -Value "`n`n$ruleText" -Encoding utf8NoBOM
        Write-Ok "appended capture rule to CLAUDE.md"
    }
}

# --- Step 5d: Migrate Plan 1 model-routing.md → knowledge/universal/routing.md ---
Write-Step "Migrating model-routing.md → knowledge/universal/routing.md"
$oldRouting = Join-Path $claudeDir 'model-routing.md'
$newRouting = Join-Path $claudeDir 'knowledge/universal/routing.md'
if ((Test-Path $oldRouting) -and -not (Test-Path "$oldRouting.migrated")) {
    if ($DryRun) {
        Write-Ok "[dry-run] would migrate $oldRouting → $newRouting"
    } else {
        # If the new file is the empty seed, replace it with the old content.
        # Otherwise append the old content to preserve any updates already in the new file.
        $existing = Get-Content $newRouting -Raw -ErrorAction SilentlyContinue
        if ($existing -match 'populated by /consolidate-lessons') {
            Copy-Item $oldRouting $newRouting -Force
        } else {
            Add-Content -Path $newRouting -Value "`n# --- Migrated from model-routing.md ---`n"
            Add-Content -Path $newRouting -Value (Get-Content $oldRouting -Raw)
        }
        # Rename the source so re-running bootstrap is a no-op
        Rename-Item -Path $oldRouting -NewName 'model-routing.md.migrated'
        Write-Ok "migrated; original kept at $oldRouting.migrated"
    }
} else {
    Write-Skip "migration already done or no source file"
}

# --- Step 6: Deploy catalog and journal seeds ---
Write-Step "Deploying catalog and journal"
$catSrc = Join-Path $repoRoot 'references\model-routing.md'
$catDst = Join-Path $claudeDir 'model-routing.md'
# Skip re-seeding the catalog if Step 5d already migrated it (migration renames to .migrated);
# re-deploying would resurrect the legacy file that was intentionally retired.
if (Test-Path "$catDst.migrated") {
    Write-Skip "Plan 1 catalog migrated to knowledge/universal/routing.md; skipping legacy catalog seed"
} else {
    Copy-WithPrompt $catSrc $catDst 'routing catalog' -Force:$Force
}

$logSrc = Join-Path $repoRoot 'references\model-routing-log.md'
$logDst = Join-Path $claudeDir 'model-routing-log.md'
Copy-IfMissing $logSrc $logDst 'routing journal (never overwritten)'

# --- Step 7: Verify backends ---
Write-Step "Verifying backends reachable"
$backends = @(
    @{ name = 'gemini';    test = { gemini --version 2>&1 | Out-String } },
    @{ name = 'codex';     test = { codex --version 2>&1 | Out-String } },
    @{ name = 'ollama';    test = { ollama --version 2>&1 | Out-String } },
    @{ name = 'lms';       test = { lms version 2>&1 | Out-String } },
    @{ name = 'gh';        test = { gh --version 2>&1 | Out-String } },
    @{ name = 'LM Studio HTTP'; test = {
        try { Invoke-RestMethod 'http://localhost:1234/v1/models' -TimeoutSec 3 | Out-Null; "ok" }
        catch { "unreachable: $($_.Exception.Message)" }
    } }
)
foreach ($b in $backends) {
    try {
        $out = & $b.test 2>&1
        # Rely on output-regex match only: $LASTEXITCODE is sticky across iterations
        # (the LM Studio HTTP probe doesn't invoke a native exe, so it would inherit
        # the prior backend's exit code). Regex covers all current probes ("ok" for
        # the HTTP one, "version" / "vN" for the version-flag ones).
        if ($out -match 'ok|version|v\d') { Write-Ok "$($b.name): reachable" }
        else { Write-Warn "$($b.name): $out" }
    } catch { Write-Warn "$($b.name): $($_.Exception.Message)" }
}

# Plan 4: run fleet doctor as part of verification
Write-Step "Running fleet doctor"
if (-not $DryRun) {
    & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts\fleet-doctor.ps1') -Path $fleetDst 2>&1 | Write-Host
} else {
    Write-Ok "[dry-run] would run fleet-doctor.ps1 against $fleetDst"
}

# --- Summary ---
Write-Step "Bootstrap complete (Plans 1-8 + Decision Loop + Cost Ledger)"
# Record the deployed version so the next run's Step 0 can report drift.
if (-not $DryRun) {
    Set-Content -Path $versionMarker -Value $repoVersion -Encoding utf8NoBOM
    Write-Ok "recorded deployed version $repoVersion -> $versionMarker"
} else {
    Write-Ok "[dry-run] would record deployed version $repoVersion -> $versionMarker"
}
# Plan 8 first-run hint
$nomicPresent = $false
try {
    $tagsOut = ollama list 2>&1 | Out-String
    if ($tagsOut -match 'nomic-embed-text') { $nomicPresent = $true }
} catch { }
if (-not $nomicPresent) {
    Write-Host ""
    Write-Warn "Plan 8 needs an embedding model. Run once:"
    Write-Host "       ollama pull nomic-embed-text"
    Write-Host "  Then build the KB index:  /kb-index --full"
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Source the OTel env helper before each session:  . $otelEnvDst"
Write-Host "  2. Start the live dashboard:"
Write-Host "       python -m uvicorn dashboard.main:app --port 8765   (then open http://localhost:8765)"
Write-Host "  3. Fleet: /fleet doctor to health-check providers, then fan out with"
Write-Host "       /ensemble, /six-hats, or /council across every model at once."
Write-Host "  4. Code phase: /code-decompose -> /code-parallel -> /code-merge"
Write-Host "       for parallel, worktree-isolated implementation."
Write-Host "  5. Jobs + KB: /job-start to track work; /kb-index --full then /kb-search"
Write-Host "       to build and query the knowledge base."
Write-Host "  6. Projects + cost: /projects for the multi-project command center; /cost for the ledger."
Write-Host "  7. Over time: /consolidate-routing, /consolidate-lessons, /consolidate-decisions"
Write-Host "       to tune the catalog and let the system self-improve."
Write-Host ""
