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
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"
. "$PSScriptRoot/prime-hours.ps1"

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
        [string]$Grader = 'heuristic',
        [string]$Stage,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl'),
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp; capability = $Capability; candidate = $Candidate
        source = $Source; kind = $Kind; cost_tier = $CostTier
        exit_code = $ExitCode; duration_s = $DurationS
        passed = $Passed; score = $Score; reason = $Reason; grader = $Grader
    }
    if ($Stage) { $row['stage'] = $Stage }
    try {
        $line = ($row | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $JournalPath -Value $line -Encoding utf8NoBOM
    } catch {
        Write-Warning "routing journal write failed: $($_.Exception.Message)"
    }
}

function Invoke-Tool {
    <# Dispatch a routable tools.yaml transport. cli/python share the legacy
       execution branch; http and stdio-json delegate to fleet-lib primitives. #>
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$TimeoutS = 120
    )
    $guard = Get-InstrumentPromptGuard -Instrument $Tool -Prompt $Prompt
    if ($null -ne $guard) { return $guard }
    $kind = [string]$Tool.kind
    if ($kind -eq 'http') {
        $httpResult = Invoke-FleetHttpChat -Provider $Tool -Prompt $Prompt
        if (-not $httpResult.ContainsKey('tokens')) {
            $httpUsage = Get-FleetTokenUsage -Provider $Tool -Prompt $Prompt -Stdout ([string]$httpResult.stdout)
            $httpResult.tokens = $httpUsage.tokens
            $httpResult.tokens_basis = $httpUsage.tokens_basis
        }
        return $httpResult
    }
    if ($kind -eq 'stdio-json') {
        return Invoke-FleetStdioJson -Instrument $Tool -Prompt $Prompt -TimeoutS $TimeoutS
    }
    if ($kind -notin @('cli', 'python')) {
        throw "Unsupported tool kind '$kind'."
    }
    $cmd = [string]$Tool.command_template
    $commandTokens = $cmd -split '\s+' | Where-Object { $_ -ne '' }
    $exe = $commandTokens[0]
    $rest = @($commandTokens | Select-Object -Skip 1)
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
        $usage = Get-FleetTokenUsage -Provider $Tool -Prompt $Prompt -Stdout ([string]$out)
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration; tokens = $usage.tokens; tokens_basis = $usage.tokens_basis }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration; tokens = 0; tokens_basis = 'estimate' }
    }
}

function Invoke-RoutedCandidate {
    <# Dispatch ONE candidate, grade it with the effective grader, journal the row, and
       return both the attempt summary and the raw result. Shared by Invoke-RoutedCapability
       (escalate-and-stop) and Invoke-CapabilityCalibration (fan-out). The caller decides
       whether to stop on a pass. -EffGrader is the already-resolved grader ($null = heuristic
       default). -Dispatcher is test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)]$Candidate,
        [Parameter(Mandatory)][string]$Prompt,
        [scriptblock]$EffGrader,
        [scriptblock]$Dispatcher,
        [int]$Rank = [int]::MinValue,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
        [string]$Stage,
        [int]$TimeoutS = 120,
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    $c = $Candidate
    $supportedToolKinds = @('cli', 'python', 'http', 'stdio-json')
    if ($c.source -eq 'tools' -and [string]$c.kind -notin $supportedToolKinds) {
        $reason = "unsupported kind $($c.kind) (supported: $($supportedToolKinds -join ', '))"
        $attempt = [pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0; gate=$null; grader='heuristic' }
        Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath -Stage $Stage
        return @{ attempt = $attempt; result = @{ stdout=''; stderr=''; exit_code=-1; duration_s=0 } }
    }

    # Additive declaration guard. Candidate passthrough means injected dispatchers
    # and real rows take the same pre-call path without rereading ambient config.
    if ($null -ne $c.max_prompt_bytes -and
        -not [string]::IsNullOrWhiteSpace([string]$c.max_prompt_bytes)) {
        $guard = Get-InstrumentPromptGuard `
            -Instrument @{ max_prompt_bytes = $c.max_prompt_bytes } -Prompt $Prompt
        if ($null -ne $guard) {
            $reason = [string]$guard.stderr
            $attempt = [pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0; gate=$null; grader='heuristic' }
            Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath -Stage $Stage
            return @{ attempt = $attempt; result = $guard }
        }
    }

    # Slice A: prime-hours gate (opt-in via -Rank; guards only the paid tier).
    if ($Rank -ne [int]::MinValue -and $c.cost_tier -eq 'paid') {
        $gateArgs = @{ Rank = $Rank; CostTier = 'paid' }
        if ($PrimeHoursConfig) { $gateArgs['ConfigPath'] = $PrimeHoursConfig }
        if ($PSBoundParameters.ContainsKey('GateNow')) { $gateArgs['Now'] = $GateNow }
        $gate = Test-PrimeHoursGate @gateArgs
        $eff = if ($gate.decision -eq 'ask') { if ($gate.default -eq 'run') { 'allow' } else { 'defer' } } else { $gate.decision }
        if ($eff -eq 'defer') {
            $reason = "deferred: prime-hours $($gate.reason)"
            $attempt = [pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0; gate=$gate.decision; grader=$null }
            Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath -Stage $Stage
            return @{ attempt = $attempt; result = @{ stdout=''; stderr=''; exit_code=-1; duration_s=0 } }
        }
        $script:__lastGateDecision = $gate.decision   # 'ask' or 'allow' that proceeded
    } else {
        $script:__lastGateDecision = $null
    }

    # Dispatch (injected for tests, else real).
    try {
        if ($Dispatcher) {
            $result = & $Dispatcher $c $Prompt
        } elseif ($c.source -eq 'tools') {
            $tool = Read-Tools -Path $ToolsPath | Where-Object { $_.name -eq $c.name } | Select-Object -First 1
            $result = Invoke-Tool -Tool $tool -Prompt $Prompt -TimeoutS $TimeoutS
        } else {
            $result = Invoke-Fleet -Name $c.name -Prompt $Prompt -Path $FleetPath -NoJournal
        }
    } catch {
        $result = @{ stdout=''; stderr=$_.Exception.Message; exit_code=-1; duration_s=0 }
    }

    # Verify (effective grader: resolved -Grader/-Judge, else heuristic default).
    try {
        if ($EffGrader) { $verdict = & $EffGrader -Capability $Capability -Result $result }
        else            { $verdict = Test-RoutingOutputHeuristic -Capability $Capability -Result $result }
    } catch {
        $verdict = @{ passed=$false; score=0.0; reason="grader error: $($_.Exception.Message)" }
    }
    $graderTag = if ($verdict.grader) { [string]$verdict.grader } else { 'heuristic' }

    $attempt = [pscustomobject]@{
        candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier
        passed=[bool]$verdict.passed; score=[double]$verdict.score; reason=[string]$verdict.reason
        duration_s=[int]$result.duration_s; gate=$script:__lastGateDecision; grader=$graderTag
    }
    Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind `
        -CostTier $c.cost_tier -ExitCode ([int]$result.exit_code) -DurationS ([int]$result.duration_s) `
        -Passed ([bool]$verdict.passed) -Score ([double]$verdict.score) -Reason ([string]$verdict.reason) `
        -Grader $graderTag -JournalPath $JournalPath -Stage $Stage
    return @{ attempt = $attempt; result = $result }
}

