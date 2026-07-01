#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared PowerShell library for the /baton:start front porch (slice 1).
  Dot-source from the start/init/initialize command scripts.

.DESCRIPTION
  Pure resolvers (mode/depth/teaching-level, CHARTER content, resume status,
  next-command recommendation) plus thin seamed I/O for two box-private
  JSON stores: per-project project.json and one user-profile.json.
#>

. "$PSScriptRoot/baton-home.ps1"

function Resolve-StartMode {
    param([object]$ProjectRecord)
    if ($null -eq $ProjectRecord) { return 'new' }
    return 'resume'
}

function Resolve-InterviewDepth {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'full' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.preferred_interview_depth)) {
        return $Profile.preferred_interview_depth
    }
    return 'adaptive'
}

function Resolve-TeachingLevel {
    param(
        [object]$Profile,
        [string]$Explicit
    )
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit }
    if ($null -eq $Profile) { return 'teach' }
    if (-not [string]::IsNullOrWhiteSpace($Profile.teaching_level)) {
        return $Profile.teaching_level
    }
    return 'teach'
}

$script:NextCommandMap = @{
    'completed' = @{
        command = '/baton:gate (review quality) or /baton:effective-cost (see spend)'
        why     = 'the run finished — checking quality or cost is the natural next step before starting something new'
    }
    'interrupted-budget' = @{
        command = 're-run /baton:start (or /baton:go) with a higher --budget'
        why     = 'the next task would cross the budget cap you set, so it paused rather than spend past it'
    }
    'interrupted-destructive' = @{
        command = 'approve the pending step, then resume'
        why     = 'the next task touches something hard to undo (master, a force-push, an external publish), so it paused for your OK'
    }
    'rejected' = @{
        command = '/baton:gate to see the findings, then re-run'
        why     = 'the acceptance gate reviewed the finished work and flagged it — the work still ran, this is a quality verdict'
    }
    'failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'a task could not complete — a clearer or narrower goal usually unblocks it'
    }
    'plan-failed' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning could not produce a usable set of steps from the goal as stated'
    }
    'plan-invalid' = @{
        command = 'sharpen the goal and retry /baton:start'
        why     = 'planning produced a set of steps that did not check out — a sharper goal usually fixes this'
    }
}

function Get-NextCommandRecommendation {
    param([Parameter(Mandatory)][string]$RunStatus)
    if ($script:NextCommandMap.ContainsKey($RunStatus)) {
        return $script:NextCommandMap[$RunStatus]
    }
    return @{ command = '/baton:start'; why = 'status not recognized — starting fresh is the safest next step' }
}

function Read-ProjectRecord {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $path = Join-Path (Join-Path $ProjectsRoot $ProjectId) 'project.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = Get-Content $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-ProjectRecord: $($_.Exception.Message)"
        return $null
    }
}

function Write-ProjectRecord {
    param(
        [Parameter(Mandatory)][hashtable]$Record,
        [string]$ProjectsRoot = (Join-Path (Get-BatonHome) 'projects')
    )
    $dir = Join-Path $ProjectsRoot $Record.id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'project.json'
    $Record | ConvertTo-Json -Depth 6 | Set-Content -Path $path -Encoding utf8NoBOM
}

