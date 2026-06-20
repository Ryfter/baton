# Memory Bridge (Sprint 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Projectmem-style dev memory for Baton — an append-only problem→attempt→outcome journal queried *before* acting that warns when a new task matches a past attempt (especially a known-bad fix), with a discover→crystallize promotion path into Grimdex.

**Architecture:** A pure layer (signature normalization, journal Read/Add, deterministic matching, promotion detection, formatting — no network/model) plus a seamed layer (`-Searcher` for `-Deep` semantic discovery via the KB index, `-Producer` for pluggable capture sources, `-Writer` for the Grimdex promotion write). A subcommand CLI (`remember`/`recall`/`promote`) and three `/baton:*` commands sit on top. State is box-private JSONL under `$BATON_HOME/memory-journal.jsonl`.

**Tech Stack:** PowerShell 7 (pwsh). Mirrors `scripts/usage-lib.ps1` (Read/Add/Fold) and `scripts/research-gate-lib.ps1` (seamed `-Searcher`, fallback, child-process CLI tests). Reuses `Invoke-KbSearch` (`scripts/kb-lib.ps1`) for `-Deep` and `Get-BatonHome` (`scripts/baton-home.ps1`).

## Global Constraints

- **Advisory, never blocking.** Recall emits a warning; it never stops work (matches Triage/Research-Gate/Conductor posture).
- **Box-private state.** The journal is `$BATON_HOME/memory-journal.jsonl`; the default promotion target is `~/.claude/knowledge/projects/baton/memory-lessons.md`. Any committed example carries placeholder content only — no real rosters/endpoints/budgets.
- **Hermetic tests.** The suite never touches a real network, model, real `$BATON_HOME`, or the real KB. `-Searcher` and `-Writer` are stubbed; journal + lessons targets are temp dirs/files. Zero network and zero real-model calls across the whole suite.
- **Never throw on I/O fault.** Journal writes warn-and-continue (mirror `Add-UsageEvent`); a missing/empty journal reads as empty; a malformed JSONL line is skipped.
- **PowerShell automatic-variable trap.** Never name a parameter or local `$args`, `$input`, `$event` — use `$pArgs`, etc. Array-returning functions guard single-element flattening with the unary-comma idiom `return ,([object[]]@(...))`.
- **Encoding.** Append rows with `-Encoding utf8`; write whole files with `Set-Content ... -Encoding utf8` (journal) to match `usage-lib`.
- **Determinism.** A given input to `Get-MemorySignature` always yields the same token-set key. Matching and promotion detection are deterministic; only `-Deep` semantic recall is non-deterministic and is advisory-only.

---

### Task 1: Signature normalization + journal Read/Add (pure foundation)

**Files:**
- Create: `scripts/memory-lib.ps1`
- Create (test scaffold): `scripts/test-memory-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` from `scripts/baton-home.ps1`.
- Produces:
  - `Get-MemorySignature([string]$Text) -> [string]` — normalized space-joined sorted-distinct token set; `''` for empty/whitespace.
  - `Read-MemoryJournal([string]$Path) -> [object[]]` — robust JSONL reader; missing path → empty; malformed line skipped.
  - `Add-MemoryEvent(...) -> [pscustomobject]@{ id; signature }` — appends one row, computes `id` + `signature`, never throws on write fault.

- [ ] **Step 1: Create the library file header + script defaults**

Create `scripts/memory-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Memory Bridge (Sprint 5). Projectmem-style problem->attempt->outcome dev memory:
  an append-only memory-journal.jsonl, deterministic signature matching (warn before
  repeating a known-bad fix), and a discover->crystallize promotion path into Grimdex.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-memory.ps1 wraps it for
  /baton:remember, /baton:recall, /baton:memory-promote. Advisory only — never blocks.
  House pattern mirrors usage-lib.ps1 (Read/Add/Fold) and research-gate-lib.ps1 (-Searcher seam).
.NOTES
  See docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md (d-mb-1..6).
#>
. "$PSScriptRoot/baton-home.ps1"

$script:DefaultMemoryPath  = (Join-Path (Get-BatonHome) 'memory-journal.jsonl')
$script:DefaultLessonsPath = $(if ($env:BATON_MEM_LESSONS) { $env:BATON_MEM_LESSONS } else { Join-Path $HOME '.claude/knowledge/projects/baton/memory-lessons.md' })
```

- [ ] **Step 2: Write the failing test scaffold**

