# Conductor Choices Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first Choices slice — `$BATON_HOME/choices/` one-JSON-per-card store, draft→admit→answer state machine, project-at-a-time cursor, and `baton choices` CLI (`brief` / `next` / `answer` / `list` / `draft` / `admit` / `reject`).

**Architecture:** Pure PowerShell lib (`choices-lib.ps1`) owns schema, transitions, ordering, and cursor. Thin runner (`fleet-choices.ps1`) parses subcommands and prints human or `--json` output. Dispatcher picks it up via `verbs.yaml`. No Maestro LLM, no Portal, no auto-unblock, no audit JSONL.

**Tech Stack:** PowerShell 7, box-private JSON under `$BATON_HOME/choices/`, existing `baton.ps1` + `verbs.yaml` dispatcher, hermetic `pwsh` Assert tests (same pattern as `test-decisions-lib.ps1`).

**Spec:** `docs/superpowers/specs/2026-08-21-conductor-choices-queue-design.md`

## Global Constraints

- Box-private only: `$BATON_HOME/choices/` — never commit real choice cards into the Baton repo.
- Tests hermetic: temp `$env:BATON_HOME`, `try/finally` restore; never touch real `~/.baton`.
- Closed status enum: `draft|admitted|answered|rejected|superseded` — refuse unknown.
- `schema_version` must be `1` for this slice — refuse other versions.
- All writes `utf8NoBOM`; `ConvertTo-Json -Depth 8`; re-stringify ISO dates with `'o'` on round-trip.
- CLI user errors: `[Console]::Error.WriteLine(...)` + `exit 2` — not `Write-Error` under `Stop`.
- Never name variables `$args`, `$input`, `$event`, `$matches`, `$host`, `$pid`.
- Mutations only through lib functions used by the runner — no parallel markdown queues.
- Soft-park is recorded as `blocks` on the card; do **not** flip Maestro job to `held` in this slice.
- YAGNI: no Portal, no audit JSONL, no Grimdex promotion, no fleet-go auto-unblock.

## File map

| File | Responsibility |
|---|---|
| `scripts/choices-lib.ps1` | Schema, IO, transitions, sort, cursor, brief text |
| `scripts/test-choices-lib.ps1` | Hermetic unit tests for the lib |
| `scripts/fleet-choices.ps1` | CLI runner (`baton choices …`) |
| `scripts/verbs.yaml` | Register `choices` verb |
| `commands/choices.md` | Slash-command / Mouth instructions |
| `scripts/baton-home.ps1` | Ensure `choices/` dir in `Initialize-BatonHome` |
| `docs/COMMANDS.md` | Short `/baton:choices` entry (fold into Task 6) |

---

### Task 1: Choice IO + schema validation

**Files:**
- Create: `scripts/choices-lib.ps1`
- Create: `scripts/test-choices-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` from `scripts/baton-home.ps1`
- Produces:
  - `Get-ChoicesDir([string]$BatonHome) -> string`
  - `New-ChoiceId() -> string` (`ch-` + 12 hex chars)
  - `Test-ChoiceSchema($Choice) -> void` (throws on invalid)
  - `Read-Choice([string]$Id, [string]$BatonHome) -> object`
  - `Write-Choice($Choice, [string]$BatonHome) -> string` (path; atomic temp+move)
  - `Get-ChoicePath([string]$Id, [string]$BatonHome) -> string`

- [ ] **Step 1: Write the failing test file**