function Read-UserProfile {
    param([string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json'))
    if (-not (Test-Path $ProfilePath)) { return $null }
    try {
        $raw = Get-Content $ProfilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Debug "Read-UserProfile: $($_.Exception.Message)"
        return $null
    }
}

function Write-UserProfile {
    param(
        [Parameter(Mandatory)][hashtable]$Profile,
        [string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json')
    )
    $dir = Split-Path -Parent $ProfilePath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $Profile | ConvertTo-Json -Depth 6 | Set-Content -Path $ProfilePath -Encoding utf8NoBOM
}

function New-CharterContent {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Audience,
        [string]$Done,
        [string]$Reasoning
    )
    $today = Get-Date -Format 'yyyy-MM-dd'
    $audienceText  = if ([string]::IsNullOrWhiteSpace($Audience))  { '(to be filled in)' } else { $Audience }
    $doneText      = if ([string]::IsNullOrWhiteSpace($Done))      { '(to be filled in)' } else { $Done }
    $reasoningText = if ([string]::IsNullOrWhiteSpace($Reasoning)) { '(to be filled in)' } else { $Reasoning }

    @"
# $Name — Project Charter

_Written by /baton:start on $today. Your plain-language record of what we're building and why._

## What we're building
$Goal

## Who it's for
$audienceText

## What "done" looks like
$doneText

## Why — the reasoning
$reasoningText

## Decisions & open questions
(to be filled in as the project moves along)

---
_Baton tracks the technical run history privately under its own home; this file is yours._
"@
}

function Format-ResumeStatus {
    param([Parameter(Mandatory)][object]$ProjectRecord)
    $name = $ProjectRecord.name
    $folder = $ProjectRecord.folder
    if ($null -eq $ProjectRecord.last_run) {
        return "Project '$name' at $folder hasn't run yet — pick up where onboarding left off, or describe what to build."
    }
    $status = $ProjectRecord.last_run.status
    $at = $ProjectRecord.last_run.at
    return "Project '$name' at $folder — last run ($at) ended with status '$status'."
}

# ============================================================================
# Slice 2 — Working-style learning loop
# Observe → fold (confidence-gated plurality) → enforce via profile update.
# Grimdex supplement is offered (never auto-written) at high confidence.
# ============================================================================

function Add-StyleObservation {
    <# Append a single behavioural observation to the style journal. Thin I/O.
       Never throws — a missed observation is not a fatal error. #>
    param(
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'style-journal.jsonl'),
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$DepthUsed,
        [Parameter(Mandatory)][bool]$DepthExplicit,
        [Parameter(Mandatory)][string]$TeachingUsed,
        [Parameter(Mandatory)][bool]$TeachingExplicit,
        [int]$TurnsToGoal = 0,
        [bool]$AudienceVolunteered = $false,
        [bool]$DoneVolunteered = $false,
        [string]$ReasoningQuality = 'brief'
    )
    try {
        $dir = Split-Path -Parent $JournalPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $row = [ordered]@{
            at                    = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
            project_id            = $ProjectId
            depth_used            = $DepthUsed
            depth_explicit        = $DepthExplicit
            teaching_used         = $TeachingUsed
            teaching_explicit     = $TeachingExplicit
            turns_to_goal         = $TurnsToGoal
            audience_volunteered  = $AudienceVolunteered
            done_volunteered      = $DoneVolunteered
            reasoning_quality     = $ReasoningQuality
        }
        $json = $row | ConvertTo-Json -Compress
        Add-Content -Path $JournalPath -Value $json -Encoding utf8NoBOM
    } catch {
        Write-Debug "Add-StyleObservation: $($_.Exception.Message)"
    }
}

function Read-StyleJournal {
    <# Read all observations from the style journal. Thin I/O.
       Returns @() on missing file or all-malformed content (fail-open). #>
    param([string]$JournalPath = (Join-Path (Get-BatonHome) 'style-journal.jsonl'))
    if (-not (Test-Path $JournalPath)) { return @() }
    $lines = Get-Content $JournalPath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }
    $results = [System.Collections.ArrayList]@()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            [void]$results.Add($obj)
        } catch {
            Write-Debug "Read-StyleJournal: skipping malformed line"
        }
    }
    if ($results.Count -eq 0) { return @() }
    return ,([object[]]$results.ToArray())
}

function Get-StyleFoldDecision {
    <# Pure decision function — no I/O. Computes depth and teaching
       recommendations from a plurality vote over non-explicit observations,
       with a confidence gate. Returns $null recommendations on insufficient
       data or a split signal. #>
    param(
        [object[]]$Observations = @(),
        [int]$MinObservations = 5,
        [double]$ConfidenceThreshold = 0.70
    )
    $result = [ordered]@{
        depth_recommendation    = $null
        teaching_recommendation = $null
        depth_confidence        = 0.0
        teaching_confidence     = 0.0
        observation_count       = 0
    }

    # --- Depth fold ---
    $depthRows = @($Observations | Where-Object { $_.depth_explicit -eq $false })
    $depthCount = $depthRows.Count
    $result.observation_count = $depthCount
    if ($depthCount -ge $MinObservations) {
        $tally = @{}
        foreach ($r in $depthRows) {
            $v = [string]$r.depth_used
            if (-not $tally.ContainsKey($v)) { $tally[$v] = 0 }
            $tally[$v]++
        }
        $winner = $null; $winnerCount = 0
        foreach ($k in $tally.Keys) {
            if ($tally[$k] -gt $winnerCount) { $winner = $k; $winnerCount = $tally[$k] }
        }
        $conf = [double]$winnerCount / [double]$depthCount
        $result.depth_confidence = [math]::Round($conf, 4)
        if ($conf -ge $ConfidenceThreshold) {
            $result.depth_recommendation = $winner
        }
    }

    # --- Teaching fold ---
    $teachRows = @($Observations | Where-Object { $_.teaching_explicit -eq $false })
    $teachCount = $teachRows.Count
    if ($teachCount -ge $MinObservations) {
        $tally = @{}
        foreach ($r in $teachRows) {
            $v = [string]$r.teaching_used
            if (-not $tally.ContainsKey($v)) { $tally[$v] = 0 }
            $tally[$v]++
        }
        $winner = $null; $winnerCount = 0
        foreach ($k in $tally.Keys) {
            if ($tally[$k] -gt $winnerCount) { $winner = $k; $winnerCount = $tally[$k] }
        }
        $conf = [double]$winnerCount / [double]$teachCount
        $result.teaching_confidence = [math]::Round($conf, 4)
        if ($conf -ge $ConfidenceThreshold) {
            $result.teaching_recommendation = $winner
        }
    }

    return $result
}