Create `scripts/test-memory-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/memory-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: signature + journal Read/Add (pure) ----
    Check 'T1 lowercases + token-set' ((Get-MemorySignature -Text 'Auth Test') -eq 'auth test')
    Check 'T2 strips unix path' (((Get-MemorySignature -Text 'error in src/app/login.ts handler') -split ' ') -notcontains 'src')
    Check 'T3 strips windows path' (((Get-MemorySignature -Text 'fault at C:\repo\x\y.ps1 line') -split ' ') -notcontains 'repo')
    Check 'T4 strips line-number ref' (((Get-MemorySignature -Text 'boom at handler:123 today') -split ' ') -notcontains '123')
    Check 'T5 strips hex/uuid hash' (((Get-MemorySignature -Text 'commit deadbeef0 broke build') -split ' ') -notcontains 'deadbeef')
    $a = Get-MemorySignature -Text 'fix the flaky auth test'
    $b = Get-MemorySignature -Text 'test auth flaky fix'
    Check 'T6 order-independent, stopwords dropped' ($a -eq $b)
    Check 'T7 empty -> empty' ((Get-MemorySignature -Text '   ') -eq '')

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "mem-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $jp = Join-Path $tmpDir 'memory-journal.jsonl'

    Check 'T8 read missing path -> empty' (@(Read-MemoryJournal -Path $jp).Count -eq 0)
    $r1 = Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock the clock' -Outcome fail -Path $jp
    Check 'T9 add returns id + signature' ($r1.id -like 'mem-*' -and $r1.signature -match 'auth')
    $rows = Read-MemoryJournal -Path $jp
    Check 'T10 row round-trips with computed fields' (@($rows).Count -eq 1 -and $rows[0].outcome -eq 'fail' -and $rows[0].promoted -eq $false)
    Add-Content -LiteralPath $jp -Value 'this is not json' -Encoding utf8
    Check 'T11 malformed line skipped' (@(Read-MemoryJournal -Path $jp).Count -eq 1)
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL — `Get-MemorySignature`/`Read-MemoryJournal`/`Add-MemoryEvent` are not defined (errors/`FAIL` lines), nonzero exit.

- [ ] **Step 4: Implement the three functions**

Append to `scripts/memory-lib.ps1`:

```powershell
function Get-MemorySignature {
    <# Normalize free text into a deterministic token-set key: lowercase, strip
       paths / line-number refs / hex+uuid hashes / digit-unit tokens, drop stopwords,
       return the sorted distinct tokens joined by spaces. Same input -> same key. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.ToLowerInvariant()
    $t = $t -replace '[a-z]:\\[^\s]+', ' '          # windows paths
    $t = $t -replace '(?:[\w.-]+/)+[\w.-]+', ' '    # unix-style paths
    $t = $t -replace ':\d+', ' '                    # :line-number refs
    $t = $t -replace '\b[0-9a-f]{8,}\b', ' '         # hex / uuid hashes
    $t = $t -replace '\b\d+[a-z]*\b', ' '            # numbers + digit-unit (30s, 200ms)
    $t = $t -replace '[^a-z0-9]+', ' '               # punctuation -> space
    $stop = @('the','a','an','to','of','in','on','is','it','and','or','for','with',
              'this','that','my','we','i','be','by','at','as','was','are','from','its')
    $tokens = $t -split '\s+' | Where-Object { $_ -and ($_.Length -gt 1) -and ($stop -notcontains $_) }
    return (($tokens | Sort-Object -Unique) -join ' ')
}

