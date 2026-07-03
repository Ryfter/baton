#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Guided-use coach engine (d074): declarative signal->suggestion rules over
  locally readable Baton state. Consumed by the SessionStart digest hook
  (scripts/hooks/baton-coach.ps1) and the fleet CLIs' "Next:" footers.
.DESCRIPTION
  Fail-open by contract: a broken signal source degrades to "no signal", a
  broken store degrades to defaults, and no public function throws to its
  caller. Zero model calls, zero network calls. The only writes are one-shot
  dedup stamps in $BATON_HOME/coach/seen.json.
.NOTES
  ConvertFrom-Json auto-parses ISO8601 strings as [datetime]; seen.json
  values and promote_recommended_at are only existence-checked here, so the
  trap is harmless in this lib.
#>

. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/start-lib.ps1"        # Read-ProjectRecord, Get-NextCommandRecommendation
. "$PSScriptRoot/prompt-pool-lib.ps1"  # Get-PromptPool, Get-ShadowVerdict
. "$PSScriptRoot/usage-lib.ps1"        # Read-UsageJournal, Get-ConserveMode, Get-UsageForecast
# Optional: Read-Fleet enables budget-aware forecasts; without it the budget
# rule degrades to conserve-mode-only (usage-lib guards with Get-Command).
try { . "$PSScriptRoot/fleet-lib.ps1" } catch { }

function Get-CoachDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'coach')
}

function Get-CoachLevel {
    <# off | quiet | teach; anything absent/unreadable/unknown -> quiet. #>
    param([string]$BatonHome = (Get-BatonHome))
    $path = Join-Path (Get-CoachDir -BatonHome $BatonHome) 'config.json'
    if (-not (Test-Path $path)) { return 'quiet' }
    try {
        $cfg = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $lvl = [string]$cfg.level
        if ($lvl -in @('off', 'quiet', 'teach')) { return $lvl }
    } catch { }
    return 'quiet'
}

function Read-CoachSeen {
    param([Parameter(Mandatory)][string]$SeenPath)
    if (-not (Test-Path $SeenPath)) { return @{} }
    try {
        $seen = Get-Content -Raw -LiteralPath $SeenPath -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($seen -is [hashtable]) { return $seen }
    } catch { }
    return @{}
}

function Set-CoachSeen {
    param([Parameter(Mandatory)][string]$SeenPath, [Parameter(Mandatory)][string]$Key)
    try {
        $seen = Read-CoachSeen -SeenPath $SeenPath
        $seen[$Key] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $dir = Split-Path -Parent $SeenPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        ConvertTo-Json -InputObject $seen -Depth 4 | Set-Content -LiteralPath $SeenPath -Encoding utf8NoBOM
    } catch { }
}