```powershell
#!/usr/bin/env pwsh
# scripts/test-choices-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'choices-lib.ps1')

$script:failures = 0
function Assert([string]$label, [bool]$cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-choices-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
try {
    $dir = Get-ChoicesDir -BatonHome $tmp
    Assert 'T1 choices dir path ends with choices' ($dir -match '[\\/]choices$')
    Assert 'T1b dir created on Get-ChoicesDir' (Test-Path -LiteralPath $dir)

    $id = New-ChoiceId
    Assert 'T2 id prefix ch-' ($id -match '^ch-[0-9a-f]{12}$')

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $good = [ordered]@{
        schema_version = 1
        id             = $id
        status         = 'draft'
        project        = 'canvas-toolchain'
        title          = 'Publish v2.2.0?'
        question       = 'Unblock npm publish?'
        options        = @(
            @{ id = 'yes'; label = 'Publish'; summary = 'Tag and publish' }
            @{ id = 'no'; label = 'Defer'; summary = 'Wait' }
        )
        recommendation = @{ option_id = 'yes'; why = 'Professors blocked' }
        evidence       = @('docs/foo.md')
        created_at     = $now
        updated_at     = $now
    }
    $path = Write-Choice -Choice $good -BatonHome $tmp
    Assert 'T3 file written' (Test-Path -LiteralPath $path)
    $back = Read-Choice -Id $id -BatonHome $tmp
    Assert 'T4 round-trip id' ($back.id -eq $id)
    Assert 'T5 round-trip status' ($back.status -eq 'draft')

    $threw = $false
    try {
        $badHash = [ordered]@{}
        foreach ($p in $good.Keys) { $badHash[$p] = $good[$p] }
        $badHash.status = 'waiting'
        Test-ChoiceSchema -Choice $badHash
    } catch { $threw = $true }
    Assert 'T6 unknown status throws' $threw

    $threw2 = $false
    try {
        $badVer = [ordered]@{}
        foreach ($p in $good.Keys) { $badVer[$p] = $good[$p] }
        $badVer.schema_version = 99
        Test-ChoiceSchema -Choice $badVer
    } catch { $threw2 = $true }
    Assert 'T7 bad schema_version throws' $threw2
}
finally {
    if ($null -eq $prev) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prev }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "FAILED: $failures"; exit 1 }
Write-Host 'ALL PASS'
exit 0
```

- [ ] **Step 2: Run test — expect fail (lib missing)**

Run: `pwsh -NoProfile -File scripts/test-choices-lib.ps1`  
Expected: FAIL — cannot dot-source `choices-lib.ps1` or functions missing.

- [ ] **Step 3: Implement minimal `choices-lib.ps1`**

```powershell
# scripts/choices-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')

$script:ChoiceStatuses = @('draft', 'admitted', 'answered', 'rejected', 'superseded')
$script:ChoiceSchemaVersion = 1

function Get-ChoicesDir {
    param([string]$BatonHome = (Get-BatonHome))
    $dir = Join-Path $BatonHome 'choices'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    return $dir
}

function New-ChoiceId {
    return ('ch-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Get-ChoicePath {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    if ($Id -notmatch '^ch-[0-9a-f]{12}$') { throw "invalid choice id: $Id" }
    return (Join-Path (Get-ChoicesDir -BatonHome $BatonHome) "$Id.json")
}

function Test-ChoiceSchema {
    param([Parameter(Mandatory)]$Choice)
    if ($null -eq $Choice) { throw 'choice is null' }
    $ver = [int]$Choice.schema_version
    if ($ver -ne $script:ChoiceSchemaVersion) {
        throw "unsupported schema_version: $ver (want $($script:ChoiceSchemaVersion))"
    }
    $st = [string]$Choice.status
    if ($st -notin $script:ChoiceStatuses) { throw "invalid status: $st" }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.id)) { throw 'id required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.project)) { throw 'project required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.title)) { throw 'title required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.question)) { throw 'question required' }
    $opts = @($Choice.options)
    if ($opts.Count -lt 2) { throw 'options must have at least 2 entries' }
    foreach ($o in $opts) {
        if ([string]::IsNullOrWhiteSpace([string]$o.id)) { throw 'option.id required' }
        if ([string]::IsNullOrWhiteSpace([string]$o.label)) { throw 'option.label required' }
    }
    if ($null -eq $Choice.recommendation -or
        [string]::IsNullOrWhiteSpace([string]$Choice.recommendation.option_id)) {
        throw 'recommendation.option_id required'
    }
    if ($null -eq $Choice.evidence) { throw 'evidence required (may be empty array)' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.created_at)) { throw 'created_at required' }
    if ([string]::IsNullOrWhiteSpace([string]$Choice.updated_at)) { throw 'updated_at required' }
    if ($st -in @('admitted', 'answered', 'rejected', 'superseded')) {
        if ([string]$Choice.priority -notin @('P0', 'P1', 'P2')) {
            throw "priority P0|P1|P2 required when status=$st"
        }
    }
}

function Write-Choice {
    param(
        [Parameter(Mandatory)]$Choice,
        [string]$BatonHome = (Get-BatonHome)
    )
    Test-ChoiceSchema -Choice $Choice
    $path = Get-ChoicePath -Id ([string]$Choice.id) -BatonHome $BatonHome
    $tmp = "$path.tmp"
    $json = ($Choice | ConvertTo-Json -Depth 8)
    Set-Content -LiteralPath $tmp -Value $json -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $path
}

function Read-Choice {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    $path = Get-ChoicePath -Id $Id -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $path)) { throw "choice not found: $Id" }
    $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Test-ChoiceSchema -Choice $obj
    return $obj
}
```