function Read-MemoryJournal {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. object[]. #>
    param([string]$Path = $script:DefaultMemoryPath)
    if (-not $Path -or -not (Test-Path $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Add-MemoryEvent {
    <# Append one memory row. Computes id + signature. Never throws on write fault
       (warns). Creates the parent dir. Returns @{ id; signature }. #>
    param(
        [Parameter(Mandatory)][string]$Problem,
        [string]$Approach = '',
        [ValidateSet('pass','fail','partial','unknown')][string]$Outcome = 'unknown',
        [ValidateSet('attempt','outcome','note')][string]$Kind = 'attempt',
        [string[]]$Tags = @(),
        [ValidateSet('project','universal')][string]$Scope = 'project',
        [string]$Source = 'manual',
        [hashtable]$Refs = @{},
        [string]$Path = $script:DefaultMemoryPath,
        [string]$Timestamp,
        [string]$Id
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
    if (-not $Id) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $rand  = [System.IO.Path]::GetRandomFileName().Substring(0,4)
        $Id = "mem-$stamp-$rand"
    }
    $sig = Get-MemorySignature -Text $Problem
    $row = [ordered]@{
        ts = $Timestamp; id = $Id; kind = $Kind; signature = $sig; problem = $Problem
        approach = $Approach; outcome = $Outcome; tags = @($Tags); source = $Source
        refs = @{ job = $Refs['job']; run = $Refs['run']; decision = $Refs['decision'] }
        scope = $Scope; promoted = $false
    }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $Path -Value ($row | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    } catch {
        Write-Warning "memory: failed to append event to $Path : $($_.Exception.Message)"
    }
    return [pscustomobject]@{ id = $Id; signature = $sig }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — `ALL CHECKS PASS` (T1–T11), exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): signature normalization + journal Read/Add (Task 1)"
```

---

### Task 2: Deterministic matching + promotion candidate detection (pure)

**Files:**
- Modify: `scripts/memory-lib.ps1`
- Modify: `scripts/test-memory-lib.ps1`

**Interfaces:**
- Consumes: `Get-MemorySignature`, `Read-MemoryJournal` (Task 1).
- Produces:
  - `Find-MemoryMatches([string]$Query,[double]$MinOverlap=0.5,[string]$Path,[object[]]$Rows) -> [object[]]` — rows whose stored `signature` token-overlaps the query at/above `MinOverlap`, ranked overlap-desc then recency-desc.
  - `Get-PromotionCandidates([int]$FailThreshold=2,[int]$WinThreshold=2,[string]$Path,[object[]]$Rows) -> [object[]]` — one candidate per flagged signature: `@{ signature; reason; fail_count; win_count; kind('avoid'|'prefer'); rows; problem }`. Excludes `promoted` rows.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-memory-lib.ps1`, insert this block immediately before the closing `}` of the `try` (after the Task 1 `T11` line):

```powershell
    # ---- Task 2: matching + promotion candidates (pure) ----
    # Rows 1 & 2 share a signature (same problem text) so the fail-threshold can fire;
    # row 4 partially overlaps so ranking is observable.
    $mp = Join-Path $tmpDir 'match-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $mp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $mp)
    [void](Add-MemoryEvent -Problem 'docker build is slow' -Approach 'cache layers' -Outcome pass -Path $mp)
    [void](Add-MemoryEvent -Problem 'auth dashboard work' -Approach 'css-grid' -Outcome pass -Path $mp)
    $mrows = Read-MemoryJournal -Path $mp

    # Rows 1 & 2 share the signature; overlaps tie at 1.0 so assert membership, not position.
    $exact = Find-MemoryMatches -Query 'auth test is flaky in ci' -Rows $mrows
    Check 'T12 exact signature match found' (@($exact | Where-Object { $_.approach -eq 'mock clock' }).Count -eq 1)
    $partial = Find-MemoryMatches -Query 'auth test timeout' -MinOverlap 0.5 -Rows $mrows
    Check 'T13 token-overlap match above floor' (@($partial).Count -ge 2)
    $miss = Find-MemoryMatches -Query 'kubernetes ingress config' -Rows $mrows
    Check 'T14 below-floor miss returns none' (@($miss).Count -eq 0)
    # Query {auth,flaky}: rows 1&2 overlap 1.0, dashboard row overlap 0.5 -> ranks last.
    $ranked = Find-MemoryMatches -Query 'auth flaky' -MinOverlap 0.5 -Rows $mrows
    Check 'T15 ranked overlap desc (partial ranks last)' (@($ranked).Count -ge 3 -and $ranked[-1].approach -eq 'css-grid' -and $ranked[0].approach -ne 'css-grid')

    $cands = Get-PromotionCandidates -FailThreshold 2 -WinThreshold 2 -Rows $mrows
    $authCand = @($cands | Where-Object { $_.signature -match 'auth' -and $_.kind -eq 'avoid' }) | Select-Object -First 1
    Check 'T16 fail-threshold fires (avoid)' ($null -ne $authCand -and $authCand.fail_count -ge 2)
    [void](Add-MemoryEvent -Problem 'speed up jest suite' -Approach 'shard' -Outcome pass -Path (Join-Path $tmpDir 'win.jsonl'))
    [void](Add-MemoryEvent -Problem 'speed up jest suite' -Approach 'shard' -Outcome pass -Path (Join-Path $tmpDir 'win.jsonl'))
    $winCands = Get-PromotionCandidates -Rows (Read-MemoryJournal -Path (Join-Path $tmpDir 'win.jsonl'))
    Check 'T17 win-threshold fires (prefer)' (@($winCands | Where-Object { $_.kind -eq 'prefer' }).Count -ge 1)
    $promotedRows = @($mrows | ForEach-Object { $h=@{}; $_.PSObject.Properties | ForEach-Object { $h[$_.Name]=$_.Value }; $h['promoted']=$true; [pscustomobject]$h })
    Check 'T18 promoted rows excluded' (@(Get-PromotionCandidates -Rows $promotedRows).Count -eq 0)
    $single = @(Add-MemoryEvent -Problem 'one off thing' -Approach 'x' -Outcome fail -Path (Join-Path $tmpDir 'single.jsonl'))
    Check 'T19 below threshold -> none' (@(Get-PromotionCandidates -Rows (Read-MemoryJournal -Path (Join-Path $tmpDir 'single.jsonl'))).Count -eq 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL at T12 — `Find-MemoryMatches` not defined.

- [ ] **Step 3: Implement the two functions**

Append to `scripts/memory-lib.ps1`:

```powershell
function Find-MemoryMatches {
    <# Rows whose stored signature token-overlaps the query signature at/above
       -MinOverlap (shared / query-token count). Ranked overlap desc then recency
       desc. Reads the journal when -Rows is not supplied. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [double]$MinOverlap = 0.5,
        [string]$Path = $script:DefaultMemoryPath,
        [object[]]$Rows
    )
    $qtokens = @((Get-MemorySignature -Text $Query) -split '\s+' | Where-Object { $_ })
    if ($qtokens.Count -eq 0) { return ([object[]]@()) }
    if ($null -eq $Rows) { $Rows = Read-MemoryJournal -Path $Path }
    $scored = foreach ($r in $Rows) {
        $rtokens = @([string]$r.signature -split '\s+' | Where-Object { $_ })
        if ($rtokens.Count -eq 0) { continue }
        $shared  = @($qtokens | Where-Object { $rtokens -contains $_ }).Count
        $overlap = [double]$shared / $qtokens.Count
        if ($overlap -ge $MinOverlap) {
            [pscustomobject]@{ row = $r; overlap = $overlap; ts = [string]$r.ts }
        }
    }
    $ranked = @($scored) | Sort-Object -Property @{ e = { $_.overlap }; Descending = $true }, @{ e = { $_.ts }; Descending = $true }
    return ,([object[]]@($ranked | ForEach-Object { $_.row }))
}

function Get-PromotionCandidates {
    <# Group non-promoted rows by signature; flag one whose fail-count >= FailThreshold
       (governance: stop repeating a bad fix) or pass-count >= WinThreshold (crystallize
       a winner). Returns one candidate per flagged signature. #>
    param(
        [int]$FailThreshold = 2,
        [int]$WinThreshold = 2,
        [string]$Path = $script:DefaultMemoryPath,
        [object[]]$Rows
    )
    if ($null -eq $Rows) { $Rows = Read-MemoryJournal -Path $Path }
    $active = @($Rows | Where-Object { $_.promoted -ne $true -and [string]$_.signature })
    $out = [System.Collections.ArrayList]@()
    foreach ($grp in ($active | Group-Object -Property signature)) {
        $fails = @($grp.Group | Where-Object { [string]$_.outcome -eq 'fail' }).Count
        $wins  = @($grp.Group | Where-Object { [string]$_.outcome -eq 'pass' }).Count
        $reason = $null; $kind = $null
        if ($fails -ge $FailThreshold)     { $reason = "failed ${fails}x";    $kind = 'avoid' }
        elseif ($wins -ge $WinThreshold)   { $reason = "succeeded ${wins}x";  $kind = 'prefer' }
        if ($reason) {
            [void]$out.Add([pscustomobject]@{
                signature = $grp.Name; reason = $reason; fail_count = $fails; win_count = $wins
                kind = $kind; rows = @($grp.Group); problem = [string]($grp.Group[0].problem)
            })
        }
    }
    return ,([object[]]$out.ToArray())
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — T1–T19 all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): deterministic matching + promotion candidate detection (Task 2)"
```

---

### Task 3: Recall report + promotion memo formatting (pure)

**Files:**
- Modify: `scripts/memory-lib.ps1`
- Modify: `scripts/test-memory-lib.ps1`

**Interfaces:**
- Consumes: `Get-MemorySignature` (Task 1); candidate shape from `Get-PromotionCandidates` (Task 2).
- Produces:
  - `Format-RecallReport([string]$Query,[object[]]$Matches,[object[]]$Candidates,[object[]]$SemanticCandidates) -> [string]` — leads with failed-attempt count, lists each match, lists promotion candidates and any semantic neighbors.
  - `Format-PromotionMemo([pscustomobject]$Candidate) -> [string]` — `AVOID`/`PREFER` rule memo with the attempts.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-memory-lib.ps1`, insert before the closing `}` of `try` (after the Task 2 `T19` line):

```powershell
    # ---- Task 3: formatting (pure) ----
    $fmtMatches = @(
        [pscustomobject]@{ approach='mock clock'; outcome='fail'; problem='auth test flaky'; refs=[pscustomobject]@{ job='j-0042' } },
        [pscustomobject]@{ approach='raise timeout'; outcome='fail'; problem='auth test flaky'; refs=[pscustomobject]@{ job='j-0051' } }
    )
    $fmtCands = @([pscustomobject]@{ signature='auth flaky test'; reason='failed 2x'; kind='avoid' })
    $report = Format-RecallReport -Query 'fix flaky auth test' -Matches $fmtMatches -Candidates $fmtCands
    Check 'T20 report leads with failed count + lists match' ($report -match '2 prior attempt' -and $report -match '2 FAILED' -and $report -match 'mock clock')
    Check 'T21 report includes promotion candidate line' ($report -match 'PROMOTION CANDIDATE' -and $report -match 'memory-promote')
    $emptyReport = Format-RecallReport -Query 'brand new task' -Matches @() -Candidates @()
    Check 'T22a empty report says no matches' ($emptyReport -match 'No prior memory')

    $promoCand = [pscustomobject]@{ signature='auth flaky test'; reason='failed 2x'; kind='avoid'
        problem='auth test is flaky'; rows=@(
            [pscustomobject]@{ approach='mock clock'; outcome='fail' },
            [pscustomobject]@{ approach='raise timeout'; outcome='fail' }) }
    $memo = Format-PromotionMemo -Candidate $promoCand
    Check 'T22b promotion memo renders AVOID + attempts' ($memo -match 'AVOID' -and $memo -match 'mock clock' -and $memo -match 'raise timeout')
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL at T20 — `Format-RecallReport` not defined.

- [ ] **Step 3: Implement the two functions**

Append to `scripts/memory-lib.ps1`:

```powershell
function Format-RecallReport {
    <# Human-readable recall warning: signature, prior matches (failed count first),
       promotion candidates, and any semantic neighbors. Pure string builder. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [object[]]$Matches = @(),
        [object[]]$Candidates = @(),
        [object[]]$SemanticCandidates = @()
    )
    $sig = Get-MemorySignature -Text $Query
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("RECALL — signature: $sig")
    $fails = @($Matches | Where-Object { [string]$_.outcome -eq 'fail' })
    if (@($Matches).Count -eq 0) {
        [void]$sb.AppendLine("No prior memory matches this task.")
    } else {
        [void]$sb.AppendLine("$(@($Matches).Count) prior attempt(s) on this signature — $(@($fails).Count) FAILED:")
        foreach ($m in $Matches) {
            $oc = ([string]$m.outcome).ToUpperInvariant()
            $job = if ($m.refs -and $m.refs.job) { "  [$($m.refs.job)]" } else { '' }
            [void]$sb.AppendLine("  • $($m.approach) — $oc ($($m.problem))$job")
        }
    }
    foreach ($c in $Candidates) {
        [void]$sb.AppendLine("PROMOTION CANDIDATE: signature '$($c.signature)' $($c.reason) — consider /baton:memory-promote")
    }
    if (@($SemanticCandidates).Count) {
        [void]$sb.AppendLine("Related (semantic):")
        foreach ($s in $SemanticCandidates) {
            $txt = ("$($s.text)" -replace '\s+',' ').Trim()
            [void]$sb.AppendLine("  ~ $($s.source): $txt")
        }
    }
    return $sb.ToString().TrimEnd()
}

function Format-PromotionMemo {
    <# A promotion candidate -> a Grimdex lesson/decision draft (AVOID or PREFER). #>
    param([Parameter(Mandatory)][pscustomobject]$Candidate)
    $verb = if ($Candidate.kind -eq 'avoid') { 'AVOID' } else { 'PREFER' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## Memory-promoted rule ($verb)")
    [void]$sb.AppendLine("Signature: $($Candidate.signature)")
    [void]$sb.AppendLine("Problem: $($Candidate.problem)")
    [void]$sb.AppendLine("Basis: $($Candidate.reason)")
    [void]$sb.AppendLine("Attempts:")
    foreach ($r in @($Candidate.rows)) {
        [void]$sb.AppendLine("  - $($r.approach) -> $($r.outcome)")
    }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — T1–T22b all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): recall report + promotion memo formatting (Task 3)"
```

---

### Task 4: Seamed recall — deterministic core + `-Deep` semantic discovery

**Files:**
- Modify: `scripts/memory-lib.ps1`
- Modify: `scripts/test-memory-lib.ps1`

**Interfaces:**
- Consumes: `Read-MemoryJournal`, `Get-MemorySignature` (Task 1); `Find-MemoryMatches`, `Get-PromotionCandidates` (Task 2); `Invoke-KbSearch` (`scripts/kb-lib.ps1`, optional — wrapped in try/catch).
- Produces:
  - `Invoke-MemoryRecall([string]$Task,[double]$MinOverlap=0.5,[int]$FailThreshold=2,[int]$WinThreshold=2,[switch]$Deep,[string]$Path,[scriptblock]$Searcher) -> [hashtable]@{ signature; matches; candidates; semantic }` — deterministic matches always; `-Deep` adds semantic neighbors via `-Searcher` (offline makes **zero** searcher calls); candidates surfaced are only those whose signature appears in the matches.
  - `Invoke-RealMemorySearch([string]$Query) -> [object[]]` — default searcher; wraps `Invoke-KbSearch`, `@()` on any error.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-memory-lib.ps1`, insert before the closing `}` of `try` (after the Task 3 block):

```powershell
    # ---- Task 4: seamed recall ----
    $rp = Join-Path $tmpDir 'recall-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $rp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $rp)
    $script:semCalls = 0
    $stubSearcher = { param($q) $script:semCalls++; @([pscustomobject]@{ source='kb'; text='prior auth note' }) }

    $rec = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Searcher $stubSearcher
    Check 'T23 offline recall: matches found, zero searcher calls' (@($rec.matches).Count -eq 2 -and $rec.semantic.Count -eq 0 -and $script:semCalls -eq 0)
    Check 'T23b touched candidate surfaced' (@($rec.candidates | Where-Object { $_.kind -eq 'avoid' }).Count -ge 1)
    $recDeep = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Deep -Searcher $stubSearcher
    Check 'T24 deep recall invokes searcher + appends semantic' ($recDeep.semantic.Count -eq 1 -and $script:semCalls -eq 1)
    $throwSearcher = { param($q) throw 'kb index down' }
    $recErr = Invoke-MemoryRecall -Task 'auth test is flaky in ci' -Path $rp -Deep -Searcher $throwSearcher
    Check 'T25 searcher throw degrades to empty (no throw)' (@($recErr.semantic).Count -eq 0 -and @($recErr.matches).Count -eq 2)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL at T23 — `Invoke-MemoryRecall` not defined.

- [ ] **Step 3: Implement the recall orchestration**

Append to `scripts/memory-lib.ps1`:

```powershell
function Invoke-RealMemorySearch {
    <# Default semantic searcher for -Deep: reuse the KB embedding index. Best-effort
       and box-private — returns @() if the index is absent or kb-search errors. #>
    param([Parameter(Mandatory)][string]$Query)
    try { return @(Invoke-KbSearch -Query $Query -K 3 -SnippetChars 400) } catch { return @() }
}

function Invoke-MemoryRecall {
    <# Pre-action recall: deterministic signature matches always; -Deep additionally
       pulls KB semantic neighbors via the -Searcher seam (offline makes ZERO searcher
       calls). Surfaces only promotion candidates whose signature appears in the
       matches. Returns @{ signature; matches; candidates; semantic }. #>
    param(
        [Parameter(Mandatory)][string]$Task,
        [double]$MinOverlap = 0.5,
        [int]$FailThreshold = 2,
        [int]$WinThreshold = 2,
        [switch]$Deep,
        [string]$Path = $script:DefaultMemoryPath,
        [scriptblock]$Searcher = { param($q) Invoke-RealMemorySearch -Query $q }
    )
    $rows    = Read-MemoryJournal -Path $Path
    $matches = Find-MemoryMatches -Query $Task -MinOverlap $MinOverlap -Rows $rows
    $cands   = Get-PromotionCandidates -FailThreshold $FailThreshold -WinThreshold $WinThreshold -Rows $rows
    $msigs   = @($matches | ForEach-Object { [string]$_.signature } | Sort-Object -Unique)
    $touched = @($cands | Where-Object { $msigs -contains $_.signature })
    $semantic = @()
    if ($Deep) {
        try { $semantic = @(& $Searcher $Task) } catch { $semantic = @() }
    }
    return @{
        signature  = (Get-MemorySignature -Text $Task)
        matches    = @($matches)
        candidates = @($touched)
        semantic   = @($semantic)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — through T25, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): seamed recall — deterministic core + -Deep semantic discovery (Task 4)"
```

---

### Task 5: Seamed capture source + promotion (two nomination paths, one write)

**Files:**
- Modify: `scripts/memory-lib.ps1`
- Modify: `scripts/test-memory-lib.ps1`

**Interfaces:**
- Consumes: `Add-MemoryEvent`, `Read-MemoryJournal` (Task 1); `Format-PromotionMemo` (Task 3).
- Produces:
  - `Invoke-MemorySource([string]$Source='manual',[hashtable]$Fields,[string]$Path,[scriptblock]$Producer) -> [string[]]` — pluggable capture adapter; default appends one manual row from `$Fields`; returns appended ids.
  - `Set-MemoryPromoted([string]$Signature,[string]$Path)` — idempotent journal rewrite stamping every matching-signature row `promoted=$true`; best-effort (warns on fault).
  - `Write-PromotionToGrimdex([string]$Memo,[pscustomobject]$Candidate,[string]$LessonsPath) -> [string]` — default `-Writer`; appends the memo to the box-private lessons file; returns the path.
  - `Invoke-MemoryPromote([pscustomobject]$Candidate,[string]$Id,[string]$Signature,[int]$FailThreshold=2,[int]$WinThreshold=2,[string]$Path,[scriptblock]$Writer) -> [hashtable]@{ promoted; signature; written }` — watch path (pass `-Candidate`) or flag path (pass `-Id`/`-Signature`); writes via `-Writer` then stamps. On writer fault: `promoted=$false`, rows left un-stamped. Unknown id/signature: throws.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-memory-lib.ps1`, insert before the closing `}` of `try` (after the Task 4 block):

```powershell
    # ---- Task 5: capture source + promotion (seamed -Writer) ----
    $sp = Join-Path $tmpDir 'source-journal.jsonl'
    $ids = Invoke-MemorySource -Source manual -Fields @{ problem='db migration failed'; approach='down then up'; outcome='fail'; tags=@('db') } -Path $sp
    Check 'T26 source appends a manual row + returns id' (@($ids).Count -eq 1 -and $ids[0] -like 'mem-*' -and @(Read-MemoryJournal -Path $sp).Count -eq 1)

    $pp = Join-Path $tmpDir 'promote-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail -Path $pp)
    [void](Add-MemoryEvent -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail -Path $pp)
    $cand = (Get-PromotionCandidates -Rows (Read-MemoryJournal -Path $pp))[0]
    $script:writeCalls = 0
    $stubWriter = { param($memo,$c) $script:writeCalls++; "stub-target" }
    $res = Invoke-MemoryPromote -Candidate $cand -Path $pp -Writer $stubWriter
    Check 'T27 promote (watch) calls writer + stamps rows' ($res.promoted -eq $true -and $script:writeCalls -eq 1 -and @(Read-MemoryJournal -Path $pp | Where-Object { $_.promoted -eq $true }).Count -eq 2)

    $fp = Join-Path $tmpDir 'flag-journal.jsonl'
    $fr1 = Add-MemoryEvent -Problem 'cache invalidation bug' -Approach 'ttl bump' -Outcome fail -Path $fp
    $script:writeCalls2 = 0
    $stubWriter2 = { param($memo,$c) $script:writeCalls2++; "t2" }
    $resFlag = Invoke-MemoryPromote -Id $fr1.id -Path $fp -Writer $stubWriter2
    Check 'T28 promote (flag by id) calls writer + stamps' ($resFlag.promoted -eq $true -and $script:writeCalls2 -eq 1 -and @(Read-MemoryJournal -Path $fp | Where-Object { $_.promoted -eq $true }).Count -eq 1)
    $threw = $false
    try { Invoke-MemoryPromote -Id 'mem-nope-0000' -Path $fp -Writer $stubWriter2 } catch { $threw = $true }
    Check 'T28b unknown id throws' ($threw)

    $wf = Join-Path $tmpDir 'writefault-journal.jsonl'
    [void](Add-MemoryEvent -Problem 'x problem here' -Approach 'a' -Outcome fail -Path $wf)
    [void](Add-MemoryEvent -Problem 'x problem here' -Approach 'b' -Outcome fail -Path $wf)
    $candWf = (Get-PromotionCandidates -Rows (Read-MemoryJournal -Path $wf))[0]
    $faultWriter = { param($memo,$c) throw 'grimdex unavailable' }
    $resWf = Invoke-MemoryPromote -Candidate $candWf -Path $wf -Writer $faultWriter
    Check 'T29 writer fault -> promoted false, rows not stamped' ($resWf.promoted -eq $false -and @(Read-MemoryJournal -Path $wf | Where-Object { $_.promoted -eq $true }).Count -eq 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: FAIL at T26 — `Invoke-MemorySource` not defined.

- [ ] **Step 3: Implement source + promotion**

Append to `scripts/memory-lib.ps1`:

```powershell
function Invoke-MemorySource {
    <# Pluggable capture adapter. -Source names the producer (v1 ships 'manual').
       A -Producer scriptblock returns one or more field-hashtables; the default
       treats -Fields as a single manual row. Appends via Add-MemoryEvent; returns
       the appended ids. The seam future Conductor-ledger ingest plugs into. #>
    param(
        [string]$Source = 'manual',
        [hashtable]$Fields = @{},
        [string]$Path = $script:DefaultMemoryPath,
        [scriptblock]$Producer
    )
    $records = if ($Producer) { @(& $Producer $Fields) } else { ,$Fields }
    $ids = foreach ($r in $records) {
        $oc = if ($r['outcome']) { [string]$r['outcome'] } else { 'unknown' }
        $sc = if ($r['scope'])   { [string]$r['scope'] }   else { 'project' }
        $refs = @{}; if ($r['job']) { $refs['job'] = $r['job'] }
        $res = Add-MemoryEvent -Problem ([string]$r['problem']) -Approach ([string]$r['approach']) `
            -Outcome $oc -Tags @($r['tags']) -Scope $sc -Source $Source -Refs $refs -Path $Path
        $res.id
    }
    return ,([string[]]$ids)
}

function Set-MemoryPromoted {
    <# Idempotent journal rewrite: stamp every row with -Signature as promoted=true.
       Best-effort; warns on fault. #>
    param([Parameter(Mandatory)][string]$Signature, [string]$Path = $script:DefaultMemoryPath)
    if (-not (Test-Path $Path)) { return }
    try {
        $rows = Read-MemoryJournal -Path $Path
        $lines = foreach ($r in $rows) {
            $h = @{}; foreach ($p in $r.PSObject.Properties) { $h[$p.Name] = $p.Value }
            if ([string]$r.signature -eq $Signature) { $h['promoted'] = $true }
            ($h | ConvertTo-Json -Depth 6 -Compress)
        }
        Set-Content -LiteralPath $Path -Value $lines -Encoding utf8
    } catch { Write-Warning "memory: failed to stamp promoted in $Path : $($_.Exception.Message)" }
}

function Write-PromotionToGrimdex {
    <# Default promotion writer: append the memo to the box-private Grimdex/KB lessons
       file. Override via the -Writer seam (tests do). Returns the path written. #>
    param(
        [Parameter(Mandatory)][string]$Memo,
        [pscustomobject]$Candidate,
        [string]$LessonsPath = $script:DefaultLessonsPath
    )
    $dir = Split-Path -Parent $LessonsPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Add-Content -LiteralPath $LessonsPath -Value ("`n" + $Memo + "`n") -Encoding utf8
    return $LessonsPath
}

function Invoke-MemoryPromote {
    <# Crystallize a candidate into a Grimdex write, then stamp its source rows
       promoted. Two nomination paths: watch (-Candidate) or flag (-Id / -Signature).
       The -Writer seam performs the write (default = Write-PromotionToGrimdex).
       On writer fault: promoted=$false and rows are left un-stamped (re-surfaces).
       Unknown id/signature throws. #>
    param(
        [pscustomobject]$Candidate,
        [string]$Id,
        [string]$Signature,
        [int]$FailThreshold = 2,
        [int]$WinThreshold = 2,
        [string]$Path = $script:DefaultMemoryPath,
        [scriptblock]$Writer = { param($memo,$cand) Write-PromotionToGrimdex -Memo $memo -Candidate $cand }
    )
    if (-not $Candidate) {
        $rows = Read-MemoryJournal -Path $Path
        $sig = $Signature
        if ($Id) {
            $hit = @($rows | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
            if (-not $hit) { throw "no memory with id '$Id'" }
            $sig = [string]$hit.signature
        }
        if (-not $sig) { throw "promote requires -Candidate, -Id, or -Signature" }
        $grp = @($rows | Where-Object { [string]$_.signature -eq $sig })
        if ($grp.Count -eq 0) { throw "no memory with signature '$sig'" }
        $fails = @($grp | Where-Object { [string]$_.outcome -eq 'fail' }).Count
        $wins  = @($grp | Where-Object { [string]$_.outcome -eq 'pass' }).Count
        $Candidate = [pscustomobject]@{
            signature = $sig; reason = "flagged (fail ${fails}, pass ${wins})"
            fail_count = $fails; win_count = $wins
            kind = if ($fails -ge $wins) { 'avoid' } else { 'prefer' }
            rows = $grp; problem = [string]$grp[0].problem
        }
    }
    $memo = Format-PromotionMemo -Candidate $Candidate
    try { $written = & $Writer $memo $Candidate }
    catch {
        Write-Warning "memory: promotion write failed: $($_.Exception.Message)"
        return @{ promoted = $false; signature = $Candidate.signature; written = $null }
    }
    Set-MemoryPromoted -Signature $Candidate.signature -Path $Path
    return @{ promoted = $true; signature = $Candidate.signature; written = $written }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — through T29, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/memory-lib.ps1 scripts/test-memory-lib.ps1
git commit -m "feat(memory): seamed capture source + two-path promotion (Task 5)"
```

---

### Task 6: CLI + slash commands + bootstrap wiring + plugin bump

**Files:**
- Create: `scripts/fleet-memory.ps1`
- Create: `commands/remember.md`
- Create: `commands/recall.md`
- Create: `commands/memory-promote.md`
- Modify: `scripts/memory-lib.ps1` (no change — referenced only)
- Modify: `scripts/test-memory-lib.ps1` (add CLI child-process checks)
- Modify: `scripts/bootstrap.ps1:259` (manifest array — add two scripts)
- Modify: `scripts/test-bootstrap.ps1` (two deploy asserts)
- Modify: `.claude-plugin/plugin.json` (`1.2.0-rc.12` → `1.2.0-rc.13`)

**Interfaces:**
- Consumes: every public function from `scripts/memory-lib.ps1` (Tasks 1–5).
- Produces: the `/baton:remember`, `/baton:recall`, `/baton:memory-promote` operator surfaces via `scripts/fleet-memory.ps1 <subcommand> $ARGUMENTS`. Test seam: `BATON_HOME` redirects the journal; `BATON_MEM_LESSONS` redirects the default promotion writer's target (so the CLI promote test never writes the real KB).

- [ ] **Step 1: Write the CLI runner**

Create `scripts/fleet-memory.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Memory Bridge runner. Subcommands: remember (capture a problem->attempt->outcome),
  recall (pre-action warning if a task matches a past attempt), promote (watch list /
  flag one into Grimdex). Advisory only — never blocks work.
.NOTES
  See docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'recall',
    [Parameter(Position=1)][string]$Target,                 # id|signature for promote (flag path)
    [string]$Problem,
    [string]$Approach,
    [ValidateSet('pass','fail','partial','unknown')][string]$Outcome = 'unknown',
    [string]$Tags,
    [ValidateSet('project','universal')][string]$Scope = 'project',
    [string]$RefJob,
    [string]$Text,
    [string]$File,
    [double]$MinOverlap = 0.5,
    [switch]$Deep,
    [switch]$Json,
    [string]$MemoryPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'memory-journal.jsonl' } else { Join-Path $HOME '.baton/memory-journal.jsonl' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'memory-lib.ps1')

switch ($Subcommand) {
    'remember' {
        if (-not $Problem) { Write-Error "remember requires -Problem"; exit 2 }
        $tagArr = if ($Tags) { @($Tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $refs = @{}; if ($RefJob) { $refs['job'] = $RefJob }
        $res = Add-MemoryEvent -Problem $Problem -Approach $Approach -Outcome $Outcome -Tags $tagArr -Scope $Scope -Source 'manual' -Refs $refs -Path $MemoryPath
        if ($Json) { $res | ConvertTo-Json } else { Write-Host "remembered $($res.id) (signature: $($res.signature))" }
        return
    }
    'recall' {
        $task = if ($Text) { $Text }
                elseif ($File) { if (-not (Test-Path $File)) { Write-Error "file not found: $File"; exit 2 }; (Get-Content -LiteralPath $File -Raw).Trim() }
                else { '' }
        if (-not $task) { Write-Error "recall requires -Text or -File"; exit 2 }
        $r = Invoke-MemoryRecall -Task $task -MinOverlap $MinOverlap -Deep:$Deep -Path $MemoryPath
        if ($Json) { $r | ConvertTo-Json -Depth 6 }
        else { Write-Host (Format-RecallReport -Query $task -Matches $r.matches -Candidates $r.candidates -SemanticCandidates $r.semantic) }
        return
    }
    'promote' {
        if ($Target) {
            $pArgs = @{ Path = $MemoryPath }
            if ($Target -like 'mem-*') { $pArgs['Id'] = $Target } else { $pArgs['Signature'] = $Target }
            $res = Invoke-MemoryPromote @pArgs
            if ($Json) { $res | ConvertTo-Json }
            elseif ($res.promoted) { Write-Host "promoted signature '$($res.signature)' -> $($res.written)" }
            else { Write-Host "promotion write failed for '$($res.signature)' — left un-stamped." }
        } else {
            $cands = Get-PromotionCandidates -Path $MemoryPath
            if ($Json) { @($cands) | ConvertTo-Json -Depth 6 }
            elseif (@($cands).Count -eq 0) { Write-Host "No promotion candidates." }
            else {
                Write-Host "Promotion candidates:"
                foreach ($c in $cands) { Write-Host "  • $($c.signature) — $($c.reason) [$($c.kind)]  (flag: /baton:memory-promote $($c.signature))" }
            }
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use remember|recall|promote)"; exit 2 }
}
```

- [ ] **Step 2: Write the three slash commands**

Create `commands/remember.md`:

```markdown
---
description: Capture a problem→attempt→outcome into Baton's dev memory so recall can warn before you repeat a known-bad fix. Box-private, advisory.
argument-hint: -Problem "<p>" [-Approach "<a>"] [-Outcome pass|fail|partial|unknown] [-Tags a,b] [-Scope project|universal] [-RefJob <id>]
---

# /baton:remember

Append a problem→attempt→outcome row to the box-private memory journal. Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" remember $ARGUMENTS
```

## Arguments

$ARGUMENTS
```

Create `commands/recall.md`:

```markdown
---
description: Before starting a task, check Baton's dev memory for prior attempts on the same problem — warns when a past fix failed. --deep adds semantic KB neighbors. Advisory.
argument-hint: (-Text "<task>" | -File <path>) [-Deep] [-Json]
---

# /baton:recall

Warn if a task matches a past attempt (especially a known-bad fix). Deterministic
signature match always; `-Deep` adds semantic KB discovery. Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" recall $ARGUMENTS
```

## Arguments

$ARGUMENTS
```

Create `commands/memory-promote.md`:

```markdown
---
description: Crystallize a recurring memory pattern into a Grimdex rule. No args lists watched candidates (auto-detected); pass an id/signature to flag one. Always a visible write.
argument-hint: [<id|signature>] [-Json]
---

# /baton:memory-promote

Promote a recurring problem→attempt→outcome pattern into Grimdex. With no target it
lists the auto-detected candidates (the watcher); with an id or signature it promotes
that one (the flag path). Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" promote $ARGUMENTS
```

## Arguments

$ARGUMENTS
```

- [ ] **Step 3: Add the CLI child-process tests**

In `scripts/test-memory-lib.ps1`, insert before the closing `}` of `try` (after the Task 5 block):

```powershell
    # ---- Task 6: CLI (child process; zero network/model) ----
    $cli = Join-Path $PSScriptRoot 'fleet-memory.ps1'
    $cliHome = Join-Path $tmpDir 'clihome'
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    $env:BATON_HOME = $cliHome
    $env:BATON_MEM_LESSONS = (Join-Path $tmpDir 'cli-lessons.md')   # redirect promotion writer off the real KB

    & pwsh -NoProfile -File $cli remember -Problem 'auth test is flaky in ci' -Approach 'mock clock' -Outcome fail 2>&1 | Out-Null
    & pwsh -NoProfile -File $cli remember -Problem 'auth test is flaky in ci' -Approach 'raise timeout' -Outcome fail 2>&1 | Out-Null
    Check 'T30 CLI remember round-trips into journal' (@(Read-MemoryJournal -Path (Join-Path $cliHome 'memory-journal.jsonl')).Count -eq 2)

    $recallOut = & pwsh -NoProfile -File $cli recall -Text 'fix the flaky auth test' 2>&1 | Out-String
    Check 'T31 CLI recall prints warning + failed count' ($recallOut -match 'RECALL' -and $recallOut -match 'FAILED')

    $listOut = & pwsh -NoProfile -File $cli promote 2>&1 | Out-String
    Check 'T32 CLI promote (no target) lists candidates' ($listOut -match 'Promotion candidates' -and $listOut -match 'avoid')

    $sig = (Get-PromotionCandidates -Path (Join-Path $cliHome 'memory-journal.jsonl'))[0].signature
    & pwsh -NoProfile -File $cli promote $sig 2>&1 | Out-Null
    $stamped = @(Read-MemoryJournal -Path (Join-Path $cliHome 'memory-journal.jsonl') | Where-Object { $_.promoted -eq $true }).Count
    Check 'T33 CLI promote <signature> writes lessons + stamps rows' ((Test-Path $env:BATON_MEM_LESSONS) -and $stamped -eq 2)

    Remove-Item Env:\BATON_HOME, Env:\BATON_MEM_LESSONS -ErrorAction SilentlyContinue
```

- [ ] **Step 4: Wire the bootstrap manifest**

In `scripts/bootstrap.ps1`, line 259 (the `foreach ($script in @(...))` deploy manifest), add `'memory-lib.ps1', 'fleet-memory.ps1'` immediately after `'fleet-go.ps1',`. The fragment to change:

```
'research-gate-lib.ps1', 'fleet-research-gate.ps1', 'conductor-lib.ps1', 'fleet-go.ps1', 'idea-lib.ps1')) {
```

becomes:

```
'research-gate-lib.ps1', 'fleet-research-gate.ps1', 'conductor-lib.ps1', 'fleet-go.ps1', 'memory-lib.ps1', 'fleet-memory.ps1', 'idea-lib.ps1')) {
```

- [ ] **Step 5: Add the bootstrap deploy asserts**

In `scripts/test-bootstrap.ps1`, after the `fleet-go` assert (line ~51 `Assert "deploys fleet-go script" ...`), add:

```powershell
Assert "deploys memory-lib script"   ($out -match 'memory-lib\.ps1')
Assert "deploys fleet-memory script" ($out -match 'fleet-memory\.ps1')
```

- [ ] **Step 6: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.2.0-rc.12"` to `"version": "1.2.0-rc.13"`.

- [ ] **Step 7: Run both suites to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-memory-lib.ps1`
Expected: PASS — `ALL CHECKS PASS` (T1–T33), exit 0.

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — including the two new memory deploy asserts.

- [ ] **Step 8: Commit**

```bash
git add scripts/fleet-memory.ps1 commands/remember.md commands/recall.md commands/memory-promote.md scripts/test-memory-lib.ps1 scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(memory): /baton:remember + /baton:recall + /baton:memory-promote CLI, bootstrap wiring, rc.13 (Task 6)"
```

---

## Notes for the final whole-branch review

- **Spec:** `docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md` (d-mb-1..6).
- **Hermeticity is the headline risk to verify:** confirm no test touches a real network, model, real `$BATON_HOME`, or the real KB — the CLI promote test MUST set `BATON_MEM_LESSONS` to a temp file (Task 6 Step 3) so the default writer never appends to `~/.claude/knowledge/...`.
- **Determinism:** `Get-MemorySignature` must be order-independent and stable (T6); the only non-deterministic path is `-Deep` semantic recall, which is advisory.
- **Automatic-variable trap:** verify no parameter/local named `$args`/`$input`/`$event` (the CLI uses `$pArgs`).
- **Array-flatten:** `Find-MemoryMatches`, `Get-PromotionCandidates`, `Invoke-MemorySource` return via the `,([...]@(...))` idiom — confirm single-element returns stay arrays.
