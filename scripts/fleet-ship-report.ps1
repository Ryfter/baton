#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:ship-report runner. Per-PR pipeline cost/quality card from existing journals.
.DESCRIPTION
  Assemble a ship-report card for one PR (or -Branch / -RunDir WIP view), or --all
  trend table from previously written ship-report.json files. Writes ship-report.md
  + ship-report.json under the run dir. PR comment post is OFF unless -Post
  (observe-first, d078).
#>
param(
    [Parameter(Position = 0)][string]$Pr,
    [string]$Branch,
    [string]$RunDir,
    [string]$RunId,
    [string]$RepoRoot = (Get-Location).Path,
    [string]$Repo = '',
    [string]$BaseBranch = 'master',
    [switch]$All,
    [switch]$Json,
    [switch]$Post,
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { $null })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ship-report-lib.ps1')

function Write-ShipReportErr([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

try {
    if (-not $BatonHome) { $BatonHome = Get-BatonHome }
    $defaults = Get-ShipReportDefaults -BatonHome $BatonHome

    # ---- --all trend view ----
    if ($All) {
        $cards = @(Read-ShipReportCardsFromRuns -RunsRoot $defaults.runs_root)
        if ($Json) {
            ConvertTo-Json -InputObject @($cards) -Depth 10
        } else {
            Write-Output (Format-ShipReportTrendTable -Cards @($cards))
        }
        exit 0
    }

    # ---- resolve target ----
    $prNumber = 0
    if ($Pr) {
        $prRaw = $Pr.Trim().TrimStart('#')
        if (-not [int]::TryParse($prRaw, [ref]$prNumber) -or $prNumber -le 0) {
            Write-ShipReportErr "ship-report: invalid PR number '$Pr' (want a positive integer)"
            exit 2
        }
    }

    if ($prNumber -le 0 -and -not $Branch -and -not $RunDir -and -not $RunId) {
        Write-ShipReportErr 'ship-report: pass <pr-number>, -Branch <name>, -RunDir <path>, or --all'
        exit 2
    }

    $prMeta = $null
    $gitStats = $null
    $branchName = $Branch

    if ($prNumber -gt 0) {
        try {
            $prMeta = Get-ShipReportPrMeta -PrNumber $prNumber -Repo $Repo
            if (-not $branchName -and $prMeta.branch) { $branchName = [string]$prMeta.branch }
        } catch {
            Write-ShipReportErr ("ship-report: failed to load PR #{0}: {1}" -f $prNumber, $_.Exception.Message)
            exit 2
        }
    }

    if ($branchName -and (Test-Path -LiteralPath $RepoRoot)) {
        try {
            $gitStats = Get-ShipReportGitBranchStats -RepoRoot $RepoRoot -Branch $branchName -Base $BaseBranch
        } catch {
            # Git is best-effort for WIP views; card still renders with n/a commits.
            $gitStats = [ordered]@{
                commit_count    = 0
                commits         = @()
                first_commit_at = $null
                last_commit_at  = $null
                branch          = $branchName
                base            = $BaseBranch
            }
        }
    }

    # If only -RunDir / -RunId, synthesize a thin meta shell so the card still titles.
    if (-not $prMeta -and ($RunDir -or $RunId -or $branchName)) {
        $prMeta = [ordered]@{
            pr_number       = $(if ($prNumber -gt 0) { $prNumber } else { $null })
            title           = ''
            state           = ''
            branch          = $branchName
            base_branch     = $BaseBranch
            merged_at       = $null
            merge_sha       = $null
            url             = ''
            linked_issue    = $null
            commit_count    = $(if ($gitStats) { [int]$gitStats.commit_count } else { 0 })
            first_commit_at = $(if ($gitStats) { $gitStats.first_commit_at } else { $null })
            comment_bodies  = @()
            body            = ''
        }
    }

    $resolvedRunDir = Resolve-ShipReportRunDir -RunDir $RunDir -RunId $RunId -PrNumber $prNumber -BatonHome $BatonHome
    $resolvedRunId = $RunId
    if (-not $resolvedRunId -and $resolvedRunDir) {
        $resolvedRunId = Split-Path -Leaf $resolvedRunDir
    }

    $fleetRows = @(Read-FleetJournalRows -Path $defaults.fleet_journal)
    $usageRows = @(Read-UsageJournalRows -Path $defaults.usage_journal)
    $decisions = @()
    $effCost = $null
    if ($resolvedRunDir) {
        $decisions = @(Read-RunDecisions -RunDir $resolvedRunDir)
        $effCost = Read-RunEffectiveCost -RunDir $resolvedRunDir
    }

    $card = Build-ShipReportCard `
        -FleetRows $fleetRows `
        -UsageRows $usageRows `
        -Decisions $decisions `
        -PrMeta $prMeta `
        -GitStats $gitStats `
        -EffectiveCost $effCost `
        -RunId $(if ($resolvedRunId) { $resolvedRunId } else { '' })

    # Ensure branch is set when only -Branch was supplied.
    if (-not $card.branch -and $branchName) { $card.branch = $branchName }
    if ($null -eq $card.pr_number -and $prNumber -gt 0) { $card.pr_number = $prNumber }

    $markdown = Format-ShipReportCard -Card $card

    if ($resolvedRunDir) {
        $null = Write-ShipReportToRunDir -RunDir $resolvedRunDir -Card $card -Markdown $markdown
    }

    if ($Post) {
        if ($prNumber -le 0) {
            Write-ShipReportErr 'ship-report: --post requires a PR number'
            exit 2
        }
        try {
            $null = Post-ShipReportPrComment -PrNumber $prNumber -Body $markdown -Repo $Repo
        } catch {
            Write-ShipReportErr ("ship-report: failed to post PR comment: {0}" -f $_.Exception.Message)
            exit 2
        }
    }

    if ($Json) {
        ConvertTo-Json -InputObject $card -Depth 10
    } else {
        Write-Output $markdown
        if ($resolvedRunDir) {
            Write-Output ("`n(wrote {0})" -f (Join-Path $resolvedRunDir 'ship-report.md'))
        }
        if (-not $Post -and $prNumber -gt 0) {
            Write-Output '(PR comment not posted; pass --post to publish)'
        }
    }
    exit 0
} catch {
    Write-ShipReportErr ("ship-report: {0}" -f $_.Exception.Message)
    exit 2
}
