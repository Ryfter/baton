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

function Write-RoutingJournalLine {
    <# Append one compact JSON row (JSONL) per dispatch attempt. A logging fault warns
       and returns; it never crashes the dispatch loop. -Timestamp is injectable for tests. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Source, [string]$Kind, [string]$CostTier,
        [int]$ExitCode, [int]$DurationS,
        [bool]$Passed, [double]$Score, [string]$Reason,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp; capability = $Capability; candidate = $Candidate
        source = $Source; kind = $Kind; cost_tier = $CostTier
        exit_code = $ExitCode; duration_s = $DurationS
        passed = $Passed; score = $Score; reason = $Reason
    }
    try {
        $line = ($row | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $JournalPath -Value $line -Encoding utf8NoBOM
    } catch {
        Write-Warning "routing journal write failed: $($_.Exception.Message)"
    }
}

function Invoke-Tool {
    <# Dispatch a tools.yaml kind:cli entry. Pipe the prompt via stdin when stdin:true
       (robust path, immune to embedded quotes/$/backticks); otherwise pass it as the
       final positional arg. Returns @{ stdout; stderr; exit_code; duration_s }.
       -TimeoutS is accepted for signature parity with Invoke-Fleet-Cli (not enforced inline). #>
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$TimeoutS = 120
    )
    $cmd = [string]$Tool.command_template
    $tokens = $cmd -split '\s+' | Where-Object { $_ -ne '' }
    $exe = $tokens[0]
    $rest = @($tokens | Select-Object -Skip 1)
    $start = Get-Date
    try {
        if ($Tool.stdin -eq $true) {
            $tmpFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmpFile -Value $Prompt -Encoding utf8NoBOM
                $out = (Get-Content -LiteralPath $tmpFile -Raw | & $exe @rest 2>&1 | Out-String)
            } finally {
                Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
            }
        } else {
            $out = (& $exe @rest $Prompt 2>&1 | Out-String)
        }
        $exit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration }
    }
}
