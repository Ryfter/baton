#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code PostToolUse hook: appends a one-line summary of every model dispatch
  to ~/.claude/model-routing-log.md.

.DESCRIPTION
  Reads a JSON event from stdin (Claude Code's hook protocol). Recognizes Bash
  invocations of model CLIs (ollama, gemini, codex, lms, copilot, gh copilot) and
  Agent tool dispatches. Skips everything else.

  Errors are written to ~/.claude/hooks/log-tool-call.err.log so a buggy hook
  never breaks Claude Code itself.

.PARAMETER JournalPath
  Override journal path (used by tests). Defaults to ~/.claude/model-routing-log.md.

.PARAMETER ErrorPath
  Override error log path (used by tests). Defaults to ~/.claude/hooks/log-tool-call.err.log.
#>

param(
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$ErrorPath   = (Join-Path $HOME '.claude/hooks/log-tool-call.err.log')
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

function Log-Error($msg) {
    try {
        $dir = Split-Path -Parent $ErrorPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Add-Content -Path $ErrorPath -Value "$ts | $msg"
    } catch {
        # Last resort: swallow. Never crash the hook.
    }
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
        Log-Error "empty stdin"
        exit 0
    }

    $event = $raw | ConvertFrom-Json -ErrorAction Stop

    $toolName = $event.tool_name
    $exit     = if ($event.tool_response.exit_code -ne $null) { $event.tool_response.exit_code } else { 0 }
    $elapsed  = if ($event.tool_response.duration_ms) { [int]($event.tool_response.duration_ms / 1000) } else { 0 }
    $ts       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')

    $target = $null
    $brief  = ''

    switch ($toolName) {
        'Bash' {
            $cmd = $event.tool_input.command
            $target = Get-DispatchTarget $cmd
            if ($target) {
                $target = "bash:$target"
            }
        }
        'Agent' {
            $sub = $event.tool_input.subagent_type
            $desc = $event.tool_input.description
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

    # Build the journal line. Quote the brief if present.
    $line = "$ts | hook | $target | ${elapsed}s | exit:$exit"
    if ($brief) {
        $line += " | `"$brief`""
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
    Log-Error "hook crashed: $($_.Exception.Message); input was: $raw"
    exit 0  # never propagate failure
}
