# Fleet Labor Slice 2 — Agentic Executor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the empty `-Spawner` seam so `/baton:go -Execute` makes agentic instruments (codex, agy, claude-cli) actually edit a repo — inside a throwaway git worktree, proven by the diff growing, verified by the existing acceptance gate, left on a branch for the user to merge.

**Architecture:** One new library (`scripts/fleet-executor-lib.ps1`) owns the git primitives and the spawner factory. `Invoke-Conductor` gains one optional `-DiffProvider` scriptblock (post-walk cumulative diff → `changes.diff` → gate artifact; absent = byte-for-byte unchanged). `fleet-go.ps1` gains `-Execute`/`-RepoPath` wiring the two together. Edit-eligibility = new optional `agentic` fleet field, platform-inferred when absent.

**Tech Stack:** PowerShell 7, git plumbing (`worktree add`, `write-tree`, `diff`), existing Baton libs (`conductor-lib`, `fleet-lib`, `routing-lib`).

**Spec:** `docs/superpowers/specs/2026-07-05-fleet-labor-slice2-agentic-executor-design.md` (d078). Read it if a requirement here seems ambiguous — the spec governs.

## Global Constraints

- Every shell command arg stays **under 965 bytes** (silent failure above); large content via files/stdin.
- CLI errors: `[Console]::Error.WriteLine(...)` + `exit 2` — never `Write-Error` under `$ErrorActionPreference='Stop'`.
- All file writes `-Encoding utf8NoBOM`.
- `ConvertFrom-Json` auto-parses ISO dates to DateTime — re-stringify on round-trip.
- `ConvertTo-Json -InputObject @(...)` when an array must stay an array.
- Never name variables `$args`, `$input`, `$event`, `$matches`, `$host`, `$pid`.
- Unary-comma return wrap only for direct-assignment consumers; `@()` when callers pipe.
- Guard division: never allow 0/0.
- **Tests never touch** real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or the real `D:\dev` tree — temp dirs + `try/finally` restore, always.
- Box-private data (real rosters/endpoints/budgets) never in the repo — placeholder values only in `references/fleet.yaml`.
- When `-DiffProvider` is absent, `Invoke-Conductor` behavior is **byte-for-byte unchanged**. When `-Execute` is absent, `fleet-go.ps1` behavior is **unchanged**.
- The executor **never merges and never touches the user's checkout** — labor lands only in the throwaway worktree; the branch is kept for the human.
- Existing test seams (`BATON_GO_TEST_PLAN` / `BATON_GO_TEST_SPAWN` / `BATON_GO_TEST_GATE`) keep working.

## Execution model ladder (spec §11)

- Task 1 → **Haiku** (transcription: complete code below)
- Task 2 → **Sonnet** (routing filter + spawner closure judgment)
- Task 3 → **Sonnet** (engine seam, regression-sensitive)
- Task 4 → **Sonnet** (multi-file wiring + E2E test)
- Task 5 → **Haiku** (docs/deploy transcription)
- Final whole-branch review → **Opus**. Streamlined ceremony: no per-task reviewers.

---

### Task 1: `fleet-executor-lib.ps1` — git primitives + eligibility

**Files:**
- Create: `scripts/fleet-executor-lib.ps1`
- Create: `scripts/test-fleet-executor-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` (from `scripts/baton-home.ps1`); git CLI.
- Produces (later tasks rely on these exact names/shapes):
  - `New-RunWorktree -RepoPath <string> -RunId <string>` → `@{ worktree = <path>; branch = <string>; base_sha = <sha> }`, throws on failure.
  - `Get-RunDiff -Worktree <string> -BaseSha <string>` → `<string>` (cumulative unified diff incl. new/untracked files; `''` when unchanged or on git failure).
  - `Get-WorktreeTreeSha -Worktree <string>` → `<sha string>` of the current content tree (after `add -A`), `$null` on git failure.
  - `Test-ProviderAgentic -Provider <object>` → `[bool]`.
  - `Remove-RunWorktree -Worktree <string> -RepoPath <string> [-Force]` → removes the worktree dir, **keeps the branch**, throws on git failure.

- [ ] **Step 1: Write the library**

