#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Research Gate (Sprint 4). Emits a build/adopt/adapt/inconclusive verdict for a
  task by grounding a cheap governed-fleet model in real evidence (local tool
  registry + prior research ensemble + KB + optional live search).
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-research-gate.ps1 wraps it
  for /baton:research-gate. routing-lib brings Select-Capability + Read-Tools and,
  via fleet-lib, Invoke-Fleet. Recommend-only — never blocks, never dispatches work.
.NOTES
  See docs/superpowers/specs/2026-06-18-research-gate-sprint4-design.md (d-rg-1..6).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability, Read-Tools (+ fleet-lib: Invoke-Fleet)

function Get-GateJsonBlock {
    <# Extract the JSON object from a reply that may be fenced or prose-wrapped:
       first '{' to last '}'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('{')
    $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function New-GateFallback {
    <# Deterministic inconclusive verdict when no model is available or the reply
       can't be parsed. The caller decides whether to retry / go deep. #>
    param([string]$Reason = 'unparseable')
    return @{
        recommendation='inconclusive'; options=@()
        rationale="Automated research gate could not produce a verdict ($Reason)."
        next_action='Run with --deep, or research manually before deciding build/adopt/adapt.'
        confidence=0.30; risk_if_wrong='medium'
        escalation_needed=$true; escalated=$false; escalated_from=$null
    }
}

function Test-GateEscalationNeeded {
    <# True when the verdict warrants a second pass on a stronger model:
       confidence below 0.70, OR risk_if_wrong high, OR recommendation inconclusive. #>
    param([Parameter(Mandatory)][hashtable]$Verdict)
    $conf = if ($null -ne $Verdict.confidence) { [double]$Verdict.confidence } else { 0.0 }
    if ($conf -lt 0.70) { return $true }
    if ([string]$Verdict.risk_if_wrong -eq 'high') { return $true }
    if ([string]$Verdict.recommendation -eq 'inconclusive') { return $true }
    return $false
}

function ConvertTo-GateHashtable {
    <# Parse the model's JSON reply into a normalized verdict hashtable, or $null
       when the reply has no valid JSON object. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-GateJsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    if ($null -eq $h['options']) { $h['options'] = @() } else { $h['options'] = @($h['options']) }
    if (-not $h.ContainsKey('escalated'))      { $h['escalated'] = $false }
    if (-not $h.ContainsKey('escalated_from')) { $h['escalated_from'] = $null }
    if (-not $h.ContainsKey('escalation_needed')) {
        $h['escalation_needed'] = (Test-GateEscalationNeeded -Verdict $h)
    }
    return $h
}

function Get-ToolsRegistrySummary {
    <# Compact "name — capability (cost_tier)" lines for enabled tools — the local
       'do we already have it wired?' grounding. Returns string[]; '' inputs -> @(). #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return ,([string[]]@()) }
    $lines = foreach ($t in (Read-Tools -Path $Path)) {
        if ($t.enabled -ne $true) { continue }
        "$($t.name) — $($t.capability) ($($t.cost_tier))"
    }
    return ,([string[]]$lines)
}

function Get-EnsembleSynthesis {
    <# Newest phases/research/ensemble-*/synthesis.md under a job dir, or '' when
       there is no job / no prior ensemble. Reads files only — no network. #>
    param([string]$JobDir)
    if (-not $JobDir -or -not (Test-Path $JobDir)) { return '' }
    $researchDir = Join-Path $JobDir 'phases/research'
    if (-not (Test-Path $researchDir)) { return '' }
    $hit = Get-ChildItem -Path $researchDir -Recurse -Filter 'synthesis.md' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hit) { return '' }
    return (Get-Content -LiteralPath $hit.FullName -Raw).Trim()
}

