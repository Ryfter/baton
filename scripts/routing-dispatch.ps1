#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing dispatcher (Slice 2). Dispatches the cheapest capable candidate
  for a capability, verifies its output with a heuristic grader, escalates up the
  ranked ladder on failure, and journals every attempt.
.DESCRIPTION
  Builds on Slice 1's Select-Capability. Heuristic grading only; the -Grader parameter
  on Invoke-RoutedCapability is the seam Slice 3 fills (LLM-judge + user ratings).
  See docs/superpowers/specs/2026-06-08-routing-s2-dispatch-verify-escalate-design.md.
#>

# routing-lib.ps1 gives Select-Capability/Read-Tools/Get-CostTierRank and dot-sources
# fleet-lib.ps1 (Invoke-Fleet, Invoke-Fleet-Cli) transitively.
. "$PSScriptRoot/routing-lib.ps1"

function Test-RoutingOutputHeuristic {
    <# Default grader. Deterministic and free. Contract: (Capability, Result) -> {passed, score, reason}.
       Result is a dispatch result hashtable {stdout, exit_code, ...}. Heuristic score is binary. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][hashtable]$Result
    )
    if ([int]$Result.exit_code -ne 0) {
        return @{ passed = $false; score = 0.0; reason = "exit $([int]$Result.exit_code)" }
    }
    $out = [string]$Result.stdout
    if ([string]::IsNullOrWhiteSpace($out)) {
        return @{ passed = $false; score = 0.0; reason = 'empty output' }
    }
    switch ($Capability) {
        'struct-extract' {
            try { $null = $out | ConvertFrom-Json -ErrorAction Stop }
            catch { return @{ passed = $false; score = 0.0; reason = 'not valid JSON' } }
        }
        'commit-msg' {
            $subject = $out -split "\r?\n" | Where-Object { $_.Trim() } | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($subject)) {
                return @{ passed = $false; score = 0.0; reason = 'no commit subject line' }
            }
        }
        default { }   # base gate already satisfied; non-empty output suffices (quality is Slice 3)
    }
    return @{ passed = $true; score = 1.0; reason = 'ok' }
}
