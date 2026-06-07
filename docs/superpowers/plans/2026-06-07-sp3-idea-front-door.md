# SP3 — `/idea` Front Door Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `/idea "<raw idea>"` — a job-less front door that runs research + a `/council` viability debate, drafts a reviewable concept doc, and on approval creates board-ready GitHub Issues on Project #5.

**Architecture:** Approach A — a thin command-prompt (`commands/idea.md`) that the conductor executes, stitching the existing `/research` and `/council` flows, backed by one new tested library `scripts/idea-lib.ps1` for the genuinely-new bits (workspace, concept-doc scaffold, issue-payload assembly, and the `gh` publish wrapper). The network boundary is split: `Build-IdeaIssues` is pure and fully unit-tested; `Publish-IdeaIssues` is a thin `gh` wrapper tested with a stubbed `gh`.

**Tech Stack:** PowerShell 7 (pwsh), `gh` CLI, Claude Code command-prompts. No Python changes.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/idea-lib.ps1` (create) | `Get-IdeasRoot`, `ConvertTo-IdeaSlug`, `New-IdeaWorkspace`, `New-IdeaConceptDoc`, `Build-IdeaIssues` (pure), `Publish-IdeaIssues` (gh) |
| `scripts/test-idea-lib.ps1` (create) | Single test script covering every `idea-lib.ps1` function; same Check/temp-dir/exit-code harness as `scripts/test-fleet-runs-bridge.ps1` |
| `commands/idea.md` (create) | The `/idea` command-prompt stitching the six stages |
| `scripts/bootstrap.ps1` (modify) | Deploy `idea-lib.ps1` (libs array, ~line 250) + `idea.md` (commands array, ~line 228) |
| `scripts/test-bootstrap.ps1` (modify) | Assert `idea-lib.ps1` + `idea.md` land in the deploy |

**Conventions to follow (verified against the repo):**
- Lib root resolver mirrors `Get-RunsRoot` in `scripts/runs-lib.ps1:5` — param > `$env:` override > `~/.claude/...` default. SP3 uses `$env:IDEAS_ROOT`.
- Test scripts use the harness in `scripts/test-fleet-runs-bridge.ps1:1-9,56-60`: `$ErrorActionPreference='Stop'`, dot-source the lib, a `Check($name,$cond)` function incrementing `$script:fail`, a temp dir under `[System.IO.Path]::GetTempPath()`, `try/finally` cleanup, and `exit 1`/`exit 0` at the end.
- **NEVER name a PowerShell variable `$args`** — it is an automatic variable. The SP2 build hit this exact bug (silent splat failure). Use `$ghArgs`.
- Returning arrays from functions uses the `return ,([object[]]$x)` idiom so 0/1-element results don't unroll to `$null`/scalar.

---

### Task 1: `New-IdeaWorkspace` (workspace + slug)

**Files:**
- Create: `scripts/idea-lib.ps1`
- Create (test): `scripts/test-idea-lib.ps1`

- [ ] **Step 1: Write the failing test**

Create `scripts/test-idea-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/idea-lib.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("idea-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    # --- Task 1: New-IdeaWorkspace ---
    $ws = New-IdeaWorkspace -Idea 'A Better Front Door!' -IdeasRoot $root -Timestamp '2026-06-07T10-00-00'
    Check 'workspace slug sanitized'   ($ws.slug -eq 'a-better-front-door')
    Check 'workspace path uses slug+ts'($ws.path -eq (Join-Path $root 'a-better-front-door-2026-06-07T10-00-00'))
    Check 'workspace dir created'      (Test-Path $ws.path)
    Check 'research subdir created'    (Test-Path (Join-Path $ws.path 'research'))
    Check 'council subdir created'     (Test-Path (Join-Path $ws.path 'council'))

    $ws2 = New-IdeaWorkspace -Idea '!!!' -IdeasRoot $root -Timestamp '2026-06-07T10-00-01'
    Check 'degenerate idea -> idea slug'($ws2.slug -eq 'idea')

    $longIdea = ('x' * 100)
    $ws3 = New-IdeaWorkspace -Idea $longIdea -IdeasRoot $root -Timestamp '2026-06-07T10-00-02'
    Check 'slug capped at 60'          ($ws3.slug.Length -le 60)

    $env:IDEAS_ROOT = $root
    $ws4 = New-IdeaWorkspace -Idea 'env rooted' -Timestamp '2026-06-07T10-00-03'
    Check 'honours $env:IDEAS_ROOT'    ($ws4.path -like "$root*")
    Remove-Item Env:IDEAS_ROOT
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: FAIL — aborts with `CommandNotFoundException` ("New-IdeaWorkspace is not recognized") because `idea-lib.ps1` doesn't exist / has no such function yet.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/idea-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
# Library for the /idea front door. Job-less: creates an idea workspace, scaffolds
# the concept doc, builds GitHub issue payloads (pure), and publishes them via gh.

function Get-IdeasRoot([string]$IdeasRoot) {
    if ($IdeasRoot) { return $IdeasRoot }
    if ($env:IDEAS_ROOT) { return $env:IDEAS_ROOT }
    return (Join-Path $HOME '.claude/ideas')
}

function ConvertTo-IdeaSlug([string]$Text) {
    if (-not $Text) { return 'idea' }
    $s = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim('-') }
    if (-not $s) { return 'idea' }
    return $s
}

