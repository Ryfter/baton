# Source this file in your PowerShell profile to enable Claude Code OTel export.
# Values verified against docs/superpowers/notes/otel-findings.md.
#
# IMPORTANT: Claude Code writes OTel events to STDERR (not stdout).
# Redirect stderr only so the interactive session stays on stdout:
#
#   claude 2>> $env:CCO_TELEMETRY_PATH
#
# Do NOT pipe stdout (claude 2>&1 | Tee-Object ...) — that breaks interactive
# mode. Claude detects piped stdout and switches to --print (non-interactive).

$env:CLAUDE_CODE_ENABLE_TELEMETRY = '1'
$env:OTEL_LOGS_EXPORTER = 'console'
$env:OTEL_LOG_TOOL_DETAILS = '1'

# Where Claude Code's stderr is redirected:
$env:CCO_TELEMETRY_PATH = (Join-Path $HOME '.claude/telemetry/events.jsonl')

# Flush OTel events every 1 second so api_request events are written before exit.
# Default is 5000ms which causes events to be lost in short sessions.
$env:OTEL_LOGS_EXPORT_INTERVAL = '1000'
