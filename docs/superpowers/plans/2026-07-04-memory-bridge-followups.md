# Memory Bridge Follow-ups (M1–M3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Sprint 5's three tracked review follow-ups: scope/kind-routed promotion writes into the real Grimdex tree (M1), order-stable + atomic journal stamping (M2), and `recall --json` test coverage (M3).

**Architecture:** All changes live in `scripts/memory-lib.ps1` behind the existing `-Writer` seam (d-mb-4) — a new pure router `Get-PromotionWriteTarget` + a private `Get-MemoryProjectId`, an upgraded default writer `Write-PromotionToGrimdex`, and a line-wise atomic rewrite in `Set-MemoryPromoted`. Tests extend the existing single-file Check suite `scripts/test-memory-lib.ps1` (T34+). No new files, no schema change, no CLI flag changes.

**Tech Stack:** PowerShell 7+, house Assert/Check test style, hermetic temp dirs.

**Branch:** `feature/memory-bridge-followups` (create from master before Task 1).

**Spec:** `docs/superpowers/specs/2026-07-04-memory-bridge-followups-design.md` (d054 follow-ups). Spec path amendments (grounded against the REAL Grimdex layout + GRIMDEX.md law #1 — the spec's `universal/lessons.md` and `projects/<id>/lessons.md` do not exist):

- universal + avoid → `<root>/universal/mistakes.md`
- universal + prefer → `<root>/universal/winners.md`
- project → `<root>/projects/<project-id>/decision-guidance.md` (GRIMDEX.md law #1: "Guidance and lessons: projects/<project-id>/decision-guidance.md")

## Global Constraints

- **Hermetic tests:** temp `BATON_HOME`, temp fake Grimdex root, `BATON_MEM_LESSONS` redirect — NEVER the real `D:\Dev\Grimdex`, `~/.claude`, or `~/.baton`. The test file must pin `$env:BATON_GRIMDEX_ROOT = ''` at setup and restore the original value in `finally` (a developer box may have it set globally; child-process CLI tests inherit env).
- **Promotions are never lost:** unwritable/absent Grimdex root, unknown scope, or missing project id → box-private lessons file (+ one `Write-Warning`). A total write failure still surfaces through `Invoke-MemoryPromote`'s existing catch (promoted=$false, rows un-stamped — T29 contract unchanged).
- **Append-only Grimdex writes** with a dated header; NO git automation inside memory-lib (commit/push stays human).
- **Atomic journal rewrite:** `Set-MemoryPromoted` writes a temp file then `Move-Item -Force` over the original. Untouched and malformed lines are preserved **byte-verbatim** (the old rewrite silently dropped malformed lines — fixed here).
- **ConvertFrom-Json DateTime trap:** re-stringify any `[datetime]` top-level value with `.ToUniversalTime().ToString('o')` before re-serializing a touched row (house lesson; only `ts` qualifies).
- **Unary-comma rules:** `,([object[]]$x)` only on direct-assignment returns; `@($x)` when callers pipe; `@()` inside hashtable literals. No changes to existing returns in this plan.
- All writes `-Encoding utf8` (pwsh 7 = no BOM). Never name variables `$args`/`$input`/`$event`/`$matches`/`$host`/`$pid`. Every shell command arg < 965 bytes. Hooks/CLIs untouched except docs.
- Path building: use ONE `Join-Path` with a forward-slash child string (e.g. `Join-Path $root "projects/$id/decision-guidance.md"`) so test string-equality asserts match — do not nest Join-Path calls.

---

### Task 1: M1 — routed promotion writer (`Get-PromotionWriteTarget` + `Get-MemoryProjectId` + router `Write-PromotionToGrimdex`)

**Files:**
- Modify: `scripts/memory-lib.ps1` (insert the two new functions ABOVE `Write-PromotionToGrimdex`; replace `Write-PromotionToGrimdex`)
- Test: `scripts/test-memory-lib.ps1` (setup pin + T34–T44)

**Interfaces:**
- Consumes: `$script:DefaultLessonsPath` (existing), `$env:BATON_GRIMDEX_ROOT` (new, optional), candidate shape from `Get-PromotionCandidates` / `Invoke-MemoryPromote` (`signature`, `kind`, `rows` with per-row `scope`).
- Produces: `Get-PromotionWriteTarget -Candidate <pscustomobject> [-GrimdexRoot <string>] [-ProjectId <string>] [-FallbackPath <string>]` → `[pscustomobject]@{ path; tier }` with tier ∈ `universal-mistakes|universal-winners|project|box-private`; `Get-MemoryProjectId -ProjectDir <string>` → slug string or `$null`; `Write-PromotionToGrimdex` keeps its return contract (path written) and its default position as the `-Writer` seam target — `Invoke-MemoryPromote` needs NO change.

- [ ] **Step 1: Pin the Grimdex env var in the test setup (protects every existing CLI test from a real `BATON_GRIMDEX_ROOT`)**

In `scripts/test-memory-lib.ps1`, immediately after `function Check(...)` (line 6), add:

```powershell
$script:savedGrimdexRoot = $env:BATON_GRIMDEX_ROOT
$env:BATON_GRIMDEX_ROOT = ''
```

And in the `finally` block, before the fail-count check, add:

```powershell
    if ($null -ne $script:savedGrimdexRoot) { $env:BATON_GRIMDEX_ROOT = $script:savedGrimdexRoot } else { Remove-Item Env:\BATON_GRIMDEX_ROOT -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Write the failing tests (T34–T44)**

Append to `scripts/test-memory-lib.ps1` after the T33 block (before `Remove-Item Env:\BATON_HOME...` at line 154 — keep that line last in the `try`):

```powershell
    # ---- Follow-ups M1: promotion write-target routing ----
    $gxRoot = Join-Path $tmpDir 'fake-grimdex'
    New-Item -ItemType Directory -Force -Path $gxRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $gxRoot 'universal') | Out-Null

    $uniAvoid  = [pscustomobject]@{ signature='s one';  kind='avoid';  problem='p'; reason='failed 2x';    rows=@([pscustomobject]@{ scope='universal'; outcome='fail' }) }
    $uniPrefer = [pscustomobject]@{ signature='s two';  kind='prefer'; problem='p'; reason='succeeded 2x'; rows=@([pscustomobject]@{ scope='universal'; outcome='pass' }) }
    $projCand  = [pscustomobject]@{ signature='s three';kind='prefer'; problem='p'; reason='succeeded 2x'; rows=@([pscustomobject]@{ scope='project';   outcome='pass' }) }
    $mixCand   = [pscustomobject]@{ signature='s four'; kind='avoid';  problem='p'; reason='failed 2x';    rows=@([pscustomobject]@{ scope='project'; outcome='fail' }, [pscustomobject]@{ scope='universal'; outcome='fail' }) }
    $bpPath    = Join-Path $tmpDir 'bp-fallback.md'

    $t1 = Get-PromotionWriteTarget -Candidate $uniAvoid -GrimdexRoot $gxRoot -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T34 universal+avoid -> universal/mistakes.md' ($t1.path -eq (Join-Path $gxRoot 'universal/mistakes.md') -and $t1.tier -eq 'universal-mistakes')
    $t2 = Get-PromotionWriteTarget -Candidate $uniPrefer -GrimdexRoot $gxRoot -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T35 universal+prefer -> universal/winners.md' ($t2.path -eq (Join-Path $gxRoot 'universal/winners.md') -and $t2.tier -eq 'universal-winners')
    $t3 = Get-PromotionWriteTarget -Candidate $projCand -GrimdexRoot $gxRoot -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T36 project scope -> projects/<id>/decision-guidance.md' ($t3.path -eq (Join-Path $gxRoot 'projects/proj-x/decision-guidance.md') -and $t3.tier -eq 'project')
    $t4 = Get-PromotionWriteTarget -Candidate $mixCand -GrimdexRoot $gxRoot -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T37 mixed scopes -> universal wins' ($t4.tier -eq 'universal-mistakes')
    $t5 = Get-PromotionWriteTarget -Candidate $projCand -GrimdexRoot '' -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T38 empty root -> box-private fallback' ($t5.tier -eq 'box-private' -and $t5.path -eq $bpPath)
    $t6 = Get-PromotionWriteTarget -Candidate $projCand -GrimdexRoot (Join-Path $tmpDir 'no-such-root') -ProjectId 'proj-x' -FallbackPath $bpPath
    Check 'T39 absent root -> box-private fallback' ($t6.tier -eq 'box-private')
    $t7 = Get-PromotionWriteTarget -Candidate $projCand -GrimdexRoot $gxRoot -ProjectId '' -FallbackPath $bpPath
    Check 'T40 project scope without id -> box-private fallback' ($t7.tier -eq 'box-private')

    $gitProj = Join-Path $tmpDir 'gitproj'
    New-Item -ItemType Directory -Force -Path $gitProj | Out-Null
    & git -C $gitProj init --quiet 2>&1 | Out-Null
    & git -C $gitProj remote add origin https://github.com/Ryfter/Fake.Repo.git 2>&1 | Out-Null
    Check 'T41 project id from git remote slug' ((Get-MemoryProjectId -ProjectDir $gitProj) -eq 'fake-repo')
    $plain = Join-Path $tmpDir 'Plain Folder'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    Check 'T41b project id from folder-name slug' ((Get-MemoryProjectId -ProjectDir $plain) -eq 'plain-folder')

    $w1 = Write-PromotionToGrimdex -Memo '## memo-a' -Candidate $uniAvoid -GrimdexRoot $gxRoot -ProjectDir $plain -LessonsPath $bpPath
    $mistakesRaw = Get-Content -LiteralPath (Join-Path $gxRoot 'universal/mistakes.md') -Raw
    Check 'T42 routed append lands in fake root with header' ($w1 -eq (Join-Path $gxRoot 'universal/mistakes.md') -and $mistakesRaw -match 'baton memory-promote' -and $mistakesRaw -match [regex]::Escape('s one') -and $mistakesRaw -match 'memo-a')
    $w3 = Write-PromotionToGrimdex -Memo '## memo-c' -Candidate $projCand -GrimdexRoot $gxRoot -ProjectDir $plain -LessonsPath $bpPath
    Check 'T43 project-scope append creates the project tier file' ($w3 -eq (Join-Path $gxRoot 'projects/plain-folder/decision-guidance.md') -and (Test-Path $w3))
    $badRoot = Join-Path $tmpDir 'root-as-file.txt'
    Set-Content -LiteralPath $badRoot -Value 'x' -Encoding utf8
    $warnBag = @()
    $w2 = Write-PromotionToGrimdex -Memo '## memo-b' -Candidate $uniAvoid -GrimdexRoot $badRoot -ProjectDir $plain -LessonsPath $bpPath -WarningVariable warnBag -WarningAction SilentlyContinue
    Check 'T44 unwritable root -> box-private fallback + warning' ($w2 -eq $bpPath -and (Test-Path $bpPath) -and @($warnBag).Count -ge 1 -and (Get-Content -LiteralPath $bpPath -Raw) -match 'memo-b')
```

- [ ] **Step 3: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL — `Get-PromotionWriteTarget` / `Get-MemoryProjectId` not defined (script error before checks, or T34+ FAIL lines). T1–T33 must still PASS when the run reaches them.

- [ ] **Step 4: Implement — insert the two new functions above `Write-PromotionToGrimdex` (line 277) and replace `Write-PromotionToGrimdex`**

```powershell
function Get-MemoryProjectId {
    <# Network-free project id for the Grimdex project tier: git remote repo
       slug, else folder-name slug. Same derivation as coach-lib's
       Get-CoachProjectId / job-lib's Resolve-ProjectId — duplicated ON
       PURPOSE so memory-lib stays a leaf library (no coach/job dot-source). #>
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

function Get-PromotionWriteTarget {
    <# M1 router (pure decision; only reads Test-Path): candidate scope/kind +
       Grimdex root -> where the promotion memo belongs.
         universal + avoid  -> <root>/universal/mistakes.md
         universal + prefer -> <root>/universal/winners.md
         project            -> <root>/projects/<ProjectId>/decision-guidance.md
       No/absent root, or project scope without an id -> box-private fallback.
       Scope: 'universal' when ANY source row was captured scope=universal
       (the human said so at capture time); else project (fail-open default). #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Candidate,
        [string]$GrimdexRoot = $env:BATON_GRIMDEX_ROOT,
        [string]$ProjectId,
        [string]$FallbackPath = $script:DefaultLessonsPath
    )
    $bp = [pscustomobject]@{ path = $FallbackPath; tier = 'box-private' }
    if ([string]::IsNullOrWhiteSpace($GrimdexRoot) -or -not (Test-Path $GrimdexRoot)) { return $bp }
    $isUniversal = @(@($Candidate.rows) | Where-Object { [string]$_.scope -eq 'universal' }).Count -gt 0
    if ($isUniversal) {
        if ([string]$Candidate.kind -eq 'avoid') {
            return [pscustomobject]@{ path = (Join-Path $GrimdexRoot 'universal/mistakes.md'); tier = 'universal-mistakes' }
        }
        return [pscustomobject]@{ path = (Join-Path $GrimdexRoot 'universal/winners.md'); tier = 'universal-winners' }
    }
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { return $bp }
    return [pscustomobject]@{ path = (Join-Path $GrimdexRoot "projects/$ProjectId/decision-guidance.md"); tier = 'project' }
}

function Write-PromotionToGrimdex {
    <# Default promotion writer, now a ROUTER (M1): scope/kind-routed append
       into the Grimdex tree under BATON_GRIMDEX_ROOT, with a dated header
       (date + signature + provenance). No root / unknown scope / any write
       fault -> box-private lessons file + warning (a promotion is never
       lost). Append-only; committing/pushing Grimdex stays human. Override
       via the -Writer seam (tests do). Returns the path written. #>
    param(
        [Parameter(Mandatory)][string]$Memo,
        [pscustomobject]$Candidate,
        [string]$LessonsPath = $script:DefaultLessonsPath,
        [string]$GrimdexRoot = $env:BATON_GRIMDEX_ROOT,
        [string]$ProjectDir
    )
    if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
    $projId = $null
    try { $projId = Get-MemoryProjectId -ProjectDir $ProjectDir } catch { }
    $target = if ($Candidate) {
        Get-PromotionWriteTarget -Candidate $Candidate -GrimdexRoot $GrimdexRoot -ProjectId $projId -FallbackPath $LessonsPath
    } else {
        [pscustomobject]@{ path = $LessonsPath; tier = 'box-private' }
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $sig = if ($Candidate) { [string]$Candidate.signature } else { '' }
    $payload = "`n<!-- baton memory-promote $stamp | signature: $sig | source: memory-journal -->`n" + $Memo + "`n"
    try {
        $dir = Split-Path -Parent $target.path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $target.path -Value $payload -Encoding utf8
        return $target.path
    } catch {
        Write-Warning "memory: routed promotion write failed ($($target.path)) — falling back to box-private: $($_.Exception.Message)"
    }
    $dir = Split-Path -Parent $LessonsPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -LiteralPath $LessonsPath -Value $payload -Encoding utf8
    return $LessonsPath
}
```

Note: `Invoke-MemoryPromote`'s default `-Writer` scriptblock is untouched — the router activates through the new parameter defaults. If the fallback append itself throws, the exception propagates to `Invoke-MemoryPromote`'s existing writer catch → `promoted=$false`, rows un-stamped (T29 contract).

- [ ] **Step 5: Run the suite to verify T34–T44 pass and T1–T33 stay green**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: `ALL CHECKS PASS`

- [ ] **Step 6: Commit**

```powershell
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): M1 scope/kind-routed promotion writes into the Grimdex tree (fail-open to box-private)"
```

---

### Task 2: M2 — order-stable, atomic `Set-MemoryPromoted`

**Files:**
- Modify: `scripts/memory-lib.ps1:261-275` (replace `Set-MemoryPromoted`)
- Test: `scripts/test-memory-lib.ps1` (T45–T48)

**Interfaces:**
- Consumes/Produces: `Set-MemoryPromoted -Signature <string> [-Path <string>]` — signature unchanged; behavior upgraded (order-preserving, malformed-line-preserving, atomic temp+replace).

- [ ] **Step 1: Write the failing tests (T45–T48)** — append after the T44 block:

```powershell
    # ---- Follow-ups M2: order-stable atomic promoted stamp ----
    $op = Join-Path $tmpDir 'ordered-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'ordered row one target' -Approach 'a' -Outcome fail -Path $op)
    [void](Add-MemoryEvent -Problem 'other row keep verbatim' -Approach 'b' -Outcome pass -Path $op)
    Add-Content -LiteralPath $op -Value 'this is not json' -Encoding utf8
    $before = @(Get-Content -LiteralPath $op)
    $sigOrd = (Read-MemoryJournal -Path $op)[0].signature
    Set-MemoryPromoted -Signature $sigOrd -Path $op
    $after = @(Get-Content -LiteralPath $op)
    Check 'T45 stamped line = original with ONLY promoted flipped (string-level)' ($after[0] -eq ($before[0] -replace '"promoted":false', '"promoted":true'))
    Check 'T46 untouched row byte-identical' ($after[1] -eq $before[1])
    Check 'T47 malformed line preserved verbatim' ($after[2] -eq 'this is not json')
    Check 'T48 no temp file left behind' (@(Get-ChildItem -Path $tmpDir -Filter 'ordered-journal.jsonl.tmp-*').Count -eq 0)
```

- [ ] **Step 2: Run to verify T45–T47 fail** (current code scrambles key order and drops the malformed line)

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: T45 FAIL (key order scrambled), T47 FAIL (malformed line dropped). T46 may accidentally pass or fail — either is fine pre-fix.

- [ ] **Step 3: Replace `Set-MemoryPromoted`**

```powershell
function Set-MemoryPromoted {
    <# Idempotent journal rewrite: stamp every row with -Signature as
       promoted=true. Line-wise: untouched and malformed lines are preserved
       byte-verbatim; touched rows round-trip through [ordered] preserving
       the original field order (DateTime values re-stringified 'o' — the
       ConvertFrom-Json auto-parse trap). Whole-file-atomic: temp + replace.
       Best-effort; warns on fault. #>
    param([Parameter(Mandatory)][string]$Signature, [string]$Path = $script:DefaultMemoryPath)
    if (-not (Test-Path $Path)) { return }
    $tmp = "$Path.tmp-$([System.IO.Path]::GetRandomFileName())"
    try {
        $outLines = foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $null
            try { $row = $line | ConvertFrom-Json -ErrorAction Stop } catch { $line; continue }
            if ([string]$row.signature -ne $Signature) { $line; continue }
            $h = [ordered]@{}
            foreach ($p in $row.PSObject.Properties) {
                $v = $p.Value
                if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('o') }
                $h[$p.Name] = $v
            }
            $h['promoted'] = $true
            ($h | ConvertTo-Json -Depth 6 -Compress)
        }
        Set-Content -LiteralPath $tmp -Value $outLines -Encoding utf8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch {
        Write-Warning "memory: failed to stamp promoted in $Path : $($_.Exception.Message)"
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 4: Run the full suite** — T45–T48 pass; T27/T28/T33 (which re-read stamped journals) stay green.

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: `ALL CHECKS PASS`

- [ ] **Step 5: Commit**

```powershell
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "fix(memory): M2 order-stable atomic promoted stamp; malformed journal lines preserved"
```

---

### Task 3: M3 — `recall --json` test backfill

**Files:**
- Test: `scripts/test-memory-lib.ps1` (T49–T51; child-process CLI, pattern of T30–T33)

**Interfaces:**
- Consumes: `scripts/fleet-memory.ps1` `recall -Text <t> -Json` (existing; `Invoke-MemoryRecall` result piped `ConvertTo-Json -Depth 6`). No production change expected — this is coverage. If T50 exposes a single-element-array collapse, the fix is in `fleet-memory.ps1` line 44: `ConvertTo-Json -Depth 6 -InputObject $r` is NOT the issue (hashtable values keep array-ness); only touch production code if a test actually fails, and then fix in `Invoke-MemoryRecall`'s return by casting the field `[object[]]`.

- [ ] **Step 1: Append the tests** — after the T48 block (still before the `Remove-Item Env:\BATON_HOME...` line, which now must also clear the M3 home; see step code):

```powershell
    # ---- Follow-ups M3: recall --json coverage ----
    $jsonHome = Join-Path $tmpDir 'jsonhome'
    New-Item -ItemType Directory -Force -Path $jsonHome | Out-Null
    $env:BATON_HOME = $jsonHome

    $emptyRaw = & pwsh -NoProfile -File $cli recall -Text 'never seen task xyz' -Json 2>&1 | Out-String
    $emptyObj = $null
    try { $emptyObj = $emptyRaw | ConvertFrom-Json } catch { }
    Check 'T49 empty journal --json: valid JSON, empty matches array' ($null -ne $emptyObj -and $emptyRaw -match '"matches":\s*\[\]' -and @($emptyObj.matches).Count -eq 0 -and ([string]$emptyObj.signature).Length -gt 0)

    & pwsh -NoProfile -File $cli remember -Problem 'solo json check row' -Approach 'only' -Outcome fail 2>&1 | Out-Null
    $soloRaw = & pwsh -NoProfile -File $cli recall -Text 'solo json check row' -Json 2>&1 | Out-String
    $soloObj = $soloRaw | ConvertFrom-Json
    Check 'T50 single match stays a JSON array of one' ($soloRaw -match '"matches":\s*\[' -and @($soloObj.matches).Count -eq 1 -and $soloObj.matches[0].approach -eq 'only')

    & pwsh -NoProfile -File $cli remember -Problem 'solo json check row' -Approach 'again' -Outcome fail 2>&1 | Out-Null
    $twoRaw = & pwsh -NoProfile -File $cli recall -Text 'solo json check row' -Json 2>&1 | Out-String
    $twoObj = $twoRaw | ConvertFrom-Json
    Check 'T51 populated --json shape: 2 matches + avoid candidate + signature' (@($twoObj.matches).Count -eq 2 -and @($twoObj.candidates | Where-Object { $_.kind -eq 'avoid' }).Count -ge 1 -and ([string]$twoObj.signature) -match 'json')
```

(The existing `Remove-Item Env:\BATON_HOME, Env:\BATON_MEM_LESSONS ...` line stays LAST in the `try` block, after this section — it now also cleans up `$jsonHome`'s env.)

- [ ] **Step 2: Run** — coverage rows should pass against current code.

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: `ALL CHECKS PASS`. If T50 fails (single-element collapse), report DONE_WITH_CONCERNS with the raw output — do not improvise a production fix beyond the one named in Interfaces above.

- [ ] **Step 3: Commit**

```powershell
git add scripts/test-memory-lib.ps1
git commit -m "test(memory): M3 recall --json coverage (empty/single/populated shapes)"
```

---

### Task 4: Docs + version bump + regression sweep

**Files:**
- Modify: `commands/memory-promote.md`
- Modify: `.claude-plugin/plugin.json` (`"version": "1.8.0"` → `"version": "1.8.1-rc.1"`)

**Interfaces:** none (docs + metadata).

- [ ] **Step 1: Append to `commands/memory-promote.md`** (after the `## Arguments` section):

```markdown
## Where promotions land (routing)

When `BATON_GRIMDEX_ROOT` points at a Grimdex working copy, the default
writer routes by the pattern's captured scope + kind:

- universal + avoid → `<root>/universal/mistakes.md`
- universal + prefer → `<root>/universal/winners.md`
- project → `<root>/projects/<project-id>/decision-guidance.md` (id from the
  current folder's git remote, else the folder name)

`BATON_GRIMDEX_ROOT` unset/absent, unknown scope, or any write fault → the
box-private lessons file (`BATON_MEM_LESSONS` or the KB default), plus a
warning — a promotion is never lost. Writes are append-only with a dated
header; committing and pushing Grimdex stays with the human.
```

- [ ] **Step 2: Bump the plugin version**

In `.claude-plugin/plugin.json` change `"version": "1.8.0"` to `"version": "1.8.1-rc.1"`.

- [ ] **Step 3: Regression sweep**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1` → `ALL CHECKS PASS`
Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1` → exit 0 (no new files; memory-lib already deployed — this is a pure regression check)

- [ ] **Step 4: Commit**

```powershell
git add commands/memory-promote.md .claude-plugin/plugin.json
git commit -m "docs(memory): promotion routing + BATON_GRIMDEX_ROOT; bump 1.8.1-rc.1"
```

---

## Execution Handoff

Subagent-driven (standing default), streamlined ceremony (no per-task reviewers). Ladder: **Tasks 1–4 = haiku** (all code is complete in this plan — transcription + test runs); escalate Task 1 to **sonnet** only if the haiku implementer reports BLOCKED. **Final whole-branch review = opus** on `feature/memory-bridge-followups` (review package via `scripts/review-package <merge-base> HEAD`), findings triaged per house policy before PR.

## Ambiguities resolved (spec deltas — flag to Kevin at review)

1. Spec named `universal/lessons.md` and `projects/<id>/lessons.md`; neither exists in the real Grimdex. Routed to the real shelf per GRIMDEX.md: `universal/mistakes.md` (avoid), `universal/winners.md` (prefer), `projects/<id>/decision-guidance.md` (law #1 names it as the home of guidance AND lessons).
2. Promotion candidates carry no `scope` field — scope is derived from source rows (any `scope=universal` row → universal; the human set scope at capture time).
3. Project-id resolution is a deliberate private duplicate (`Get-MemoryProjectId`) of coach-lib's `Get-CoachProjectId`, keeping memory-lib a leaf library (third instance of this precedent: job-lib → coach-lib → memory-lib).
4. M2 hardened beyond the spec: line-wise rewrite preserves untouched AND malformed lines byte-verbatim — the old whole-file round-trip silently DROPPED malformed lines (latent data loss), and would have reformatted `ts` via the ConvertFrom-Json DateTime trap.
5. Test setup now pins `BATON_GRIMDEX_ROOT=''` (restored in `finally`) so no test — especially the child-process CLI rows — can ever route into the real `D:\Dev\Grimdex`.
