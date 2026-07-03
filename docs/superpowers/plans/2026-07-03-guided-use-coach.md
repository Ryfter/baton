# Guided-Use Coach (v1.8.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Baton suggest its own commands — a read-only orientation digest at session start plus one-line `Next:` footers on the run-path CLIs — driven by one declarative rules engine (spec: `docs/superpowers/specs/2026-07-03-guided-use-coach-design.md`, d074).

**Architecture:** New `scripts/coach-lib.ps1` engine (fail-open signal readers → ordered rule table → one-shot dedup stamps) consumed by a new SessionStart hook (`scripts/hooks/baton-coach.ps1`) and by footer calls at the end of four fleet CLIs. Zero model calls, zero network calls; a coach failure can never break a session or a host command.

**Tech Stack:** PowerShell 7 (pwsh), existing Baton libs (`baton-home`, `start-lib`, `prompt-pool-lib`, `usage-lib`, optional `fleet-lib`), Claude Code plugin hooks (`hooks/hooks.json`).

## Global Constraints

- Every shell command argument stays under 965 bytes (silent failure above).
- Hook scripts ALWAYS `exit 0` on every path; errors go to `$BATON_HOME/logs/baton-coach.err.log`. CLI error paths elsewhere use `[Console]::Error.WriteLine` + `exit 2` — NEVER `Write-Error` (it throws under `$ErrorActionPreference='Stop'`).
- All file writes use `-Encoding utf8NoBOM`.
- Never name variables `$args`, `$input`, `$event`, `$matches`, or `$host` (PowerShell automatic variables).
- `ConvertFrom-Json` auto-parses ISO8601 strings into `[datetime]` — only existence/identity is read from such values here; never compare them as strings without re-stringifying.
- Unary-comma flatten guard: `,([object[]]$x)` only on direct-assignment returns and never on an empty array (return plain `@()` for the empty case); use `@()` inside hashtable literals.
- Tests are hermetic: temp `BATON_HOME` via `try/finally` env restore; NEVER touch real `~/.baton` or `~/.claude`.
- Footers must never print when the host CLI was invoked with `-Json` (machine output stays parseable — `Write-Host` merges into stdout when the CLI runs as a child `pwsh`).
- The coach makes no model calls, no network calls, and no writes except `seen.json` stamps and `config.json` reads.
- Rule ordering (= digest/footer priority): `next-command`, `gate-failure`, `promote-pending`, `pool-verdict`, `budget`, `onboard`. Entries with `dedup_key = $null` are digest-only.

---

### Task 1: Coach engine (`coach-lib.ps1`) + tests

**Files:**
- Create: `scripts/coach-lib.ps1`
- Create: `scripts/test-coach-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` (baton-home.ps1); `Read-ProjectRecord -ProjectId -ProjectsRoot`, `Get-NextCommandRecommendation -RunStatus` (start-lib.ps1); `Get-PromptPool -PoolDir`, `Get-ShadowVerdict -Pool` (prompt-pool-lib.ps1); `Read-UsageJournal -Path`, `Get-ConserveMode -Rows`, `Get-UsageForecast -Worker -UsagePath -FleetPath` (usage-lib.ps1).
- Produces (used by Tasks 2–3): `Get-CoachDir([string]$BatonHome)` → coach dir path; `Get-CoachLevel([string]$BatonHome)` → `'off'|'quiet'|'teach'`; `Get-CoachContext(-BatonHome, -ProjectDir)` → hashtable (keys listed in the code below); `Get-CoachSuggestions(-Context, -SeenPath, [switch]-IncludeSeen, [string[]]-ExcludeIds)` → `@(@{id; command; why; dedup_key})`; `Set-CoachSeen(-SeenPath, -Key)`; `Read-CoachSeen(-SeenPath)` → hashtable; `Write-CoachFooter([string[]]-ExcludeIds, -BatonHome, -ProjectDir)` → prints ≤1 `Next:` line via `Write-Host` and stamps it.

- [ ] **Step 1: Write the failing test suite**

