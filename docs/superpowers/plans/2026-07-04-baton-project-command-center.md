# Baton Project Command Center (Layer 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Baton the single front door for every project under a `D:\dev` home base — name a project (`/baton:go --whimsicalcarving <goal>`), it resolves the name to that project's folder and runs the existing Conductor there, with a live active/inactive/archived roster and per-project resume.

**Architecture:** A neutral core (two new PowerShell libs) over box-private `$BATON_HOME`, plus thin per-harness adapters. `session-markers-lib.ps1` owns a harness-neutral session-marker contract (active-detection). `registry-lib.ps1` scans `D:\dev`, folds the scan over `start-lib`'s existing per-project `project.json` records, and resolves a project name → folder. Two Claude-adapter hooks write/clear markers and capture the resume pointer. `fleet-go.ps1` gains `--project`/`--slug` retargeting. A new `/baton:project` surface administers the registry.

**Tech Stack:** PowerShell 7, box-private JSON under `$BATON_HOME`, Claude Code hooks (SessionStart/SessionEnd), the existing `start-lib.ps1` project-record store and `conductor-lib.ps1` engine.

## Global Constraints

- Box-private data (`$BATON_HOME`) — registry records, session markers, resume pointers — NEVER the repo or shared seeds; placeholder paths only in examples.
- Every shell command arg < 965 bytes; use files for anything larger.
- CLI user-errors: `[Console]::Error.WriteLine(...)` + `exit 2` — NEVER `Write-Error` under `$ErrorActionPreference='Stop'`. **Hooks ALWAYS `exit 0`.**
- All writes `utf8NoBOM`.
- `ConvertFrom-Json` auto-parses ISO-8601 strings to `[datetime]`; re-stringify (`'o'` or explicit format) on any round-trip write.
- `ConvertTo-Json` needs `-InputObject @(...)` for a guaranteed JSON array (a piped single element unrolls).
- Never name a variable `$args`, `$input`, `$event`, `$matches`, `$host`, or `$pid`.
- Unary-comma return wrap `,([object[]]$x)` is for DIRECT-ASSIGNMENT consumers only; use `@($x)` when callers pipe or inside hashtable literals; guard the EMPTY case before a comma-return.
- Guard `0/0` NaN denominators in any age/TTL math.
- Tests are HERMETIC: temp `$BATON_HOME` AND a temp home-base root, `try/finally` restore of every env var, and NEVER touch real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or the real `D:\dev`.
- The project id derivation MUST match `coach-lib.ps1`'s `Get-CoachProjectId` (git-remote repo name slug, else folder-name slug) so registry records line up with what `/baton:start` and the coach already write.
- Codex adapter implementation is OUT of scope (the marker/resume contract is defined; only the Claude adapter ships). Layer 2 (dashboard) is a separate future spec.

**Spec:** `docs/superpowers/specs/2026-07-04-baton-project-command-center-design.md` (d076).

---

### Task 1: Session-marker contract (`session-markers-lib.ps1`)

The neutral active-detection substrate: any harness writes the same marker shape; the registry reads it. Pure/seamed, zero harness dependency.

**Files:**
- Create: `scripts/session-markers-lib.ps1`
- Test: `scripts/test-session-markers-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` from `scripts/baton-home.ps1`.
- Produces:
  - `Get-SessionsDir([string]$BatonHome) -> string` (path `$BatonHome/sessions`)
  - `Write-SessionMarker([string]$Agent, [string]$SessionId, [string]$Cwd, [string]$BatonHome) -> void` (writes `<sessions>/<sanitized-id>.json` = `{agent,session_id,cwd,started_at}`)
  - `Clear-SessionMarker([string]$SessionId, [string]$BatonHome) -> hashtable|$null` (removes the marker file, returns the parsed record it removed, or `$null`)
  - `Get-ActiveSessions([int]$TtlHours=24, [string]$BatonHome) -> object[]` (marker records with `started_at` within TTL; read-only; fail-open to `@()`)
  - `Test-FolderActive([string]$Folder, [object[]]$Sessions) -> bool` (case-insensitive full-path match of `$Folder` against any session `cwd`)

- [ ] **Step 1: Write the failing test**

```powershell
# scripts/test-session-markers-lib.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/session-markers-lib.ps1"

$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" }
    else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("bmk-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # write → read back active
    Write-SessionMarker -Agent 'claude' -SessionId 'sess-1' -Cwd 'D:\dev\Whittle' -BatonHome $tmp
    $act = @(Get-ActiveSessions -BatonHome $tmp)
    Assert 'M1 one active marker after write' (@($act).Count -eq 1)
    Assert 'M2 marker carries agent+cwd' ($act[0].agent -eq 'claude' -and $act[0].cwd -eq 'D:\dev\Whittle')
    Assert 'M3 Test-FolderActive matches case-insensitively' (Test-FolderActive -Folder 'd:\dev\whittle' -Sessions $act)
    Assert 'M4 Test-FolderActive no false match' (-not (Test-FolderActive -Folder 'D:\dev\Other' -Sessions $act))

    # clear → returns record, no longer active
    $rec = Clear-SessionMarker -SessionId 'sess-1' -BatonHome $tmp
    Assert 'M5 Clear returns the removed record' ($null -ne $rec -and $rec.session_id -eq 'sess-1')
    Assert 'M6 no active markers after clear' (@(Get-ActiveSessions -BatonHome $tmp).Count -eq 0)

    # TTL age-out: hand-write a stale marker
    $sdir = Get-SessionsDir -BatonHome $tmp
    $stale = @{ agent='claude'; session_id='old'; cwd='D:\dev\Old'; started_at=(Get-Date).AddHours(-48).ToString('o') }
    $stale | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'old.json') -Encoding utf8NoBOM
    Assert 'M7 stale marker aged out' (@(Get-ActiveSessions -TtlHours 24 -BatonHome $tmp).Count -eq 0)

    # fail-open: no sessions dir
    $empty = Join-Path ([IO.Path]::GetTempPath()) ("bmk2-" + [guid]::NewGuid().ToString('N'))
    Assert 'M8 missing dir → empty' (@(Get-ActiveSessions -BatonHome $empty).Count -eq 0)
    Assert 'M9 clear missing marker → null' ($null -eq (Clear-SessionMarker -SessionId 'nope' -BatonHome $tmp))
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-session-markers-lib.ps1`
Expected: FAIL — `Write-SessionMarker` not defined.