function Invoke-RoutedCapability {
    <# Dispatch -> verify -> escalate over Select-Capability's cost-ascending candidates.
       The first candidate whose output passes the grader wins. If all fail, the outcome
       is 'escalate-to-conductor' (PowerShell cannot invoke Claude; Claude is the orchestrator).
       -Grader is the seam Slice 3 fills (default = heuristic). -Dispatcher is test injection. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('local','free','paid')][string]$MaxCostTier,
        [switch]$RequireLocal,
        [int]$TimeoutS = 120,
        [scriptblock]$Grader,
        [scriptblock]$Dispatcher,
        [switch]$Judge,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
        [int]$Rank = [int]::MinValue,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'routing-journal.jsonl')
    )
    $sel = @{ Capability = $Capability; ToolsPath = $ToolsPath; FleetPath = $FleetPath }
    if ($RequireLocal) { $sel['RequireLocal'] = $true }
    if ($MaxCostTier)  { $sel['MaxCostTier']  = $MaxCostTier }
    $candidates = Select-Capability @sel

    # Slice 3: -Grader wins; else -Judge wires the LLM-judge grader; else heuristic default.
    $effGrader = if ($Grader) { $Grader }
                 elseif ($Judge) { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }
                 else { $null }

    $attempts = [System.Collections.ArrayList]@()
    if (-not $candidates -or $candidates.Count -eq 0) {
        return [pscustomobject]@{ status='no-candidate'; capability=$Capability; winner=$null; result=$null; attempts=@() }
    }

    foreach ($c in $candidates) {
        $rcArgs = @{
            Capability = $Capability; Candidate = $c; Prompt = $Prompt
            EffGrader = $effGrader; Dispatcher = $Dispatcher; TimeoutS = $TimeoutS
            ToolsPath = $ToolsPath; FleetPath = $FleetPath; JournalPath = $JournalPath
        }
        if ($Rank -ne [int]::MinValue)                 { $rcArgs['Rank'] = $Rank }
        if ($PrimeHoursConfig)                         { $rcArgs['PrimeHoursConfig'] = $PrimeHoursConfig }
        if ($PSBoundParameters.ContainsKey('GateNow')) { $rcArgs['GateNow'] = $GateNow }
        $rc = Invoke-RoutedCandidate @rcArgs
        [void]$attempts.Add($rc.attempt)
        if ($rc.attempt.passed) {
            return [pscustomobject]@{ status='passed'; capability=$Capability; winner=$c.name; result=$rc.result; attempts=$attempts.ToArray() }
        }
    }

    return [pscustomobject]@{ status='escalate-to-conductor'; capability=$Capability; winner=$null; result=$null; attempts=$attempts.ToArray() }
}
