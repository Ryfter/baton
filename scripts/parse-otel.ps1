#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reads new OpenTelemetry events from a file, transforms each api_request
  event into a journal `otel` line, appends to the routing journal.

.DESCRIPTION
  Idempotent via an event-count marker file. Re-running picks up only new
  events appended since last run.

  Format: reads the multi-line JavaScript object format that Claude Code's
  console exporter writes to stderr (capture with `claude 2>> events.jsonl`).
  Also handles standard JSONL format (one JSON object per line) used in tests.

  The format detection is automatic:
    JSONL  — first non-whitespace content is '{"' (brace + quote)
    JS     — first non-whitespace content is '{' followed by a newline

  Schema: flat Claude Code attributes (model, input_tokens, output_tokens,
  cost_usd). NOT the OTel gen-ai semantic conventions. See:
  docs/superpowers/notes/otel-findings.md

.PARAMETER EventsPath
  Path to the file Claude Code writes events to.
  Defaults to ~/.claude/telemetry/events.jsonl.

.PARAMETER JournalPath
  Path to the routing journal. Defaults to $BATON_HOME/model-routing-log.md.

.PARAMETER MarkerPath
  Path to the event-count marker. Defaults to ~/.claude/telemetry/.parse-marker.

.PARAMETER CatalogPath
  Path to the routing catalog (read for pricing-table fallback only).
  Defaults to ~/.claude/model-routing.md.
#>

param(
    [string]$EventsPath  = (Join-Path $HOME '.claude/telemetry/events.jsonl'),
    [string]$JournalPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'model-routing-log.md' } else { Join-Path $HOME '.baton/model-routing-log.md' }),
    [string]$MarkerPath  = (Join-Path $HOME '.claude/telemetry/.parse-marker'),
    # Plan 3 migrated the catalog into the KB; fall back to the legacy path if the new one isn't there yet (e.g. pre-bootstrap).
    [string]$CatalogPath = $(
        $new = Join-Path $HOME '.claude/knowledge/universal/routing.md'
        $old = Join-Path $HOME '.claude/model-routing.md'
        if (Test-Path $new) { $new } else { $old }
    ),
    [string]$StatePath   = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } elseif ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'current-job.json' } else { Join-Path $HOME '.baton/current-job.json' })
)

$ErrorActionPreference = 'Stop'

# Plan 3: read current job/phase from state file once (parser is one-shot)
$script:JobTag = ''
try {
    if (Test-Path $StatePath) {
        $raw = Get-Content $StatePath -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $state = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($state.job_id -and $state.phase) {
                $script:JobTag = " | job:$($state.job_id) | phase:$($state.phase)"
            }
        }
    }
} catch {
    # Corrupted state — fall back to untagged
}