- [ ] **Step 3: Write the implementation**

```powershell
# scripts/session-markers-lib.ps1
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Neutral session-marker contract for active-project detection (d076).
  Any agent harness writes the same marker shape; the registry reads it.
  Fail-open: a broken store degrades to "no active sessions", never throws.
#>
. "$PSScriptRoot/baton-home.ps1"

function Get-SessionsDir {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'sessions')
}

function Write-SessionMarker {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Cwd,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $dir = Get-SessionsDir -BatonHome $BatonHome
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $rec = [ordered]@{
            agent      = $Agent
            session_id = $SessionId
            cwd        = $Cwd
            started_at = (Get-Date).ToUniversalTime().ToString('o')
        }
        ConvertTo-Json -InputObject $rec -Depth 4 |
            Set-Content -LiteralPath (Join-Path $dir "$safe.json") -Encoding utf8NoBOM
    } catch { Write-Debug "Write-SessionMarker: $($_.Exception.Message)" }
}

function Clear-SessionMarker {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$BatonHome = (Get-BatonHome)
    )
    try {
        $safe = ($SessionId -replace '[^A-Za-z0-9._-]+', '_')
        $path = Join-Path (Get-SessionsDir -BatonHome $BatonHome) "$safe.json"
        if (-not (Test-Path $path)) { return $null }
        $rec = $null
        try { $rec = Get-Content -Raw -LiteralPath $path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $rec
    } catch { Write-Debug "Clear-SessionMarker: $($_.Exception.Message)"; return $null }
}

function Get-ActiveSessions {
    param(
        [int]$TtlHours = 24,
        [string]$BatonHome = (Get-BatonHome)
    )
    $out = [System.Collections.ArrayList]@()
    try {
        $dir = Get-SessionsDir -BatonHome $BatonHome
        if (-not (Test-Path $dir)) { return @() }
        $cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * [math]::Abs($TtlHours))
        foreach ($f in Get-ChildItem -File -Path $dir -Filter '*.json' -ErrorAction SilentlyContinue) {
            try {
                $rec = Get-Content -Raw -LiteralPath $f.FullName -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (-not $rec.started_at) { continue }
                # ConvertFrom-Json already parsed started_at to [datetime]; normalize to UTC.
                $started = ([datetime]$rec.started_at).ToUniversalTime()
                if ($started -ge $cutoff) { [void]$out.Add($rec) }
            } catch { }
        }
    } catch { Write-Debug "Get-ActiveSessions: $($_.Exception.Message)" }
    if ($out.Count -eq 0) { return @() }
    return ,([object[]]$out.ToArray())
}

function Test-FolderActive {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [object[]]$Sessions = @()
    )
    try {
        $target = [IO.Path]::GetFullPath($Folder).TrimEnd('\','/')
        foreach ($s in $Sessions) {
            if (-not $s.cwd) { continue }
            $c = [IO.Path]::GetFullPath([string]$s.cwd).TrimEnd('\','/')
            if ($c -ieq $target) { return $true }
        }
    } catch { }
    return $false
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-session-markers-lib.ps1`
Expected: `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/session-markers-lib.ps1 scripts/test-session-markers-lib.ps1
git commit -m "feat(command-center): neutral session-marker contract (M-task1)"
```

---

### Task 2: Registry scan (`registry-lib.ps1` part 1 — discovery)

Discover projects under the home base and derive their identity/blurb.

**Files:**
- Create: `scripts/registry-lib.ps1`
- Test: `scripts/test-registry-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` (baton-home.ps1).
- Produces:
  - `Get-ProjectHomeRoot() -> string` (env `BATON_PROJECTS_ROOT` if set, else `D:\dev`)
  - `Get-ProjectId([string]$Folder) -> string` (git-remote repo-name slug via `git -C`, else folder-name slug — mirrors `Get-CoachProjectId`)
  - `Get-FolderSlug([string]$Folder) -> string` (folder-name, lowercased, `[^a-z0-9-]+`→`-`, trimmed — the friendly `--slug`)
  - `Get-ProjectBlurb([string]$Folder) -> string` (CHARTER "What we're building" first line → README first `# ` heading → `(no description)`)
  - `Test-IsProjectFolder([string]$Folder) -> bool` (has `.git` OR `CHARTER.md`)
  - `Find-ProjectFolders([string]$Root) -> object[]` (per project: `@{ id; slug; folder; blurb }`; `@()` if root missing)

- [ ] **Step 1: Write the failing test**

```powershell
# scripts/test-registry-lib.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/registry-lib.ps1"

$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("breg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    # project via .git
    $p1 = Join-Path $root 'WhimsicalCarving'; New-Item -ItemType Directory -Force -Path (Join-Path $p1 '.git') | Out-Null
    # project via CHARTER.md, with a blurb
    $p2 = Join-Path $root 'Whittle'; New-Item -ItemType Directory -Force -Path $p2 | Out-Null
    Set-Content -LiteralPath (Join-Path $p2 'CHARTER.md') -Value "# Whittle — Project Charter`n`n## What we're building`nA CLI wood-carving planner`n" -Encoding utf8NoBOM
    # NOT a project (plain folder)
    $p3 = Join-Path $root 'notes'; New-Item -ItemType Directory -Force -Path $p3 | Out-Null

    Assert 'R1 .git folder is a project' (Test-IsProjectFolder -Folder $p1)
    Assert 'R2 CHARTER folder is a project' (Test-IsProjectFolder -Folder $p2)
    Assert 'R3 plain folder is not a project' (-not (Test-IsProjectFolder -Folder $p3))

    Assert 'R4 folder slug lowercases' ((Get-FolderSlug -Folder $p1) -eq 'whimsicalcarving')
    Assert 'R5 blurb from CHARTER section' ((Get-ProjectBlurb -Folder $p2) -eq 'A CLI wood-carving planner')
    Assert 'R6 blurb fallback when none' ((Get-ProjectBlurb -Folder $p1) -eq '(no description)')

    $found = @(Find-ProjectFolders -Root $root)
    Assert 'R7 scan finds exactly the two projects' (@($found).Count -eq 2)
    Assert 'R8 scan skips the plain folder' (-not ($found.slug -contains 'notes'))
    Assert 'R9 scan carries folder+blurb' (($found | Where-Object { $_.slug -eq 'whittle' }).blurb -eq 'A CLI wood-carving planner')

    Assert 'R10 missing root → empty' (@(Find-ProjectFolders -Root (Join-Path $root 'nope')).Count -eq 0)
}
finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-registry-lib.ps1`
Expected: FAIL — `Test-IsProjectFolder` not defined.

