# Maestro CLI harness pivot — S0 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task (Kevin's default — do not offer inline execution). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Demote the Maestro room; bare `baton` prints a 3-line passive status and exits; factory actions are explicit verbs (`admit`, `status`, `quota`).

**Architecture:** Add `Format-BatonPassiveStatus` and `Resolve-BatonProjectFromCwd` to `maestro-lib.ps1`. Route bare `baton` and `maestro` (no subcommand) through `Invoke-BatonPassiveStatus`. Register `admit` and `status` in `verbs.yaml`. Remove `Invoke-BatonRoom` from all default entry paths. Update CLI tests.

**Tech Stack:** PowerShell 7, existing Maestro + cursor-quota libs, `verbs.yaml` dispatcher.

**Spec:** `docs/superpowers/specs/2026-08-28-maestro-cli-harness-pivot-design.md`

## Global Constraints

- Bare `baton` must **never block** on stdin — exit 0 after printing 3 stdout lines (+ optional stderr hint).
- Do **not** auto-launch Claude Code, Codex, or any REPL (**decision B**).
- Hermetic tests: temp `BATON_HOME` only; never mutate real `~/.baton/fleet.yaml`.
- Args via JSON file for any new MCP bridge ops (965-byte rule) — **N/A for S0** (no MCP changes in S0).
- Match existing Assert-pattern test style in `scripts/test-*.ps1`.
- Exit codes: success 0; usage/validation errors 2; launcher failures 1.

---

## File map

| File | Responsibility |
|---|---|
| `scripts/maestro-lib.ps1` | `Resolve-BatonProjectFromCwd`, `Get-BatonJobCounts`, `Format-BatonPassiveStatus` |
| `scripts/maestro.ps1` | `Invoke-BatonPassiveStatus`, `Invoke-MaestroAdmit`; demote room |
| `scripts/baton.ps1` | Bare dispatch → passive status; update `Show-BatonHelp` |
| `scripts/verbs.yaml` | Add `admit`, `status`; update header comment |
| `scripts/test-maestro-cli.ps1` | Replace room tests with passive + admit tests |
| `scripts/test-baton-cli.ps1` | Bare baton = passive, not room |

Room scroll/card functions in `maestro-lib.ps1` may remain for S1 deletion if still referenced by tests; **remove** `Invoke-BatonRoom` call sites in S0.

---

### Task 1: Project-from-cwd resolver + job counts

**Files:**
- Modify: `scripts/maestro-lib.ps1`
- Test: `scripts/test-maestro-cli.ps1`

**Interfaces:**
- Consumes: `Get-ProjectId` (`registry-lib.ps1`), `Get-MaestroRoomChoices`, `Get-MaestroJobRecords`
- Produces:
  - `Resolve-BatonProjectFromCwd [-BatonHome] [-Cwd]` → `[pscustomobject]@{ Id; Path; Registered }`
  - `Get-BatonJobCounts [-BatonHome]` → `[pscustomobject]@{ Active; Held; WaitingQuota }`
  - `Format-BatonPassiveStatus [-BatonHome] [-Cwd]` → `[string[]]` (exactly 3 lines)

- [ ] **Step 1: Write failing tests** — append to the hermetic block in `scripts/test-maestro-cli.ps1`:

```powershell
. (Join-Path $here 'registry-lib.ps1')

$projCtx = Resolve-BatonProjectFromCwd -BatonHome $home2 -Cwd (Join-Path $wt2 'ct-install-easy')
Assert 'C1 worktree cwd resolves parent project' ([string]$projCtx.Id -eq 'canvas-toolchain')
Assert 'C2 worktree cwd is registered' ($projCtx.Registered -eq $true)

$badCtx = Resolve-BatonProjectFromCwd -BatonHome $home2 -Cwd '/tmp/not-a-project'
Assert 'C3 unknown cwd is unregistered' ($badCtx.Registered -eq $false)

$counts = Get-BatonJobCounts -BatonHome $home2
Assert 'C4 empty factory counts zero' ($counts.Active -eq 0 -and $counts.Held -eq 0)

$lines = Format-BatonPassiveStatus -BatonHome $home2 -Cwd (Join-Path $wt2 'ct-install-easy')
Assert 'C5 passive status is 3 lines' (@($lines).Count -eq 3)
Assert 'C6 line1 starts with project' ($lines[0] -match '^project\s')
Assert 'C7 line2 starts with quota' ($lines[1] -match '^quota\s')
Assert 'C8 line3 starts with jobs' ($lines[2] -match '^jobs\s')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-maestro-cli.ps1`  
Expected: FAIL — `Resolve-BatonProjectFromCwd` not recognized