function Invoke-StyleFold {
    <# Orchestrate the fold: read journal + profile, decide, update profile.
       Thin I/O wrapper around Get-StyleFoldDecision. #>
    param(
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'style-journal.jsonl'),
        [string]$ProfilePath = (Join-Path (Get-BatonHome) 'user-profile.json'),
        [int]$MinObservations = 5
    )
    $foldResult = [ordered]@{
        updated          = $false
        depth_changed    = $false
        teaching_changed = $false
        depth_confidence    = 0.0
        teaching_confidence = 0.0
        note             = $null
    }

    $profile = Read-UserProfile -ProfilePath $ProfilePath
    if ($null -eq $profile) { return $foldResult }

    $depthLearning   = $false
    $teachingLearning = $false
    if ($profile.PSObject.Properties.Name -contains 'depth_learning') {
        $depthLearning = ($profile.depth_learning -eq $true)
    }
    if ($profile.PSObject.Properties.Name -contains 'teaching_learning') {
        $teachingLearning = ($profile.teaching_learning -eq $true)
    }
    if (-not $depthLearning -and -not $teachingLearning) { return $foldResult }

    $observations = Read-StyleJournal -JournalPath $JournalPath
    $decision = Get-StyleFoldDecision -Observations $observations -MinObservations $MinObservations

    $foldResult.depth_confidence    = $decision.depth_confidence
    $foldResult.teaching_confidence = $decision.teaching_confidence

    $profileHash = @{}
    foreach ($p in $profile.PSObject.Properties) { $profileHash[$p.Name] = $p.Value }

    $changed = $false

    # Depth
    if ($depthLearning -and $null -ne $decision.depth_recommendation) {
        $current = $profileHash['preferred_interview_depth']
        if ($current -ne $decision.depth_recommendation) {
            $profileHash['preferred_interview_depth'] = $decision.depth_recommendation
            $obs = if ($profileHash.ContainsKey('depth_observations')) { [int]$profileHash['depth_observations'] } else { 0 }
            $profileHash['depth_observations'] = $obs + 1
            $foldResult.depth_changed = $true
            $changed = $true
        }
    }

    # Teaching
    if ($teachingLearning -and $null -ne $decision.teaching_recommendation) {
        $current = $profileHash['teaching_level']
        if ($current -ne $decision.teaching_recommendation) {
            $profileHash['teaching_level'] = $decision.teaching_recommendation
            $obs = if ($profileHash.ContainsKey('teaching_observations')) { [int]$profileHash['teaching_observations'] } else { 0 }
            $profileHash['teaching_observations'] = $obs + 1
            $foldResult.teaching_changed = $true
            $changed = $true
        }
    }

    if ($changed) {
        $profileHash['updated_at'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        Write-UserProfile -Profile $profileHash -ProfilePath $ProfilePath
        $foldResult.updated = $true
    }

    return $foldResult
}

function Format-StyleFoldNote {
    <# Pure formatter: returns a terse one-liner for the user, or $null if nothing changed. #>
    param([Parameter(Mandatory)][hashtable]$FoldResult)
    if (-not $FoldResult.updated) { return $null }
    $parts = @()
    if ($FoldResult.depth_changed) {
        $parts += "depth updated"
    } else {
        $parts += "depth unchanged"
    }
    if ($FoldResult.teaching_changed) {
        $parts += "teaching updated"
    } else {
        $parts += "teaching unchanged"
    }
    $summary = $parts -join ', '
    return "[baton:start] Interview style updated: $summary. Your next /baton:start will reflect these preferences."
}

function Get-GrimdexStyleNote {
    <# Pure formatter: returns a compact working-style snapshot suitable for Grimdex.
       Caller decides whether to write it. #>
    param([Parameter(Mandatory)][object]$Profile)
    $today = Get-Date -Format 'yyyy-MM-dd'
    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $depth = if ($Profile.PSObject.Properties.Name -contains 'preferred_interview_depth') { $Profile.preferred_interview_depth } else { '(unset)' }
    $teaching = if ($Profile.PSObject.Properties.Name -contains 'teaching_level') { $Profile.teaching_level } else { '(unset)' }
    $depthObs = if ($Profile.PSObject.Properties.Name -contains 'depth_observations') { $Profile.depth_observations } else { 0 }
    $teachObs = if ($Profile.PSObject.Properties.Name -contains 'teaching_observations') { $Profile.teaching_observations } else { 0 }
    @"
## Working-style snapshot — $today
- Interview depth: $depth (from $depthObs sessions)
- Teaching level: $teaching (from $teachObs sessions)
- Updated: $ts
"@
}

