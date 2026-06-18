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