- [ ] **Step 3: Implement in `maestro-lib.ps1`**

Add after `Get-MaestroJobRecords`:

```powershell
function Resolve-BatonProjectFromCwd {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string]$Cwd = $(Get-Location).Path
    )
    $path = try { [IO.Path]::GetFullPath($Cwd) } catch { [string]$Cwd }
    . (Join-Path $PSScriptRoot 'registry-lib.ps1')
    $slug = Get-ProjectId -Folder $path
    $choices = @(Get-MaestroRoomChoices -BatonHome $BatonHome)
    # Exact project folder match via registry records
    foreach ($c in @($choices | Where-Object { $_.Kind -eq 'project' })) {
        $recPath = Join-Path $BatonHome 'projects' ([string]$c.Id) 'project.json'
        if (Test-Path -LiteralPath $recPath) {
            $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json
            $folder = [string]$rec.folder
            if ($folder) {
                try {
                    $full = [IO.Path]::GetFullPath($folder)
                    if ($path.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
                        return [pscustomobject]@{ Id = [string]$c.Id; Path = $path; Registered = $true }
                    }
                } catch { }
            }
        }
        if ([string]$c.Id -eq $slug) {
            return [pscustomobject]@{ Id = [string]$c.Id; Path = $path; Registered = $true }
        }
    }
    # Worktree match
    foreach ($c in @($choices | Where-Object { $_.Kind -eq 'worktree' })) {
        if ($path -match [regex]::Escape([string]$c.Label) -or [string]$c.Id -eq $slug) {
            foreach ($p in @($choices | Where-Object { $_.Kind -eq 'project' })) {
                if (Test-MaestroChoiceMatchesProject -Choice $c -ProjectId ([string]$p.Id)) {
                    return [pscustomobject]@{ Id = [string]$p.Id; Path = $path; Registered = $true }
                }
            }
        }
    }
    return [pscustomobject]@{ Id = $slug; Path = $path; Registered = $false }
}

function Get-BatonJobCounts {
    param([string]$BatonHome)
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $active = 0; $held = 0; $wq = 0
    $terminal = @('done', 'rejected', 'cancelled')
    foreach ($rec in @(Get-MaestroJobRecords -JobsDir $jobsDir)) {
        $st = [string]$rec.Job.status
        if ($terminal -contains $st) { continue }
        switch -Regex ($st) {
            '^held$' { $held++ }
            '^waiting-quota$' { $wq++ }
            '^(running|admitted)$' { $active++ }
            default { $active++ }
        }
    }
    return [pscustomobject]@{ Active = $active; Held = $held; WaitingQuota = $wq }
}

function Format-BatonPassiveStatus {
    param(
        [string]$BatonHome,
        [string]$Cwd = $(Get-Location).Path
    )
    $ctx = Resolve-BatonProjectFromCwd -BatonHome $BatonHome -Cwd $Cwd
    $projLabel = if ($ctx.Registered) { [string]$ctx.Id } else { '(unregistered)' }
    $line1 = ('project  {0} · {1}' -f $projLabel, $ctx.Path)

    . (Join-Path $PSScriptRoot 'cursor-quota-lib.ps1')
    $cfg = Get-CursorQuotaConfig -BatonHome $BatonHome
    $claude = Read-ClaudeQuotaCache -BatonHome $BatonHome
    $cursor = Read-CursorQuotaCache -BatonHome $BatonHome
    $parts = [System.Collections.Generic.List[string]]::new()
    $cl = Format-ClaudeQuotaStatusLine -Cache $claude -Format detail -Config $cfg
    if ($cl) { [void]$parts.Add(($cl -replace '^\s+', '')) }
    $cu = Format-CursorQuotaStatusLine -Cache $cursor -Format detail -Config $cfg
    if ($cu) { [void]$parts.Add(($cu -replace '^\s+Cursor', 'Cursor')) }
    $line2 = if ($parts.Count -gt 0) {
        ('quota    ' + ($parts -join ' · '))
    } else {
        'quota    (no snapshot — run Claude Code or baton quota)'
    }

    $c = Get-BatonJobCounts -BatonHome $BatonHome
    $wqTxt = if ($c.WaitingQuota -gt 0) { " · $($c.WaitingQuota) waiting quota" } else { '' }
    $line3 = ('jobs     {0} active · {1} held{2}' -f $c.Active, $c.Held, $wqTxt)

    return @($line1, $line2, $line3)
}
```

