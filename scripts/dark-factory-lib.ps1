#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Dark factory Level-4 automation — seed Maestro lanes, status, curriculum hooks.
.DESCRIPTION
  Queues overnight work for dashboard, Baton spine, and Grimdex-edu curriculum build-out.
  Kevin sleeps; Maestro admit → fire → worktrees do the labor.
#>
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'maestro-lib.ps1')
. (Join-Path $PSScriptRoot 'security-researcher-lib.ps1')

$script:DarkFactoryGrimdexEduRoot = '/Users/kev/Dev/Grimdex-edu'
$script:DarkFactoryGrimdexEduProject = 'grimdex-edu'

function Get-DarkFactoryGrimdexEduRoot {
    param([string]$BatonHome = (Get-BatonHome))
    if ($env:GRIMDEX_EDU_ROOT -and (Test-Path -LiteralPath $env:GRIMDEX_EDU_ROOT)) {
        return (Resolve-Path -LiteralPath $env:GRIMDEX_EDU_ROOT).Path
    }
    $rec = Join-Path $BatonHome "projects/$($script:DarkFactoryGrimdexEduProject)/project.json"
    if (Test-Path -LiteralPath $rec) {
        try {
            $doc = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
            $folder = [string]$doc.folder
            if ($folder -and (Test-Path -LiteralPath $folder)) {
                return (Resolve-Path -LiteralPath $folder).Path
            }
        } catch { }
    }
    if (Test-Path -LiteralPath $script:DarkFactoryGrimdexEduRoot) {
        return (Resolve-Path -LiteralPath $script:DarkFactoryGrimdexEduRoot).Path
    }
    return $null
}