Create `scripts/fleet-executor-lib.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet Labor Slice 2 (d078): agentic-executor primitives. A throwaway git worktree
  receives the fleet's edits; proof that labor happened is the worktree's diff
  growing (proof-by-diff — no model prose is ever parsed). The run branch is always
  left for the human to merge; nothing here merges or touches the user's checkout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"     # Invoke-Fleet for the spawner dispatch
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability for the spawner routing

function New-RunWorktree {
    <# Throwaway worktree at <repo-parent>/.baton-worktrees/<run-id> on a new branch
       baton/run-<run-id> off the repo's current HEAD. Returns
       @{ worktree; branch; base_sha }. Throws with a clear message on any git
       failure — callers surface it and exit 2. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$RunId
    )
    & git -C $RepoPath rev-parse --git-dir 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "execute: '$RepoPath' is not a git repository" }
    $base = [string](& git -C $RepoPath rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "execute: '$RepoPath' has no commits (HEAD does not resolve)"
    }
    $base = $base.Trim()
    $resolvedRepo = (Resolve-Path -LiteralPath $RepoPath).Path
    $wtRoot = Join-Path (Split-Path $resolvedRepo -Parent) '.baton-worktrees'
    New-Item -ItemType Directory -Force -Path $wtRoot | Out-Null
    $wt = Join-Path $wtRoot $RunId
    $branch = "baton/run-$RunId"
    $out = & git -C $RepoPath worktree add -b $branch $wt HEAD 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree add failed: $(@($out) -join ' ')" }
    return @{ worktree = $wt; branch = $branch; base_sha = $base }
}

function Get-RunDiff {
    <# Cumulative unified diff of the worktree vs BaseSha, INCLUDING new/untracked
       files: everything is staged first (`add -A`) so `git diff <sha>` sees them —
       the worktree is throwaway, so staging is harmless (spec §7 mandates new files
       appear in changes.diff). Empty string when nothing changed or on git failure
       (fail-open: an unreadable diff means "no provable work", never a crash). #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$BaseSha
    )
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return '' }
    $out = & git -C $Worktree diff $BaseSha 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (@($out) -join "`n")
}

function Get-WorktreeTreeSha {
    <# SHA of the worktree's current content tree (index tree after `add -A`, via
       `git write-tree` — plumbing only, no commit is created). Two equal shas =
       the tree did not change between calls; this is the spawner's "diff grew"
       primitive, robust even when an instrument makes its own commits. $null on
       git failure. #>
    param([Parameter(Mandatory)][string]$Worktree)
    & git -C $Worktree add -A 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $sha = [string](& git -C $Worktree write-tree 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sha)) { return $null }
    return $sha.Trim()
}

function Test-ProviderAgentic {
    <# Edit-eligibility (d078, concept-anchored per d025): the optional `agentic`
       field is authoritative when present; absent, eligibility is inferred from
       platform ∈ {claude, codex, gemini}. Chat/local/github providers are filtered
       out of edit tasks (their diff-apply path is Slice 3). Accepts either a fleet
       provider hashtable or a Select-Capability candidate object. #>
    param([Parameter(Mandatory)]$Provider)
    if ($null -ne $Provider.agentic) { return [bool]$Provider.agentic }
    return (([string]$Provider.platform) -in @('claude', 'codex', 'gemini'))
}