- [ ] **Step 3: Write the implementation**

```powershell
# scripts/registry-lib.ps1
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Project registry (d076): scan the D:\dev home base, fold the scan over
  start-lib's per-project project.json records, resolve a project name to a
  folder, and roster projects by active/inactive/archived lifecycle.
  Neutral core — no harness dependency. Fail-open throughout.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/start-lib.ps1"             # Read-/Write-ProjectRecord
. "$PSScriptRoot/session-markers-lib.ps1"   # Get-ActiveSessions, Test-FolderActive

function Get-ProjectHomeRoot {
    if ($env:BATON_PROJECTS_ROOT) { return [string]$env:BATON_PROJECTS_ROOT }
    return 'D:\dev'
}

function Get-FolderSlug {
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $leaf = Split-Path -Leaf ([IO.Path]::GetFullPath($Folder))
        return ($leaf.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
    } catch { return '' }
}

function Get-ProjectId {
    <# Git-remote repo-name slug, else folder-name slug. Mirrors
       coach-lib's Get-CoachProjectId so registry records line up with what
       /baton:start and the coach already key by. #>
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $remote = (& git -C $Folder remote get-url origin 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remote) {
            $clean = "$remote" -replace '^(https?://|git@)', '' -replace ':', '/' -replace '\.git$', ''
            $parts = $clean -split '/' | Where-Object { $_ }
            if (@($parts).Count -ge 2) {
                $repo = [string]$parts[-1]
                return ($repo.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
            }
        }
    } catch { }
    return (Get-FolderSlug -Folder $Folder)
}

function Get-ProjectBlurb {
    param([Parameter(Mandatory)][string]$Folder)
    try {
        $charter = Join-Path $Folder 'CHARTER.md'
        if (Test-Path $charter) {
            $lines = Get-Content -LiteralPath $charter -ErrorAction Stop
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^##\s+What we''re building') {
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        $t = $lines[$j].Trim()
                        if ($t -and $t -notmatch '^#') { return $t }
                    }
                }
            }
        }
        $readme = Join-Path $Folder 'README.md'
        if (Test-Path $readme) {
            foreach ($line in (Get-Content -LiteralPath $readme -ErrorAction Stop)) {
                if ($line -match '^#\s+(.+)$') { return $Matches[1].Trim() }
            }
        }
    } catch { }
    return '(no description)'
}

function Test-IsProjectFolder {
    param([Parameter(Mandatory)][string]$Folder)
    return ((Test-Path (Join-Path $Folder '.git')) -or (Test-Path (Join-Path $Folder 'CHARTER.md')))
}

function Find-ProjectFolders {
    param([string]$Root = (Get-ProjectHomeRoot))
    $out = [System.Collections.ArrayList]@()
    try {
        if (-not (Test-Path $Root)) { return @() }
        foreach ($d in Get-ChildItem -Directory -Path $Root -ErrorAction SilentlyContinue) {
            if (-not (Test-IsProjectFolder -Folder $d.FullName)) { continue }
            [void]$out.Add([ordered]@{
                id     = (Get-ProjectId -Folder $d.FullName)
                slug   = (Get-FolderSlug -Folder $d.FullName)
                folder = $d.FullName
                blurb  = (Get-ProjectBlurb -Folder $d.FullName)
            })
        }
    } catch { Write-Debug "Find-ProjectFolders: $($_.Exception.Message)" }
    if ($out.Count -eq 0) { return @() }
    return ,([object[]]$out.ToArray())
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-registry-lib.ps1`
Expected: `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/registry-lib.ps1 scripts/test-registry-lib.ps1
git commit -m "feat(command-center): registry scan + project id/slug/blurb (M-task2)"
```

---

### Task 3: Registry roster, reconcile, resolution, resume (`registry-lib.ps1` part 2)

Fold the scan over existing records, group by lifecycle, resolve a target folder, and map an agent to its resume command.

**Files:**
- Modify: `scripts/registry-lib.ps1` (append functions)
- Modify: `scripts/test-registry-lib.ps1` (append checks)

**Interfaces:**
- Consumes: Task 1 (`Get-ActiveSessions`, `Test-FolderActive`), Task 2 (`Find-ProjectFolders`, `Get-ProjectId`, `Get-FolderSlug`), `start-lib.ps1` (`Read-ProjectRecord` at `$ProjectsRoot/<id>/project.json`).
- Produces:
  - `Get-ProjectRoster([string]$Root, [string]$BatonHome) -> hashtable` (`@{ active=@(); inactive=@(); archived=@() }`; each entry `@{ id; slug; folder; blurb; archived; resumable; agent; last_session_id }`)
  - `Resolve-ProjectTarget([string]$Slug, [string]$Cwd, [string]$Root, [string]$BatonHome) -> hashtable` (`@{ status='resolved'; folder=... }` | `@{ status='unknown'; slug=... }` | `@{ status='picker' }`)
  - `Get-ResumeCommand([string]$Agent, [string]$SessionId) -> string|$null`

- [ ] **Step 1: Write the failing test (append to `scripts/test-registry-lib.ps1`, before the final tally)**

