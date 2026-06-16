#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:triage runner. Resolves the task (url/file/text), invokes the Triage
  Agent through the fleet, and prints the triage object as YAML (default) or JSON.
.NOTES
  Recommend-only: classifies and recommends; it does NOT dispatch the work or
  mutate GitHub. Sprint 3 wires the output into labels/Project fields.
#>
param(
    [string]$Url,
    [string]$File,
    [string]$Text,
    [switch]$Json,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [string]$ToolsPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'tools.yaml' } else { Join-Path $HOME '.baton/tools.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'triage-lib.ps1')

# Test seam: a stub fleet + canned JSON dispatcher injected via env so the suite
# never calls a real model. Absent in production.
$dispatcher = $null
if ($env:BATON_TRIAGE_TEST_FLEET) { $FleetPath = $env:BATON_TRIAGE_TEST_FLEET }
if ($env:BATON_TRIAGE_TEST_JSON) {
    $canned = $env:BATON_TRIAGE_TEST_JSON
    $dispatcher = { param($c,$p) @{ stdout = $canned; stderr=''; exit_code = 0; duration_s = 1 } }
}

$taskText = Read-TriageInput -Url $Url -File $File -Text $Text
$triageArgs = @{ Input = $taskText; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
if ($dispatcher) { $triageArgs['Dispatcher'] = $dispatcher }
$triage = Invoke-TriageAgent @triageArgs

if ($Json) {
    $triage | ConvertTo-Json -Depth 6
} else {
    # Deterministic key order for a readable YAML-ish block.
    $order = @('type','priority','estimate','risk','research_required','recommended_platform',
               'recommended_model','agent_type','area','next_action','confidence','ambiguity',
               'escalation_needed','escalated','escalated_from','pipeline')
    foreach ($k in $order) {
        if (-not $triage.ContainsKey($k)) { continue }
        $v = $triage[$k]
        if ($k -eq 'pipeline') {
            Write-Host "pipeline:"
            foreach ($stage in @($v)) { Write-Host "  - $stage" }
        } else {
            Write-Host "${k}: $v"
        }
    }
}