function Remove-RunWorktree {
    <# Explicit discard of the worktree DIRECTORY only. The run branch is
       intentionally KEPT so the human can still inspect or merge the work.
       Throws on git failure. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RepoPath,
        [switch]$Force
    )
    $extra = @(); if ($Force) { $extra += '--force' }
    $out = & git -C $RepoPath worktree remove @extra $Worktree 2>&1
    if ($LASTEXITCODE -ne 0) { throw "execute: git worktree remove failed: $(@($out) -join ' ')" }
}
```

- [ ] **Step 2: Write the failing tests**

Create `scripts/test-fleet-executor-lib.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-TempRepo {
    param([string]$Root)
    $p = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q
    & git -C $p config user.email 'test@test.local'
    & git -C $p config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $p 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m 'init' 2>$null | Out-Null
    return $p
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exec-lib-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
try {
    $repo = New-TempRepo -Root $tmpRoot

    # ---- New-RunWorktree ----
    $wt = New-RunWorktree -RepoPath $repo -RunId 'go-t1'
    Check 'W1 worktree dir exists' (Test-Path $wt.worktree)
    Check 'W2 worktree lives under sibling .baton-worktrees' ($wt.worktree -like (Join-Path $tmpRoot '.baton-worktrees\*'))
    Check 'W3 branch named baton/run-<id>' ($wt.branch -eq 'baton/run-go-t1')
    Check 'W4 base_sha is repo HEAD' ($wt.base_sha -eq ([string](& git -C $repo rev-parse HEAD)).Trim())
    Check 'W5 worktree checked out on the run branch' ((([string](& git -C $wt.worktree branch --show-current)).Trim()) -eq 'baton/run-go-t1')

    $notRepo = Join-Path $tmpRoot 'plain'; New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $threw = $false; try { New-RunWorktree -RepoPath $notRepo -RunId 'x' | Out-Null } catch { $threw = $true }
    Check 'W6 non-repo throws' $threw

    # ---- Get-RunDiff ----
    Check 'D1 fresh worktree diff is empty' ((Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha) -eq '')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'a.txt') -Value 'changed' -Encoding utf8NoBOM
    $d1 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D2 edited file appears in diff' ($d1 -match 'changed')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'brand-new.txt') -Value 'i am new' -Encoding utf8NoBOM
    $d2 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D3 NEW (untracked) file captured in diff' ($d2 -match 'brand-new\.txt')
    Check 'D4 diff grew with the new file' ($d2.Length -gt $d1.Length)
    Check 'D5 user repo tree untouched by worktree edits' (-not (Test-Path (Join-Path $repo 'brand-new.txt')))

    # ---- Get-WorktreeTreeSha ----
    $t1 = Get-WorktreeTreeSha -Worktree $wt.worktree
    $t2 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S1 stable tree sha when nothing changes' (($null -ne $t1) -and ($t1 -eq $t2))
    Set-Content -LiteralPath (Join-Path $wt.worktree 'another.txt') -Value 'x' -Encoding utf8NoBOM
    $t3 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S2 tree sha changes when a file lands' ($t3 -ne $t1)
    Check 'S3 non-repo path -> $null' ($null -eq (Get-WorktreeTreeSha -Worktree $notRepo))

    # ---- Test-ProviderAgentic ----
    Check 'A1 agentic:true is authoritative' (Test-ProviderAgentic -Provider @{ agentic = $true; platform = 'local' })
    Check 'A2 agentic:false is authoritative' (-not (Test-ProviderAgentic -Provider @{ agentic = $false; platform = 'codex' }))
    Check 'A3 platform codex inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'codex' })
    Check 'A4 platform claude inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'claude' })
    Check 'A5 platform gemini inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'gemini' })
    Check 'A6 platform local not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'local' }))
    Check 'A7 platform github not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'github' }))
    Check 'A8 no platform, no marker -> not agentic' (-not (Test-ProviderAgentic -Provider @{ name = 'mystery' }))

    # ---- Remove-RunWorktree ----
    Remove-RunWorktree -Worktree $wt.worktree -RepoPath $repo -Force
    Check 'R1 worktree dir removed' (-not (Test-Path $wt.worktree))
    $branches = [string](& git -C $repo branch --list 'baton/run-go-t1')
    Check 'R2 run branch KEPT after removal' ($branches -match 'baton/run-go-t1')
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
```

- [ ] **Step 3: Run the tests**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`
Expected: `ALL PASS` (write the lib first per Step 1; if you wrote tests first, expected FAIL with "function not recognized", then pass after Step 1).

- [ ] **Step 4: Commit**

```bash
git add scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1
git commit -m "feat(executor): fleet-executor-lib git primitives + edit-eligibility (d078 Task 1)"
```

---

### Task 2: routing passthrough + `New-AgenticSpawner`

**Files:**
- Modify: `scripts/routing-lib.ps1:163` (one-field passthrough in the fleet-candidate projection)
- Modify: `scripts/fleet-executor-lib.ps1` (append `New-AgenticSpawner`)
- Modify: `scripts/test-fleet-executor-lib.ps1` (append spawner tests)

**Interfaces:**
- Consumes: `Select-Capability -Capability -MaxCostTier -FleetPath -ToolsPath` → ranked candidate objects (each has `.name`, `.platform`, and — after this task — `.agentic`); `Invoke-Fleet -Name -Prompt -Path -NoJournal` → `@{ stdout; stderr; exit_code; duration_s }`; Task 1's `Test-ProviderAgentic`, `Get-WorktreeTreeSha`.
- Produces: `New-AgenticSpawner -Worktree <string> [-FleetPath] [-ToolsPath] [-MaxCostTier] [-RunDir] [-Dispatcher <scriptblock>]` → **scriptblock** matching the `-Spawner` contract: `param($task)` → `@{ ok; spend; chose; why; alternatives }`. The optional `-Dispatcher` receives `($pick, $prompt)` and returns the `Invoke-Fleet` result shape (test seam).

- [ ] **Step 1: Add the `agentic` passthrough in `Select-Capability`**

In `scripts/routing-lib.ps1`, in the **fleet**-candidate projection (the `[pscustomobject]@{ ... }` around line 159–167), change the line:

```powershell
                role = $p.role; platform = $p.platform
```

to:

```powershell
                role = $p.role; platform = $p.platform
                agentic = $p.agentic   # Slice 2 (d078) edit-eligibility passthrough (null when absent)
```

Do NOT touch the tools projection (tools carry no `agentic`; `Test-ProviderAgentic` returns `$false` for them via the platform fallback).

- [ ] **Step 2: Append `New-AgenticSpawner` to `scripts/fleet-executor-lib.ps1`**

```powershell
function New-AgenticSpawner {
    <# Factory: returns a scriptblock matching Invoke-Conductor's -Spawner contract
       (param($task) -> @{ ok; spend; chose; why; alternatives }). Per task: route the
       capability, FILTER to edit-eligible providers, dispatch with cwd = the worktree
       (Push-Location/Pop-Location around the call), and prove labor by the worktree
       content tree changing (proof-by-diff, d078). Precedence: nonzero exit -> fail;
       tree changed -> ok; exit 0 + no change -> ok with why 'no changes'.
       -Dispatcher injects a fake instrument for hermetic tests. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$RunDir,
        [scriptblock]$Dispatcher
    )
    return {
        param($task)
        $cap = if ($task.capability) { $task.capability } else { 'reasoning' }
        $cands = @(Select-Capability -Capability $cap -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath |
                   Where-Object { ($null -ne $_) -and (Test-ProviderAgentic -Provider $_) })
        if ($cands.Count -lt 1) {
            return @{ ok = $false; spend = 0.0; chose = ''; why = "no edit-capable candidate for '$cap'"; alternatives = @() }
        }
        $pick = $cands[0]
        $alts = @($cands | Select-Object -Skip 1 | ForEach-Object { $_.name })
        $prompt = "Task: $($task.desc)"
        $preTree = Get-WorktreeTreeSha -Worktree $Worktree
        Push-Location -LiteralPath $Worktree
        try {
            $res = if ($Dispatcher) { & $Dispatcher $pick $prompt }
                   else { Invoke-Fleet -Name $pick.name -Prompt $prompt -Path $FleetPath -NoJournal }
        } finally { Pop-Location }
        $postTree = Get-WorktreeTreeSha -Worktree $Worktree
        $grew = ($null -ne $preTree) -and ($null -ne $postTree) -and ($preTree -ne $postTree)
        # Best-effort per-task incremental diff for the report; never fails the task.
        if ($RunDir -and $grew) {
            try {
                $tasksDir = Join-Path $RunDir 'tasks'
                New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
                $taskDiff = @(& git -C $Worktree diff $preTree $postTree 2>$null) -join "`n"
                Set-Content -LiteralPath (Join-Path $tasksDir "$($task.id).diff") -Value $taskDiff -Encoding utf8NoBOM
            } catch { }
        }
        if ([int]$res.exit_code -ne 0) {
            return @{ ok = $false; spend = 0.0; chose = $pick.name; why = "$($pick.name): exit $($res.exit_code)"; alternatives = $alts }
        }
        if ($grew) {
            return @{ ok = $true; spend = 0.0; chose = $pick.name; why = "routed $cap -> $($pick.name); worktree diff grew"; alternatives = $alts }
        }
        return @{ ok = $true; spend = 0.0; chose = $pick.name; why = "$($pick.name): no changes"; alternatives = $alts }
    }.GetNewClosure()
}
```

- [ ] **Step 3: Append spawner tests to `scripts/test-fleet-executor-lib.ps1`**

Insert the following block **inside the existing `try {}`**, after the `Remove-RunWorktree` checks (`R1`/`R2`) and before the `finally`:

```powershell
    # ---- New-AgenticSpawner (hermetic: fake dispatcher, temp fleet.yaml, temp BATON_HOME) ----
    $savedBatonHome = $env:BATON_HOME
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    try {
        $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'
        Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
'@
        $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'   # intentionally absent file
        $repo2 = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'sp')).FullName
        $wt2 = New-RunWorktree -RepoPath $repo2 -RunId 'go-sp1'
        $runDir2 = Join-Path $tmpRoot 'run-sp1'
        New-Item -ItemType Directory -Force -Path $runDir2 | Out-Null
        $task = [pscustomobject]@{ id = 't1'; desc = 'write the feature'; capability = 'code-gen' }

        # dispatcher that EDITS (writes into its cwd — must be the worktree)
        $editDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'made-by-instrument.txt') -Value 'work' -Encoding utf8NoBOM
            return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $cwdBefore = (Get-Location).Path
        $sp = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -MaxCostTier 'paid' -RunDir $runDir2 -Dispatcher $editDisp
        $r = & $sp $task
        Check 'P1 edit task ok' ($r.ok -eq $true)
        Check 'P2 picked the agentic provider (local filtered out)' ($r.chose -eq 'fake-agentic')
        Check 'P3 why records diff grew' ($r.why -match 'diff grew')
        Check 'P4 edit landed IN the worktree' (Test-Path (Join-Path $wt2.worktree 'made-by-instrument.txt'))
        Check 'P5 user repo untouched' (-not (Test-Path (Join-Path $repo2 'made-by-instrument.txt')))
        Check 'P6 caller cwd untouched' ((Get-Location).Path -eq $cwdBefore)
        Check 'P7 per-task diff written' (Test-Path (Join-Path $runDir2 'tasks/t1.diff'))
        Check 'P8 per-task diff names the new file' ((Get-Content -Raw (Join-Path $runDir2 'tasks/t1.diff')) -match 'made-by-instrument\.txt')

        # dispatcher that does NOTHING, exit 0
        $noopDisp = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $sp2 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r2 = & $sp2 $task
        Check 'P9 no-op exit 0 is ok' ($r2.ok -eq $true)
        Check 'P10 no-op why says no changes' ($r2.why -match 'no changes')

        # dispatcher that FAILS (exit 1)
        $failDisp = { param($pick, $prompt) @{ stdout = ''; stderr = 'boom'; exit_code = 1; duration_s = 0 } }
        $sp3 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $failDisp
        $r3 = & $sp3 $task
        Check 'P11 nonzero exit is NOT ok' ($r3.ok -eq $false)
        Check 'P12 failure why names provider + exit' ($r3.why -match 'fake-agentic.*exit 1')

        # fleet with ONLY non-agentic providers -> no edit-capable candidate
        $fleetLocalOnly = Join-Path $env:BATON_HOME 'fleet-local-only.yaml'
        Set-Content -LiteralPath $fleetLocalOnly -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
