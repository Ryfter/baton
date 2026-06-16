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