function Get-DarkFactoryLanes {
    <# Canonical overnight lanes — one queued job per track unless already active. #>
    return @(
        [ordered]@{
            lane       = 'dashboard'
            project    = 'baton'
            stakes     = 'standard'
            instrument = 'coding'
            goal       = @'
Dark factory dashboard slice: add a Dark Factory panel to the Baton dashboard (HTMX partial on home).
Show: Maestro job queue counts, security-researcher due projects, Grimdex-edu curriculum shipped vs backlog.
Add dashboard/readers/dark_factory.py, routers/dark_factory.py, partial + styles, pytest coverage.
Keep the existing maestro compose strip; this is an ops card above the fleet row.
'@
        }
        [ordered]@{
            lane       = 'baton-spine'
            project    = 'baton'
            stakes     = 'standard'
            instrument = 'coding-pwsh'
            goal       = @'
Dark factory automation wedge: scripts/dark-factory-lib.ps1 seed + status, fleet-dark-factory.ps1 CLI,
verbs.yaml entry, and dark-factory-night.sh that runs seed → maestro-admit → maestro-fire once.
Document in commands/dark-factory.md. Hermetic test-dark-factory-lib.ps1. Ox Alpha for labor.
'@
        }
        [ordered]@{
            lane       = 'grimdex-edu-curriculum'
            project    = $script:DarkFactoryGrimdexEduProject
            stakes     = 'standard'
            instrument = 'coding-pwsh'
            goal       = @'
Grimdex-edu curriculum build-out: read learn/curriculum-backlog.yaml and scripts/curriculum-audit.ps1.
Ship the highest-priority missing lesson pages (capability markdown under learn/*/capabilities/).
Each page needs: front matter, ## In plain terms, ## Official sources, pass-through links.
Run curriculum-audit.ps1 and update docs/curriculum-roadmap.md with shipped vs pending counts.
'@
        }
    )
}

function Ensure-DarkFactoryProjectRegistry {
    param([string]$BatonHome = (Get-BatonHome))
    $projDir = Join-Path $BatonHome "projects/$($script:DarkFactoryGrimdexEduProject)"
    $recPath = Join-Path $projDir 'project.json'
    if (Test-Path -LiteralPath $recPath) { return $recPath }
    $root = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    if (-not $root) { return $null }
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    $rec = [ordered]@{
        id     = $script:DarkFactoryGrimdexEduProject
        name   = 'Grimdex-edu'
        folder = $root
        agent  = 'baton'
        notes  = 'Learn module — verbose educational layer (D41). Auto-registered by dark-factory.'
    }
    ($rec | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $recPath -Encoding utf8NoBOM
    return $recPath
}

function New-DarkFactoryMaestroJob {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Stakes = 'standard',
        [string]$Source = 'cli',
        [string]$Status = 'queued',
        [string]$BatonHome = (Get-BatonHome)
    )
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $jobsDir)) {
        New-Item -ItemType Directory -Force -Path $jobsDir | Out-Null
    }
    $jid = 'mj-' + ([guid]::NewGuid().ToString('n').Substring(0, 12))
    $job = [ordered]@{
        id          = $jid
        project     = $Project
        goal        = $Goal.Trim()
        stakes      = $Stakes
        missed_fire = 'catch-up'
        source      = $Source
        status      = $Status
        provider    = $null
        run_id      = $null
        created_at  = ([datetime]::UtcNow).ToString('o')
        tags        = @('dark-factory')
    }
    ($job | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $jobsDir "$jid.json") -Encoding utf8NoBOM
    Write-MaestroEvent -Root $jobsDir -JobId $jid -Kind 'queued' -Status $Status
    return $job
}

function Test-DarkFactoryLaneActive {
    param(
        [Parameter(Mandatory)][string]$Lane,
        [Parameter(Mandatory)][string]$Project,
        [string]$BatonHome = (Get-BatonHome)
    )
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $jobsDir)) { return $false }
    foreach ($rec in @(Get-MaestroJobRecords -JobsDir $jobsDir)) {
        $j = $rec.Job
        if ([string]$j.project -ne $Project) { continue }
        $st = [string]$j.status
        if ($st -in @('done', 'held')) { continue }
        $goal = [string]$j.goal
        if ($goal -notmatch "<!--\s*dark-factory:lane=$([regex]::Escape($Lane))\s*-->") { continue }
        if ($st -in @('queued', 'admitted', 'running', 'waiting-quota', 'excess_capacity')) {
            return $true
        }
    }
    return $false
}

function Invoke-DarkFactorySeed {
    param(
        [string]$BatonHome = (Get-BatonHome),
        [switch]$Admit,
        [switch]$DryRun
    )
    Ensure-DarkFactoryProjectRegistry -BatonHome $BatonHome | Out-Null
    $created = [System.Collections.ArrayList]@()
    $skipped = [System.Collections.ArrayList]@()
    foreach ($lane in @(Get-DarkFactoryLanes)) {
        $proj = [string]$lane.project
        $name = [string]$lane.lane
        if (Test-DarkFactoryLaneActive -Lane $name -Project $proj -BatonHome $BatonHome) {
            [void]$skipped.Add($name)
            continue
        }
        if ($DryRun) {
            [void]$created.Add([ordered]@{ lane = $name; project = $proj; dry_run = $true })
            continue
        }
        $markedGoal = "<!-- dark-factory:lane=$name -->`n$([string]$lane.goal)"
        $job = New-DarkFactoryMaestroJob -Project $proj -Goal $markedGoal -Stakes ([string]$lane.stakes) -BatonHome $BatonHome
        [void]$created.Add([ordered]@{ lane = $name; job_id = [string]$job.id; project = $proj })
    }
    $admitted = @()
    if ($Admit -and -not $DryRun) {
        $admitScript = Join-Path $PSScriptRoot 'maestro-admit.ps1'
        if (Test-Path -LiteralPath $admitScript) {
            $admitJson = & pwsh -NoProfile -File $admitScript -BatonHome $BatonHome -Json 2>$null | ConvertFrom-Json
            $admitted = @($admitJson.admitted)
        }
    }
    return [ordered]@{
        created  = @($created)
        skipped  = @($skipped)
        admitted = $admitted
    }
}

function Get-DarkFactoryStatus {
    param([string]$BatonHome = (Get-BatonHome))
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $jobs = @()
    if (Test-Path -LiteralPath $jobsDir) {
        $jobs = @(Get-MaestroJobRecords -JobsDir $jobsDir | ForEach-Object { $_.Job })
    }
    $byStatus = @{}
    foreach ($j in $jobs) {
        $st = [string]$j.status
        if (-not $byStatus.ContainsKey($st)) { $byStatus[$st] = 0 }
        $byStatus[$st]++
    }
    $dfJobs = @($jobs | Where-Object {
        ($_.tags -and @($_.tags) -contains 'dark-factory') -or ([string]$_.goal -match 'Dark factory|dark factory|Grimdex-edu curriculum')
    })
    $sec = $null
    try { $sec = Invoke-SecurityResearcherTick -BatonHome $BatonHome } catch { $sec = @{ count = 0; due = @() } }
    $eduRoot = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    $curriculum = @{ root = $eduRoot; shipped = 0; pending = 0; modules = @() }
    if ($eduRoot) {
        $auditScript = Join-Path $eduRoot 'scripts/curriculum-audit.ps1'
        if (Test-Path -LiteralPath $auditScript) {
            try {
                $auditJson = & pwsh -NoProfile -File $auditScript -Json 2>$null | ConvertFrom-Json
                if ($auditJson) { $curriculum = $auditJson }
            } catch { }
        } else {
            $pages = @(Get-ChildItem -LiteralPath (Join-Path $eduRoot 'learn') -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '[\\/]capabilities[\\/]' })
            $curriculum.shipped = $pages.Count
        }
    }
    return [ordered]@{
        schema_version = 1
        jobs_total     = $jobs.Count
        jobs_by_status = $byStatus
        dark_factory   = @($dfJobs | Select-Object -First 8 | ForEach-Object {
            @{ id = $_.id; project = $_.project; status = $_.status; created_at = $_.created_at }
        })
        security_due   = @($sec.due)
        security_count = [int]$sec.count
        curriculum     = $curriculum
        lanes          = @(Get-DarkFactoryLanes | ForEach-Object { $_.lane })
    }
}

function Get-DarkFactoryRouteAroundText {
    return @'
## Provider route-around — Baton's superpower

When a seat hits its cap (Grok dry, Fable 100%, Codex lockout, Claude window, etc.):

1. **Do not halt.** Route around — that is why Baton exists.
2. **No fixed failover list.** Use the same rules as every other dispatch:
   - ``Select-Capability`` ranks eligible providers for the capability + stakes policy
   - **economy** (standard/low): cheapest tier that clears the bar, then quality + learned cost
   - **champion** (high): best quality first, cost tier tiebreak
   - Usage journal excludes exhausted/cooling workers only — everything else competes on the ranking
   - ``Invoke-CapabilityFailover`` walks that ranked list until one produces usable output
3. Kevin's Cursor example applies: when Fable is 100% used, keep going with Cursor auto,
   another Cursor seat, or whatever ``Select-Capability`` ranks next — not a memorized sequence.
4. Log skips in handoff + ``report-<project>.md``; never ask Kevin to pick a backup model.
'@
}

function Get-DarkFactoryContextMaintenanceText {
    return @'
## Context windows — maintain aggressively (long runs)

Unbounded chat history is a factory failure mode. **Every thread** must keep prompts lean:

1. **Handoff-first:** Treat `~/.baton/maestro/handoffs/<job-id>.md` as authoritative state.
   Do not assume prior conversation memory survives the next dispatch.
2. **Before each instrument / fleet-go:** run Efficiency Officer select or delta-packet:
   `pwsh -File scripts/fleet-efficiency.ps1 -Action select -Request "<claim>" -Root <repo>`
   Never paste whole trees, full transcripts, or duplicate standing orders.
3. **After each completed claim:** refresh the handoff (current state, relevant files, done-when),
   append ≤8 lines to `~/.baton/overnight/report-<project>.md`, then **spawn a fresh orchestrator**
   for the next claim instead of continuing one bloated thread.
4. **Parallel = disjoint context:** each worker gets only its `allowed_paths` slice + handoff excerpt.
   Never fan the same full session dump to multiple orchestrators.
5. **Rotate early:** if context is heavy, quality drops, or you are re-explaining — new run/worktree
   beat retrying inside a stuffed window. Ox Alpha is cheap; stale context is not.
6. Efficiency Officer **never blocks** labor, but skipping context hygiene is a Maestro bug.
'@
}

function Get-DarkFactoryStandingOrderText {
    param([string]$BatonHome = (Get-BatonHome))
    $eduRoot = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    $curriculum = 'unknown'
    if ($eduRoot) {
        $auditScript = Join-Path $eduRoot 'scripts/curriculum-audit.ps1'
        if (Test-Path -LiteralPath $auditScript) {
            try {
                $a = & pwsh -NoProfile -File $auditScript -Json 2>$null | ConvertFrom-Json
                if ($a) { $curriculum = "shipped=$($a.shipped) backlog=$($a.backlog) pending=$($a.pending)" }
            } catch { }
        }
    }
    $ctx = Get-DarkFactoryContextMaintenanceText
    $route = Get-DarkFactoryRouteAroundText
    return @"
# Dark factory standing order — $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC

Kevin is offline. **Keep working tonight.** Level 4 dark factory is active.

## Seating (baton-d124) — USE OX ALPHA HEAVILY

- **Primary seat:** ``openrouter-ox-alpha`` (stealth/ox-alpha on OpenRouter) for Conductor,
  planning, diff_apply, verify loops, research, and writing.
- **Secondary:** Grok 4.6 agentic when Ox cannot edit; Codex review only if usage < 40%.
- **Seat exhausted?** ``Select-Capability`` picks the next best eligible provider — never halt.
- **Never:** Fable or GPT-5.6 Sol for security/adversarial work.
- **Never** paste private Grimlore bodies into Ox/OpenRouter prompts.

$route

Fleet path: ``$BatonHome/overnight/fleet.yaml``

$ctx

## Worktree naming

``WT-<project<=7>-<goal-slug>`` under ``.baton-worktrees/``; branch ``baton/run-<run-id>`` for review.

## Priority lanes (queued — admit when slots open)

1. **dashboard** (baton) — command center + Dark Factory panel; keep HTMX polling green.
2. **baton-spine** (baton) — dark-factory seed/broadcast/night scripts; verbs + docs.
3. **grimdex-edu-curriculum** — ship Learn pages from ``learn/curriculum-backlog.yaml``
   ($curriculum). Start **grimdex-harness** module (4 lessons).

Commands:
- ``pwsh -File scripts/fleet-dark-factory.ps1 -Action broadcast``
- ``pwsh -File scripts/fleet-dark-factory.ps1 -Action night -Fire``
- ``~/.baton/overnight/bin/dark-factory-night.sh``

## Rules

- Fan parallel orchestrators; do not serialize projects.
- Never ask Kevin to spawn conductors.
- Never auto-merge to master — leave ``baton/run-*`` branches for human review.
- Efficiency Officer never blocks labor (fail-open) — but **must run** for context select/delta.

Read also: ``~/.baton/overnight/LAYER-SEATING.md``, ``docs/maestro-autoroute.md``
"@
}

function Get-DarkFactoryProjectBrief {
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$BatonHome = (Get-BatonHome)
    )
    $eduRoot = Get-DarkFactoryGrimdexEduRoot -BatonHome $BatonHome
    switch -Regex ($ProjectId) {
        '^baton' {
            return @'
Continue dark factory tonight on Baton:
- Command center dashboard shipped — keep hero, MyDashboard intel, dark factory panel green.
- Automation: fleet-dark-factory broadcast/seed/night; maestro-admit queued dark-factory jobs.
- Officers/instruments wedge: Ox Alpha default seat on all instrument rows.
- Refresh handoffs after each claim; Efficiency select before every fleet-go --execute.
Use openrouter-ox-alpha heavily for every labor run.
'@
        }
        '^grimdex-edu' {
            return @"
Continue Grimdex-edu Learn curriculum build-out ($eduRoot):
- Backlog: learn/curriculum-backlog.yaml (15 lessons planned).
- Audit: scripts/curriculum-audit.ps1 -Json
- Ship grimdex-harness module first: what-is-grimdex, learn-module-verbosity, student-zone-layout, install-and-bootstrap.
- Each page: front matter, ## In plain terms, ## Official sources, pass-through links.
- One lesson batch per fresh orchestrator; handoff between batches.
Use openrouter-ox-alpha for all writing labor. No course wiki content (D41).
"@
        }
        '^grimdex-know|^grimdex' {
            return @'
Grimdex engine / knowledge: capture any Baton officer decisions as Grimdex records when touched.
Ox Alpha for docs and small scripts. Do not fork student Grimdex installs.
Handoff + Efficiency select before large doc edits.
'@
        }
        '^grimlore' {
            return @'
Grimlore context cards only — no private bodies to Ox. Structure references for Baton agents.
Keep prompts to roster facts; never paste private card bodies into OpenRouter.
'@
        }
        default {
            return @"
Continue this project's highest-value backlog tonight.
Use openrouter-ox-alpha heavily for planning and labor; Grok only when Ox cannot edit.
If a preferred seat is out of quota, ``Select-Capability`` picks the next best eligible provider.
Work in WT-<project>-<slug> worktrees; leave baton/run-* branches for Kevin.
Maintain context aggressively: handoff after each claim, fresh orchestrator per slice.
"@
        }
    }
}

function Invoke-DarkFactoryBroadcast {
    <# Push standing order + per-job handoffs into every active Maestro thread. #>
    param(
        [string]$BatonHome = (Get-BatonHome),
        [switch]$Seed,
        [switch]$Admit
    )
    Ensure-DarkFactoryProjectRegistry -BatonHome $BatonHome | Out-Null
    $orderText = Get-DarkFactoryStandingOrderText -BatonHome $BatonHome
    $overnight = Join-Path $BatonHome 'overnight'
    if (-not (Test-Path -LiteralPath $overnight)) { New-Item -ItemType Directory -Force -Path $overnight | Out-Null }
    $orderPath = Join-Path $overnight 'DARK-FACTORY-TONIGHT.md'
    Set-Content -LiteralPath $orderPath -Value $orderText -Encoding utf8NoBOM
    $maestroOrder = Join-Path (Get-MaestroRoot -BatonHome $BatonHome) 'STANDING-ORDER.md'
    Set-Content -LiteralPath $maestroOrder -Value $orderText -Encoding utf8NoBOM

    $ctxBlock = Get-DarkFactoryContextMaintenanceText
    $goalNext = Join-Path $overnight 'goal-next.md'
    @(
        '# goal-next — dark factory tonight (auto-broadcast)',
        '',
        '**Ox Alpha heavily.** Primary seat: ``openrouter-ox-alpha``.',
        '**Seat exhausted?** Route via ``Select-Capability`` — next best eligible provider, not a fixed list.',
        '',
        'Kevin is asleep. Continue all active Maestro threads. Do not stop for approval.',
        '',
        'Read: ``DARK-FACTORY-TONIGHT.md`` · ``LAYER-SEATING.md`` · ``MAESTRO-PARALLEL.md``',
        '',
        $ctxBlock,
        '',
        (Get-DarkFactoryProjectBrief -ProjectId 'baton' -BatonHome $BatonHome),
        ''
    ) | Set-Content -LiteralPath $goalNext -Encoding utf8NoBOM

    $projDir = Join-Path $BatonHome 'projects'
    $sessions = @()
    if (Test-Path -LiteralPath $projDir) {
        foreach ($pj in Get-ChildItem -LiteralPath $projDir -Directory) {
            $projId = $pj.Name
            try {
                Set-MaestroProjectSession -Project $projId -Provider 'openrouter-ox-alpha' -Kind 'openrouter' -BatonHome $BatonHome | Out-Null
                [void]$sessions.Add($projId)
            } catch { }
        }
    }

    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $active = @('queued', 'admitted', 'running', 'waiting-quota', 'excess_capacity')
    $handoffs = [System.Collections.ArrayList]@()
    $constraints = @(
        'Aggressive context hygiene: handoff-only prompts; Efficiency select/delta before dispatch;',
        'fresh orchestrator per claim; fold to report-*.md after each slice.',
        'Ox Alpha heavily. No merge to master. No private Grimlore to Ox.'
    ) -join ' '
    foreach ($rec in @(Get-MaestroJobRecords -JobsDir $jobsDir)) {
        $j = $rec.Job
        $st = [string]$j.status
        if ($active -notcontains $st) { continue }
        $proj = [string]$j.project
        $jid = [string]$j.id
        $brief = Get-DarkFactoryProjectBrief -ProjectId $proj -BatonHome $BatonHome
        $goalBlock = @"
$brief

---
Standing order (all threads):
$(Get-DarkFactoryStandingOrderText -BatonHome $BatonHome)
"@
        $path = Write-MaestroHandoff -JobId $jid -Goal $goalBlock `
            -CurrentState "Maestro job $jid status=$st project=$proj" `
            -RelevantFiles "See project folder in ~/.baton/projects/$proj/project.json; handoff is authoritative over chat history." `
            -Constraints $constraints `
            -DoneWhen 'Concrete diff in worktree + baton/run-* branch left for Kevin; handoff refreshed for next claim.' `
            -Checks 'pwsh -File scripts/fleet-efficiency.ps1 -Action select -Request "<next claim>" -Root <repo>; pwsh -File scripts/fleet-dark-factory.ps1 -Action status -Json' `
            -BatonHome $BatonHome
        [void]$handoffs.Add([ordered]@{ job_id = $jid; project = $proj; status = $st; handoff = $path })
    }

    $seedResult = $null
    if ($Seed) {
        $seedResult = Invoke-DarkFactorySeed -BatonHome $BatonHome -Admit:$Admit
    } elseif ($Admit) {
        $admitScript = Join-Path $PSScriptRoot 'maestro-admit.ps1'
        if (Test-Path -LiteralPath $admitScript) {
            & pwsh -NoProfile -File $admitScript -BatonHome $BatonHome | Out-Null
        }
    }

    return [ordered]@{
        standing_order = $orderPath
        maestro_order  = $maestroOrder
        goal_next      = $goalNext
        sessions       = @($sessions)
        handoffs       = @($handoffs)
        seed           = $seedResult
    }
}