'@
        $sp4 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetLocalOnly -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r4 = & $sp4 $task
        Check 'P13 local-only fleet -> not ok' ($r4.ok -eq $false)
        Check 'P14 message names the capability' ($r4.why -match "no edit-capable candidate for 'code-gen'")

        # agentic: true override on a local entry -> eligible
        $fleetOverride = Join-Path $env:BATON_HOME 'fleet-override.yaml'
        Set-Content -LiteralPath $fleetOverride -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local-agentic
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    agentic: true
    command_template: 'echo "{{prompt}}"'
'@
        $sp5 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetOverride -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r5 = & $sp5 $task
        Check 'P15 agentic:true override makes a local entry eligible' ($r5.chose -eq 'fake-local-agentic')
    } finally {
        if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
        else { $env:BATON_HOME = $savedBatonHome }
    }
```

- [ ] **Step 4: Run the tests**

Run: `pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1`
Expected: `ALL PASS` (W*, D*, S*, A*, R*, P1–P15).

Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1` (routing regression after the passthrough)
Expected: all existing checks PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/fleet-executor-lib.ps1 scripts/test-fleet-executor-lib.ps1
git commit -m "feat(executor): New-AgenticSpawner + agentic candidate passthrough (d078 Task 2)"
```

---

### Task 3: `Invoke-Conductor -DiffProvider` seam

**Files:**
- Modify: `scripts/conductor-lib.ps1:495` (param list) and `scripts/conductor-lib.ps1:555-574` (acceptance phase)
- Modify: `scripts/test-conductor-lib.ps1` (append seam tests)

**Interfaces:**
- Consumes: existing `Resolve-GateArtifact`, `Add-RunEvent`, `New-RunEvent`, `Invoke-AcceptanceGate`.
- Produces: `Invoke-Conductor ... [-DiffProvider <scriptblock>]`. Contract: invoked **post-walk with no arguments**, returns the cumulative diff `<string>`. Non-empty → written to `<run-dir>/changes.diff` (utf8NoBOM) and used as the gate artifact **text**. Empty/throwing/absent → existing `-GateArtifact`/`-GateDiff` resolution applies unchanged (throw is fail-open with a warn event).

- [ ] **Step 1: Add the parameter**

In `scripts/conductor-lib.ps1`, in `Invoke-Conductor`'s `param(...)` block, change:

```powershell
        [scriptblock]$Gater
