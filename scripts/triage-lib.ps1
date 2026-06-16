#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Triage Agent (Sprint 1). Classifies an issue/task into a structured triage
  object by routing through the fleet (role=triage; Haiku preferred), with
  Sonnet escalation on low confidence / high risk.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-triage.ps1 wraps it for
  the /baton:triage command. routing-lib.ps1 brings Select-Capability and, via
  fleet-lib.ps1, Invoke-Fleet for dispatch.
.NOTES
  See docs/superpowers/specs/2026-06-15-triage-agent-sprint1-design.md (d045).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function Read-TriageInput {
    <# Resolve the task description from exactly one source: -Url (gh issue view),
       -File (local markdown), or -Text (inline). Returns the normalized string. #>
    param(
        [string]$Url,
        [string]$File,
        [string]$Text
    )
    $sources = @($Url, $File, $Text | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($sources.Count -ne 1) {
        throw "Read-TriageInput requires exactly one of -Url, -File, or -Text."
    }
    if ($Url)  { return (& gh issue view $Url --json title,body --jq '"# " + .title + "\n\n" + .body' 2>&1 | Out-String).Trim() }
    if ($File) {
        if (-not (Test-Path $File)) { throw "Triage input file not found: $File" }
        return (Get-Content -LiteralPath $File -Raw).Trim()
    }
    return $Text.Trim()
}

function Build-TriagePrompt {
    <# Compose the triage instruction: role + strict-JSON schema + the task text.
       Temperature is left to the provider default; the prompt enforces JSON-only. #>
    param([Parameter(Mandatory)][string]$TaskText)
    $schema = @'
{
  "type": "bug|plan|spec|coding|test|review|polish|chore|docs|research",
  "priority": "P0|P1|P2|P3|P4",
  "estimate": "XS|S|M|L|XL",
  "risk": "low|medium|high",
  "research_required": true,
  "recommended_platform": "Claude|Codex|Copilot|Gemini|Local|Human",
  "recommended_model": "Haiku|Sonnet|Opus|Codex|Copilot|local/<name>",
  "agent_type": "Triage|Planning|Implementation|Review|Research|Polish",
  "pipeline": ["<stage>", "..."],
  "area": "<repo/component area or null>",
  "next_action": "<one sentence: the next concrete step>",
  "confidence": 0.0,
  "ambiguity": "low|medium|high"
}
'@
    return @"
You are a software task triage agent. Classify the task below and respond with
ONLY valid JSON matching this schema exactly. No prose, no markdown fences.

Schema:
$schema

Guidance: confidence is your 0.0-1.0 certainty in the classification. Set
ambiguity to high when the task lacks the context needed to classify it.
pipeline is the ordered list of phases the work should pass through.

Task:
$TaskText
"@
}

function Test-TriageEscalationNeeded {
    <# True when the triage result warrants a second-pass on a stronger model:
       confidence below 0.70, OR risk high, OR ambiguity high. #>
    param([Parameter(Mandatory)][hashtable]$Triage)
    $conf = if ($null -ne $Triage.confidence) { [double]$Triage.confidence } else { 0.0 }
    if ($conf -lt 0.70) { return $true }
    if ([string]$Triage.risk -eq 'high') { return $true }
    if ([string]$Triage.ambiguity -eq 'high') { return $true }
    return $false
}

function Get-TriageJsonBlock {
    <# Extract the JSON object from a model reply that may be fenced or prose-wrapped:
       take the substring from the first '{' to the last '}'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('{')
    $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function New-TriageFallback {
    <# Deterministic low-confidence object used when no model is available or the
       reply can't be parsed. The caller decides whether to retry. #>
    param([string]$Reason = 'unparseable')
    return @{
        type='unknown'; priority='P3'; estimate='M'; risk='medium'
        research_required=$true; recommended_platform='Human'; recommended_model='Sonnet'
        agent_type='Triage'; pipeline=@('human_review'); area=$null
        next_action="Manual triage needed ($Reason)."
        confidence=0.40; ambiguity='high'
        escalation_needed=$true; escalated=$false; escalated_from=$null
    }
}

function ConvertTo-TriageHashtable {
    <# Parse the model's JSON reply into a normalized triage hashtable, or $null
       when the reply has no valid JSON object. #>
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-TriageJsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    if (-not $h.ContainsKey('escalated'))      { $h['escalated'] = $false }
    if (-not $h.ContainsKey('escalated_from')) { $h['escalated_from'] = $null }
    if (-not $h.ContainsKey('escalation_needed')) {
        $h['escalation_needed'] = (Test-TriageEscalationNeeded -Triage $h)
    }
    return $h
}

function Invoke-TriageAgent {
    <# Classify a task. Routes through Select-Capability (role=triage; Haiku
       preferred), dispatches the cheapest candidate, parses strict JSON, and
       escalates to a champion-ranked second candidate on low confidence / high
       risk. -Dispatcher injects dispatch for tests; real path uses Invoke-Fleet. #>
    param(
        [Parameter(Mandatory)][string]$Input,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher
    )
    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -Path $FleetPath -NoJournal
    }

    $cands = Select-Capability -Capability triage -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
    if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
        return (New-TriageFallback -Reason 'no triage-capable worker available')
    }

    # $Input is an automatic variable (pipeline enumerator) in PowerShell — read via
    # $PSBoundParameters to get the value bound to the -Input parameter.
    $taskText = [string]$PSBoundParameters['Input']
    $prompt = Build-TriagePrompt -TaskText $taskText
    $pick   = $cands[0]
    $res    = & $dispatch $pick $prompt
    if ([int]$res.exit_code -ne 0) { return (New-TriageFallback -Reason "dispatch exit $([int]$res.exit_code)") }

    $triage = ConvertTo-TriageHashtable -RawStdout ([string]$res.stdout)
    if ($null -eq $triage) { return (New-TriageFallback -Reason 'model returned no valid JSON') }

    if (Test-TriageEscalationNeeded -Triage $triage) {
        $champs = Select-Capability -Capability triage -MaxCostTier $MaxCostTier -SelectionMode champion -FleetPath $FleetPath -ToolsPath $ToolsPath
        $esc = @($champs | Where-Object { $_.name -ne $pick.name }) | Select-Object -First 1
        if ($esc) {
            $res2 = & $dispatch $esc $prompt
            if ([int]$res2.exit_code -eq 0) {
                $triage2 = ConvertTo-TriageHashtable -RawStdout ([string]$res2.stdout)
                if ($null -ne $triage2) {
                    $triage2['escalated'] = $true
                    $triage2['escalated_from'] = $pick.name
                    return $triage2
                }
            }
        }
    }
    return $triage
}