function New-IdeaWorkspace {
    param(
        [Parameter(Mandatory)][string]$Idea,
        [string]$IdeasRoot,
        [string]$Timestamp
    )
    $root = Get-IdeasRoot $IdeasRoot
    $slug = ConvertTo-IdeaSlug $Idea
    if (-not $Timestamp) { $Timestamp = (Get-Date -Format 'yyyy-MM-ddTHH-mm-ss') }
    $path = Join-Path $root "$slug-$Timestamp"
    foreach ($sub in @('', 'research', 'council')) {
        $d = if ($sub) { Join-Path $path $sub } else { $path }
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    return [pscustomobject]@{ path = $path; slug = $slug }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: PASS — all Task 1 checks print `PASS:` and the script ends `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/idea-lib.ps1 scripts/test-idea-lib.ps1
git commit -m "feat(idea): New-IdeaWorkspace + slug for /idea front door"
```

---

### Task 2: `New-IdeaConceptDoc` (scaffold)

**Files:**
- Modify: `scripts/idea-lib.ps1`
- Modify (test): `scripts/test-idea-lib.ps1`

- [ ] **Step 1: Write the failing test**

In `scripts/test-idea-lib.ps1`, add this block inside the `try { }`, immediately after the Task 1 block (before the closing `}` of `try`):

```powershell
    # --- Task 2: New-IdeaConceptDoc ---
    $cdir = Join-Path $root 'concept-test'
    New-Item -ItemType Directory -Force -Path $cdir | Out-Null
    $cpath = Join-Path $cdir 'concept.md'
    New-IdeaConceptDoc -Path $cpath -Title 'Better Front Door' -Idea 'a better front door' -Date '2026-06-07'
    Check 'concept.md written'         (Test-Path $cpath)
    $c = Get-Content $cpath -Raw
    Check 'frontmatter title'          ($c -match '(?m)^title: Better Front Door$')
    Check 'frontmatter status draft'   ($c -match '(?m)^status: draft$')
    Check 'frontmatter source /idea'   ($c -match '(?m)^source: /idea$')
    Check 'has Problem header'         ($c -match '(?m)^## Problem$')
    Check 'has Viability header'       ($c -match '(?m)^## Viability verdict$')
    Check 'has Approach header'        ($c -match '(?m)^## Proposed approach$')
    Check 'has Risks header'           ($c -match '(?m)^## Risks & open questions$')
    Check 'has Decomposition header'   ($c -match '(?m)^## Decomposition$')
    Check 'has Out of scope header'    ($c -match '(?m)^## Out of scope$')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: FAIL — aborts with `CommandNotFoundException` for `New-IdeaConceptDoc`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/idea-lib.ps1`:

```powershell
function New-IdeaConceptDoc {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Title,
        [string]$Idea,
        [string]$Date
    )
    if (-not $Date) { $Date = (Get-Date -Format 'yyyy-MM-dd') }
    $ideaLine = if ($Idea) { $Idea } else { '(raw idea)' }
    $doc = @"
---
title: $Title
date: $Date
status: draft
source: /idea
---

# $Title

> Raw idea: $ideaLine

## Problem

_What hurts, and for whom._

## Viability verdict

_The debate's go / no-go / go-if, with confidence._

## Proposed approach

_The strongest version of the idea._

## Risks & open questions

_What could sink this; what we still don't know._

## Decomposition

_Epic-level tasks — each becomes a GitHub Issue._

## Out of scope

_What this explicitly does not include._
"@
    Set-Content -Path $Path -Value $doc -Encoding utf8
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/idea-lib.ps1 scripts/test-idea-lib.ps1
git commit -m "feat(idea): New-IdeaConceptDoc scaffold"
```

---

### Task 3: `Build-IdeaIssues` (pure payload assembly)

**Files:**
- Modify: `scripts/idea-lib.ps1`
- Modify (test): `scripts/test-idea-lib.ps1`

- [ ] **Step 1: Write the failing test**

In `scripts/test-idea-lib.ps1`, add this block inside `try { }` after the Task 2 block:

```powershell
    # --- Task 3: Build-IdeaIssues (pure) ---
    $tasks = @(
        [pscustomobject]@{ title='Wire the bridge'; description='Connect A to B.'; acceptance='Tests pass.'; tier='Tier-1' },
        [pscustomobject]@{ title='Add the view';    description='New panel.' }
    )
    $issues = Build-IdeaIssues -Tasks $tasks -ConceptPath '/x/concept.md' -ExtraLabels @('sp3')
    Check 'two issues built'           ($issues.Count -eq 2)
    Check 'title carried'              ($issues[0].title -eq 'Wire the bridge')
    Check 'desc in body'              ($issues[0].body -like '*Connect A to B.*')
    Check 'acceptance block present'   ($issues[0].body -like '*## Acceptance criteria*')
    Check 'backlink present'           ($issues[0].body -like '*From concept: /x/concept.md*')
    Check 'from:idea label always'     ($issues[0].labels -contains 'from:idea')
    Check 'tier label carried'         ($issues[0].labels -contains 'Tier-1')
    Check 'extra label carried'        ($issues[0].labels -contains 'sp3')
    Check 'no acceptance -> no block'  ($issues[1].body -notlike '*## Acceptance criteria*')
    Check 'labels de-duplicated'       (($issues[0].labels | Where-Object { $_ -eq 'from:idea' }).Count -eq 1)

    $none = Build-IdeaIssues -Tasks @() -ConceptPath '/x/concept.md'
    Check 'empty tasks -> empty'       ($none.Count -eq 0)

    $bad = Build-IdeaIssues -Tasks @([pscustomobject]@{ description='no title here' }) -ConceptPath '/x/concept.md' -WarningAction SilentlyContinue
    Check 'titleless task skipped'     ($bad.Count -eq 0)

    $special = Build-IdeaIssues -Tasks @([pscustomobject]@{ title='Fix "quotes" & <tags>'; description='100% done' }) -ConceptPath '/x/concept.md'
    Check 'special chars survive'      ($special[0].title -eq 'Fix "quotes" & <tags>')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: FAIL — aborts with `CommandNotFoundException` for `Build-IdeaIssues`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/idea-lib.ps1`:

```powershell
function Build-IdeaIssues {
    # Pure: turn epic-level task objects into GitHub issue payloads. No network.
    param(
        [object[]]$Tasks,
        [Parameter(Mandatory)][string]$ConceptPath,
        [string[]]$ExtraLabels
    )
    $out = @()
    foreach ($t in @($Tasks)) {
        $title = "$($t.title)".Trim()
        if (-not $title) { Write-Warning "Skipping task with no title."; continue }
        $bodyParts = @()
        if ($t.description) { $bodyParts += "$($t.description)".Trim() }
        if ($t.acceptance)  { $bodyParts += "## Acceptance criteria`n`n$("$($t.acceptance)".Trim())" }
        $bodyParts += "From concept: $ConceptPath"
        $body = ($bodyParts -join "`n`n")
        $labels = @('from:idea')
        if ($t.tier) { $labels += "$($t.tier)".Trim() }
        if ($ExtraLabels) { $labels += $ExtraLabels }
        $labels = @($labels | Where-Object { $_ } | Select-Object -Unique)
        $out += [pscustomobject]@{ title = $title; body = $body; labels = $labels }
    }
    return ,([object[]]$out)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/idea-lib.ps1 scripts/test-idea-lib.ps1
git commit -m "feat(idea): Build-IdeaIssues pure payload assembly"
```

---

### Task 4: `Publish-IdeaIssues` (gh wrapper, pre-flight + per-issue isolation)

**Files:**
- Modify: `scripts/idea-lib.ps1`
- Modify (test): `scripts/test-idea-lib.ps1`

- [ ] **Step 1: Write the failing test**

In `scripts/test-idea-lib.ps1`, add this block inside `try { }` after the Task 3 block. It shadows `gh` with a local function (PowerShell resolves functions before external commands), so no network is touched:

```powershell
    # --- Task 4: Publish-IdeaIssues (stubbed gh) ---
    # Stub: 'auth status' honours $script:authExit; 'issue create' fails for title 'FAILME'.
    $script:authExit = 0
    function gh {
        if ($args[0] -eq 'auth') { $global:LASTEXITCODE = $script:authExit; return 'ok' }
        $ti = [array]::IndexOf([object[]]$args, '--title')
        $title = if ($ti -ge 0) { $args[$ti + 1] } else { '' }
        if ($title -eq 'FAILME') { $global:LASTEXITCODE = 1; return 'boom' }
        $global:LASTEXITCODE = 0
        return 'https://github.com/Ryfter/coding-agent-orchestrator/issues/123'
    }

    # happy path: two issues created
    $okIssues = @(
        [pscustomobject]@{ title='Alpha'; body='a'; labels=@('from:idea') },
        [pscustomobject]@{ title='Beta';  body='b'; labels=@('from:idea','Tier-2') }
    )
    $res = Publish-IdeaIssues -Issues $okIssues
    Check 'two results returned'       ($res.Count -eq 2)
    Check 'first ok'                   ($res[0].ok -eq $true)
    Check 'number parsed'              ($res[0].number -eq 123)

    # per-issue isolation: middle one fails, others still created
    $mixed = @(
        [pscustomobject]@{ title='Alpha';  body='a'; labels=@('from:idea') },
        [pscustomobject]@{ title='FAILME'; body='x'; labels=@('from:idea') },
        [pscustomobject]@{ title='Gamma';  body='g'; labels=@('from:idea') }
    )
    $res2 = Publish-IdeaIssues -Issues $mixed
    Check 'three results returned'     ($res2.Count -eq 3)
    Check 'failing one flagged'        ($res2[1].ok -eq $false -and $res2[1].error)
    Check 'after-failure one still ok' ($res2[2].ok -eq $true)

    # unauth pre-flight: nothing created, single preflight error
    $script:authExit = 1
    $res3 = Publish-IdeaIssues -Issues $okIssues
    Check 'unauth -> one preflight row'($res3.Count -eq 1)
    Check 'unauth row not ok'          ($res3[0].ok -eq $false)
    Check 'unauth error mentions auth' ($res3[0].error -like '*auth*')
    $script:authExit = 0

    Remove-Item Function:gh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: FAIL — aborts with `CommandNotFoundException` for `Publish-IdeaIssues`.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/idea-lib.ps1`. Note `$ghArgs` (never `$args` — it is an automatic variable; the SP2 build was broken by exactly this):

```powershell
function Publish-IdeaIssues {
    # Thin gh wrapper. Pre-flight auth check stops before creating anything;
    # then best-effort per issue so one failure never aborts the rest.
    param(
        [object[]]$Issues,
        [string]$Project,
        [string]$Repo
    )
    $authOk = $true
    try { & gh auth status 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $authOk = $false } }
    catch { $authOk = $false }
    if (-not $authOk) {
        return ,([object[]]@([pscustomobject]@{ title = '(preflight)'; number = $null; ok = $false; error = 'gh not authenticated' }))
    }
    $results = @()
    foreach ($iss in @($Issues)) {
        $tmp = $null
        try {
            $tmp = New-TemporaryFile
            Set-Content -Path $tmp -Value $iss.body -Encoding utf8
            $ghArgs = @('issue', 'create', '--title', $iss.title, '--body-file', "$tmp")
            foreach ($l in @($iss.labels)) { $ghArgs += @('--label', $l) }
            if ($Repo)    { $ghArgs += @('--repo', $Repo) }
            if ($Project) { $ghArgs += @('--project', $Project) }
            $url = (& gh @ghArgs 2>&1 | Select-Object -Last 1)
            if ($LASTEXITCODE -ne 0) { throw "gh issue create failed: $url" }
            $num = if ("$url" -match '/(\d+)\s*$') { [int]$Matches[1] } else { $null }
            $results += [pscustomobject]@{ title = $iss.title; number = $num; ok = $true; error = $null }
        }
        catch {
            $results += [pscustomobject]@{ title = $iss.title; number = $null; ok = $false; error = "$_" }
        }
        finally {
            if ($tmp -and (Test-Path $tmp)) { Remove-Item -Force $tmp }
        }
    }
    return ,([object[]]$results)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-idea-lib.ps1`
Expected: PASS — `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/idea-lib.ps1 scripts/test-idea-lib.ps1
git commit -m "feat(idea): Publish-IdeaIssues gh wrapper with preflight + isolation"
```

---

### Task 5: `commands/idea.md` (the front-door command-prompt)

**Files:**
- Create: `commands/idea.md`

This is a Claude Code command-prompt (markdown the conductor executes), not executable code — there is no unit test; it is verified by the bootstrap smoke (Task 6) and by reading it for accuracy against the libs.

- [ ] **Step 1: Create the command file**

Create `commands/idea.md`:

````markdown
---
description: The idea front door. Turns a raw idea into board-ready GitHub Issues via research + a /council viability debate + a reviewable concept doc, with one human gate. Job-less.
argument-hint: "<raw idea>" [--no-research] [--providers a,b,c] [--tier free,local]
---

# /idea

Turn a raw idea into board-ready GitHub Issues. Job-less — this runs *before* you
commit to a job; its output (issues) becomes the backlog. Exactly one human gate:
you approve the concept doc before any issue is created.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted raw idea + optional `--no-research`,
   `--providers a,b,c`, `--tier free,local`. Empty idea → stop with:
   *"Usage: /idea \"<raw idea>\" [--no-research] [--providers …] [--tier …]"*.

2. **Create the idea workspace** (job-less; sibling of `~/.claude/ensembles/`):

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $ws = New-IdeaWorkspace -Idea '<raw idea>'
   $ws.path
   ```

3. **KB pre-fetch (prior art).** Query the embedded KB for related work and keep
   the hits to seed research + the concept doc. Graceful no-op if the index is
   empty or errors.

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $kbHits = Invoke-KbSearch -Query '<raw idea>' -K 3 -SnippetChars 600 2>$null
   ```

4. **Research (skip if `--no-research`).** Run a research ensemble on the idea,
   writing into the workspace's `research/` dir, then synthesize. Resolve the
   roster and run exactly as `/research` does (explicit `--providers` > `--tier` >
   `Get-FleetResearchDefault`), but the output dir is the idea workspace, not a
   job phase:

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $outDir = Join-Path $ws.path 'research'
   # roster resolution + Invoke-FleetEnsemble + synthesis.md exactly as /research steps 3-6,
   # prepending the KB hits from step 3 as a "Relevant prior knowledge" block.
   ```

   Write `research/synthesis.md`.

5. **Viability debate.** Run a two-round `/council` on the framed question
   *"Is this worth building, and what is the strongest version of it?"*, seeded
   with the research synthesis, writing into the workspace's `council/` dir:

   ```powershell
   . "$HOME/.claude/scripts/council-lib.ps1"
   $outDir = Join-Path $ws.path 'council'
   # roster + Build-CouncilR1Tasks/Build-CouncilR2Tasks + Invoke-FleetEnsembleTasks
   # exactly as /council steps 2-7, writing round1/, round2/, and synthesis.md.
   ```

   **Quorum abort is non-fatal here.** If the council can't reach quorum, do NOT
   stop — record that the debate was thin and continue to the concept doc with a
   *low-confidence viability* note.

6. **Draft the concept doc.** Scaffold it, then fill every section from the
   research + council syntheses (and the KB hits). Be honest in **Viability
   verdict** — flag low confidence when research/debate was thin.

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $concept = Join-Path $ws.path 'concept.md'
   New-IdeaConceptDoc -Path $concept -Title '<short idea title>' -Idea '<raw idea>'
   ```

   Fill the sections (Problem · Viability verdict · Proposed approach · Risks &
   open questions · **Decomposition** · Out of scope). In **Decomposition**, write
   the epic-level task list — each task gets a one-line title, 2-3 sentences of
   scope, acceptance criteria, and an optional Tier label. Then **present
   `concept.md` inline**.

7. **Human gate — approve / revise / drop.**
   - *revise* → edit the doc per feedback and re-present (loop).
   - *drop* → stop; the workspace + concept doc stay as a record.
   - *approve* → continue to step 8.

8. **Land on the board.** Build issue payloads from the Decomposition task list and
   create them. Build the `$tasks` array from the concept doc's Decomposition
   (one entry per task, fields `title`, `description`, `acceptance`, optional
   `tier`):

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $tasks = @(
       [pscustomobject]@{ title='<task 1 title>'; description='<scope>'; acceptance='<criteria>'; tier='Tier-2' }
       # ... one entry per Decomposition task
   )
   $issues = Build-IdeaIssues -Tasks $tasks -ConceptPath $concept
   $results = Publish-IdeaIssues -Issues $issues -Project 'coding-agent-orchestrator'
   $results | Format-Table title, number, ok, error -AutoSize
   ```

   If the first result is the `(preflight)` row with `ok = $false`, tell the user
   `gh` isn't authenticated (suggest `! gh auth login`) and that **no issues were
   created**. Otherwise report which issues landed (by number) and which failed.

9. **Write the issue numbers back into `concept.md`** under the Decomposition
   section (e.g. append `- #<number> — <title>` for each created issue) so the
   doc records where the tasks went.

10. **Decision capture (judgment).** If the viability debate produced a genuine
    go / no-go / architectural decision with real alternatives, capture it via the
    file-based decision intake (see `CLAUDE.md`). Skip for routine ideas.

## Arguments

$ARGUMENTS
````

- [ ] **Step 2: Sanity-check the command references**

Run (verifies every function the command calls actually exists in the deployed libs):

```bash
pwsh -NoProfile -Command ". scripts/idea-lib.ps1; Get-Command New-IdeaWorkspace, New-IdeaConceptDoc, Build-IdeaIssues, Publish-IdeaIssues | Select-Object Name"
```
Expected: all four names listed, no errors.

- [ ] **Step 3: Commit**

```bash
git add commands/idea.md
git commit -m "feat(idea): /idea front-door command-prompt"
```

---

### Task 6: Deploy via bootstrap + smoke

**Files:**
- Modify: `scripts/bootstrap.ps1` (libs array ~line 250; commands array ~line 228)
- Modify: `scripts/test-bootstrap.ps1`

- [ ] **Step 1: Write the failing smoke assertions**

First read the existing assertions to match the file's style:

Run: `pwsh -NoProfile -Command "Get-Content scripts/test-bootstrap.ps1 | Select-String -Pattern 'idea|runs-lib|research.md' -SimpleMatch"`
Expected: shows existing `runs-lib`/`research.md`-style checks (so you can mirror them); shows **no** `idea` matches yet.

In `scripts/test-bootstrap.ps1`, mirror the existing deployed-file assertions (the ones that confirm a lib + a command landed under the temp `$claudeDir`) by adding equivalents for `idea-lib.ps1` and `idea.md`. Use the same assertion helper and the same `$claudeDir`/`scripts` + `commands` path variables the surrounding checks already use. For example, alongside the existing `runs-lib.ps1` check add:

```powershell
Check 'idea-lib.ps1 deployed' (Test-Path (Join-Path $claudeDir 'scripts/idea-lib.ps1'))
Check 'idea.md deployed'      (Test-Path (Join-Path $claudeDir 'commands/idea.md'))
```

(Match the exact `Check`/assertion name and path variables already used in that file; the line above is the shape, not necessarily the verbatim variable names.)

- [ ] **Step 2: Run smoke to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — `idea-lib.ps1 deployed` / `idea.md deployed` fail because bootstrap doesn't deploy them yet.

- [ ] **Step 3: Add idea files to the deploy arrays**

In `scripts/bootstrap.ps1`, add `'idea-lib.ps1'` to the libs `foreach` array (currently ends `…, 'runs-lib.ps1', 'statusline-feed.ps1', 'fleet-runs-bridge.ps1')` near line 250):

```powershell
foreach ($script in @('job-lib.ps1', 'consolidate-lessons.ps1', 'parse-otel.ps1', 'fleet-lib.ps1', 'fleet-doctor.ps1', 'fleet-ensemble.ps1', 'six-hats-lib.ps1', 'council-lib.ps1', 'code-lib.ps1', 'kb-lib.ps1', 'decisions-lib.ps1', 'consolidate-decisions.ps1', 'cost-lib.ps1', 'runs-lib.ps1', 'statusline-feed.ps1', 'fleet-runs-bridge.ps1', 'idea-lib.ps1')) {
```

And add `'idea.md'` to the slash-commands `foreach` array (near line 228), in the research-family line:

```powershell
    'fleet.md','ensemble.md','research.md','six-hats.md','council.md','idea.md',
```

- [ ] **Step 4: Run smoke to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — including the two new `idea` checks.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(idea): deploy idea-lib.ps1 + idea.md via bootstrap"
```

---

## Final Gate (run before finishing the branch)

All must pass:

- [ ] `pwsh -NoProfile -File scripts/test-idea-lib.ps1` → `ALL PASS`
- [ ] `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → all checks pass
- [ ] Full PowerShell suite — run every `scripts/test-*.ps1` (the SP2 gate ran 5 suites; idea-lib adds one). Each exits 0.
- [ ] Python suite unchanged but verify still green: `python -m pytest dashboard kb -q`
- [ ] Bootstrap dry-run smoke: `pwsh -NoProfile -File scripts/bootstrap.ps1 -DryRun` completes without error and reports it *would* deploy `idea-lib.ps1` + `idea.md`.

Then use **superpowers:finishing-a-development-branch** to merge through the gated flow.