```

to:

```powershell
        [scriptblock]$Gater,
        [scriptblock]$DiffProvider
```

- [ ] **Step 2: Wire the seam into the acceptance phase**

Still in `Invoke-Conductor`, replace this exact line (start of step 4, after the walk loop):

```powershell
    $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
```

with:

```powershell
    # Slice 2 (d078): a -DiffProvider produces the walk's cumulative diff post-walk;
    # non-empty -> recorded to changes.diff and gated as the artifact. Absent, empty,
    # or throwing (fail-open) -> the existing -GateArtifact/-GateDiff path unchanged.
    $art = ''
    if ($DiffProvider) {
        $produced = ''
        try { $produced = [string](& $DiffProvider) }
        catch { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message "diff provider failed (fail-open): $($_.Exception.Message)") }
        if (-not [string]::IsNullOrWhiteSpace($produced)) {
            Set-Content -LiteralPath (Join-Path $RunDir 'changes.diff') -Value $produced -Encoding utf8NoBOM
            $art = $produced
        }
    }
    if ([string]::IsNullOrWhiteSpace($art)) { $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff }
```

No other line in the function changes.

- [ ] **Step 3: Append seam tests to `scripts/test-conductor-lib.ps1`**

Insert inside the existing `try {}`, after the last existing check block (keep the file's `Check` style):

```powershell
    # ---- Slice 2 (d078): -DiffProvider seam ----
    $tmpDp = Join-Path ([System.IO.Path]::GetTempPath()) "cond-dp-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDp | Out-Null
    try {
        $dpPlanner = { param($g) @{ run_id='go-dp'; goal=$g; budget_cap=$null; tasks=@([pscustomobject]@{ id='t1'; desc='d'; command=''; capability='code-gen'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true }) } }
        $dpSpawn = { param($t) @{ ok=$true; spend=0.0; chose='stub'; why='w'; alternatives=@() } }
        $dpGater = { param($gArt, $gGoal) @{ verdict='accept'; reason="saw:$gArt"; counts=@{critical=0;important=0;minor=0}; polish_brief=''; findings=@(); reviews=@(); unparsed=@() } }

        $runDp1 = Initialize-RunDir -RunId 'go-dp-1' -Root $tmpDp
        $dp1 = { "diff --git a/x b/x`n+produced-by-walk" }
        $rDp1 = Invoke-Conductor -Goal 'g' -RunDir $runDp1 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider $dp1
        Check 'DP1 changes.diff written' (Test-Path (Join-Path $runDp1 'changes.diff'))
        Check 'DP2 gate received the produced diff' ($rDp1.acceptance.reason -match 'produced-by-walk')
        Check 'DP3 run completed with accept' ($rDp1.status -eq 'completed')

        $runDp2 = Initialize-RunDir -RunId 'go-dp-2' -Root $tmpDp
        $rDp2 = Invoke-Conductor -Goal 'g' -RunDir $runDp2 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { '' }
        Check 'DP4 empty diff -> no changes.diff' (-not (Test-Path (Join-Path $runDp2 'changes.diff')))
        Check 'DP5 empty diff + no gate target -> no acceptance section' ($null -eq $rDp2.acceptance)

        $runDp3 = Initialize-RunDir -RunId 'go-dp-3' -Root $tmpDp
        $rDp3 = Invoke-Conductor -Goal 'g' -RunDir $runDp3 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { '' } -GateArtifact 'fallback-artifact'
        Check 'DP6 empty produced diff falls back to -GateArtifact' ($rDp3.acceptance.reason -match 'fallback-artifact')

        $runDp4 = Initialize-RunDir -RunId 'go-dp-4' -Root $tmpDp
        $rDp4 = Invoke-Conductor -Goal 'g' -RunDir $runDp4 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { throw 'boom' }
        Check 'DP7 throwing diff provider is fail-open (run completes)' ($rDp4.status -eq 'completed')
        Check 'DP8 fail-open logged a gate warn event' ((Get-Content -Raw (Join-Path $runDp4 'events.jsonl')) -match 'diff provider failed')
    } finally {
        Remove-Item -Recurse -Force $tmpDp -ErrorAction SilentlyContinue
    }