Create `scripts/test-coach-lib.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
# Hermetic tests for the guided-use coach engine (d074). Never touches real
# ~/.baton or ~/.claude: temp BATON_HOME, try/finally restore.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    . (Join-Path $here 'coach-lib.ps1')

    $coachDir = Get-CoachDir -BatonHome $env:BATON_HOME
    $seenPath = Join-Path $coachDir 'seen.json'

    # --- Level ---
    Assert "C1 level defaults to quiet when config absent" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    Assert "C2 level teach parses" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'teach')
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    Assert "C3 level off parses" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'off')
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"LOUD"}' -Encoding utf8NoBOM
    Assert "C4 unknown level falls back to quiet" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    Set-Content (Join-Path $coachDir 'config.json') 'not json {' -Encoding utf8NoBOM
    Assert "C5 malformed config falls back to quiet" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    Remove-Item (Join-Path $coachDir 'config.json') -Force

    # --- Seen store ---
    Set-CoachSeen -SeenPath $seenPath -Key 'k1'
    $seen = Read-CoachSeen -SeenPath $seenPath
    Assert "C6 seen stamp round-trips" ($seen.ContainsKey('k1'))
    Set-Content $seenPath 'garbage {{' -Encoding utf8NoBOM
    Assert "C7 malformed seen.json reads as empty" ((Read-CoachSeen -SeenPath $seenPath).Count -eq 0)
    Set-CoachSeen -SeenPath $seenPath -Key 'k2'
    Assert "C8 stamp after malformed rewrites the store" ((Read-CoachSeen -SeenPath $seenPath).ContainsKey('k2'))
    Remove-Item $seenPath -Force

    # --- Empty context: nothing readable, nothing thrown ---
    $bare = Join-Path $tmp 'bare-dir'
    New-Item -ItemType Directory -Force -Path $bare | Out-Null
    $ctx0 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $bare
    Assert "C9 empty context: no project" ($null -eq $ctx0.project)
    Assert "C10 empty context: not a git repo" (-not $ctx0.is_git_repo)
    Assert "C11 empty context: pool not ok" (-not $ctx0.pool_ok)
    Assert "C12 empty context: no budget risk" (-not $ctx0.budget_at_risk)
    Assert "C13 empty context: zero failure runs" ($ctx0.failure_runs -eq 0)
    Assert "C14 empty context yields no suggestions" (@(Get-CoachSuggestions -Context $ctx0 -SeenPath $seenPath).Count -eq 0)

    # --- Onboard: git repo without a project record ---
    $repoDir = Join-Path $tmp 'proj-alpha'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoDir '.git') | Out-Null
    $ctx1 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C15 detects git repo" ($ctx1.is_git_repo)
    Assert "C16 project id from folder slug" ($ctx1.project_id -eq 'proj-alpha')
    $s1 = @(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath)
    Assert "C17 onboard rule fires" ((@($s1).Count -eq 1) -and ($s1[0].id -eq 'onboard') -and ($s1[0].command -eq '/baton:start'))
    Assert "C18 onboard dedup key carries normalized dir" ($s1[0].dedup_key -eq "onboard:$($ctx1.project_dir_normalized)")
    Set-CoachSeen -SeenPath $seenPath -Key $s1[0].dedup_key
    Assert "C19 stamped onboard is filtered" (@(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath).Count -eq 0)
    Assert "C20 -IncludeSeen bypasses the stamp" (@(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath -IncludeSeen).Count -eq 1)

    # --- Registered project: next-command orientation ---
    $projDir = Join-Path (Join-Path $env:BATON_HOME 'projects') 'proj-alpha'
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    Set-Content (Join-Path $projDir 'project.json') '{"id":"proj-alpha","last_run":{"status":"completed"}}' -Encoding utf8NoBOM
    $ctx2 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C21 project record loads" ($null -ne $ctx2.project)
    $s2 = @(Get-CoachSuggestions -Context $ctx2 -SeenPath $seenPath -IncludeSeen)
    Assert "C22 next-command rule fires for last_run.status" ((@($s2).Count -ge 1) -and ($s2[0].id -eq 'next-command'))
    Assert "C23 next-command is digest-only (null dedup_key)" ($null -eq $s2[0].dedup_key)
    Assert "C24 registered project suppresses onboard" (@($s2 | Where-Object { $_.id -eq 'onboard' }).Count -eq 0)

    # --- Gate failure runs ---
    $runsRoot = Join-Path $env:BATON_HOME 'runs'
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-fail-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-fail-1/acceptance.json') '{"verdict":"polish","reason":"needs polish"}' -Encoding utf8NoBOM
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-ok-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-ok-1/acceptance.json') '{"verdict":"accept","reason":"fine"}' -Encoding utf8NoBOM
    $ctx3 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C25 failure run counted" ($ctx3.failure_runs -eq 1)
    Assert "C26 latest failure run id captured" ($ctx3.latest_failure_run_id -eq 'run-fail-1')
    $s3 = @(Get-CoachSuggestions -Context $ctx3 -SeenPath $seenPath)
    $gf = @($s3 | Where-Object { $_.id -eq 'gate-failure' })
    Assert "C27 gate-failure rule fires" ((@($gf).Count -eq 1) -and ($gf[0].command -eq '/baton:optimize-prompt'))
    Assert "C28 gate-failure dedup key names the run" ($gf[0].dedup_key -eq 'gate-failure:run-fail-1')

    # --- Pool: promote-pending + pool-verdict ---
    $poolDir = Join-Path $env:BATON_HOME 'prompts/pool'
    New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
    $poolJson = @'
{
  "schema": 1, "champion": "p001",
  "candidates": [
    { "id": "p001", "file": "p001.txt", "status": "champion",
      "offline": { "minibatch": { "win_rate_vs_champion": null } },
      "live": { "runs": 6, "accept": 4, "polish": 1, "reject": 1, "realized_cost_usd": 4.0, "rework_cost_usd": 0.0 },
      "promote_recommended_at": null, "retired_at": null, "retired_by": null },
    { "id": "p002", "file": "p002.txt", "status": "candidate",
      "offline": { "minibatch": { "win_rate_vs_champion": 0.8 } },
      "live": { "runs": 6, "accept": 5, "polish": 1, "reject": 0, "realized_cost_usd": 2.5, "rework_cost_usd": 0.0 },
      "promote_recommended_at": "2026-07-03T00:00:00Z", "retired_at": null, "retired_by": null }
  ]
}
'@
    Set-Content (Join-Path $poolDir 'pool.json') $poolJson -Encoding utf8NoBOM
    $ctx4 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C29 pool loads" ($ctx4.pool_ok)
    Assert "C30 champion id read" ($ctx4.pool_champion_id -eq 'p001')
    Assert "C31 challenger id read" ($ctx4.pool_challenger_id -eq 'p002')
    Assert "C32 verdict ready at threshold" ($ctx4.pool_verdict_ready)
    Assert "C33 promote pending detected" (@($ctx4.promote_pending) -contains 'p002')
    $s4 = @(Get-CoachSuggestions -Context $ctx4 -SeenPath $seenPath)
    $pp = @($s4 | Where-Object { $_.id -eq 'promote-pending' })
    $pv = @($s4 | Where-Object { $_.id -eq 'pool-verdict' })
    Assert "C34 promote-pending rule fires with --apply" ((@($pp).Count -eq 1) -and ($pp[0].command -eq '/baton:optimize-prompt --apply') -and ($pp[0].dedup_key -eq 'promote:p002'))
    Assert "C35 pool-verdict rule fires with --pool" ((@($pv).Count -eq 1) -and ($pv[0].command -eq '/baton:optimize-prompt --pool') -and ($pv[0].dedup_key -eq 'pool-verdict:p001:p002'))
    # Registered project => next-command (digest-only) leads; then the trio.
    Assert "C36 ordering: next-command, gate-failure, promote-pending, pool-verdict" (($s4[0].id -eq 'next-command') -and ($s4[1].id -eq 'gate-failure') -and ($s4[2].id -eq 'promote-pending') -and ($s4[3].id -eq 'pool-verdict'))
    $sEx = @(Get-CoachSuggestions -Context $ctx4 -SeenPath $seenPath -ExcludeIds @('gate-failure','promote-pending','pool-verdict'))
    Assert "C37 -ExcludeIds drops the optimizer trio (next-command remains)" ((@($sEx).Count -eq 1) -and ($sEx[0].id -eq 'next-command'))

    # --- Budget: conserve mode ---
    Set-ConserveMode -On $true -UsagePath (Join-Path $env:BATON_HOME 'usage-journal.jsonl')
    $ctx5 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C38 conserve mode read" ($ctx5.conserve)
    Assert "C39 budget at risk under conserve" ($ctx5.budget_at_risk)
    $bg = @(Get-CoachSuggestions -Context $ctx5 -SeenPath $seenPath | Where-Object { $_.id -eq 'budget' })
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    Assert "C40 budget rule fires daily-keyed" ((@($bg).Count -eq 1) -and ($bg[0].command -eq '/baton:usage') -and ($bg[0].dedup_key -eq "budget:$today"))

    # --- Poisoned pool: context still gathers, no throw ---
    Set-Content (Join-Path $poolDir 'pool.json') 'not a pool {{' -Encoding utf8NoBOM
    $ctx6 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C41 poisoned pool degrades to pool_ok=false" (-not $ctx6.pool_ok)
    Assert "C42 other signals survive a poisoned pool" ($ctx6.conserve -and ($ctx6.failure_runs -eq 1))

    # --- Write-CoachFooter (restore healthy pool first) ---
    Set-Content (Join-Path $poolDir 'pool.json') $poolJson -Encoding utf8NoBOM
    Remove-Item $seenPath -Force -ErrorAction SilentlyContinue
    $f1 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C43 footer prints one Next: line at quiet" ((@($f1).Count -eq 1) -and ($f1[0] -like 'Next: /baton:optimize-prompt*') -and ($f1[0] -notlike '*—*'))
    $f2 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C44 footer suggestion was stamped (next call moves on)" ((@($f2).Count -eq 1) -and ($f2[0] -ne $f1[0]))
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    $f3 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C45 teach footer includes the why" ((@($f3).Count -eq 1) -and ($f3[0] -like 'Next: *—*'))
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $f4 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C46 off level prints nothing" (@($f4).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM
    # Exhaust remaining stampable suggestions, then verify silence.
    $null = Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1
    $null = Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1
    $f5 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C47 all stamped -> no footer" (@($f5).Count -eq 0)
    # Digest-only entries never reach footers: context with ONLY next-command.
    Remove-Item (Join-Path $poolDir 'pool.json') -Force
    Remove-Item (Join-Path $runsRoot 'run-fail-1') -Recurse -Force
    Set-ConserveMode -On $false -UsagePath (Join-Path $env:BATON_HOME 'usage-journal.jsonl')
    $f6 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C48 digest-only next-command never appears as a footer" (@($f6).Count -eq 0)
} finally {
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-coach-lib.ps1`
Expected: hard failure loading `coach-lib.ps1` (file does not exist) — non-zero exit.