function Build-GatePrompt {
    <# Compose the gate instruction: role + strict-JSON verdict schema + an evidence
       block (local registry, prior ensemble, KB, live search) + the task text. #>
    param(
        [Parameter(Mandatory)][string]$TaskText,
        [string[]]$RegistryLines = @(),
        [string]$EnsembleText = '',
        [array]$KbHits = @(),
        [array]$SearchEvidence = @()
    )
    $schema = @'
{
  "recommendation": "build|adopt|adapt|inconclusive",
  "options": [
    { "name": "<tool/lib/service/internal>", "kind": "library|tool|service|internal",
      "fit": "strong|partial|weak", "note": "<one line: what it is + why it fits or not>" }
  ],
  "rationale": "<why this recommendation>",
  "next_action": "<one concrete next step>",
  "confidence": 0.0,
  "risk_if_wrong": "low|medium|high"
}
'@
    $evidence = "## Evidence`n"
    if ($RegistryLines.Count) { $evidence += "`nTools already wired locally:`n" + (($RegistryLines | ForEach-Object { "- $_" }) -join "`n") + "`n" }
    else { $evidence += "`nTools already wired locally: (none)`n" }
    if ($EnsembleText)  { $evidence += "`nPrior research ensemble synthesis:`n$EnsembleText`n" }
    if ($KbHits.Count)  { $evidence += "`nRelevant prior knowledge (KB):`n" + (($KbHits | ForEach-Object { "- $($_.source): $((""$($_.text)"" -replace '\s+',' ').Trim())" }) -join "`n") + "`n" }
    if ($SearchEvidence.Count) { $evidence += "`nLive web/registry search results:`n" + (($SearchEvidence | ForEach-Object { "- $($_.title) ($($_.url)): $($_.snippet)" }) -join "`n") + "`n" }

    return @"
You are a software research gate. Decide whether the task below should be built
from scratch, or whether something already exists to adopt or adapt. Use the
Evidence. Respond with ONLY valid JSON matching this schema exactly — no prose,
no markdown fences.

Schema:
$schema

Guidance: prefer adopt/adapt when a strong/partial-fit option exists; recommend
build only when nothing fits; recommend inconclusive when the evidence is too thin
to decide. confidence is your 0.0-1.0 certainty. List concrete options with honest
fit ratings.

$evidence

## Task
$TaskText
"@
}

function Format-GateMemo {
    <# Human-readable markdown memo from a verdict hashtable. #>
    param([Parameter(Mandatory)][hashtable]$Verdict)
    $rec  = ([string]$Verdict.recommendation).ToUpperInvariant()
    $conf = if ($null -ne $Verdict.confidence) { '{0:0.00}' -f [double]$Verdict.confidence } else { 'n/a' }
    $risk = [string]$Verdict.risk_if_wrong
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("RESEARCH GATE — recommendation: $rec  (confidence $conf, risk-if-wrong $risk)")
    if ($Verdict.escalated -eq $true) { [void]$sb.AppendLine("(escalated from $($Verdict.escalated_from))") }
    [void]$sb.AppendLine("Options:")
    foreach ($o in @($Verdict.options)) {
        [void]$sb.AppendLine("  • $($o.name) ($($o.kind), $($o.fit)) — $($o.note)")
    }
    [void]$sb.AppendLine("Rationale: $($Verdict.rationale)")
    [void]$sb.AppendLine("Next action: $($Verdict.next_action)")
    return $sb.ToString().TrimEnd()
}

function Invoke-EvidenceSearch {
    <# Gather external evidence via the -Searcher seam (default: real web +
       package-registry search). Only runs under -Deep; offline returns @() with
       ZERO searcher calls. Normalizes each result to @{source;title;snippet;url}.
       A searcher error degrades to @() — never throws (graceful degradation). #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [scriptblock]$Searcher = { param($q) Invoke-RealEvidenceSearch -Query $q },
        [switch]$Deep
    )
    if (-not $Deep) { return ,(@()) }
    try {
        $raw = & $Searcher $Query
    } catch {
        Write-Debug "Invoke-EvidenceSearch: $($_.Exception.Message)"
        return ,(@())
    }
    $norm = foreach ($r in @($raw)) {
        [pscustomobject]@{
            source  = [string]$r.source
            title   = [string]$r.title
            snippet = [string]$r.snippet
            url     = [string]$r.url
        }
    }
    return ,(@($norm))
}

function Invoke-RealEvidenceSearch {
    <# Default searcher: a single web/registry search round. Best-effort and
       box-private — returns @() if no search tool is wired. Replace/extend per box.
       Kept tiny on purpose: -Deep surfaces candidates; it does NOT verify existence. #>
    param([Parameter(Mandatory)][string]$Query)
    # No hard dependency on a specific search tool in the seed. A box wires its own
    # (e.g. a firecrawl/WebSearch shim) by overriding the -Searcher seam from the CLI.
    return @()
}