```powershell
    # --- Task 3: roster / resolution / resume ---
    $home2 = Join-Path ([IO.Path]::GetTempPath()) ("breg-home-" + [guid]::NewGuid().ToString('N'))
    $projRoot = Join-Path $home2 'projects'
    New-Item -ItemType Directory -Force -Path $projRoot | Out-Null

    # a record for Whittle marked archived; WhimsicalCarving has no record (→ inactive)
    $whittleId = Get-ProjectId -Folder $p2
    Write-ProjectRecord -Record @{ id=$whittleId; name='Whittle'; folder=$p2; archived=$true } -ProjectsRoot $projRoot

    # make WhimsicalCarving active via a live marker
    Write-SessionMarker -Agent 'claude' -SessionId 'live-1' -Cwd $p1 -BatonHome $home2

    $roster = Get-ProjectRoster -Root $root -BatonHome $home2
    Assert 'R11 active group holds the live project' (@($roster.active | Where-Object { $_.folder -eq $p1 }).Count -eq 1)
    Assert 'R12 archived group holds the archived record' (@($roster.archived | Where-Object { $_.folder -eq $p2 }).Count -eq 1)
    Assert 'R13 archived project not in inactive' (@($roster.inactive | Where-Object { $_.folder -eq $p2 }).Count -eq 0)

    # resolution precedence
    $byslug = Resolve-ProjectTarget -Slug 'whimsicalcarving' -Root $root -BatonHome $home2
    Assert 'R14 --slug resolves to its folder' ($byslug.status -eq 'resolved' -and $byslug.folder -eq $p1)
    $bad = Resolve-ProjectTarget -Slug 'ghost' -Root $root -BatonHome $home2
    Assert 'R15 unknown slug → unknown' ($bad.status -eq 'unknown')
    $cwd = Resolve-ProjectTarget -Cwd $p2 -Root $root -BatonHome $home2
    Assert 'R16 cwd-is-project resolves to cwd' ($cwd.status -eq 'resolved' -and $cwd.folder -eq $p2)
    $hb = Resolve-ProjectTarget -Cwd $root -Root $root -BatonHome $home2
    Assert 'R17 home base (not a project) → picker' ($hb.status -eq 'picker')

    # resume command is agent-tagged
    Assert 'R18 claude resume command' ((Get-ResumeCommand -Agent 'claude' -SessionId 'abc') -eq 'claude --resume abc')
    Assert 'R19 codex resume command' ((Get-ResumeCommand -Agent 'codex' -SessionId 'abc') -like 'codex*abc*')
    Assert 'R20 unknown agent → null' ($null -eq (Get-ResumeCommand -Agent 'mystery' -SessionId 'abc'))

    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-registry-lib.ps1`
Expected: FAIL — `Get-ProjectRoster` not defined.

- [ ] **Step 3: Append the implementation to `scripts/registry-lib.ps1`**

```powershell
$script:ResumeCommandMap = @{
    # Per-agent resume invocation. NOTE: verify exact CLI syntax at build time
    # against each tool (claude --resume vs --continue; codex resume subcommand).
    'claude' = 'claude --resume {0}'
    'codex'  = 'codex resume {0}'
}

function Get-ResumeCommand {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][string]$SessionId
    )
    $key = $Agent.ToLowerInvariant()
    if (-not $script:ResumeCommandMap.ContainsKey($key)) { return $null }
    return ($script:ResumeCommandMap[$key] -f $SessionId)
}

function Get-ProjectRoster {
    param(
        [string]$Root = (Get-ProjectHomeRoot),
        [string]$BatonHome = (Get-BatonHome)
    )
    $projectsRoot = Join-Path $BatonHome 'projects'
    $active = [System.Collections.ArrayList]@()
    $inactive = [System.Collections.ArrayList]@()
    $archived = [System.Collections.ArrayList]@()
    $sessions = @(Get-ActiveSessions -BatonHome $BatonHome)

    foreach ($p in @(Find-ProjectFolders -Root $Root)) {
        $rec = Read-ProjectRecord -ProjectId $p.id -ProjectsRoot $projectsRoot
        $isArchived = ($null -ne $rec -and $rec.archived -eq $true)
        $isHidden   = ($null -ne $rec -and $rec.hidden -eq $true)
        if ($isHidden) { continue }
        $blurb = if ($rec -and $rec.blurb) { [string]$rec.blurb } else { [string]$p.blurb }
        $entry = [ordered]@{
            id              = $p.id
            slug            = $p.slug
            folder          = $p.folder
            blurb           = $blurb
            archived        = $isArchived
            resumable       = ($null -ne $rec -and -not [string]::IsNullOrWhiteSpace($rec.last_session_id))
            agent           = if ($rec) { [string]$rec.agent } else { $null }
            last_session_id = if ($rec) { [string]$rec.last_session_id } else { $null }
        }
        if ($isArchived) { [void]$archived.Add($entry) }
        elseif (Test-FolderActive -Folder $p.folder -Sessions $sessions) { [void]$active.Add($entry) }
        else { [void]$inactive.Add($entry) }
    }
    return @{
        active   = @($active.ToArray())
        inactive = @($inactive.ToArray())
        archived = @($archived.ToArray())
    }
}

function Resolve-ProjectTarget {
    param(
        [string]$Slug,
        [string]$Cwd,
        [string]$Root = (Get-ProjectHomeRoot),
        [string]$BatonHome = (Get-BatonHome)
    )
    $found = @(Find-ProjectFolders -Root $Root)
    # 1. Explicit --slug: match against folder slug, id, or record slug (lenient).
    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        $want = $Slug.ToLowerInvariant()
        foreach ($p in $found) {
            if ($p.slug -eq $want -or $p.id -eq $want) {
                return @{ status = 'resolved'; folder = $p.folder }
            }
        }
        return @{ status = 'unknown'; slug = $Slug }
    }
    # 2. cwd is itself a project folder.
    if (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-IsProjectFolder -Folder $Cwd)) {
        return @{ status = 'resolved'; folder = ([IO.Path]::GetFullPath($Cwd)) }
    }
    # 3. Home base / not a project → caller shows the picker.
    return @{ status = 'picker' }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-registry-lib.ps1`
Expected: `ALL CHECKS PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/registry-lib.ps1 scripts/test-registry-lib.ps1
git commit -m "feat(command-center): roster + resolution + agent-tagged resume (M-task3)"
```

---

### Task 4: Claude adapter hooks + resume capture

SessionStart stamps the marker; SessionEnd clears it and writes the resume pointer into the project's record. Hooks always exit 0.

**Files:**
- Create: `scripts/hooks/baton-session-start.ps1`
- Create: `scripts/hooks/baton-session-stop.ps1`
- Modify: `hooks/hooks.json`
- Test: `scripts/test-session-hooks.ps1`