- [ ] **Step 3: Write the engine**

Create `scripts/coach-lib.ps1` with exactly this content:

```powershell
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
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-coach-lib.ps1`
Expected: `ALL PASS` (C1–C48), exit 0.

Note on C44: after C43 stamps `gate-failure:run-fail-1`, the next footer must print a DIFFERENT suggestion (`promote-pending`) — that's what "moves on" asserts. C47 exhausts `pool-verdict` and `budget` (2 more calls) before asserting silence.

- [ ] **Step 5: Run neighbor regressions (the libs coach-lib dot-sources)**

Run: `pwsh -NoProfile -File scripts/test-start-lib.ps1; pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1; pwsh -NoProfile -File scripts/test-usage.ps1`
Expected: all pass (coach-lib only reads them; no modifications were made).

- [ ] **Step 6: Commit**

```bash
git add scripts/coach-lib.ps1 scripts/test-coach-lib.ps1
git commit -m "feat(coach): guided-use rules engine — context readers, rule table, one-shot stamps, footer helper (d074)"
```

---

### Task 2: SessionStart digest hook + registration + tests

**Files:**
- Create: `scripts/hooks/baton-coach.ps1`
- Modify: `hooks/hooks.json`
- Create: `scripts/test-baton-coach-hook.ps1`