- [ ] **Step 4: Run test — expect ALL PASS**

Run: `pwsh -NoProfile -File scripts/test-choices-lib.ps1`  
Expected: `ALL PASS`

- [ ] **Step 5: Commit**

```bash
git add scripts/choices-lib.ps1 scripts/test-choices-lib.ps1
git commit -m "feat(choices): schema validation and atomic choice file IO"
```

---

### Task 2: Draft / admit / reject transitions

**Files:**
- Modify: `scripts/choices-lib.ps1`
- Modify: `scripts/test-choices-lib.ps1`

**Interfaces:**
- Consumes: Task 1 IO helpers
- Produces:
  - `New-ChoiceDraft(...) -> object` (writes `draft`, returns choice)
  - `Set-ChoiceAdmitted([string]$Id, [string]$Priority='P1', ...) -> object`
  - `Set-ChoiceRejected([string]$Id, ...) -> object`
  - Priority enum: `P0|P1|P2` only

- [ ] **Step 1: Append failing tests** (inside the same `try` block, before `finally`)

```powershell
    $d = New-ChoiceDraft `
        -Project 'bookprofile' `
        -Title 'A/B/C surface' `
        -Question 'Public, personal, or hybrid?' `
        -Options @(
            @{ id = 'a'; label = 'Public'; summary = 'Static only' }
            @{ id = 'b'; label = 'Personal'; summary = 'Local only' }
            @{ id = 'c'; label = 'Hybrid'; summary = 'Local then publish' }
        ) `
        -RecommendationOptionId 'c' `
        -RecommendationWhy 'Match free stack + share later' `
        -Evidence @('BookProfile/docs/...') `
        -Blocks 'bp-scaffold' `
        -BatonHome $tmp
    Assert 'T8 draft status' ($d.status -eq 'draft')
    Assert 'T8b blocks set' ($d.blocks -eq 'bp-scaffold')

    $a = Set-ChoiceAdmitted -Id $d.id -Priority 'P0' -BatonHome $tmp
    Assert 'T9 admitted' ($a.status -eq 'admitted')
    Assert 'T9b priority P0' ($a.priority -eq 'P0')
    Assert 'T9c admitted_at set' (-not [string]::IsNullOrWhiteSpace([string]$a.admitted_at))

    $threwAdmit = $false
    try { Set-ChoiceAdmitted -Id $d.id -BatonHome $tmp } catch { $threwAdmit = $true }
    Assert 'T10 double admit throws' $threwAdmit

    $d2 = New-ChoiceDraft -Project 'x' -Title 't' -Question 'q' `
        -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
        -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp
    $r = Set-ChoiceRejected -Id $d2.id -BatonHome $tmp
    Assert 'T11 rejected' ($r.status -eq 'rejected')
```

- [ ] **Step 2: Run test — expect FAIL on missing functions**

Run: `pwsh -NoProfile -File scripts/test-choices-lib.ps1`  
Expected: FAIL — `New-ChoiceDraft` not found.