function Read-PricingTable($catalogPath) {
    # Reads the catalog's "## Pricing table" markdown table; returns
    # @{ 'model-name' = @{ input = <decimal>; output = <decimal> } } in $/M tokens.
    $prices = @{}
    if (-not (Test-Path $catalogPath)) { return $prices }
    $content = Get-Content $catalogPath -Raw
    if ($content -notmatch '(?ms)## Pricing table(?:\s*\([^)]*\))?\s*\n.*?\n(\| Model \|.*?)(?:\n##|\z)') {
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

function Get-Cost($model, $inTokens, $outTokens, $prices) {
    if (-not $prices.ContainsKey($model)) {
        return @{ cost = 0.0; warning = "no price for model '$model' in catalog" }
    }
    $p = $prices[$model]
    $cost = ($inTokens / 1000000.0) * [double]$p.input + ($outTokens / 1000000.0) * [double]$p.output
    return @{ cost = [math]::Round($cost, 4); warning = $null }
}

function Split-OtelBlocks([string]$content) {
    # Split content into individual event blocks.
    # JSONL: lines starting with '{"' => one JSON object per line.
    # JS multi-line: Claude Code console exporter format — split on top-level boundaries.
    $trimmed = $content.TrimStart()
    if ($trimmed -match '^\{"') {
        # JSONL: return non-empty lines that start with '{'
        return @($content -split "`n" | Where-Object { $_.Trim() -match '^\{' })
    }
    # JS multi-line: split between '} ... {' event boundaries
    return @(
        $content -split '(?<=\})\s*[\r\n]+\s*(?=\{)' |
        Where-Object { $_.Trim() -match '^\{' }
    )
}

function Get-OtelEventFields([string]$block) {
    # Extract fields from an api_request event block (JS object or JSON string).
    # Returns $null if not claude_code.api_request or missing required fields.

    # Body — determines event type
    $body = $null
    if ($block -match '"?body"?:\s*"([^"]+)"') { $body = $matches[1] }
    if ($body -ne 'claude_code.api_request') { return $null }

    # Timestamp: prefer "event.timestamp" (ISO-8601 string in attributes).
    # Fall back to top-level unix-microsecond timestamp on the envelope.
    $ts = $null
    if ($block -match '"event\.timestamp":\s*"([^"]+)"') {
        $raw = $matches[1]
        # Normalise Z suffix to explicit +00:00 for journal consistency
        if ($raw -match 'Z$') { $raw = $raw -replace 'Z$', '+00:00' }
        $ts = $raw
    } elseif ($block -match '"?timestamp"?:\s*(\d{13,})') {
        try {
            $ms = [long]$matches[1] / 1000
            $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($ms)
            $ts = $dt.ToString('yyyy-MM-ddTHH:mm:sszzz')
        } catch { $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') }
    } else {
        $ts = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    }

    # Model: unquoted key in JS format; quoted key in JSON
    $model = $null
    if ($block -match '(?m)^\s*model:\s*"([^"]+)"') { $model = $matches[1] }
    elseif ($block -match '"model":\s*"([^"]+)"')    { $model = $matches[1] }

    # Token counts: may be bare integers or quoted strings in JS format
    $inTok = 0; $outTok = 0
    if ($block -match '(?m)^\s*input_tokens:\s*"?(\d+)"?')   { $inTok  = [int]$matches[1] }
    elseif ($block -match '"input_tokens":\s*"?(\d+)"?')     { $inTok  = [int]$matches[1] }
    if ($block -match '(?m)^\s*output_tokens:\s*"?(\d+)"?')  { $outTok = [int]$matches[1] }
    elseif ($block -match '"output_tokens":\s*"?(\d+)"?')    { $outTok = [int]$matches[1] }

    if (-not $model -or ($inTok -eq 0 -and $outTok -eq 0)) { return $null }

    # Cost: bare decimal or quoted string; integer or decimal
    $costUsd = $null
    if ($block -match '(?m)^\s*cost_usd:\s*"?([\d]+(?:\.[\d]+)?)"?') {
        try { $c = [double]$matches[1]; if ($c -gt 0) { $costUsd = $c } } catch {}
    } elseif ($block -match '"cost_usd":\s*"?([\d]+(?:\.[\d]+)?)"?') {
        try { $c = [double]$matches[1]; if ($c -gt 0) { $costUsd = $c } } catch {}
    }

    return @{
        timestamp     = $ts
        model         = $model
        input_tokens  = $inTok
        output_tokens = $outTok
        cost_usd      = $costUsd
    }
}

if (-not (Test-Path $EventsPath)) { exit 0 }

# Idempotency via event-count marker (total blocks seen, not line count).
$skipCount = 0
if (Test-Path $MarkerPath) {
    $markerRaw = (Get-Content $MarkerPath -Raw)
    if ($markerRaw -match '^\d+') { $skipCount = [int]($markerRaw.Trim()) }
}

$content = Get-Content $EventsPath -Raw -ErrorAction SilentlyContinue
if (-not $content) { exit 0 }

$allBlocks = @(Split-OtelBlocks $content)
if ($skipCount -ge $allBlocks.Count) { exit 0 }

$prices = Read-PricingTable $CatalogPath

# Ensure journal exists.
$journalDir = Split-Path -Parent $JournalPath
if (-not (Test-Path $journalDir)) { New-Item -ItemType Directory -Force -Path $journalDir | Out-Null }
if (-not (Test-Path $JournalPath)) {
    Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---"
}

$newJournalLines = @()
$warnings = @()

for ($i = $skipCount; $i -lt $allBlocks.Count; $i++) {
    $fields = Get-OtelEventFields $allBlocks[$i]
    if (-not $fields) { continue }

    $ts     = $fields.timestamp
    $model  = $fields.model
    $inTok  = $fields.input_tokens
    $outTok = $fields.output_tokens

    # Cost: prefer native cost_usd from event; fall back to catalog pricing table.
    if ($null -ne $fields.cost_usd) {
        $costValue = [math]::Round($fields.cost_usd, 4)
    } else {
        $costResult = Get-Cost $model $inTok $outTok $prices
        if ($costResult.warning) { $warnings += $costResult.warning }
        $costValue = $costResult.cost
    }
    $costStr = "{0:F4}" -f $costValue

    $newJournalLines += "$ts | otel | $model | in:$inTok out:$outTok | `$$costStr | api_request$($script:JobTag)"
}

if ($newJournalLines.Count -gt 0) {
    Add-Content -Path $JournalPath -Value ($newJournalLines -join "`n")
}

# Update marker: total event blocks seen so far (not line count).
$markerDir = Split-Path -Parent $MarkerPath
if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
Set-Content -Path $MarkerPath -Value $allBlocks.Count.ToString()

if ($warnings.Count -gt 0) {
    foreach ($w in ($warnings | Select-Object -Unique)) {
        Write-Warning $w
    }
}

Write-Host "Processed $($newJournalLines.Count) new event(s); marker at block $($allBlocks.Count)"