**Interfaces:**
- Consumes (Task 1): `Get-CoachDir`, `Get-CoachLevel`, `Get-CoachContext`, `Get-CoachSuggestions`, `Set-CoachSeen`; `Get-BatonHome` (via coach-lib's dot-sources).
- Produces: session-context digest lines on stdout; nothing else depends on this task.

- [ ] **Step 1: Write the failing hook test**

Create `scripts/test-baton-coach-hook.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
# Tests for the SessionStart baton-coach hook: orientation digest scaled by
# registration, one-shot onboard line, always exits 0. Hermetic BATON_HOME.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks/baton-coach.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

function Invoke-CoachHook([string]$Cwd) {
    # Claude Code feeds hooks a JSON payload on stdin; cwd is what the coach reads.
    $payload = '{"cwd":' + (ConvertTo-Json $Cwd) + ',"hook_event_name":"SessionStart","source":"startup"}'
    $out = @($payload | & pwsh -NoProfile -File $hook 2>$null)
    return ,@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-hook-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'

    # H1: BATON_HOME absent -> silent, exit 0.
    $plainDir = Join-Path $tmp 'plain'
    New-Item -ItemType Directory -Force -Path $plainDir | Out-Null
    $o1 = Invoke-CoachHook $plainDir
    Assert "H1 absent BATON_HOME: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H1 absent BATON_HOME: silent" (@($o1).Count -eq 0)

    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null

    # H2: non-git dir -> silent.
    $o2 = Invoke-CoachHook $plainDir
    Assert "H2 non-git dir: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H2 non-git dir: silent" (@($o2).Count -eq 0)

    # H3: unregistered git repo -> one onboard line, then one-shot silence.
    $repoDir = Join-Path $tmp 'proj-alpha'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoDir '.git') | Out-Null
    $o3 = Invoke-CoachHook $repoDir
    Assert "H3 unregistered repo: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H3 unregistered repo: one onboard line" ((@($o3).Count -eq 1) -and ($o3[0] -like '*Baton available*') -and ($o3[0] -like '*/baton:start*'))
    $o3b = Invoke-CoachHook $repoDir
    Assert "H3b onboard is one-shot" (@($o3b).Count -eq 0)

    # H4: registered project -> digest with status + suggestion, never dedups.
    $projDir = Join-Path (Join-Path $env:BATON_HOME 'projects') 'proj-alpha'
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    Set-Content (Join-Path $projDir 'project.json') '{"id":"proj-alpha","last_run":{"status":"completed"}}' -Encoding utf8NoBOM
    $o4 = Invoke-CoachHook $repoDir
    Assert "H4 registered project: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H4 digest headline names the project + status" ((@($o4).Count -ge 2) -and ($o4[0] -like "*proj-alpha*") -and ($o4[0] -like '*completed*'))
    Assert "H4 digest carries a suggested next command" (@($o4 | Where-Object { $_ -like 'Suggested next:*' }).Count -eq 1)
    $o4b = Invoke-CoachHook $repoDir
    Assert "H4b digest repeats on every start (status report, no dedup)" (@($o4b).Count -eq @($o4).Count)

    # H5: teach level appends the why.
    $coachDir = Join-Path $env:BATON_HOME 'coach'
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    $o5 = Invoke-CoachHook $repoDir
    Assert "H5 teach digest includes why" (@($o5 | Where-Object { ($_ -like 'Suggested next:*') -and ($_ -like '*—*') }).Count -eq 1)

    # H6: off level -> silent even for a registered project.
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $o6 = Invoke-CoachHook $repoDir
    Assert "H6 off: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H6 off: silent" (@($o6).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM

    # H7: poisoned pool must not break the digest or the exit code.
    $poolDir = Join-Path $env:BATON_HOME 'prompts/pool'
    New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
    Set-Content (Join-Path $poolDir 'pool.json') 'garbage {{' -Encoding utf8NoBOM
    $o7 = Invoke-CoachHook $repoDir
    Assert "H7 poisoned pool: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H7 poisoned pool: digest still prints" (@($o7).Count -ge 2)
} finally {
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-baton-coach-hook.ps1`
Expected: failures (hook file does not exist; `& pwsh -File` against a missing file exits non-zero, H1 fails).

- [ ] **Step 3: Write the hook**

Create `scripts/hooks/baton-coach.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  SessionStart(startup) hook: guided-use orientation digest (d074).
  Read-only except the one-shot onboard stamp. Non-blocking: always exits 0;
  errors go to $BATON_HOME/logs/baton-coach.err.log. Runs after
  baton-init.ps1 (registered earlier in hooks/hooks.json), so BATON_HOME
  exists by the time this fires — if it still doesn't, stay silent.
#>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../coach-lib.ps1'),         # repo/plugin layout: scripts/hooks -> scripts
        (Join-Path $scriptDir '../scripts/coach-lib.ps1')  # deployed layout: ~/.claude/hooks -> ~/.claude/scripts
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath

    $batonHome = Get-BatonHome
    if (-not (Test-Path $batonHome)) { exit 0 }
    $level = Get-CoachLevel -BatonHome $batonHome
    if ($level -eq 'off') { exit 0 }

    # cwd from the hook's stdin JSON payload; fall back to the process cwd.
    $projDir = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.cwd) { $projDir = [string]$payload.cwd }
            }
        }
    } catch { }

    $ctx = Get-CoachContext -BatonHome $batonHome -ProjectDir $projDir
    $seenPath = Join-Path (Get-CoachDir -BatonHome $batonHome) 'seen.json'

    if ($ctx.project) {
        # Registered project: status digest (never dedups) + top suggestion.
        $status = if ($ctx.project.last_run -and $ctx.project.last_run.status) { [string]$ctx.project.last_run.status } else { 'no runs yet' }
        Write-Output ("Baton coach — project '{0}': last run {1}." -f $ctx.project_id, $status)
        if ($ctx.pool_ok) {
            $challStr = if ($ctx.pool_challenger_id) { "challenger $($ctx.pool_challenger_id) ($($ctx.pool_verdict_state))" } else { 'no challenger' }
            Write-Output ("Prompt pool: champion {0}, {1}." -f $ctx.pool_champion_id, $challStr)
        }
        $budgetStr = if ($ctx.conserve) { 'CONSERVE MODE ON' } elseif ($ctx.budget_at_risk) { 'budget at risk' } else { 'budget ok' }
        Write-Output ("Usage: {0}." -f $budgetStr)
        $sugg = @(Get-CoachSuggestions -Context $ctx -SeenPath $seenPath -IncludeSeen)
        if (@($sugg).Count -gt 0) {
            $top = $sugg[0]
            if ($level -eq 'teach') { Write-Output ("Suggested next: {0} — {1}" -f $top.command, $top.why) }
            else { Write-Output ("Suggested next: {0}" -f $top.command) }
        }
    } elseif ($ctx.is_git_repo) {
        # Unregistered repo: one-shot onboard push line (stamped).
        $sugg = @(Get-CoachSuggestions -Context $ctx -SeenPath $seenPath | Where-Object { $_.id -eq 'onboard' })
        if (@($sugg).Count -gt 0) {
            $onboard = $sugg[0]
            if ($level -eq 'teach') { Write-Output ("Baton available: {0} — {1}" -f $onboard.command, $onboard.why) }
            else { Write-Output ("Baton available — {0} to onboard." -f $onboard.command) }
            Set-CoachSeen -SeenPath $seenPath -Key ([string]$onboard.dedup_key)
        }
    }
    exit 0
} catch {
    try {
        $log = Join-Path (Get-BatonHome) 'logs/baton-coach.err.log'
        $d = Split-Path -Parent $log
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Add-Content -Path $log -Value ((Get-Date -Format o) + " | " + $_.Exception.Message)
    } catch { }
    exit 0
}
```

- [ ] **Step 4: Register the hook**

Modify `hooks/hooks.json` — the `SessionStart` entry gains a second command in the SAME `hooks` array (order matters: init first, coach second). Replace the current `SessionStart` value with:

```json
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-init.ps1\""
          },
          {
            "type": "command",
            "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-coach.ps1\""
          }
        ]
      }
    ],
```

Leave `PostToolUse` and `Stop` untouched. Validate the file still parses: `pwsh -NoProfile -Command "Get-Content hooks/hooks.json -Raw | ConvertFrom-Json | Out-Null; 'ok'"` → `ok`.

- [ ] **Step 5: Run the hook tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-baton-coach-hook.ps1`
Expected: `ALL PASS` (H1–H7), exit 0.

- [ ] **Step 6: Run the init-hook regression**

Run: `pwsh -NoProfile -File scripts/test-baton-init-hook.ps1`
Expected: all pass (init hook untouched; this guards the hooks.json edit).

- [ ] **Step 7: Commit**

```bash
git add scripts/hooks/baton-coach.ps1 hooks/hooks.json scripts/test-baton-coach-hook.ps1
git commit -m "feat(coach): SessionStart orientation digest hook, scaled by project registration (d074)"
```

---

### Task 3: `Next:` footers on the four fleet CLIs + footer tests

**Files:**
- Modify: `scripts/fleet-usage.ps1` (status branch, non-JSON path)
- Modify: `scripts/fleet-gate.ps1` (run branch, non-JSON path)
- Modify: `scripts/fleet-go.ps1` (non-JSON report block)
- Modify: `scripts/fleet-optimize-prompt.ps1` (non-JSON `-Pool` report end AND non-JSON evolution-success end)
- Create: `scripts/test-coach-footers.ps1`

**Interfaces:**
- Consumes (Task 1): `Write-CoachFooter -ExcludeIds <string[]>` — prints ≤1 line via `Write-Host`, stamps what it prints, silently no-ops on any error.
- Produces: nothing new — behavior only.

**Wiring pattern (identical in all four scripts).** After the script's existing dot-source line(s) near the top, add:

```powershell
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
```

At each human-readable output end, add a guarded call (the `Get-Command` check plus coach-lib's own try/catch make a broken coach a no-op, never a broken CLI):

```powershell
if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds @(<per-script list>) }
```

Footer calls go ONLY on non-JSON paths — when the CLI runs as a child `pwsh`, `Write-Host` merges into stdout and would corrupt `-Json` output. Never add a footer to an error/`exit 2` path.

- [ ] **Step 1: Write the failing footer test**

Create `scripts/test-coach-footers.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
# End-to-end footer checks via the cheapest real CLI (fleet-usage status):
# footer prints, one-shots, respects off, excludes self, never pollutes -Json.
# fleet-gate/go/optimize-prompt use the identical guarded call — wiring parity
# is checked by grep here and behavior by the opus final review.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$usageCli = Join-Path $here 'fleet-usage.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-footer-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $up = Join-Path $env:BATON_HOME 'usage-journal.jsonl'

    # Fixture: one polish-verdict run -> the gate-failure suggestion is live.
    $runsRoot = Join-Path $env:BATON_HOME 'runs'
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-fail-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-fail-1/acceptance.json') '{"verdict":"polish","reason":"x"}' -Encoding utf8NoBOM

    # Run the CLIs from a NON-git cwd: otherwise the repo cwd makes the
    # onboard rule fire (temp BATON_HOME has no project record for the repo)
    # and pollutes the one-shot assertions with a second live suggestion.
    $workDir = Join-Path $tmp 'work'
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Push-Location $workDir

    # F1: footer appears once...
    $o1 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F1 usage status exits 0" ($LASTEXITCODE -eq 0)
    Assert "F1 footer suggests optimize-prompt" (@($o1 | Where-Object { $_ -like 'Next: /baton:optimize-prompt*' }).Count -eq 1)

    # F2: ...and is one-shot.
    $o2 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F2 footer one-shot (stamped)" (@($o2 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)

    # F3: -Json stays pure even with a fresh (unstamped) suggestion.
    Remove-Item (Join-Path (Join-Path $env:BATON_HOME 'coach') 'seen.json') -Force -ErrorAction SilentlyContinue
    $o3 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up -Json 2>$null | ForEach-Object { "$_" })
    Assert "F3 -Json output has no footer" (@($o3 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)
    Assert "F3 -Json output parses" ($null -ne (($o3 -join "`n") | ConvertFrom-Json))

    # F4: level off -> no footer.
    $coachDir = Join-Path $env:BATON_HOME 'coach'
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $o4 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F4 off level: no footer" (@($o4 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM

    # F5: self-suggestion excluded — only the budget signal, run /baton:usage.
    Remove-Item (Join-Path $runsRoot 'run-fail-1') -Recurse -Force
    Remove-Item (Join-Path $coachDir 'seen.json') -Force -ErrorAction SilentlyContinue
    . (Join-Path $here 'usage-lib.ps1')
    Set-ConserveMode -On $true -UsagePath $up
    $o5 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F5 usage never suggests itself" (@($o5 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)

    # F6: wiring parity — all four CLIs carry the guarded footer call.
    foreach ($cli in 'fleet-usage.ps1', 'fleet-gate.ps1', 'fleet-go.ps1', 'fleet-optimize-prompt.ps1') {
        $src = Get-Content -Raw (Join-Path $here $cli)
        Assert "F6 $cli sources coach-lib" ($src -like '*coach-lib.ps1*')
        Assert "F6 $cli calls Write-CoachFooter" ($src -like '*Write-CoachFooter*')
    }
    $opSrc = Get-Content -Raw (Join-Path $here 'fleet-optimize-prompt.ps1')
    Assert "F6 optimize-prompt excludes its own rules" ($opSrc -like "*'gate-failure'*" -and $opSrc -like "*'promote-pending'*" -and $opSrc -like "*'pool-verdict'*")
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-coach-footers.ps1`
Expected: F1 and F6 fail (no footer wiring exists yet); F2/F4/F5 may vacuously pass — that's fine, F1/F6 are the red markers.

- [ ] **Step 3: Wire fleet-usage.ps1**

Add the coach-lib dot-source after the existing `. "$PSScriptRoot/usage-lib.ps1"`-style source lines near the top (immediately after `$ErrorActionPreference = 'Stop'` and the script's existing dot-sources):

```powershell
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
```

In the `'status'` switch branch, the non-JSON `else` block currently ends with:

```powershell
            foreach ($s in $states) { Write-StateLine $s }
        }
        return