- [ ] **Step 3: Implement transitions in `choices-lib.ps1`**

```powershell
function New-ChoiceDraft {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][object[]]$Options,
        [Parameter(Mandatory)][string]$RecommendationOptionId,
        [Parameter(Mandatory)][string]$RecommendationWhy,
        [object[]]$Evidence = @(),
        [string]$Blocks,
        [string]$BatonHome = (Get-BatonHome)
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $id = New-ChoiceId
    $choice = [ordered]@{
        schema_version = $script:ChoiceSchemaVersion
        id             = $id
        status         = 'draft'
        project        = $Project
        title          = $Title
        question       = $Question
        options        = @($Options)
        recommendation = @{ option_id = $RecommendationOptionId; why = $RecommendationWhy }
        evidence       = @($Evidence)
        created_at     = $now
        updated_at     = $now
    }
    if (-not [string]::IsNullOrWhiteSpace($Blocks)) { $choice.blocks = $Blocks }
    [void](Write-Choice -Choice $choice -BatonHome $BatonHome)
    return (Read-Choice -Id $id -BatonHome $BatonHome)
}

function Set-ChoiceAdmitted {
    param(
        [Parameter(Mandatory)][string]$Id,
        [ValidateSet('P0','P1','P2')][string]$Priority = 'P1',
        [string]$BatonHome = (Get-BatonHome)
    )
    $c = Read-Choice -Id $Id -BatonHome $BatonHome
    if ([string]$c.status -ne 'draft') { throw "admit requires draft; got $($c.status)" }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $c.status = 'admitted'
    $c.priority = $Priority
    $c.admitted_at = $now
    $c.updated_at = $now
    [void](Write-Choice -Choice $c -BatonHome $BatonHome)
    return (Read-Choice -Id $Id -BatonHome $BatonHome)
}

function Set-ChoiceRejected {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BatonHome = (Get-BatonHome)
    )
    $c = Read-Choice -Id $Id -BatonHome $BatonHome
    if ([string]$c.status -notin @('draft', 'admitted')) {
        throw "reject requires draft|admitted; got $($c.status)"
    }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ([string]::IsNullOrWhiteSpace([string]$c.priority)) { $c.priority = 'P1' }
    $c.status = 'rejected'
    $c.updated_at = $now
    [void](Write-Choice -Choice $c -BatonHome $BatonHome)
    return (Read-Choice -Id $Id -BatonHome $BatonHome)
}
```

- [ ] **Step 4: Run tests — ALL PASS**

Run: `pwsh -NoProfile -File scripts/test-choices-lib.ps1`

- [ ] **Step 5: Commit**

```bash
git add scripts/choices-lib.ps1 scripts/test-choices-lib.ps1
git commit -m "feat(choices): draft, admit, and reject transitions"
```

---

### Task 3: List / sort / cursor / next

**Files:**
- Modify: `scripts/choices-lib.ps1`
- Modify: `scripts/test-choices-lib.ps1`

**Interfaces:**
- Produces:
  - `Get-Choices([string]$BatonHome, [string]$Project, [string]$Status) -> object[]`
  - `Get-AdmittedProjectOrder([string]$BatonHome) -> string[]`
  - `Get-Cursor([string]$BatonHome) -> object`
  - `Set-Cursor($Cursor, [string]$BatonHome) -> void`
  - `Reset-ChoicesBriefCursor([string]$BatonHome) -> object`
  - `Get-NextAdmittedChoice([string]$BatonHome) -> object|$null`
  - `Move-ChoiceCursorAfterAnswer([string]$BatonHome) -> object|$null`

**Sort rules (spec):**
- Project order: among projects with ≥1 admitted, sort by best priority on any admitted card (`P0` before `P1` before `P2`), then oldest `admitted_at` among that project’s best-priority cards.
- Within project: admitted cards by priority then `admitted_at`.
- Cursor stays on project until no admitted remain.
- Scan only `ch-*.json` (ignore `_cursor.json`).

- [ ] **Step 1: Append failing tests**