**Interfaces:**
- Consumes: `session-markers-lib.ps1` (Write/Clear), `registry-lib.ps1` (`Get-ProjectId`), `start-lib.ps1` (`Read-/Write-ProjectRecord`), `baton-home.ps1` (`Get-BatonHome`).
- Hook stdin JSON payload provides `session_id` and `cwd` (SessionEnd also `reason`).
- Produces: on SessionEnd, the project record gains `agent`, `last_session_id`, `last_ended_at`.

- [ ] **Step 1: Write the failing test (child-process, drives the real hook scripts via piped JSON)**

```powershell
# scripts/test-session-hooks.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$startHook = Join-Path $here 'hooks/baton-session-start.ps1'
$stopHook  = Join-Path $here 'hooks/baton-session-stop.ps1'

$home2 = Join-Path ([IO.Path]::GetTempPath()) ("bhk-" + [guid]::NewGuid().ToString('N'))
$proj  = Join-Path $home2 'proj'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$oldHome = $env:BATON_HOME
$env:BATON_HOME = $home2
try {
    $payload = @{ session_id='hook-sess'; cwd=$proj } | ConvertTo-Json -Compress

    # SessionStart → marker written, exit 0
    $payload | & pwsh -NoProfile -File $startHook
    Assert 'H1 start hook exits 0' ($LASTEXITCODE -eq 0)
    . "$here/session-markers-lib.ps1"
    Assert 'H2 marker present after start' (@(Get-ActiveSessions -BatonHome $home2 | Where-Object { $_.cwd -eq $proj }).Count -eq 1)

    # SessionEnd → marker cleared + resume pointer written, exit 0
    $payload | & pwsh -NoProfile -File $stopHook
    Assert 'H3 stop hook exits 0' ($LASTEXITCODE -eq 0)
    Assert 'H4 marker cleared after stop' (@(Get-ActiveSessions -BatonHome $home2).Count -eq 0)

    . "$here/registry-lib.ps1"
    $pid2 = Get-ProjectId -Folder $proj
    $rec = Read-ProjectRecord -ProjectId $pid2 -ProjectsRoot (Join-Path $home2 'projects')
    Assert 'H5 resume pointer captured' ($null -ne $rec -and $rec.last_session_id -eq 'hook-sess' -and $rec.agent -eq 'claude')

    # malformed JSON → still exit 0 (fail-open)
    'not json' | & pwsh -NoProfile -File $startHook
    Assert 'H6 malformed stdin still exits 0' ($LASTEXITCODE -eq 0)
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-session-hooks.ps1`
Expected: FAIL — hook scripts do not exist.

- [ ] **Step 3: Write the hooks**

```powershell
# scripts/hooks/baton-session-start.ps1
#!/usr/bin/env pwsh
<# SessionStart(startup) adapter: stamp a neutral session marker for active
   detection (d076). Non-blocking: always exits 0. #>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $libCandidates = @(
        (Join-Path $scriptDir '../session-markers-lib.ps1'),
        (Join-Path $scriptDir '../scripts/session-markers-lib.ps1')
    )
    $libPath = $libCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $libPath) { exit 0 }
    . $libPath

    $sid = $null; $cwd = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.session_id) { $sid = [string]$payload.session_id }
                if ($payload.cwd) { $cwd = [string]$payload.cwd }
            }
        }
    } catch { }
    if ($sid) { Write-SessionMarker -Agent 'claude' -SessionId $sid -Cwd $cwd }
    exit 0
} catch { exit 0 }
```

```powershell
# scripts/hooks/baton-session-stop.ps1
#!/usr/bin/env pwsh
<# SessionEnd adapter: clear the session marker and write the resume pointer
   into the project's record (d076). Non-blocking: always exits 0. #>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    function Resolve-Lib([string]$name) {
        @((Join-Path $scriptDir "../$name"), (Join-Path $scriptDir "../scripts/$name")) |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    $mk = Resolve-Lib 'session-markers-lib.ps1'
    $reg = Resolve-Lib 'registry-lib.ps1'
    if (-not $mk -or -not $reg) { exit 0 }
    . $mk
    . $reg   # also dot-sources start-lib (Read-/Write-ProjectRecord) + baton-home

    $sid = $null; $cwd = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.session_id) { $sid = [string]$payload.session_id }
                if ($payload.cwd) { $cwd = [string]$payload.cwd }
            }
        }
    } catch { }
    if (-not $sid) { exit 0 }

    $cleared = Clear-SessionMarker -SessionId $sid
    $agent = if ($cleared -and $cleared.agent) { [string]$cleared.agent } else { 'claude' }

    # Write the resume pointer into the project record (merge, don't clobber).
    $batonHome = Get-BatonHome
    $projectsRoot = Join-Path $batonHome 'projects'
    $projId = Get-ProjectId -Folder $cwd
    $existing = Read-ProjectRecord -ProjectId $projId -ProjectsRoot $projectsRoot
    $rec = @{}
    if ($existing) { foreach ($p in $existing.PSObject.Properties) { $rec[$p.Name] = $p.Value } }
    $rec['id'] = $projId
    if (-not $rec.ContainsKey('name')) { $rec['name'] = (Split-Path -Leaf $cwd) }
    if (-not $rec.ContainsKey('folder')) { $rec['folder'] = $cwd }
    $rec['agent'] = $agent
    $rec['last_session_id'] = $sid
    $rec['last_ended_at'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-ProjectRecord -Record $rec -ProjectsRoot $projectsRoot
    exit 0
} catch { exit 0 }
```

- [ ] **Step 4: Register the hooks in `hooks/hooks.json`**

Add `baton-session-start.ps1` as a third hook in the existing `SessionStart`→`startup` array (after `baton-coach.ps1`), and add a new top-level `SessionEnd` block. The full file becomes:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-init.ps1\"" },
          { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-coach.ps1\"" },
          { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-session-start.ps1\"" }
        ]
      }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/log-tool-call.ps1\"" } ] },
      { "matcher": "*", "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-feed.ps1\"" } ] }
    ],
    "Stop": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/decision-detect.ps1\"" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/baton-session-stop.ps1\"" } ] }
    ]
  }
}
```

- [ ] **Step 5: Run the hook test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-session-hooks.ps1`
Expected: `ALL CHECKS PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/hooks/baton-session-start.ps1 scripts/hooks/baton-session-stop.ps1 hooks/hooks.json scripts/test-session-hooks.ps1
git commit -m "feat(command-center): Claude adapter hooks — markers + resume capture (M-task4)"
```

