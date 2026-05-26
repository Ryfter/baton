#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code PostToolUse hook: appends a one-line summary of every model dispatch
  to ~/.claude/model-routing-log.md.

.DESCRIPTION
  Reads a JSON event from stdin (Claude Code's hook protocol). Recognizes Bash
  invocations of model CLIs (ollama, gemini, codex, lms, copilot, gh copilot) and
  Agent tool dispatches. Skips everything else.

  Note: `copilot` and `gh copilot` are distinct CLIs (separate products from
  GitHub) — both patterns are intentional.

  Errors are written to ~/.claude/hooks/log-tool-call.err.log so a buggy hook
  never breaks Claude Code itself.

.PARAMETER JournalPath
  Override journal path (used by tests). Defaults to ~/.claude/model-routing-log.md.

.PARAMETER ErrorPath
  Override error log path (used by tests). Defaults to ~/.claude/hooks/log-tool-call.err.log.
#>

param(
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/log-tool-call.err.log'),
    [string]$StatePath   = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path $HOME '.claude/current-job.json' })
)

$ErrorActionPreference = 'Continue'  # never crash Claude Code; log and move on

# Patterns that identify a model-dispatch Bash command.
# Tune this list after first real Octopus run by inspecting ~/.claude-octopus/logs/.
$dispatchPatterns = @(
    '^\s*ollama\s+(run|generate|chat)\b',
    '^\s*gemini\b',
    '^\s*codex\b',
    '^\s*lms\b',
    '^\s*copilot\b',
    '^\s*gh\s+copilot\b',
    '^\s*claude\s+-p\b'   # nested Claude Code call
)

function Write-ErrorLog($msg) {
    try {
        $dir = Split-Path -Parent $ErrorPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Add-Content -Path $ErrorPath -Value "$ts | $msg"
    } catch {
        # Last resort: swallow. Never crash the hook.
    }
}

function Sanitize-JournalField($s) {
    if (-not $s) { return $s }
    return ($s -replace '\|', '¦' -replace "`r?`n", ' ' -replace '"', '''')
}

function Get-DispatchTarget($command) {
    foreach ($pattern in $dispatchPatterns) {
        if ($command -match $pattern) {
            # Extract first ~60 chars as the target description
            $snippet = $command.Trim()
            if ($snippet.Length -gt 60) { $snippet = $snippet.Substring(0, 60) + '…' }
            return $snippet
        }
    }
    return $null
}

try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw) {
        Write-ErrorLog "empty stdin"
        exit 0
    }

    $evt = $raw | ConvertFrom-Json -ErrorAction Stop

    $toolName = $evt.tool_name
    $exit     = if ($null -ne $evt.tool_response.exit_code) { $evt.tool_response.exit_code } else { 0 }
    $elapsed  = if ($null -ne $evt.tool_response.duration_ms) { [int]($evt.tool_response.duration_ms / 1000) } else { 0 }
    $ts       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')

    $target = $null
    $brief  = ''

    switch ($toolName) {
        'Bash' {
            $cmd = $evt.tool_input.command
            $target = Get-DispatchTarget $cmd
            if ($target) {
                $target = "bash:$target"
            }
        }
        'Agent' {
            $sub = $evt.tool_input.subagent_type
            $desc = $evt.tool_input.description
            if ($sub) {
                $target = "agent:$sub"
                $brief = $desc
            }
        }
        default {
            # Read, Write, Edit, Grep, Glob, etc. — not dispatches; skip.
        }
    }

    if (-not $target) {
        exit 0  # not a dispatch, nothing to log
    }

    # Sanitize before assembling — pipe chars in the user payload must not break
    # the pipe-delimited journal format.
    $target = Sanitize-JournalField $target
    $brief  = Sanitize-JournalField $brief

    # Build the journal line. Quote the brief if present.
    $line = "$ts | hook | $target | ${elapsed}s | exit:$exit"
    if ($brief) {
        $line += " | `"$brief`""
    }

    # Plan 3: trailing job: + phase: tags from state file
    try {
        if (Test-Path $StatePath) {
            $raw = Get-Content $StatePath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $state = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($state.job_id -and $state.phase) {
                    $line += " | job:$($state.job_id) | phase:$($state.phase)"
                }
            }
        }
    } catch {
        # Corrupted state file — log and skip tags. Never crash the hook.
        Write-ErrorLog "state file read failed: $($_.Exception.Message)"
    }

    # Ensure journal dir exists
    $journalDir = Split-Path -Parent $JournalPath
    if (-not (Test-Path $journalDir)) {
        New-Item -ItemType Directory -Force -Path $journalDir | Out-Null
    }
    if (-not (Test-Path $JournalPath)) {
        Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---"
    }

    Add-Content -Path $JournalPath -Value $line
    exit 0

} catch {
    Write-ErrorLog "hook crashed: $($_.Exception.Message); input was: $raw"
    exit 0  # never propagate failure
}