```powershell
    function New-Admitted([string]$proj, [string]$pri, [datetime]$when) {
        $x = New-ChoiceDraft -Project $proj -Title "$proj $pri" -Question 'q' `
            -Options @(@{id='a';label='A';summary='a'},@{id='b';label='B';summary='b'}) `
            -RecommendationOptionId 'a' -RecommendationWhy 'w' -Evidence @() -BatonHome $tmp
        $obj = Set-ChoiceAdmitted -Id $x.id -Priority $pri -BatonHome $tmp
        $obj.admitted_at = $when.ToUniversalTime().ToString('o')
        $obj.updated_at = $obj.admitted_at
        [void](Write-Choice -Choice $obj -BatonHome $tmp)
        return $obj
    }
    $t0 = [datetime]'2026-08-21T10:00:00Z'
    $t1 = [datetime]'2026-08-21T11:00:00Z'
    $t2 = [datetime]'2026-08-21T12:00:00Z'
    $bp = New-Admitted 'bookprofile' 'P1' $t1
    $ct = New-Admitted 'canvas-toolchain' 'P0' $t2
    $af = New-Admitted 'atomicforge' 'P0' $t0
    $order = @(Get-AdmittedProjectOrder -BatonHome $tmp)
    Assert 'T12 P0 projects before P1' ($order[-1] -eq 'bookprofile')
    Assert 'T12b older P0 first' ($order[0] -eq 'atomicforge' -and $order[1] -eq 'canvas-toolchain')

    $cur = Reset-ChoicesBriefCursor -BatonHome $tmp
    Assert 'T13 cursor project atomicforge' ($cur.active_project -eq 'atomicforge')
    $n1 = Get-NextAdmittedChoice -BatonHome $tmp
    Assert 'T14 next is af card' ($n1.project -eq 'atomicforge')
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement list/sort/cursor helpers**

Priority rank: `P0=0, P1=1, P2=2`.  
`_cursor.json`: `{ schema_version:1, active_project, current_id, project_order:[] }`.  
`Get-NextAdmittedChoice`: if `current_id` still admitted, return it; else first admitted in `active_project`; else advance project in `project_order`.

- [ ] **Step 4: Run — ALL PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/choices-lib.ps1 scripts/test-choices-lib.ps1
git commit -m "feat(choices): admitted ordering and project-at-a-time cursor"
```

---

### Task 4: Answer + brief formatter

**Files:**
- Modify: `scripts/choices-lib.ps1`
- Modify: `scripts/test-choices-lib.ps1`

**Interfaces:**
- Produces:
  - `Set-ChoiceAnswered([string]$Id, [string]$OptionId, [string]$FreeText, [string]$Note, [string]$BatonHome) -> object`
  - `Format-ChoicesBrief([string]$BatonHome) -> string` (pure read of admitted cards; no cursor mutation)
  - `Format-ChoiceCard($Choice) -> string`

**Answer rules:** require `option_id` **or** non-empty `free_text`; if `option_id`, must match an option; status must be `admitted`; set `answered` + `answered_at`; caller/runner then `Move-ChoiceCursorAfterAnswer`.

**Brief:** group by `Get-AdmittedProjectOrder`; per project list title, question, options, recommendation, evidence. Runner calls `Reset-ChoicesBriefCursor` then `Format-ChoicesBrief`.

- [ ] **Step 1: Failing tests**

```powershell
    $ans = Set-ChoiceAnswered -Id $af.id -OptionId 'a' -BatonHome $tmp
    Assert 'T15 answered' ($ans.status -eq 'answered')
    Assert 'T15b answer option' ($ans.answer.option_id -eq 'a')
    $threwOpt = $false
    try { Set-ChoiceAnswered -Id $ct.id -OptionId 'nope' -BatonHome $tmp } catch { $threwOpt = $true }
    Assert 'T16 bad option throws' $threwOpt

    $brief = Format-ChoicesBrief -BatonHome $tmp
    Assert 'T17 brief names canvas-toolchain' ($brief -match 'canvas-toolchain')
    Assert 'T17c brief only admitted projects' ($brief -notmatch '(?m)^##\s+atomicforge')
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement `Set-ChoiceAnswered`, `Format-ChoicesBrief`, `Format-ChoiceCard`**

`Format-ChoiceCard` shape:

```
[ch-xxxxxxxxxxxx] canvas-toolchain · P0 · admitted
Publish v2.2.0?
Unblock npm publish?