function Get-CoachProjectId {
    <# Same id derivation as job-lib's Resolve-ProjectId (git remote repo
       name, else folder name, slugified) but anchored to -ProjectDir via
       `git -C` so the coach never mutates the caller's cwd. #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    try {
        $remote = (& git -C $ProjectDir remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote) {
            $clean = "$remote" -replace '^(https?://|git@)', '' -replace ':', '/' -replace '\.git$', ''
            $parts = $clean -split '/' | Where-Object { $_ }
            if (@($parts).Count -ge 2) {
                $repo = [string]$parts[-1]
                return ($repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    } catch { }
    try {
        $folder = Split-Path -Leaf ([IO.Path]::GetFullPath($ProjectDir))
        return ($folder.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
    } catch { return $null }
}

function Get-CoachFailureRuns {
    <# Hook-weight failure scan: newest-first run dirs whose acceptance.json
       verdict is reject/polish. Duplicates optimize-prompt-lib's
       Get-HistoricalRuns filter ON PURPOSE — sourcing that lib would drag
       routing-lib + fleet-lib into the SessionStart hook path (spec, d074).
       Unlike Get-HistoricalRuns this needs no plan.json (verdicts only). #>
    param([int]$MaxRuns = 5, [Parameter(Mandatory)][string]$Root)
    $found = [System.Collections.ArrayList]@()
    try {
        if (-not (Test-Path $Root)) { return @() }
        $runs = Get-ChildItem -Directory $Root | Sort-Object CreationTime -Descending
        foreach ($run in $runs) {
            $accPath = Join-Path $run.FullName 'acceptance.json'
            if (Test-Path $accPath) {
                try {
                    $acc = Get-Content -Raw -LiteralPath $accPath -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ("$($acc.verdict)" -match 'reject|polish') {
                        [void]$found.Add(@{ run_id = $run.Name; verdict = [string]$acc.verdict })
                        if ($found.Count -ge $MaxRuns) { break }
                    }
                } catch { }
            }
        }
    } catch { }
    if ($found.Count -eq 0) { return @() }
    return ,([object[]]$found)
}

function Get-CoachContext {
    <# Gathers every coach signal; each reader is individually fail-open (a
       broken source leaves its keys at the inert default, never throws). #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [string]$ProjectDir = (Get-Location).Path
    )
    $ctx = @{
        project = $null; project_id = $null
        is_git_repo = $false; project_dir_normalized = [string]$ProjectDir
        pool_ok = $false; pool_champion_id = $null; pool_challenger_id = $null
        pool_verdict_state = $null; pool_verdict_ready = $false
        promote_pending = @()
        conserve = $false; budget_at_risk = $false
        latest_failure_run_id = $null; failure_runs = 0
    }
    try { $ctx.project_dir_normalized = ([IO.Path]::GetFullPath($ProjectDir)).TrimEnd('\', '/').ToLowerInvariant() } catch { }

    # Git repo? (.git file or dir, walking up.)
    try {
        $d = [IO.Path]::GetFullPath($ProjectDir)
        while ($d) {
            if (Test-Path (Join-Path $d '.git')) { $ctx.is_git_repo = $true; break }
            $parent = Split-Path -Parent $d
            if ((-not $parent) -or ($parent -eq $d)) { break }
            $d = $parent
        }
    } catch { }

    # Project record.
    try {
        $ctx.project_id = Get-CoachProjectId -ProjectDir $ProjectDir
        if ($ctx.project_id) {
            $ctx.project = Read-ProjectRecord -ProjectId $ctx.project_id -ProjectsRoot (Join-Path $BatonHome 'projects')
        }
    } catch { }

    # Prompt pool.
    try {
        $loaded = Get-PromptPool -PoolDir (Join-Path $BatonHome 'prompts/pool')
        if ($loaded.ok) {
            $pool = $loaded.pool
            $ctx.pool_ok = $true
            $ctx.pool_champion_id = [string]$pool.champion
            $v = Get-ShadowVerdict -Pool $pool
            $ctx.pool_verdict_state = [string]$v.state
            if ($v.challenger_id) { $ctx.pool_challenger_id = [string]$v.challenger_id }
            $ctx.pool_verdict_ready = ([string]$v.state -in @('promote', 'retire', 'stalemate'))
            $ctx.promote_pending = @($pool.candidates | Where-Object {
                ($_.status -eq 'candidate') -and ($null -ne $_.promote_recommended_at)
            } | ForEach-Object { [string]$_.id })
        }
    } catch { }

    # Usage governor.
    try {
        $usagePath = Join-Path $BatonHome 'usage-journal.jsonl'
        $rows = @(Read-UsageJournal -Path $usagePath)
        $ctx.conserve = [bool](Get-ConserveMode -Rows $rows)
        $atRisk = $false
        $workers = @($rows | Where-Object { $_.event -eq 'tick' } | ForEach-Object { [string]$_.worker } | Sort-Object -Unique)
        foreach ($w in $workers) {
            $f = Get-UsageForecast -Worker $w -UsagePath $usagePath -FleetPath (Join-Path $BatonHome 'fleet.yaml')
            if (($f.status -eq 'ok') -and ($null -ne $f.days_to_exhaustion) -and ([double]$f.days_to_exhaustion -le 2)) {
                $atRisk = $true; break
            }
        }
        $ctx.budget_at_risk = ($ctx.conserve -or $atRisk)
    } catch { }

    # Failure runs (optimizer feedstock).
    try {
        $hist = @(Get-CoachFailureRuns -MaxRuns 5 -Root (Join-Path $BatonHome 'runs'))
        $ctx.failure_runs = @($hist).Count
        if (@($hist).Count -gt 0) { $ctx.latest_failure_run_id = [string]$hist[0].run_id }
    } catch { }

    return $ctx
}

function Get-CoachSuggestions {
    <# Ordered rule evaluation (order = priority): next-command,
       gate-failure, promote-pending, pool-verdict, budget, onboard.
       dedup_key=$null marks a digest-only orientation entry (never footers,
       never stamped). -IncludeSeen bypasses the seen filter (the digest is
       a status report); -ExcludeIds lets a CLI drop rules that would
       suggest the command the user just ran. Never throws. #>
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [string]$SeenPath,
        [switch]$IncludeSeen,
        [string[]]$ExcludeIds = @()
    )
    $items = [System.Collections.ArrayList]@()
    try {
        $ctx = $Context
        if ($ctx.project -and $ctx.project.last_run -and $ctx.project.last_run.status) {
            $rec = Get-NextCommandRecommendation -RunStatus ([string]$ctx.project.last_run.status)
            [void]$items.Add(@{ id = 'next-command'; command = [string]$rec.command; why = [string]$rec.why; dedup_key = $null })
        }
        if ($ctx.latest_failure_run_id) {
            [void]$items.Add(@{
                id = 'gate-failure'; command = '/baton:optimize-prompt'
                why = 'this failure can feed the prompt optimizer'
                dedup_key = "gate-failure:$($ctx.latest_failure_run_id)"
            })
        }
        foreach ($cid in @($ctx.promote_pending)) {
            [void]$items.Add(@{
                id = 'promote-pending'; command = '/baton:optimize-prompt --apply'
                why = "live evidence says challenger $cid wins"
                dedup_key = "promote:$cid"
            })
        }
        if ($ctx.pool_verdict_ready) {
            [void]$items.Add(@{
                id = 'pool-verdict'; command = '/baton:optimize-prompt --pool'
                why = 'enough live evidence for a verdict'
                dedup_key = "pool-verdict:$($ctx.pool_champion_id):$($ctx.pool_challenger_id)"
            })
        }
        if ($ctx.budget_at_risk) {
            [void]$items.Add(@{
                id = 'budget'; command = '/baton:usage'
                why = 'see where the spend is going'
                dedup_key = ('budget:' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))
            })
        }
        if ($ctx.is_git_repo -and ($null -eq $ctx.project)) {
            [void]$items.Add(@{
                id = 'onboard'; command = '/baton:start'
                why = 'register this repo so Baton can orient and route for you'
                dedup_key = "onboard:$($ctx.project_dir_normalized)"
            })
        }
    } catch { }

    $out = @($items | Where-Object { $ExcludeIds -notcontains $_.id })
    if ((-not $IncludeSeen) -and $SeenPath) {
        $seen = Read-CoachSeen -SeenPath $SeenPath
        $out = @($out | Where-Object { ($null -eq $_.dedup_key) -or (-not $seen.ContainsKey([string]$_.dedup_key)) })
    }
    if (@($out).Count -eq 0) { return @() }
    return ,([object[]]$out)
}

