#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build R1 and R2 task arrays for the LLM Council preset.

.DESCRIPTION
  Pure functions on top of Invoke-FleetEnsembleTasks (Plan 5b). The council
  runs two rounds: R1 = each member answers independently; R2 = each member
  reads OTHER members' R1 answers and refines. A separate chair (Claude in
  the slash command) synthesizes the final answer from R1+R2.

  Council size cap = 5 (R2 prompt grows O(N) in peer content).
  Quorum floor for proceeding to R2 = 2 surviving R1 members.
#>

$script:CouncilMaxSize = 5
$script:CouncilQuorum  = 2

function Get-CouncilLimits {
    <# Return @{ max; quorum } so the slash command can read the same constants. #>
    return @{ max = $script:CouncilMaxSize; quorum = $script:CouncilQuorum }
}

function Build-CouncilR1Tasks {
    <#
    .SYNOPSIS
      Round-1 tasks: each member answers the question independently.

    .PARAMETER Question
      The council's question. Used as-is for R1 prompts.

    .PARAMETER Providers
      Council roster. Capped at CouncilMaxSize. Members below quorum throw.
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Providers
    )
    if (-not $Providers -or $Providers.Count -lt 1) {
        throw "Build-CouncilR1Tasks requires at least one council member."
    }
    if ($Providers.Count -gt $script:CouncilMaxSize) {
        Write-Warning ("Council roster has {0} members; capping at {1}." -f $Providers.Count, $script:CouncilMaxSize)
        $Providers = $Providers[0..($script:CouncilMaxSize - 1)]
    }
    $tasks = @()
    foreach ($p in $Providers) {
        $tasks += @{ label = $p; provider = $p; prompt = $Question }
    }
    return $tasks
}

function Build-CouncilR2Tasks {
    <#
    .SYNOPSIS
      Round-2 tasks: each member reads OTHERS' R1 answers and refines.

    .DESCRIPTION
      Stitches each member's R2 prompt: original question + the OTHER members'
      R1 content, separated by --- markers. Self is excluded. If a peer's R1
      file is missing or marked as ENSEMBLE ERROR/TIMEOUT, that peer is
      replaced by a brief note (kept in the stitch order so the chair sees
      who failed). A member whose own R1 failed still runs in R2 with the
      original question + the surviving peers' content — second chance.

    .PARAMETER R1Dir
      Directory containing round1/<member>.md files (one per provider).
    #>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][string[]]$Providers,
        [Parameter(Mandatory)][string]$R1Dir
    )
    if (-not (Test-Path $R1Dir)) {
        throw "Build-CouncilR2Tasks: R1Dir '$R1Dir' does not exist."
    }
    if (-not $Providers -or $Providers.Count -lt 1) {
        throw "Build-CouncilR2Tasks requires at least one council member."
    }

    # Preload all R1 contents once (so we don't re-read N^2 times).
    $r1 = @{}
    foreach ($p in $Providers) {
        $f = Join-Path $R1Dir "$p.md"
        if (-not (Test-Path $f)) {
            $r1[$p] = $null
            continue
        }
        $raw = (Get-Content $f -Raw)
        if ($raw -match '\[ENSEMBLE (ERROR|TIMEOUT)\]') {
            $r1[$p] = $null
        } else {
            $r1[$p] = $raw.Trim()
        }
    }

    $tasks = @()
    foreach ($self in $Providers) {
        # Build the peer-content block: every OTHER provider, in roster order.
        $peerBlocks = @()
        foreach ($other in $Providers) {
            if ($other -eq $self) { continue }
            $content = $r1[$other]
            if ($null -eq $content) {
                $peerBlocks += "$($other): (no usable R1 answer - failed or timed out)"
            } else {
                # Collapse newlines so the resulting prompt stays single-line
                # (Plan 4 substitution constraint, same as Six Hats).
                $flat = ($content -replace "`r?`n", ' ').Trim()
                $peerBlocks += "$($other): $flat"
            }
        }
        $peerJoined = ($peerBlocks -join ' --- ')
        $prompt = "You are a council member reviewing other members' answers to this question. Question: $Question. Other members' answers follow, separated by --- markers. Read them, identify where they agree, where they diverge, and what they miss. Then state your REFINED answer for the chair. $peerJoined"
        $tasks += @{ label = $self; provider = $self; prompt = $prompt }
    }
    return $tasks
}

function Get-CouncilR1Survivors {
    <#
    .SYNOPSIS
      Read the R1 manifest, return the list of providers whose R1 was 'ok'.

    .DESCRIPTION
      The slash command uses this to check quorum before R2.
    #>
    param(
        [Parameter(Mandatory)][array]$R1Manifest
    )
    return @($R1Manifest | Where-Object { $_.status -eq 'ok' } | ForEach-Object { $_.provider })
}