Options:
  [yes] Publish — Tag and publish
  [no] Defer — Wait

Recommended: yes — Professors blocked
Evidence: docs/foo.md
Blocks: (none)
```

- [ ] **Step 4: Run — ALL PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/choices-lib.ps1 scripts/test-choices-lib.ps1
git commit -m "feat(choices): answer persistence and brief/card formatters"
```

---

### Task 5: CLI runner `fleet-choices.ps1`

**Files:**
- Create: `scripts/fleet-choices.ps1`
- Create: `scripts/test-fleet-choices.ps1`

**Interfaces:**
- Subcommands: `brief`, `next`, `answer`, `list`, `draft`, `admit`, `reject`
- Prefer named `param()` switches matching `verbs.yaml` `flag_aliases` (`-Json`, `-Project`, `-Status`, `-Priority`, `-Text`, `-Title`, `-Question`, `-Blocks`, `-Evidence`, `-OptionsJson`, `-Rec`, `-RecWhy`) plus positional `Subcommand` and remaining ids.

- [ ] **Step 1: Write `scripts/test-fleet-choices.ps1` hermetic smoke**

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'fleet-choices.ps1'
$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-ch-cli-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
$fail = 0
function Assert($l,$c){ if($c){Write-Host "PASS $l"} else {Write-Host "FAIL $l"; $script:fail++} }
try {
    $optsPath = Join-Path $tmp 'opts.json'
    Set-Content -LiteralPath $optsPath -Encoding utf8NoBOM -Value '[{"id":"a","label":"A","summary":"sa"},{"id":"b","label":"B","summary":"sb"}]'
    $draftOut = & pwsh -NoProfile -File $runner draft -Project demo -Title 'T' -Question 'Q' -OptionsJson $optsPath -Rec a -RecWhy 'because' -Json 2>&1 | Out-String
    $d = $draftOut | ConvertFrom-Json
    Assert 'C1 draft json id' ($d.id -match '^ch-')
    & pwsh -NoProfile -File $runner admit $d.id -Priority P0
    Assert 'C2 admit exit 0' ($LASTEXITCODE -eq 0)
    $brief = & pwsh -NoProfile -File $runner brief 2>&1 | Out-String
    Assert 'C3 brief mentions demo' ($brief -match 'demo')
    $next = & pwsh -NoProfile -File $runner next -Json 2>&1 | Out-String | ConvertFrom-Json
    Assert 'C4 next id' ($next.id -eq $d.id)
    & pwsh -NoProfile -File $runner answer $d.id a
    Assert 'C5 answer exit 0' ($LASTEXITCODE -eq 0)
    $next2 = & pwsh -NoProfile -File $runner next 2>&1 | Out-String
    Assert 'C6 empty next message' ($next2 -match 'none admitted')
}
finally {
    if ($null -eq $prev) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prev }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'; exit 0
```

- [ ] **Step 2: Run — FAIL (runner missing)**

- [ ] **Step 3: Implement `fleet-choices.ps1`**

- `brief`: `Reset-ChoicesBriefCursor`; print `Format-ChoicesBrief` (or `-Json` of admitted cards + cursor)
- `next`: `Get-NextAdmittedChoice`; if null print `none admitted.` exit 0; else `Format-ChoiceCard` / `-Json`
- `answer <id> <option>` or `-Text`
- `list` / `draft` / `admit` / `reject` as thin wrappers
- User errors: `[Console]::Error.WriteLine` + `exit 2`

- [ ] **Step 4: Run both suites — ALL PASS**

```bash
pwsh -NoProfile -File scripts/test-choices-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-choices.ps1
```

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-choices.ps1 scripts/test-fleet-choices.ps1 scripts/choices-lib.ps1
git commit -m "feat(choices): fleet-choices CLI runner for brief/next/answer"
```