function Write-CoachFooter {
    <# One "Next:" line for the end of a fleet CLI's human-readable output.
       Fail-open by contract: any error prints nothing and never affects the
       host command. Digest-only entries (null dedup_key) are skipped; the
       printed suggestion is stamped so each triggering state fires once. #>
    param(
        [string[]]$ExcludeIds = @(),
        [string]$BatonHome = (Get-BatonHome),
        [string]$ProjectDir = (Get-Location).Path
    )
    try {
        $level = Get-CoachLevel -BatonHome $BatonHome
        if ($level -eq 'off') { return }
        $seenPath = Join-Path (Get-CoachDir -BatonHome $BatonHome) 'seen.json'
        $ctx = Get-CoachContext -BatonHome $BatonHome -ProjectDir $ProjectDir
        $sugg = @(Get-CoachSuggestions -Context $ctx -SeenPath $seenPath -ExcludeIds $ExcludeIds |
                  Where-Object { $null -ne $_.dedup_key })
        if (@($sugg).Count -eq 0) { return }
        $top = $sugg[0]
        if ($level -eq 'teach') { Write-Host ("Next: {0} — {1}" -f $top.command, $top.why) }
        else { Write-Host ("Next: {0}" -f $top.command) }
        Set-CoachSeen -SeenPath $seenPath -Key ([string]$top.dedup_key)
    } catch { }
}