```

- [ ] **Step 4: Run the tests (seam + full regression)**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: all existing checks still PASS (the absent-`-DiffProvider` regression — every pre-existing test exercises that path) plus DP1–DP8 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): -DiffProvider post-walk seam feeds the acceptance gate (d078 Task 3)"
```

---

### Task 4: `fleet-go.ps1 -Execute` mode + hermetic E2E

**Files:**
- Modify: `scripts/fleet-go.ps1` (params, execute wiring, report render)
- Create: `scripts/test-fleet-go-execute.ps1`

**Interfaces:**
- Consumes: Task 1's `New-RunWorktree`/`Get-RunDiff`, Task 2's `New-AgenticSpawner`, Task 3's `-DiffProvider`.
- Produces: `fleet-go.ps1 -Execute [-RepoPath <path>]`; new test env seam `BATON_GO_TEST_EXEC_DISPATCHER` = path to a `.ps1` that, when dot-sourced, defines `Invoke-TestExecDispatcher -Pick -Prompt` returning the `Invoke-Fleet` result shape. Result JSON gains `branch`, `worktree`, `files_changed` when `-Execute` ran.

- [ ] **Step 1: Add the parameters**

In `scripts/fleet-go.ps1`'s `param(...)`, after `[string]$Project,` add:

```powershell
    [switch]$Execute,
    [string]$RepoPath,
```

- [ ] **Step 2: Wire the execute mode**

Insert this block immediately **after** the `BATON_GO_TEST_GATE` seam block (after the line `if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }` and its closing `}`), and **before** the `if ($targetFolder) { Push-Location ... }` line:

```powershell
# Execute mode (Slice 2, d078): agentic labor into a throwaway worktree. The
# spawner routes each task to an edit-eligible instrument running with cwd =
# the worktree; the DiffProvider feeds the produced diff to the acceptance
# gate. -Execute owns the spawner: it overrides the BATON_GO_TEST_SPAWN stub
# when both are set. The run branch is ALWAYS left for the human to merge.
$wt = $null
if ($Execute) {
    . (Join-Path $PSScriptRoot 'fleet-executor-lib.ps1')
    $repo = if ($PSBoundParameters.ContainsKey('RepoPath') -and $RepoPath) { $RepoPath }
            elseif ($targetFolder) { $targetFolder }
            else { (Get-Location).Path }
    try { $wt = New-RunWorktree -RepoPath $repo -RunId (Split-Path $runDir -Leaf) }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
    $spawnArgs = @{ Worktree = $wt.worktree; FleetPath = $FleetPath; ToolsPath = $ToolsPath; MaxCostTier = $MaxCostTier; RunDir = $runDir }
    if ($env:BATON_GO_TEST_EXEC_DISPATCHER) {
        # Hermetic seam: dot-source a file defining Invoke-TestExecDispatcher.
        . $env:BATON_GO_TEST_EXEC_DISPATCHER
        $spawnArgs.Dispatcher = { param($pick, $prompt) Invoke-TestExecDispatcher -Pick $pick -Prompt $prompt }
    }
    $go['Spawner'] = New-AgenticSpawner @spawnArgs
    $go['DiffProvider'] = { Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha }.GetNewClosure()
}
```

