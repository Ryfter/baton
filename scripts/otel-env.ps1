# Source this file in your PowerShell profile to enable Claude Code OTel export.
# Values verified against docs/superpowers/notes/otel-findings.md (smoke-tested 2026-05-24).
#
# HOW OTEL CAPTURE WORKS:
#
#   Claude Code writes OTel events to STDOUT in non-interactive (--print) mode.
#   In interactive (TTY) mode, OTel events are suppressed to avoid terminal noise.
#
#   For non-interactive (automated) tasks — capture stdout to append to telemetry:
#
#     claude -p "your task" >> $env:CCO_TELEMETRY_PATH
#
#   The response text and OTel events are both in stdout. The parser filters
#   to only api_request blocks and ignores the rest.
#
#   For interactive sessions: OTel cost tracking is not available via console
#   exporter. Use the PostToolUse hook for dispatch tracking instead.
#   (Plan 2: otelcol daemon provides full coverage for both modes.)

$env:CLAUDE_CODE_ENABLE_TELEMETRY = '1'
$env:OTEL_LOGS_EXPORTER = 'console'
$env:OTEL_LOG_TOOL_DETAILS = '1'

# Where captured stdout is appended:
$env:CCO_TELEMETRY_PATH = (Join-Path $HOME '.claude/telemetry/events.jsonl')

# Flush OTel events every 1 second so api_request events appear before the response.
# Default is 5000ms.
$env:OTEL_LOGS_EXPORT_INTERVAL = '1000'