---

### Task 5: `fleet-go.ps1` retargeting (`--project` / `--slug`)  ·  INTEGRATION

Thread a resolved target folder into the run. This is the one genuine engine change — dispatch it on a mid-tier model.

**Files:**
- Modify: `scripts/fleet-go.ps1`
- Test: `scripts/test-fleet-go-retarget.ps1`

**Interfaces:**
- Consumes: `registry-lib.ps1` (`Resolve-ProjectTarget`).
- Behavior: `-Project <slug>` resolves via `Resolve-ProjectTarget -Slug`; if `resolved`, `Push-Location` the folder for the run and `Pop-Location` in `finally`; if `unknown`, error to stderr + `exit 2`; if no `-Project`, behavior is byte-for-byte unchanged (cwd default).

- [ ] **Step 1: Write the failing test**

```powershell
# scripts/test-fleet-go-retarget.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$go = Join-Path $here 'fleet-go.ps1'

$root = Join-Path ([IO.Path]::GetTempPath()) ("bgo-" + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $root 'Widget'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$home2 = Join-Path $root 'home'; New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$oldHome = $env:BATON_HOME; $oldRoot = $env:BATON_PROJECTS_ROOT
$env:BATON_HOME = $home2; $env:BATON_PROJECTS_ROOT = $root
$env:BATON_GO_TEST_PLAN = '{"goal":"x","tasks":[{"id":"t1","desc":"noop","depends_on":[],"cost_tier":"local","reversible":true}]}'
$env:BATON_GO_TEST_SPAWN = '1'
try {
    # known slug → runs, exit 0, report mentions the resolved run
    $out = & pwsh -NoProfile -File $go -Project 'widget' -Goal 'do a thing' 2>&1
    Assert 'G1 known --slug runs (exit 0)' ($LASTEXITCODE -eq 0)

    # unknown slug → exit 2, stderr message
    $err = & pwsh -NoProfile -File $go -Project 'ghost' -Goal 'x' 2>&1
    Assert 'G2 unknown --slug exits 2' ($LASTEXITCODE -eq 2)
    Assert 'G3 unknown --slug names the slug' ("$err" -match 'ghost')
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRoot) { Remove-Item Env:BATON_PROJECTS_ROOT -EA SilentlyContinue } else { $env:BATON_PROJECTS_ROOT = $oldRoot }
    Remove-Item Env:BATON_GO_TEST_PLAN, Env:BATON_GO_TEST_SPAWN -EA SilentlyContinue
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-go-retarget.ps1`
Expected: FAIL — `-Project` is not a recognized parameter (or unknown slug does not exit 2).

- [ ] **Step 3: Modify `scripts/fleet-go.ps1`**

Add `[string]$Project` to the `param(...)` block (after `[string]$GateDiff`). After the existing dot-sources (`conductor-lib.ps1`, `coach-lib.ps1`), insert the retarget resolution, and wrap the run in `Push-Location`/`Pop-Location`.

Add to `param(...)`:
```powershell
    [string]$Project,
```

Insert after line `try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }`:
```powershell
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

$targetFolder = $null
if (-not [string]::IsNullOrWhiteSpace($Project)) {
    $resolved = Resolve-ProjectTarget -Slug $Project
    if ($resolved.status -eq 'resolved') {
        $targetFolder = $resolved.folder
    } elseif ($resolved.status -eq 'unknown') {
        [Console]::Error.WriteLine("No project matches --project '$Project'. Run /baton:project list to see registered projects.")
        exit 2
    }
}
```

Wrap the run: change the single line `$result = Invoke-Conductor @go` to:
```powershell
if ($targetFolder) { Push-Location -LiteralPath $targetFolder }
try {
    $result = Invoke-Conductor @go
} finally {
    if ($targetFolder) { Pop-Location }
}
```

- [ ] **Step 4: Run to verify it passes (and the existing conductor suite still passes)**

Run: `pwsh -NoProfile -File scripts/test-fleet-go-retarget.ps1`
Expected: `ALL CHECKS PASS`.
Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: prior `ALL CHECKS PASS` unchanged (no-`-Project` path is byte-for-byte).

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-go.ps1 scripts/test-fleet-go-retarget.ps1
git commit -m "feat(command-center): fleet-go --project retargeting (M-task5)"
```

---

### Task 6: `/baton:project` registry-admin surface

The roster + registry editing CLI.

**Files:**
- Create: `scripts/fleet-project.ps1`
- Create: `commands/project.md`
- Test: `scripts/test-fleet-project.ps1`

**Interfaces:**
- Consumes: `registry-lib.ps1` (`Get-ProjectRoster`, `Find-ProjectFolders`, `Get-ProjectId`), `start-lib.ps1` (`Read-/Write-ProjectRecord`).
- Subcommands: `list [--json]`, `archive <slug>`, `unarchive <slug>`, `hide <slug>`, `set-blurb <slug> "<text>"`. Unknown/absent subcommand → usage to stderr + `exit 2`.

- [ ] **Step 1: Write the failing test**

```powershell
# scripts/test-fleet-project.ps1
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$cli = Join-Path $here 'fleet-project.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("bfp-" + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $root 'Gadget'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$home2 = Join-Path $root 'home'; New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$oldHome = $env:BATON_HOME; $oldRoot = $env:BATON_PROJECTS_ROOT
$env:BATON_HOME = $home2; $env:BATON_PROJECTS_ROOT = $root
try {
    $j = & pwsh -NoProfile -File $cli list --json 2>&1
    Assert 'P1 list --json is valid JSON' ($null -ne ($j | ConvertFrom-Json))
    Assert 'P2 gadget starts inactive' (("$j" | ConvertFrom-Json).inactive.slug -contains 'gadget')

    & pwsh -NoProfile -File $cli set-blurb gadget "A tiny gadget" | Out-Null
    Assert 'P3 set-blurb exit 0' ($LASTEXITCODE -eq 0)
    & pwsh -NoProfile -File $cli archive gadget | Out-Null
    $j2 = (& pwsh -NoProfile -File $cli list --json 2>&1) | ConvertFrom-Json
    Assert 'P4 archived after archive' ($j2.archived.slug -contains 'gadget')
    Assert 'P5 blurb persisted' (($j2.archived | Where-Object { $_.slug -eq 'gadget' }).blurb -eq 'A tiny gadget')

    & pwsh -NoProfile -File $cli unarchive gadget | Out-Null
    $j3 = (& pwsh -NoProfile -File $cli list --json 2>&1) | ConvertFrom-Json
    Assert 'P6 back to inactive after unarchive' ($j3.inactive.slug -contains 'gadget')

    & pwsh -NoProfile -File $cli 2>&1 | Out-Null
    Assert 'P7 no subcommand → exit 2' ($LASTEXITCODE -eq 2)
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRoot) { Remove-Item Env:BATON_PROJECTS_ROOT -EA SilentlyContinue } else { $env:BATON_PROJECTS_ROOT = $oldRoot }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-project.ps1`
Expected: FAIL — `fleet-project.ps1` does not exist.

- [ ] **Step 3: Write `scripts/fleet-project.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:project — the project registry command center (d076).
  list [--json] | archive <slug> | unarchive <slug> | hide <slug> | set-blurb <slug> "<text>"