```

Insert the footer between the `}` closing the `else` and the `return` — guarded on `-not $Json`:

```powershell
            foreach ($s in $states) { Write-StateLine $s }
        }
        if (-not $Json) {
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds @('budget') }
        }
        return
```

(`'budget'` is fleet-usage's self-suggestion.) Do NOT touch the `'forecast'` or mutating branches — one footer surface per CLI, on its default human path.

- [ ] **Step 4: Wire fleet-gate.ps1**

Dot-source (after `. (Join-Path $PSScriptRoot 'gate-lib.ps1')`):

```powershell
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
```

In the `'run'` branch, the non-JSON `else` block currently ends with:

```powershell
            Write-Host '---'
            Write-Host $res.polish_brief
        }
```

Append inside that `else`, after `Write-Host $res.polish_brief`:

```powershell
            Write-Host '---'
            Write-Host $res.polish_brief
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
        }
```

- [ ] **Step 5: Wire fleet-go.ps1**

Dot-source (after `. (Join-Path $PSScriptRoot 'conductor-lib.ps1')`):

```powershell
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
```

The non-JSON report block currently ends with:

```powershell
    if ($result.status -like 'interrupted-*') {
        Write-Host "Paused at $($result.pending_task_id). Review, then resume to continue past this guard."
    }
}
```

Add the footer as the last statement inside the `else` (after the `interrupted-*` `if` block, before the closing `}`):

```powershell
    if ($result.status -like 'interrupted-*') {
        Write-Host "Paused at $($result.pending_task_id). Review, then resume to continue past this guard."
    }
    if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
}
```

- [ ] **Step 6: Wire fleet-optimize-prompt.ps1**

Dot-source: add after the script's existing lib dot-source lines (below `$ErrorActionPreference = 'Stop'`):

```powershell
try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }
```

Define the exclusion list once, right after that dot-source (all three rules suggest this very command):

```powershell
$coachExclude = @('gate-failure', 'promote-pending', 'pool-verdict')
```

Two insertion points, both non-JSON only, neither on an `exit 2` path:

1. **`-Pool` report path:** locate the non-JSON branch that prints the pool report (the `if ($Pool)` handling, where the report is written via `Write-Host` and the script returns/exits with success). As the last statement of that non-JSON success output, add:

```powershell
        if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds $coachExclude }