- [ ] **Step 4: Run tests**

Run: `pwsh -NoProfile -File scripts/test-maestro-cli.ps1`  
Expected: C1–C8 PASS (other pre-existing tests may still expect room — fixed in Task 3)

- [ ] **Step 5: Commit**

```bash
git add scripts/maestro-lib.ps1 scripts/test-maestro-cli.ps1
git commit -m "feat(maestro): add passive status helpers for cwd project and job counts"
```

---

### Task 2: Passive status entry + admit verb

**Files:**
- Modify: `scripts/maestro.ps1`
- Modify: `scripts/verbs.yaml`
- Test: `scripts/test-maestro-cli.ps1`

**Interfaces:**
- Consumes: `Format-BatonPassiveStatus`, `Resolve-BatonProjectFromCwd`, `New-MaestroJob`
- Produces:
  - `Invoke-BatonPassiveStatus` — prints 3 lines + stderr hint; exit 0
  - `Invoke-MaestroAdmit` — `-Goal` mandatory; `-Project` optional; `-Fire`, `-Json`, `-MaxCostTier`

- [ ] **Step 1: Write failing tests**

```powershell
$passiveOut = & pwsh -NoProfile -File $maestro -NoWatch 2>&1 | Out-String
Assert 'P4 bare maestro is passive not room' (
    $LASTEXITCODE -eq 0 -and
    $passiveOut -match '(?m)^project\s' -and
    $passiveOut -notmatch 'type here|enter runs|╭'
)

$admitOut = & pwsh -NoProfile -File $maestro go --project baton --goal 'passive pivot' --json 2>&1 | Out-String
# baseline — go still works until admit wired in verbs (Task 4 uses baton admit)

$admitNew = & pwsh -NoProfile -File $maestro admit --project baton --goal 'from admit subcommand' --json 2>&1 | Out-String
Assert 'A1 maestro admit exit 0' ($LASTEXITCODE -eq 0)
$admitObj = $null
try { $admitObj = $admitNew | ConvertFrom-Json } catch { }
Assert 'A2 maestro admit returns mj- id' ($admitObj -and [string]$admitObj.id -match '^mj-')
```

- [ ] **Step 2: Run test — expect FAIL** on P4 and A1

Run: `pwsh -NoProfile -File scripts/test-maestro-cli.ps1`

- [ ] **Step 3: Implement `maestro.ps1` changes**

Add functions:

```powershell
function Invoke-BatonPassiveStatus {
    $lines = Format-BatonPassiveStatus -BatonHome $BatonHome
    foreach ($ln in $lines) { Write-Output $ln }
    [Console]::Error.WriteLine('hint     baton admit "…" · baton status · baton quota · baton --help')
}

function Invoke-MaestroAdmit {
    $text = $Goal
    if ([string]::IsNullOrWhiteSpace($text) -and $GoalFile) {
        if (-not (Test-Path -LiteralPath $GoalFile)) { throw "goal file not found: $GoalFile" }
        $text = Get-Content -LiteralPath $GoalFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        [Console]::Error.WriteLine('admit requires a goal: baton admit "refactor tests"')
        exit 2
    }
    $proj = $Project
    if ([string]::IsNullOrWhiteSpace($proj)) {
        $ctx = Resolve-BatonProjectFromCwd -BatonHome $BatonHome
        if (-not $ctx.Registered) {
            [Console]::Error.WriteLine('admit: cwd is not a registered project. Use --project <id>.')
            exit 2
        }
        $proj = [string]$ctx.Id
    }
    $seat = Get-MaestroConductorSeat -Provider $Provider
    $job = New-MaestroJob -BatonHome $BatonHome -Project $proj -Goal $text.Trim() `
        -MaxCostTier $MaxCostTier -Source 'cli' -Provider $seat.Name
    if ($Fire) {
        $fireScript = Join-Path $PSScriptRoot 'maestro-fire.ps1'
        & pwsh -NoProfile -File $fireScript -BatonHome $BatonHome | Out-Null
        $jobPath = Join-Path (Get-MaestroJobsDir -BatonHome $BatonHome) "$($job.id).json"
        if (Test-Path -LiteralPath $jobPath) {
            $job = Get-Content -LiteralPath $jobPath -Raw | ConvertFrom-Json
        }
    }
    if ($Json) { $job | ConvertTo-Json -Depth 6; return }
    Write-Output ("admitted {0} — {1}" -f $job.id, $job.goal)
}
```

Update switch:

```powershell
    { $_ -in @('', 'start') } {
        if ($Json) { Write-BatonSeatJson; exit 0 }
        Invoke-BatonPassiveStatus
        exit 0
    }
    'admit' { Invoke-MaestroAdmit; exit 0 }
    'status' { Invoke-MaestroStatus; exit 0 }