- [ ] **Step 3: Surface the branch in the result**

Immediately **after** the `try { $result = Invoke-Conductor @go } finally { ... }` block and **before** `if ($Json) {`, insert:

```powershell
if ($Execute -and $wt) {
    $result.branch = $wt.branch
    $result.worktree = $wt.worktree
    $changed = @(& git -C $wt.worktree diff --name-only $wt.base_sha 2>$null)
    $result.files_changed = @($changed | Where-Object { $_ }).Count
}
```

And inside the non-JSON render (the `else` branch), after the `Write-Host "Status: ..."` line, insert:

```powershell
    if ($Execute -and $wt) {
        Write-Host "$($result.files_changed) file(s) changed on branch $($result.branch) (worktree: $($result.worktree)) — review and merge when ready; Baton never merges for you."
    }
```

- [ ] **Step 4: Write the hermetic E2E test**

Create `scripts/test-fleet-go-execute.ps1` with exactly this content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "go-exec-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$saved = @{}
foreach ($k in 'BATON_HOME','BATON_GO_TEST_PLAN','BATON_GO_TEST_GATE','BATON_GO_TEST_SPAWN','BATON_GO_TEST_EXEC_DISPATCHER') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
try {
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $env:BATON_GO_TEST_SPAWN = $null

    # target repo
    $repo = Join-Path $tmpRoot 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'test@test.local'
    & git -C $repo config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m 'init' 2>$null | Out-Null

    # temp fleet with one fake agentic provider
    Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
'@

    # canned single-task plan + canned gate verdict
    $env:BATON_GO_TEST_PLAN = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_GATE = 'accept'

    # fake instrument: writes a file into its cwd (must be the worktree)
    $dispFile = Join-Path $tmpRoot 'disp.ps1'
    Set-Content -LiteralPath $dispFile -Encoding utf8NoBOM -Value @'
function Invoke-TestExecDispatcher {
    param($Pick, $Prompt)
    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'feature.txt') -Value 'made by instrument' -Encoding utf8NoBOM
    return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
}
'@
    $env:BATON_GO_TEST_EXEC_DISPATCHER = $dispFile

    # ---- happy path ----
    $raw = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $res = $raw | ConvertFrom-Json
    Check 'E1 run completed' ($res.status -eq 'completed')
    Check 'E2 result names a baton/run- branch' ($res.branch -like 'baton/run-*')
    Check 'E3 files_changed counted' ([int]$res.files_changed -ge 1)
    Check 'E4 changes.diff exists in run dir' (Test-Path (Join-Path $res.run_dir 'changes.diff'))
    Check 'E5 changes.diff carries the NEW file' ((Get-Content -Raw (Join-Path $res.run_dir 'changes.diff')) -match 'feature\.txt')
    Check 'E6 acceptance verdict landed' ($res.acceptance.verdict -eq 'accept')
    Check 'E7 user repo tree untouched' (-not (Test-Path (Join-Path $repo 'feature.txt')))
    Check 'E8 worktree has the instrument edit' (Test-Path (Join-Path ([string]$res.worktree) 'feature.txt'))
    $branches = [string](& git -C $repo branch --list 'baton/run-*')
    Check 'E9 run branch exists in the target repo' ($branches -match 'baton/run-')

    # ---- non-repo -> exit 2, no partial state ----
    $plain = Join-Path $tmpRoot 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $plain -Json 2>$null | Out-Null
    Check 'E10 non-repo exits 2' ($LASTEXITCODE -eq 2)

    # ---- without -Execute the run is unchanged (route-and-discard; no worktree) ----
    $env:BATON_GO_TEST_SPAWN = '1'
    $raw2 = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Json | Out-String
    $res2 = $raw2 | ConvertFrom-Json
    Check 'E11 non-execute run still completes' ($res2.status -eq 'completed')
    Check 'E12 non-execute result has no branch key' ($null -eq $res2.PSObject.Properties['branch'])
} finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
```

- [ ] **Step 5: Run the tests**

Run: `pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1`
Expected: `ALL PASS` (E1–E12).

Run: `pwsh -NoProfile -File scripts/test-fleet-go-retarget.ps1` (retarget regression — `-Execute` must not disturb `-Project`)
Expected: all existing checks PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-go.ps1 scripts/test-fleet-go-execute.ps1
git commit -m "feat(go): -Execute mode — agentic labor into a run worktree (d078 Task 4)"
```

---

### Task 5: deployment, docs, version bump

**Files:**
- Modify: `scripts/bootstrap.ps1:259` (deploy manifest)
- Modify: `scripts/test-bootstrap.ps1` (deploy assert, after the `fleet-probe-lib` assert at line 64)
- Modify: `commands/go.md` (document `--execute` / `--repo`)
- Modify: `AGENTS.md` (one line, after the `fleet doctor --live` line ~36)
- Modify: `references/fleet.yaml` (document the `agentic` field)
- Modify: `.claude-plugin/plugin.json` (version `1.10.0` → `1.11.0-rc.1`)