```

2. **Evolution success path:** the non-JSON `else` block ends with:

```powershell
    if ($res.success) {
        if ($res.applied) {
            ...
        } else {
            ...
            Write-Host "Re-run with -Apply to promote it to champion and deploy."
        }
    } else {
        [Console]::Error.WriteLine("Prompt evolution produced no deployable candidate: $($res.reason)")
        exit 2
    }
```

Add the footer as the last statement inside `if ($res.success) { ... }` (after the inner if/else, so it covers both applied and proposed):

```powershell
    if ($res.success) {
        if ($res.applied) {
            ...
        } else {
            ...
        }
        if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds $coachExclude }
    } else {
```

(The `...` above is the existing output code — do not change it; only append the footer line.)

- [ ] **Step 7: Run the footer tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-coach-footers.ps1`
Expected: `ALL PASS` (F1–F6), exit 0.

- [ ] **Step 8: Run the touched CLIs' regressions**

Run: `pwsh -NoProfile -File scripts/test-usage.ps1; pwsh -NoProfile -File scripts/test-gate-lib.ps1; pwsh -NoProfile -File scripts/test-conductor-lib.ps1; pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1`
Expected: all pass (footers are additive; libs untouched).

- [ ] **Step 9: Commit**

```bash
git add scripts/fleet-usage.ps1 scripts/fleet-gate.ps1 scripts/fleet-go.ps1 scripts/fleet-optimize-prompt.ps1 scripts/test-coach-footers.ps1
git commit -m "feat(coach): one-shot Next: footers on usage/gate/go/optimize-prompt human output (d074)"
```

---

### Task 4: Docs + version bump + full regression sweep

**Files:**
- Modify: `commands/go.md`, `commands/gate.md`, `commands/usage.md`, `commands/optimize-prompt.md`, `commands/start.md`
- Modify: `docs/COMMANDS.md`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: names/behavior fixed in Tasks 1–3 (`$BATON_HOME/coach/config.json` levels `off|quiet|teach` default `quiet`; digest; one-shot footers).
- Produces: docs only.

- [ ] **Step 1: Add the coach note to the four footer commands**

Append this exact paragraph to the END of each of `commands/go.md`, `commands/gate.md`, `commands/usage.md`, `commands/optimize-prompt.md`:

```markdown

## Coach footer

Non-JSON output may end with one `Next: <command>` line from the guided-use
coach — a read-only, zero-model-cost suggestion driven by local state (gate
verdicts, prompt-pool evidence, budget posture). Each suggestion appears once
per triggering state. Set the level in `$BATON_HOME/coach/config.json`
(`{"level":"off"|"quiet"|"teach"}`, default `quiet`; `teach` adds the why).
Relay the footer to the user verbatim when present.
```

- [ ] **Step 2: Add the session-start note to commands/start.md**

Append this exact paragraph to the END of `commands/start.md`:

```markdown

## Session-start coach digest

A SessionStart hook (`baton-coach.ps1`) prints a short orientation digest
before any command runs: registered projects get project/pool/budget status
plus one suggested next command; unregistered git repos get a one-shot
"Baton available — /baton:start to onboard" line. It is read-only and
zero-model-cost. The digest honors the same `$BATON_HOME/coach/config.json`
level as command footers (`off` silences it entirely).
```

- [ ] **Step 3: Add the Guided Use section to docs/COMMANDS.md**

Append this exact section at the END of `docs/COMMANDS.md`:

```markdown

## Guided use (the coach)

Baton suggests its own commands so features aren't hidden behind command
names (d074, v1.8.0). One rules engine (`scripts/coach-lib.ps1`), two
surfaces, zero model calls:

- **Session-start digest** — a SessionStart hook prints 3–5 orientation
  lines for registered projects (last-run status, prompt-pool state, budget
  posture, one suggested next command). Unregistered git repos get a single
  one-shot onboarding line; other directories get silence.
- **`Next:` footers** — `/baton:usage`, `/baton:gate`, `/baton:go`, and
  `/baton:optimize-prompt` end their human-readable output with at most one
  suggestion. Footers are one-shot per triggering state (stamps in
  `$BATON_HOME/coach/seen.json`) and never appear in `--json` output.

Rules (in priority order): last-run next step, gate `polish`/`reject` →
`/baton:optimize-prompt`, promote nudge pending → `--apply`, live A/B verdict
ready → `--pool`, budget at risk → `/baton:usage`, unregistered repo →
`/baton:start`.

Configure with `$BATON_HOME/coach/config.json`:
`{"level":"off"}` (silent), `"quiet"` (command only — default), or
`"teach"` (command + why). The coach is fail-open — it can never break a
session start or a command.
```

- [ ] **Step 4: Bump the plugin version**

In `.claude-plugin/plugin.json` change `"version": "1.7.1"` to `"version": "1.8.0-rc.1"`.

- [ ] **Step 5: Full regression sweep**

Run each; ALL must pass:

```
pwsh -NoProfile -File scripts/test-coach-lib.ps1
pwsh -NoProfile -File scripts/test-baton-coach-hook.ps1
pwsh -NoProfile -File scripts/test-coach-footers.ps1
pwsh -NoProfile -File scripts/test-baton-init-hook.ps1
pwsh -NoProfile -File scripts/test-start-lib.ps1
pwsh -NoProfile -File scripts/test-start-lib-s2.ps1
pwsh -NoProfile -File scripts/test-start-lib-s3.ps1
pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1
pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1
pwsh -NoProfile -File scripts/test-usage.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-gate-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
pwsh -NoProfile -File scripts/test-baton-home.ps1
```

- [ ] **Step 6: Commit**

```bash
git add commands/go.md commands/gate.md commands/usage.md commands/optimize-prompt.md commands/start.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "docs(coach): guided-use notes on commands + COMMANDS.md section; bump 1.8.0-rc.1"
```

---

## Execution handoff (Kevin's model ladder)

Subagent-driven, streamlined ceremony (implementers only; NO per-task reviewers; ONE opus final whole-branch review):

- Branch: `feature/guided-use-coach` off master.
- Task 1 → **haiku** (complete code above; transcription + test run).
- Task 2 → **haiku** (complete code above).
- Task 3 → **sonnet** (multi-file integration; two located insertion points in fleet-optimize-prompt).
- Task 4 → **haiku** (docs transcription + suite sweep).
- Final review → **opus**, whole branch, before PR. Merge is human-gated.