```

Remove or guard `Invoke-BatonRoom` — **do not call it** from any switch arm. Leave function body in file for now only if tests still reference scroll helpers; otherwise delete `Invoke-BatonRoom` and `Read-BatonRoomLine` in this task.

Update synopsis comment at top of `maestro.ps1` to describe passive status.

- [ ] **Step 4: Add verbs to `verbs.yaml`**

```yaml
# Bare `baton` (no verb) prints passive status — see maestro.ps1 Invoke-BatonPassiveStatus.
```

Insert after `quota` verb:

```yaml
  - name: admit
    summary: Queue a Maestro dark-factory job (project from cwd unless --project).
    class: hybrid
    runner: maestro.ps1
    json: true
    flag_aliases:
      --project: -Project
      --goal-file: -GoalFile
      --fire: -Fire
      --json: -Json
      --max-tier: -MaxCostTier
  - name: status
    summary: List Maestro jobs (factory queue and runners).
    class: engine
    runner: maestro.ps1
    json: true
    flag_aliases:
      --json: -Json
```

**Note:** `baton admit "goal"` passes `"goal"` as first tail arg — `maestro.ps1` must accept positional goal when subcommand is `admit`. Add param handling at top:

```powershell
# After $cmd = $Subcommand...
if ($cmd -eq 'admit' -and [string]::IsNullOrWhiteSpace($Goal) -and $args.Count -gt 0) {
    $Goal = ($args -join ' ').Trim()
}
```

Or dispatch from `baton.ps1` as `maestro.ps1 admit --goal "..."` — **prefer** runner receives `admit` as subcommand via injecting into maestro:

In `verbs.yaml` runner is `maestro.ps1` but baton dispatches with tail only. **Fix:** baton passes verb as first arg:

Current: `& pwsh -File maestro.ps1 @tail` for `baton admit "foo"` → tail is `"foo"` only.

**Required change in `baton.ps1`:** for runners that are `maestro.ps1`, prepend subcommand:

```powershell
if ([string]$verb.runner -eq 'maestro.ps1') {
    & pwsh -NoProfile -File $runnerPath $head @tail
} else {
    & pwsh -NoProfile -File $runnerPath @tail
}
```

And for bare baton, keep calling maestro with no args.

- [ ] **Step 5: Run tests**

Run: `pwsh -NoProfile -File scripts/test-maestro-cli.ps1`  
Expected: P4, A1, A2 PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/maestro.ps1 scripts/verbs.yaml scripts/baton.ps1 scripts/test-maestro-cli.ps1
git commit -m "feat(maestro): passive status default and admit subcommand"
```

---

### Task 3: Dispatcher + help + remove room tests

**Files:**
- Modify: `scripts/baton.ps1`
- Modify: `scripts/test-baton-cli.ps1`
- Modify: `scripts/test-maestro-cli.ps1`

- [ ] **Step 1: Write failing tests in `test-baton-cli.ps1`**

Replace H5 block:

```powershell
$bareOut = & pwsh -NoProfile -File $baton 2>&1 | Out-String
Assert 'H4 bare baton exit 0' ($LASTEXITCODE -eq 0)
Assert 'H5 bare baton is passive status' (
    $bareOut -match '(?m)^project\s' -and
    $bareOut -match '(?m)^quota\s' -and
    $bareOut -match '(?m)^jobs\s' -and
    $bareOut -notmatch '(?m)^\s+fleet\s'
)
Assert 'H5b bare baton is not the room' ($bareOut -notmatch 'type here|enter runs|╭')
```