function Invoke-IdeaInjection {
    <# Appends the idea to the CHARTER.md under "Decisions & open questions" #>
    param(
        [Parameter(Mandatory)][string]$IdeaText,
        [Parameter(Mandatory)][string]$CharterPath
    )
    if (-not (Test-Path $CharterPath)) { return $false }
    $content = Get-Content -LiteralPath $CharterPath -Raw
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $entry = "- [$ts] Idea: $IdeaText"
    
    if ($content -match '## Decisions & open questions') {
        $content = $content.Replace('## Decisions & open questions', "## Decisions & open questions`n$entry")
    } else {
        $content += "`n`n## Decisions & open questions`n$entry"
    }
    Set-Content -Path $CharterPath -Value $content.TrimEnd() -Encoding utf8NoBOM
    return $true
}

function Build-IdeaRoutingPrompt {
    <# Compose the routing instruction for the idea scope #>
    param([Parameter(Mandatory)][string]$IdeaText)
    $schema = @'
{
  "route": "re-plan|backlog",
  "reasoning": "<one sentence rationale>",
  "confidence": 0.0
}
'@
    return @"
You are a project manager routing an injected idea mid-stream. Classify the scope of this idea and respond with ONLY valid JSON matching this schema exactly. No prose, no markdown fences.

Schema:
$schema

Guidance: 
- 're-plan': for tactical pivots, immediate next steps, minor scope adjustments, or bug fixes.
- 'backlog': for massive new epics, architectural overhauls, or ideas requiring a viability debate before implementation.
- 'confidence' is your 0.0-1.0 certainty.

Idea:
$IdeaText
"@
}

function Get-IdeaRoutingJsonBlock {
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('{')
    $close = $Raw.LastIndexOf('}')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function ConvertTo-IdeaRoutingHashtable {
    param([Parameter(Mandatory)][string]$RawStdout)
    $block = Get-IdeaRoutingJsonBlock -Raw $RawStdout
    if (-not $block) { return $null }
    try { $o = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $h = @{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Resolve-IdeaRouting {
    <# Classifies the idea using a triage-capable model (via fleet). 
       Returns 're-plan' or 'backlog'. Fails open to 're-plan'. #>
    param(
        [Parameter(Mandatory)][string]$IdeaText,
        [scriptblock]$Dispatcher
    )
    $prompt = Build-IdeaRoutingPrompt -IdeaText $IdeaText

    $dispatch = {
        param($cand, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $cand $prompt) }
        # Load routing-lib dynamically if needed
        if (-not (Get-Command Select-Capability -ErrorAction Ignore)) {
            . "$PSScriptRoot/routing-lib.ps1"
        }
        return Invoke-Fleet -Name $cand.name -Prompt $prompt -NoJournal
    }

    # If Dispatcher is absent, we need routing-lib to get a candidate
    if (-not $Dispatcher) {
        if (-not (Get-Command Select-Capability -ErrorAction Ignore)) {
            . "$PSScriptRoot/routing-lib.ps1"
        }
        $cands = Select-Capability -Capability triage
        if ($null -eq $cands -or @($cands | Where-Object { $null -ne $_ }).Count -lt 1) {
            return 're-plan' # fail-open
        }
        $cand = @($cands)[0]
    } else {
        # Test seam
        $cand = @{ name = 'test-stub' }
    }

    try {
        $raw = & $dispatch $cand $prompt
        $rawText = $null
        if ($raw -is [string]) {
            $rawText = $raw
        } elseif ($null -ne $raw) {
            # Dispatch result is a structured hashtable/object (e.g. Invoke-Fleet's
            # @{ stdout; stderr; exit_code; duration_s }). Normalize before parsing.
            $memberNames = if ($raw -is [hashtable]) { $raw.Keys } else { $raw.PSObject.Properties.Name }
            if ($memberNames -contains 'exit_code') {
                $exitCode = if ($raw -is [hashtable]) { $raw['exit_code'] } else { $raw.exit_code }
                if (([int]$exitCode) -ne 0) {
                    return 're-plan' # fail-open: dispatcher reported a non-zero exit
                }
            }
            if ($memberNames -contains 'stdout') {
                $rawText = if ($raw -is [hashtable]) { [string]$raw['stdout'] } else { [string]$raw.stdout }
            }
        }
        if ($null -ne $rawText) {
            $res = ConvertTo-IdeaRoutingHashtable -RawStdout $rawText
            if ($res -and ($res.route -in @('re-plan', 'backlog'))) {
                return $res.route
            }
        }
    } catch {
        Write-Debug "Resolve-IdeaRouting error: $_"
    }
    return 're-plan' # fail-open
}
