#!/usr/bin/env pwsh
# Test harness for scripts/parse-otel.ps1
# Uses the real Claude Code OTel schema (flat attributes, native cost_usd) per
# docs/superpowers/notes/otel-findings.md.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$parser = Join-Path $here 'parse-otel.ps1'
$fixture = Join-Path $here 'fixtures\otel-sample.jsonl'
$tmpEvents = Join-Path $env:TEMP "otel-test-events-$(Get-Random).jsonl"
$tmpJournal = Join-Path $env:TEMP "otel-test-journal-$(Get-Random).md"
$tmpMarker = Join-Path $env:TEMP "otel-test-marker-$(Get-Random).txt"
$catalog = Join-Path (Split-Path $here -Parent) 'references\model-routing.md'

Copy-Item $fixture $tmpEvents
Set-Content $tmpJournal "# Model Routing Log`n# --- entries below this line ---"

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$lines = Get-Content $tmpJournal
$otelLines = @($lines | Where-Object { $_ -match '\| otel \|' })
Assert "two otel lines produced from 2-event fixture" ($otelLines.Count -eq 2)
Assert "first line model is sonnet" ($otelLines[0] -match 'claude-sonnet-4-6')
Assert "first line tokens" ($otelLines[0] -match 'in:3214 out:892')
Assert "first line cost present" ($otelLines[0] -match '\| \$\d+\.\d+ \|')
# ISO-8601 timestamp with offset (locale-independent shape).
Assert "first line timestamp is ISO-8601 with offset" ($otelLines[0] -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}')
# Native cost_usd from the fixture (0.0231) — NOT what catalog pricing would compute.
# Catalog would compute: 3214/1e6 * 3 + 892/1e6 * 15 = 0.009642 + 0.01338 = 0.023022 -> rounds to 0.0230
# The fixture explicitly carries 0.0231, so this distinguishes "read native" from "compute from table".
Assert "first line uses native cost_usd (\$0.0231)" ($otelLines[0] -match '\| \$0\.0231 \|')
Assert "first line event-type is api_request (claude_code. prefix stripped)" ($otelLines[0] -match '\| api_request\s*$')

# Idempotence: re-run should not duplicate
& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$linesAfter = Get-Content $tmpJournal
$otelLinesAfter = @($linesAfter | Where-Object { $_ -match '\| otel \|' })
Assert "idempotent: no duplicates on second run" ($otelLinesAfter.Count -eq 2)

# Append new event: re-run should pick up just the new one
Add-Content $tmpEvents -Value '{"timestamp":"2026-05-22T14:40:00.000Z","severity":"INFO","body":"claude_code.api_request","attributes":{"model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50,"cost_usd":0.0011,"request_id":"req_ghi","session.id":"sess_xyz"}}'

& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$linesFinal = Get-Content $tmpJournal
$otelLinesFinal = @($linesFinal | Where-Object { $_ -match '\| otel \|' })
Assert "picks up newly appended event" ($otelLinesFinal.Count -eq 3)

# Test: fallback to pricing-table when cost_usd is missing
$noNativeCost = '{"timestamp":"2026-05-22T15:00:00.000Z","body":"claude_code.api_request","attributes":{"model":"claude-sonnet-4-6","input_tokens":1000,"output_tokens":1000}}'
Add-Content $tmpEvents -Value $noNativeCost

& pwsh -NoProfile -File $parser `
    -EventsPath $tmpEvents `
    -JournalPath $tmpJournal `
    -MarkerPath $tmpMarker `
    -CatalogPath $catalog | Out-Null

$linesAfter2 = Get-Content $tmpJournal
$otelLinesAfter2 = @($linesAfter2 | Where-Object { $_ -match '\| otel \|' })
Assert "fallback computes from pricing table" ($otelLinesAfter2[-1] -match '\| \$0\.0180 \|')
# 1000 in @ $3/M + 1000 out @ $15/M = $0.003 + $0.015 = $0.018

Remove-Item $tmpEvents, $tmpJournal, $tmpMarker -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed" -ForegroundColor Green
    exit 0
}