**Interfaces:** none produced; consumes the names shipped in Tasks 1–4.

- [ ] **Step 1: Bootstrap manifest + deploy assert**

In `scripts/bootstrap.ps1` line 259, inside the `foreach ($script in @(...))` array, append `'fleet-executor-lib.ps1'` after `'fleet-probe-lib.ps1'` (comma-separated, same quoting style).

In `scripts/test-bootstrap.ps1`, after the line asserting `fleet-probe-lib\.ps1` (line 64), add:

```powershell
Assert "deploys fleet-executor-lib script (agentic -Execute labor needs it on-box)" ($out -match 'fleet-executor-lib\.ps1')
```

- [ ] **Step 2: Run the bootstrap test**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all asserts PASS including the new one (the manifest edit in Step 1 is what makes it pass).

- [ ] **Step 3: `commands/go.md`**

Three edits:

1. In the frontmatter `argument-hint`, change:
```
argument-hint: "<what you want done>" [--budget <n>] [--max-tier local|free|paid] [--gate-artifact <text> | --gate-diff <range>]
```
to:
```
argument-hint: "<what you want done>" [--execute] [--repo <path>] [--budget <n>] [--max-tier local|free|paid] [--gate-artifact <text> | --gate-diff <range>]
```

2. In the Step 2 code block, after the `-GateArtifact`/`-GateDiff` comment line, add:
```
   # add -Execute (and optionally -RepoPath "<path>") when the user wants the fleet to
   # actually DO the work: agentic instruments edit an isolated worktree, the produced
   # diff is acceptance-gated, and the changes land on branch baton/run-<id>
```

3. Replace the first bullet under `## Notes`:
```
- The Conductor never touches the user's checkout directly: real code/merge execution
  rides the existing gated-merge flow (per-item branches → PR). The engine itself only
  plans, routes, and logs.
```
with:
```
- The Conductor never touches the user's checkout directly. Without `--execute` the
  engine only plans, routes, and logs. With `--execute`, agentic instruments (codex,
  agy, claude-cli — `agentic`/platform-eligible providers) edit a throwaway worktree
  at `<repo-parent>/.baton-worktrees/<run-id>` on branch `baton/run-<run-id>`; the
  cumulative diff is written to `<run-dir>/changes.diff` and acceptance-gated. The
  branch is ALWAYS left for the user to review and merge — Baton never merges.
```

- [ ] **Step 4: `AGENTS.md` + `references/fleet.yaml`**

In `AGENTS.md`, after the `fleet doctor --live` bullet (~line 36), add:

```
- `/baton:go --execute` — agentic labor lands in an isolated worktree (branch `baton/run-<id>`, proof-by-diff, acceptance-gated); the branch is always left for the human to merge.
```

In `references/fleet.yaml`, in the header field-doc comment block, after the `usage_class` lines (~line 48), add:

```
#   agentic           (optional) true | false — edit-eligibility for /baton:go --execute
#                     (agentic labor into a run worktree). Authoritative when present;
#                     absent -> inferred from platform ∈ {claude, codex, gemini}.
#                     Non-agentic providers are filtered out of edit tasks (their
#                     diff-apply path arrives in Slice 3).
```

- [ ] **Step 5: Plugin version bump**

In `.claude-plugin/plugin.json`, change `"version": "1.10.0"` to `"version": "1.11.0-rc.1"` (promoted to `1.11.0` at release, per the Slice 1 pattern).

- [ ] **Step 6: Full regression sweep + commit**

Run (each must pass):
```
pwsh -NoProfile -File scripts/test-fleet-executor-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-go-execute.ps1
pwsh -NoProfile -File scripts/test-fleet-go-retarget.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
pwsh -NoProfile -File scripts/test-fleet-lib.ps1
```
Expected: every suite green.

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/go.md AGENTS.md references/fleet.yaml .claude-plugin/plugin.json
git commit -m "build(executor): deploy manifest + docs + plugin 1.11.0-rc.1 (d078 Task 5)"
```

---

## Post-plan notes (controller, not implementer)

- **Final review:** one Opus whole-branch review (streamlined ceremony) via superpowers:requesting-code-review's template, then the gated PR flow. **Never merge without Kevin's word.**
- **Box-private manual smoke** (post-merge, like Slice 1's `--live`): a real codex or agy round-trip against a scratch repo, documented in the release notes — NOT in the suite.
- The spec's `New-AgenticSpawner -BaseSha` is intentionally absent: the tree-sha primitive (`git write-tree`) proves per-task growth without needing the base, and stays correct even when an instrument makes its own commits. The DiffProvider still uses `base_sha` for the cumulative diff. (Spec §4.1's signature listed only `-Worktree -FleetPath [-MaxCostTier] [-Dispatcher]`; this matches.)