Update help assertion:

```powershell
Assert 'H3b help mentions admit' ($helpOut -match '\badmit\b')
Assert 'H3c help does not say you are in Maestro room' ($helpOut -notmatch 'you are in Maestro')
```

- [ ] **Step 2: Update `Show-BatonHelp` in `baton.ps1`**

Replace opening lines per spec (passive status, admit, status, quota).

Implement maestro subcommand prepend (Task 2 step 4 note).

- [ ] **Step 3: Rewrite room tests in `test-maestro-cli.ps1`**

**Remove** or rewrite these assertions (they expect room):
- B1–B7 (bare room, scroll, type-here)
- R1–R5 (room worktrees, English admit via room) — keep **utterance parser** unit tests (U1, U2); keep **New-MaestroJob** tests (J1–J3)
- G-scroll tests (G9–G12) if they only served room card — keep lib unit tests that don't require room loop

**Add:**

```powershell
$bare = & pwsh -NoProfile -File $baton 2>&1 | Out-String
Assert 'B1 bare baton passive exit 0' ($LASTEXITCODE -eq 0 -and $bare -match '(?m)^project\s')
Assert 'B2 bare baton does not hang on redirected stdin' ($true)  # structural — same invoke, no pipe needed

$viaVerb = & pwsh -NoProfile -File $baton admit --project baton --goal 'via verb' --json 2>&1 | Out-String
Assert 'B3 baton admit creates job' ($LASTEXITCODE -eq 0 -and $viaVerb -match 'mj-')
```

- [ ] **Step 4: Delete dead room entry** — remove `Invoke-BatonRoom`, `Read-BatonRoomLine`, `Get-BatonRoomCardText`, `Write-BatonRoomCard` from `maestro.ps1` if no tests reference them. Keep `Format-MaestroRoomBanner` in lib only if other tests use it (G14 etc.); otherwise delete scroll/card formatters in a follow-up commit within this task.

- [ ] **Step 5: Run full CLI test suite**

Run:
```bash
pwsh -NoProfile -File scripts/test-maestro-cli.ps1
pwsh -NoProfile -File scripts/test-baton-cli.ps1
pwsh -NoProfile -File scripts/test-cursor-quota.ps1
```
Expected: all OK

- [ ] **Step 6: Commit**

```bash
git add scripts/baton.ps1 scripts/maestro.ps1 scripts/maestro-lib.ps1 scripts/test-baton-cli.ps1 scripts/test-maestro-cli.ps1
git commit -m "refactor(cli): demote Maestro room; bare baton is passive status"
```

---

### Task 4: Docs touch-up (in-repo pointers only)

**Files:**
- Modify: `scripts/maestro.ps1` (synopsis)
- Modify: `scripts/baton.ps1` (synopsis)
- Modify: `scripts/verbs.yaml` (header)

- [ ] **Step 1:** Update `.SYNOPSIS` / `.DESCRIPTION` blocks to describe passive status + admit.
- [ ] **Step 2:** Verify `baton --help` output reads correctly (manual or test H3b).
- [ ] **Step 3: Commit**

```bash
git add scripts/maestro.ps1 scripts/baton.ps1 scripts/verbs.yaml
git commit -m "docs(cli): help copy for harness pivot"
```

---

## Self-review checklist

| Spec requirement | Task |
|---|---|
| Bare `baton` 3-line status, exit 0 | Task 1–3 |
| No stdin blocking | Task 2 `Invoke-BatonPassiveStatus` |
| `baton admit` with cwd inference | Task 2 |
| `baton status` | Task 2 verbs.yaml |
| Room removed from default | Task 2–3 |
| Help copy updated | Task 3–4 |
| Tests updated | Task 1–3 |
| Decision B — no REPL launch | Global constraint (no code adds launch) |

**Out of S0 scope (S1 plan later):** MCP `baton_admit`, `baton_quota`, `baton_gate`; slash skills; `baton chat`.

---

## Execution handoff

Plan saved to `docs/superpowers/plans/2026-08-28-maestro-cli-harness-s0.md`.

**Default execution:** subagent-driven-development (Kevin's standing preference — do not offer inline execution).