#>
param(
    [Parameter(Position = 0)][string]$Subcommand,
    [Parameter(Position = 1)][string]$Slug,
    [Parameter(Position = 2)][string]$Value,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

function Write-Usage {
    [Console]::Error.WriteLine("Usage: /baton:project list [--json] | archive <slug> | unarchive <slug> | hide <slug> | set-blurb <slug> `"<text>`"")
}

function Get-RecordForSlug {
    param([string]$WantSlug)
    $projectsRoot = Join-Path (Get-BatonHome) 'projects'
    foreach ($p in @(Find-ProjectFolders)) {
        if ($p.slug -eq $WantSlug.ToLowerInvariant() -or $p.id -eq $WantSlug.ToLowerInvariant()) {
            $rec = Read-ProjectRecord -ProjectId $p.id -ProjectsRoot $projectsRoot
            $h = @{}
            if ($rec) { foreach ($pr in $rec.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
            $h['id'] = $p.id
            if (-not $h.ContainsKey('name')) { $h['name'] = (Split-Path -Leaf $p.folder) }
            if (-not $h.ContainsKey('folder')) { $h['folder'] = $p.folder }
            return @{ record = $h; projectsRoot = $projectsRoot }
        }
    }
    return $null
}

function Set-RecordField {
    param([string]$WantSlug, [string]$Field, [object]$FieldValue)
    $ctx = Get-RecordForSlug -WantSlug $WantSlug
    if (-not $ctx) { [Console]::Error.WriteLine("No project matches '$WantSlug'."); exit 2 }
    $ctx.record[$Field] = $FieldValue
    Write-ProjectRecord -Record $ctx.record -ProjectsRoot $ctx.projectsRoot
}

switch (($Subcommand | ForEach-Object { $_.ToLowerInvariant() })) {
    'list' {
        $roster = Get-ProjectRoster
        if ($Json) {
            ConvertTo-Json -InputObject $roster -Depth 6
        } else {
            function Show($title, $rows) {
                Write-Host "== $title =="
                if (@($rows).Count -eq 0) { Write-Host "  (none)"; return }
                foreach ($r in $rows) {
                    $tag = if ($r.resumable) { ' [resumable]' } else { '' }
                    Write-Host ("  {0,-24} {1}{2}" -f $r.slug, $r.blurb, $tag)
                }
            }
            Show 'Active'   $roster.active
            Show 'Inactive' $roster.inactive
            Show 'Archived' $roster.archived
        }
        exit 0
    }
    'archive'   { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'archived' -FieldValue $true;  Write-Host "Archived '$Slug'."; exit 0 }
    'unarchive' { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'archived' -FieldValue $false; Write-Host "Unarchived '$Slug'."; exit 0 }
    'hide'      { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'hidden' -FieldValue $true;    Write-Host "Hid '$Slug'."; exit 0 }
    'set-blurb' { if (-not $Slug -or $null -eq $Value) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'blurb' -FieldValue $Value; Write-Host "Blurb set for '$Slug'."; exit 0 }
    default     { Write-Usage; exit 2 }
}
```

- [ ] **Step 4: Write `commands/project.md`**

```markdown
---
description: Project registry command center — list projects by lifecycle and edit the registry.
---

# /baton:project

The multi-project command center. From the `D:\dev` home base, see every
project grouped **Active / Inactive / Archived** and edit its registry entry.

Run the CLI:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/fleet-project.ps1" <subcommand> [args]
```

Subcommands:

- `list [--json]` — roster grouped by lifecycle. *Active* = a session is
  currently open in the folder; *Inactive* = registered, no open session
  (may be `[resumable]`); *Archived* = done with it.
- `archive <slug>` / `unarchive <slug>` — move a project in/out of the
  Archived group.
- `hide <slug>` — drop a `.git` folder that isn't really a project.
- `set-blurb <slug> "<text>"` — hand-write the one-line description.

Projects are discovered by scanning `D:\dev` (override with
`$env:BATON_PROJECTS_ROOT`); a folder counts if it has a `.git` dir or a
`CHARTER.md`. To start work on one, use `/baton:go --<slug> <goal>`.

State is box-private under `$BATON_HOME/projects/`.
```

- [ ] **Step 5: Run to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-fleet-project.ps1`
Expected: `ALL CHECKS PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/fleet-project.ps1 commands/project.md scripts/test-fleet-project.ps1
git commit -m "feat(command-center): /baton:project registry-admin surface (M-task6)"
```

---

### Task 7: Docs, deploy manifest, bootstrap asserts, version bump

Wire the new scripts into deploy, document the selector, and bump the plugin.

**Files:**
- Modify: `scripts/bootstrap.ps1` (Step 5b manifest array)
- Modify: `scripts/test-bootstrap.ps1` (deploy asserts)
- Modify: `commands/go.md`, `commands/start.md`, `AGENTS.md`
- Modify: `.claude-plugin/plugin.json` (version)

- [ ] **Step 1: Add the new libs to the deploy manifest**

In `scripts/bootstrap.ps1`, in the Step 5b `foreach ($script in @(...))` array (the one ending `'start-lib.ps1', 'coach-lib.ps1'))`), append the three new deployed libs:

```powershell
'start-lib.ps1', 'coach-lib.ps1', 'session-markers-lib.ps1', 'registry-lib.ps1', 'fleet-project.ps1'))
```

(The two hook scripts are plugin-shipped via `hooks/hooks.json` → `${CLAUDE_PLUGIN_ROOT}`, so they are NOT added to this manifest — same as `baton-coach.ps1`.)

- [ ] **Step 2: Add deploy asserts (the v1.8.0 coach-lib omission lesson)**

In `scripts/test-bootstrap.ps1`, after the existing `coach-lib.ps1` assert, add:

```powershell
Assert "deploys registry-lib script (roster/resolution needed on deployed boxes)" ($out -match 'registry-lib\.ps1')
Assert "deploys session-markers-lib script (active detection needs it on-box)" ($out -match 'session-markers-lib\.ps1')
Assert "deploys fleet-project script (/baton:project CLI)" ($out -match 'fleet-project\.ps1')
```

- [ ] **Step 3: Run the bootstrap suite**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: `ALL CHECKS PASS` (58 checks — was 55, +3).

- [ ] **Step 4: Document the selector in `commands/go.md`**

Add a short section (place it after the existing usage/synopsis). Exact text:

```markdown
## Running from the D:\dev home base

You can launch a run against any registered project without `cd`-ing into it:

- `/baton:go --<slug> <goal>` — resolve `<slug>` (a project under `D:\dev`)
  to its folder and run there. `--<slug>` is shorthand for `--project <slug>`.
- `/baton:go <goal>` from inside a project folder — runs against that folder
  (the default).
- From `D:\dev` itself with no `--project`, use `/baton:start` to pick a
  project.

See `/baton:project list` for the roster.
```

- [ ] **Step 5: Document the picker + resume in `commands/start.md`**

Add a short section:

```markdown
## Picking a project from the home base

Run from `D:\dev` to choose among your projects. `/baton:project list` shows
them grouped **Active / Inactive / Archived**. Pick an **inactive** project
and either start fresh (`/baton:go --<slug> <goal>`) or, if it is
`[resumable]`, resume where you left off with the saved command
(`claude --resume <id>` for a Claude session). Baton records the resume
pointer automatically when a session ends.
```

- [ ] **Step 6: Document the Codex front door in `AGENTS.md`**

Add a section (append near the fleet/commands documentation):

```markdown
## Project command center (from any agent)

Baton's project registry and front door are harness-neutral. From Codex (or
any agent), reach the same engine directly:

- Roster: `pwsh -NoProfile -File scripts/fleet-project.ps1 list --json`
- Start a project by name: `pwsh -NoProfile -File scripts/fleet-go.ps1 --project <slug> --goal "<goal>"`

Active-session detection and resume pointers use a neutral marker contract
under `$BATON_HOME/sessions/` (`{agent,session_id,cwd,started_at}`). The
Claude adapter (SessionStart/SessionEnd hooks) ships now; a Codex lifecycle
adapter writing the same marker shape is the documented follow-on.
```

- [ ] **Step 7: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.8.2"` to `"version": "1.9.0-rc.1"`.

- [ ] **Step 8: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/go.md commands/start.md AGENTS.md .claude-plugin/plugin.json
git commit -m "feat(command-center): deploy wiring, docs, Codex front door, bump 1.9.0-rc.1 (M-task7)"
```

---

## Self-Review

**1. Spec coverage:**
- §4 registry (hybrid, persisted+computed fields, seed+reconcile) → Tasks 2, 3, 6. ✅
- §5 lifecycle (active/inactive/archived, neutral marker contract, TTL age-out) → Tasks 1, 3, 4. ✅
- §6 resume (capture on end, agent-tagged, CLI surfaces command) → Tasks 3 (`Get-ResumeCommand`), 4 (capture), 5/7 (surface via start.md). ✅
- §7 resolution (—slug / cwd / picker precedence, goal-is-rest-of-line) → Task 3 (`Resolve-ProjectTarget`), Task 5 (fleet-go wiring), go.md. ✅
- §8 surfaces (`/baton:go`, `/baton:start`, `/baton:project`, AGENTS.md) → Tasks 5, 6, 7. ✅
- §9 components → all files mapped across tasks. ✅
- §3 neutral core + Claude adapter (Codex contract-defined) → libs are harness-free (Tasks 1–3), hooks are the only Claude-specific code (Task 4), AGENTS.md documents Codex path (Task 7). ✅
- §10 hermetic tests (temp BATON_HOME + temp root, restore) → every test file. ✅

**2. Placeholder scan:** No TBD/"handle edge cases"/"similar to Task N". The two "verify exact CLI syntax at build time" notes are real code with real defaults + a verification comment, not blanks. ✅

**3. Type consistency:** `Get-ProjectId`/`Get-FolderSlug`/`Find-ProjectFolders` (entry `@{id;slug;folder;blurb}`) consistent across Tasks 2/3/4/6. `Resolve-ProjectTarget` returns `@{status;folder|slug}` consumed identically in Task 5. `Get-ActiveSessions`→`Test-FolderActive` object shape consistent Tasks 1/3. Record fields (`archived`/`hidden`/`blurb`/`agent`/`last_session_id`/`last_ended_at`) written in Task 4/6 and read in Task 3 match. `Write-ProjectRecord -Record` takes a hashtable with `.id` (start-lib contract) — honored in Tasks 4/6. ✅

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-04-baton-project-command-center.md`.**

**Model ladder (Kevin's):** Tasks 1–4, 6, 7 are transcription-grade (complete code in-plan) → **haiku**. Task 5 (fleet-go retargeting) is integration wiring into a live engine → **sonnet**. Final whole-branch review → **opus**. Streamlined ceremony: no per-task reviewers; one opus whole-branch review before the PR.

**Ordering:** Tasks are sequential (2→3 append the same lib; 4 depends on 1+3; 5 depends on 3; 6 depends on 3; 7 last). Tasks 1 and 2 are independent but keep them in order for a clean ledger.

**Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, ledger between tasks, opus final review.

**2. Inline Execution** — batch with checkpoints.

Per the standing default (`feedback_default_subagent_driven_execution`), proceed **subagent-driven** unless Kevin says otherwise. Branch `feature/project-command-center`. **Do NOT self-merge** — the PR waits for Kevin's word.
