#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reads new OpenTelemetry log events from a JSONL file, transforms each into
  a journal `otel` line, appends to the routing journal.

.DESCRIPTION
  Idempotent via a line-count marker file (NOT byte offset — robust across text
  encodings). Re-running picks up only new lines appended since last run.

  Schema: this parser reads Claude Code's own flat-attribute OTel schema as
  documented in docs/superpowers/notes/otel-findings.md. It does NOT use the
  OTel gen-ai semantic conventions (gen_ai.usage.input_tokens etc.) — Claude
  Code emits its own event names (claude_code.api_request) with flat top-level
  attributes (model, input_tokens, output_tokens, cost_usd).

  Cost: prefers the native `cost_usd` field on the event. Falls back to
  computing from the catalog's pricing table when cost_usd is missing or zero
  — useful resilience if a future event type omits cost.

.PARAMETER EventsPath
  Path to the JSONL file Claude Code (or its OTel collector) writes events to.
  Defaults to ~/.claude/telemetry/events.jsonl.

.PARAMETER JournalPath
  Path to the routing journal. Defaults to ~/.claude/model-routing-log.md.

.PARAMETER MarkerPath
  Path to the line-count marker. Defaults to ~/.claude/telemetry/.parse-marker.

.PARAMETER CatalogPath
  Path to the routing catalog (read for pricing-table fallback only).
  Defaults to ~/.claude/model-routing.md.
#>

param(
    [string]$EventsPath  = (Join-Path $HOME '.claude/telemetry/events.jsonl'),
    [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md'),
    [string]$MarkerPath  = (Join-Path $HOME '.claude/telemetry/.parse-marker'),
    [string]$CatalogPath = (Join-Path $HOME '.claude/model-routing.md')
)

$ErrorActionPreference = 'Stop'

function Parse-PricingTable($catalogPath) {
    # Reads the catalog's "## Pricing table" markdown table; returns
    # @{ 'model-name' = @{ input = <decimal>; output = <decimal> } } in $/M tokens.
    $prices = @{}
    if (-not (Test-Path $catalogPath)) { return $prices }
    $content = Get-Content $catalogPath -Raw
    if ($content -notmatch '(?ms)## Pricing table.*?\n(\|.*?)(?:\n##|\z)') {
        return $prices
    }
    $tableText = $Matches[1]
    foreach ($line in $tableText -split "`n") {
        if ($line -match '^\|\s*([\w\.-]+)\s*\|\s*\$?([\d\.]+|TBD)\s*\|\s*\$?([\d\.]+|TBD)\s*\|') {
            $model = $Matches[1]
            $in    = if ($Matches[2] -eq 'TBD') { $null } else { [decimal]$Matches[2] }
            $out   = if ($Matches[3] -eq 'TBD') { $null } else { [decimal]$Matches[3] }
            if ($null -ne $in -and $null -ne $out) {
                $prices[$model] = @{ input = $in; output = $out }
            }
        }
    }
    return $prices
}

function Compute-Cost($model, $inTokens, $outTokens, $prices) {
    if (-not $prices.ContainsKey($model)) {
        return @{ cost = 0.0; warning = "no price for model '$model' in catalog" }
    }
    $p = $prices[$model]
    $cost = ($inTokens / 1000000.0) * [double]$p.input + ($outTokens / 1000000.0) * [double]$p.output
    return @{ cost = [math]::Round($cost, 4); warning = $null }
}

if (-not (Test-Path $EventsPath)) {
    # No events file yet — nothing to do.
    exit 0
}

# Determine where to start reading (line-count marker, robust across text encodings).
$skipCount = 0
if (Test-Path $MarkerPath) {
    $markerRaw = (Get-Content $MarkerPath -Raw)
    if ($markerRaw) { $skipCount = [int]($markerRaw.Trim()) }
}

$allLines = @(Get-Content $EventsPath)
if ($skipCount -ge $allLines.Count) {
    exit 0  # nothing new
}

$prices = Parse-PricingTable $CatalogPath

# Ensure journal exists.
$journalDir = Split-Path -Parent $JournalPath
if (-not (Test-Path $journalDir)) { New-Item -ItemType Directory -Force -Path $journalDir | Out-Null }
if (-not (Test-Path $JournalPath)) {
    Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---"
}

$newJournalLines = @()
$warnings = @()

for ($i = $skipCount; $i -lt $allLines.Count; $i++) {
    $line = $allLines[$i]
    if (-not $line) { continue }
    try {
        $evt = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $warnings += "skipped malformed JSONL line at index $i"
        continue
    }
    $attrs = $evt.attributes
    if (-not $attrs) { continue }

    # Flat Claude Code schema — NOT gen-ai conventions.
    $model = $attrs.model
    $inTok = if ($null -ne $attrs.input_tokens) { [int]$attrs.input_tokens } else { 0 }
    $outTok = if ($null -ne $attrs.output_tokens) { [int]$attrs.output_tokens } else { 0 }
    if (-not $model -or ($inTok -eq 0 -and $outTok -eq 0)) { continue }

    $ts = if ($evt.timestamp) { $evt.timestamp } else { (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') }

    # Cost: prefer the native cost_usd from the event; fall back to catalog table.
    $nativeCost = $null
    if ($null -ne $attrs.cost_usd) {
        try {
            $candidate = [double]$attrs.cost_usd
            if ($candidate -gt 0) { $nativeCost = $candidate }
        } catch { }
    }

    if ($null -ne $nativeCost) {
        $costValue = [math]::Round($nativeCost, 4)
    } else {
        $costResult = Compute-Cost $model $inTok $outTok $prices
        if ($costResult.warning) { $warnings += $costResult.warning }
        $costValue = $costResult.cost
    }
    $costStr = "{0:F4}" -f $costValue

    # Event-type: derive from event.body, strip claude_code. prefix for readability.
    $eventType = 'unknown'
    if ($evt.body) {
        $eventType = [string]$evt.body
        if ($eventType.StartsWith('claude_code.')) {
            $eventType = $eventType.Substring('claude_code.'.Length)
        }
    }

    $newJournalLines += "$ts | otel | $model | in:$inTok out:$outTok | `$$costStr | $eventType"
}

if ($newJournalLines.Count -gt 0) {
    Add-Content -Path $JournalPath -Value ($newJournalLines -join "`n")
}

# Update marker — total lines processed so far.
$markerDir = Split-Path -Parent $MarkerPath
if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
Set-Content -Path $MarkerPath -Value $allLines.Count.ToString()

if ($warnings.Count -gt 0) {
    foreach ($w in ($warnings | Select-Object -Unique)) {
        Write-Warning $w
    }
}

Write-Host "Processed $($newJournalLines.Count) new event(s); marker at line $($allLines.Count)"
