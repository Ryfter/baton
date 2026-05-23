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
    [switch]$Force  # overwrite the catalog without prompting
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $here
$claudeDir = Join-Path $HOME '.claude'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    skip: $msg" -ForegroundColor Yellow }
function Write-Warn($msg) { Write-Host "    warn: $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    err: $msg" -ForegroundColor Red }

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

function Copy-WithPrompt($src, $dst, $label) {
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

# --- Step 2: Deploy the hook ---
Write-Step "Deploying PostToolUse hook"
$hookSrc = Join-Path $repoRoot 'scripts\hooks\log-tool-call.ps1'
$hookDst = Join-Path $claudeDir 'hooks\log-tool-call.ps1'
Copy-WithPrompt $hookSrc $hookDst 'hook script'

# --- Step 3: Merge settings.json PostToolUse entry ---
Write-Step "Registering hook in settings.json"
$settingsPath = Join-Path $claudeDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    if ($DryRun) { Write-Ok "[dry-run] would create $settingsPath" }
    else { Set-Content $settingsPath '{}' -Encoding utf8; Write-Ok "created empty settings.json" }
}

if ($DryRun -and -not (Test-Path $settingsPath)) {
    # File doesn't exist and we're in dry-run; still surface the would-add message
    # so the user gets full visibility into what a real run would do.
    Write-Ok "[dry-run] would add PostToolUse entry pointing to $hookDst"
} else {
    # Tolerate zero-byte / whitespace-only settings.json (otherwise ConvertFrom-Json throws)
    $raw = Get-Content $settingsPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = '{}' }
    $settings = $raw | ConvertFrom-Json
    if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force }
    if (-not $settings.hooks.PostToolUse) { $settings.hooks | Add-Member -NotePropertyName PostToolUse -NotePropertyValue @() -Force }

    $hookEntry = @{
        matcher = '*'
        hooks = @(@{
            type = 'command'
            command = "pwsh -NoProfile -File `"$hookDst`""
        })
    }

    # Check for existing entry pointing to our hook
    $exists = $false
    foreach ($e in $settings.hooks.PostToolUse) {
        foreach ($h in $e.hooks) {
            if ($h.command -like "*log-tool-call.ps1*") { $exists = $true }
        }
    }
    if ($exists) {
        Write-Skip "hook already registered in settings.json"
    } elseif ($DryRun) {
        Write-Ok "[dry-run] would add PostToolUse entry pointing to $hookDst"
    } else {
        # Backup before mutating: if write is interrupted, user can recover .bak
        $backupPath = "$settingsPath.bak"
        Copy-Item $settingsPath $backupPath -Force
        $settings.hooks.PostToolUse += $hookEntry
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8
        Write-Ok "added PostToolUse entry to settings.json (backup: $backupPath)"
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
foreach ($cmd in @('log-routing.md', 'consolidate-routing.md')) {
    $src = Join-Path $repoRoot "commands\$cmd"
    $dst = Join-Path $claudeDir "commands\$cmd"
    Copy-WithPrompt $src $dst "command: $cmd"
}

# --- Step 6: Deploy catalog and journal seeds ---
Write-Step "Deploying catalog and journal"
$catSrc = Join-Path $repoRoot 'references\model-routing.md'
$catDst = Join-Path $claudeDir 'model-routing.md'
Copy-WithPrompt $catSrc $catDst 'routing catalog'

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

# --- Summary ---
Write-Step "Bootstrap complete (Plan 1 scope)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Source the OTel env helper in your PowerShell profile or before each session:"
Write-Host "       . $otelEnvDst"
Write-Host "  2. Run a real Claude Code task to populate the journal."
Write-Host "  3. Inspect $logDst to see hook + otel lines."
Write-Host "  4. After a week of use, run /consolidate-routing to tune the catalog."
Write-Host ""
Write-Host "Plan 2 (dashboard) will extend this script with Python venv + FastAPI app setup."