---

### Task 6: Wire dispatcher + docs + baton-home

**Files:**
- Modify: `scripts/verbs.yaml`
- Create: `commands/choices.md`
- Modify: `scripts/baton-home.ps1`
- Modify: `docs/COMMANDS.md`

- [ ] **Step 1: Add verbs.yaml entry**

```yaml
  - name: choices
    summary: Conductor needs-you queue — brief, next, answer, draft, admit, reject.
    class: engine
    runner: fleet-choices.ps1
    json: true
    flag_aliases:
      --json: -Json
      --project: -Project
      --status: -Status
      --priority: -Priority
      --text: -Text
      --title: -Title
      --question: -Question
      --blocks: -Blocks
      --evidence: -Evidence
      --options-json: -OptionsJson
      --rec: -Rec
      --rec-why: -RecWhy
```

- [ ] **Step 2: Create `commands/choices.md`** — Mouth runs `brief` then `next`; Kevin reply maps to `answer <id> <option>`.

- [ ] **Step 3: `Initialize-BatonHome` — add `choices` directory**

```powershell
foreach ($d in @($root, (Join-Path $root 'jobs'), (Join-Path $root 'runs'), (Join-Path $root 'logs'), (Join-Path $root 'choices'))) {
```

- [ ] **Step 4: Add `/baton:choices` section to `docs/COMMANDS.md`.**

- [ ] **Step 5: Verify**

```bash
pwsh -NoProfile -File scripts/baton.ps1 verbs --json | grep choices
pwsh -NoProfile -File scripts/test-choices-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-choices.ps1
```

Expected: verb present; both suites ALL PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/verbs.yaml commands/choices.md scripts/baton-home.ps1 docs/COMMANDS.md
git commit -m "feat(choices): register baton choices verb and document Mouth flow"
```

---

### Task 7: Dogfood overnight seed helper

Seed drafts+admits from known overnight decisions so `baton choices brief` works. Does not invent Kevin’s answers. Idempotent: skip if same `project`+`title` already exists as draft/admitted.

**Files:**
- Create: `scripts/seed-overnight-choices.ps1`
- Create: `scripts/test-seed-overnight-choices.ps1` (temp BATON_HOME only)

Cards:

| project | priority | title |
|---|---|---|
| canvas-toolchain | P0 | npm publish + #151 A/B/C |
| bookprofile | P1 | Book DNA surface A/B/C |
| atomicforge | P1 | Push local main? |
| bench-gauntlet | P1 | Stamp v2 scoring contract? |
| baton | P2 | Kill hung fleet-dispatch? |

Evidence: `~/.baton/overnight/report-*.md` paths as strings (no need to read files in seed).

- [ ] **Step 1: Implement seed script** (`New-ChoiceDraft` + `Set-ChoiceAdmitted`; print ids).
- [ ] **Step 2: Hermetic test** — run seed twice against temp home; second run adds 0 cards.
- [ ] **Step 3: Commit** (never commit real `~/.baton/choices` files).

```bash
git add scripts/seed-overnight-choices.ps1 scripts/test-seed-overnight-choices.ps1
git commit -m "feat(choices): idempotent overnight seed helper for dogfood brief"
```

---

## Spec coverage checklist

| Spec item | Task |
|---|---|
| `$BATON_HOME/choices/` one file per choice | 1 |
| Closed status + schema_version | 1–2 |
| Orchestrator draft / Conductor admit / reject | 2, 5 |
| Soft-park `blocks` field (no job held) | 2 |
| Priority then age project order | 3 |
| Project-at-a-time cursor | 3–4 |
| `brief` + auto-start cursor | 3–5 |
| CLI verbs | 5–6 |
| Drift guards | 1, 4 |
| Hermetic tests | 1–5, 7 |
| Portal / audit / auto-unblock / Grimdex | out of scope |

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-21-conductor-choices-queue.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with executing-plans checkpoints  

Which approach?
