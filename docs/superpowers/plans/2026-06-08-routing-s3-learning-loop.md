# Routing Slice 3 — Learning Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Slice 1's static `0.5` quality with a *learned quality* per
`(capability, candidate)` — a pseudo-count blend of the user's ratings, an LLM-judge
score, and heuristic pass-history — fed back as the within-tier tiebreaker, plus a
`/route --rate` capture and an LLM-judge grader on the Slice 2 seam.

**Architecture:** New `scripts/routing-learn.ps1` holds all learning functions; it is
dot-sourced by `routing-lib.ps1` (so `Select-Capability` sees it, and transitively
`routing-dispatch.ps1` does too). Ratings persist to the GitHub-backed knowledge repo
(`~/.claude/knowledge/universal/routing-ratings.jsonl`); the journal stays local. The
ranking formula is **unchanged** — cost tier dominates; learned quality only reorders
within a tier.

**Tech Stack:** PowerShell 7. JSONL stores. Existing `Read-Fleet`/`Invoke-Fleet`
(fleet-lib.ps1), `Test-RoutingOutputHeuristic`/`Write-RoutingJournalLine`/
`Invoke-RoutedCapability` (routing-dispatch.ps1), `Select-Capability` (routing-lib.ps1).

**Conventions (match the existing suites):**
- Test harness: `function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }`; temp fixtures under `[System.IO.Path]::GetTempPath()`; `try{...}finally{ Remove-Item -Recurse -Force $tmp }`; `if($script:fail -gt 0){exit 1}else{exit 0}`.
- `test-routing-learn.ps1` dot-sources **`routing-dispatch.ps1`** (which loads lib → learn → fleet-lib), so every function is in scope and no real model calls happen (judge is injected).
- JSONL writes: `Add-Content -LiteralPath $p -Value ($obj | ConvertTo-Json -Compress) -Encoding utf8NoBOM`.
- Array-return idiom: `return ,([object[]]$arr)`.
- Injectable `-Timestamp` (default `(Get-Date).ToString('o')`) and injectable dispatchers for determinism.
- All file-reading functions treat a missing path as empty and skip malformed lines (try/catch per line) — never throw.

---

## Task 1: `routing-learn.ps1` skeleton + ratings store

**Files:**
- Create: `scripts/routing-learn.ps1`
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Write the failing test** — create `scripts/test-routing-learn.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-dispatch.ps1"   # loads routing-lib -> routing-learn -> fleet-lib

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-learn-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ===== Task 1: ratings store =====
    $ratings = Join-Path $tmp 'routing-ratings.jsonl'

    # Missing file -> empty, no throw.
    Check 'ratings missing -> empty' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 0)

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'good' -Note 'clean subject' -RatingsPath $ratings `
        -Timestamp '2026-06-08T00:00:00.0000000-06:00'
    $rs = @(Get-CapabilityRatings -RatingsPath $ratings)
    Check 'rating appended'        ($rs.Count -eq 1)
    Check 'rating capability'      ($rs[0].capability -eq 'commit-msg')
    Check 'rating candidate'       ($rs[0].candidate -eq 'devstral')
    Check 'rating value'           ($rs[0].rating -eq 'good')
    Check 'rating note'            ($rs[0].note -eq 'clean subject')
    Check 'rating ts injected'     ($rs[0].ts -eq '2026-06-08T00:00:00.0000000-06:00')

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'bad' -RatingsPath $ratings -Timestamp '2026-06-08T00:00:01.0000000-06:00'
    Check 'rating appends second'  (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)

    # Creates nested dir if absent.
    $nested = Join-Path $tmp 'knowledge/universal/routing-ratings.jsonl'
    Add-CapabilityRating -Capability 'x' -Candidate 'y' -Source 'tools' -Rating 'good' -RatingsPath $nested
    Check 'rating creates nested dir' (Test-Path $nested)

    # Malformed line skipped on read.
    Add-Content -LiteralPath $ratings -Value 'not json{{' -Encoding utf8NoBOM
    Check 'malformed ratings line skipped' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — `routing-learn.ps1` does not exist yet (dot-source error or missing functions).

- [ ] **Step 3: Create `scripts/routing-learn.ps1` with the skeleton + ratings functions:**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capability-routing learning loop (Slice 3). Aggregates the user's ratings, LLM-judge
  scores, and heuristic pass-history into a learned per-(capability,candidate) quality,
  captures ratings, and provides an LLM-judge grader for the Slice 2 -Grader seam.
.DESCRIPTION
  Dot-sourced by routing-lib.ps1 (so Select-Capability and routing-dispatch.ps1 both see
  these functions). Ratings persist to the GitHub-backed knowledge repo; the journal stays
  local. See docs/superpowers/specs/2026-06-08-routing-s3-learning-loop-design.md.
#>

$script:DefaultRatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl')

function Read-JsonlRows {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. Returns object[]. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return ,([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ,([object[]]$out.ToArray())
}

function Get-CapabilityRatings {
    <# All rating rows (optionally filtered by capability/candidate). #>
    param(
        [string]$Capability, [string]$Candidate,
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    $rows = Read-JsonlRows -Path $RatingsPath
    if ($Capability) { $rows = @($rows | Where-Object { $_.capability -eq $Capability }) }
    if ($Candidate)  { $rows = @($rows | Where-Object { $_.candidate  -eq $Candidate  }) }
    return ,([object[]]$rows)
}

function Add-CapabilityRating {
    <# Append one rating row to the GitHub-backed ratings store. Creates the dir/file.
       A write fault warns and returns; never crashes. -Timestamp injectable for tests. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$Source = '',
        [Parameter(Mandatory)][ValidateSet('good','bad')][string]$Rating,
        [string]$Note = '',
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [string]$Timestamp
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToString('o') }
    $row = [ordered]@{
        ts = $Timestamp; capability = $Capability; candidate = $Candidate
        source = $Source; rating = $Rating; note = $Note
    }
    try {
        $dir = Split-Path -Parent $RatingsPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $RatingsPath -Value ($row | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    } catch {
        Write-Warning "routing rating write failed: $($_.Exception.Message)"
    }
}
```

- [ ] **Step 4: Wire the dot-source so the test can load it.** In `scripts/routing-lib.ps1`, after the existing `. "$PSScriptRoot/fleet-lib.ps1"` line (routing-lib.ps1:11), add:

```powershell
. "$PSScriptRoot/routing-learn.ps1"   # Slice 3 learning loop (ratings + learned quality + judge)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: PASS (all Task 1 checks).

- [ ] **Step 6: Commit**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1 scripts/routing-lib.ps1
git commit -m "feat(routing): Slice 3 ratings store + routing-learn.ps1 skeleton"
```

---

## Task 2: `Get-CapabilityQuality` + `Get-CapabilityQualityDetail` (the blend)

**Files:**
- Modify: `scripts/routing-learn.ps1`
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Add failing tests** — insert before the `finally` in `test-routing-learn.ps1`:

```powershell
    # ===== Task 2: learned quality blend =====
    $jq = Join-Path $tmp 'q-journal.jsonl'
    $rq = Join-Path $tmp 'q-ratings.jsonl'

    # Cold start: no data -> prior.
    Check 'cold-start -> 0.5 prior' ([math]::Abs((Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm1' -JournalPath $jq -RatingsPath $rq) - 0.5) -lt 1e-9)
    Check 'cold-start -> yaml prior' ([math]::Abs((Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm1' -JournalPath $jq -RatingsPath $rq -Prior 0.8) - 0.8) -lt 1e-9)

    # Helper to seed journal rows (passed + grader + score).
    function Add-JRow($cap,$cand,$passed,$score,$grader,$path){
        $o=[ordered]@{ ts='2026-01-01T00:00:00Z'; capability=$cap; candidate=$cand; source='fleet'; kind='cli'; cost_tier='free'; exit_code=0; duration_s=1; passed=$passed; score=$score; reason='x'; grader=$grader }
        Add-Content -LiteralPath $path -Value ($o|ConvertTo-Json -Compress) -Encoding utf8NoBOM
    }

    # All-good user ratings pull quality up toward 1.0.
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm2' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp "2026-01-01T00:00:0$_Z" }
    $qUp = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm2' -JournalPath $jq -RatingsPath $rq
    Check 'good ratings raise quality' ($qUp -gt 0.7)

    # All-bad ratings pull quality down below the prior.
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm3' -Source 'fleet' -Rating 'bad' -RatingsPath $rq -Timestamp "2026-01-01T00:01:0$_Z" }
    $qDn = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm3' -JournalPath $jq -RatingsPath $rq
    Check 'bad ratings lower quality' ($qDn -lt 0.3)

    # Low-n shrinkage: a single good rating stays nearer the prior than 5 do.
    Add-CapabilityRating -Capability 'code-gen' -Candidate 'm4' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp '2026-01-01T00:02:00Z'
    $q1 = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm4' -JournalPath $jq -RatingsPath $rq
    Check 'single rating shrinks toward prior' ($q1 -gt 0.5 -and $q1 -lt $qUp)

    # Judge + heuristic blend (no user ratings): mid-high judge + all-pass heuristic > prior.
    1..4 | ForEach-Object { Add-JRow 'code-gen' 'm5' $true 0.8 'llm-judge' $jq }
    1..4 | ForEach-Object { Add-JRow 'code-gen' 'm5' $true 1.0 'heuristic' $jq }
    $qj = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm5' -JournalPath $jq -RatingsPath $rq
    Check 'judge+heuristic raise quality' ($qj -gt 0.5)

    # Bounded [0,1].
    1..20 | ForEach-Object { Add-CapabilityRating -Capability 'code-gen' -Candidate 'm6' -Source 'fleet' -Rating 'good' -RatingsPath $rq -Timestamp "2026-01-01T00:03:$($_.ToString('00'))Z" }
    $qMax = Get-CapabilityQuality -Capability 'code-gen' -Candidate 'm6' -JournalPath $jq -RatingsPath $rq
    Check 'quality bounded <= 1' ($qMax -le 1.0 -and $qMax -gt 0.9)

    # Detail breakdown reports component rates + counts.
    $d = Get-CapabilityQualityDetail -Capability 'code-gen' -Candidate 'm5' -JournalPath $jq -RatingsPath $rq
    Check 'detail judge n' ($d.judge.n -eq 4)
    Check 'detail heuristic n' ($d.heuristic.n -eq 8)   # 4 judge rows + 4 heuristic rows, all passed
    Check 'detail user n zero' ($d.user.n -eq 0)
    Check 'detail quality matches' ([math]::Abs($d.quality - $qj) -lt 1e-9)
```

> Note: `m5` has 8 total journal rows (4 `llm-judge` + 4 `heuristic`); `heuristic.n` counts ALL rows (pass-rate over everything), `judge.n` counts only `grader='llm-judge'` rows.

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — `Get-CapabilityQuality`/`Get-CapabilityQualityDetail` not defined.

- [ ] **Step 3: Add the aggregation functions to `routing-learn.ps1`:**

```powershell
function Get-RoutingStats {
    <# Per-(capability,candidate) signal stats from ratings + journal. Internal. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath
    )
    # User ratings
    $rt = Get-CapabilityRatings -Capability $Capability -Candidate $Candidate -RatingsPath $RatingsPath
    $nu = @($rt).Count
    $gu = @($rt | Where-Object { $_.rating -eq 'good' }).Count
    $ru = if ($nu -gt 0) { [double]$gu / $nu } else { 0.0 }

    # Journal rows for this pair
    $rows = @(Read-JsonlRows -Path $JournalPath | Where-Object { $_.capability -eq $Capability -and $_.candidate -eq $Candidate })
    $judge = @($rows | Where-Object { $_.grader -eq 'llm-judge' })
    $nj = $judge.Count
    $rj = if ($nj -gt 0) { [double](($judge | Measure-Object -Property score -Average).Average) } else { 0.0 }
    $nh = $rows.Count
    $ph = @($rows | Where-Object { $_.passed -eq $true }).Count
    $rh = if ($nh -gt 0) { [double]$ph / $nh } else { 0.0 }

    return @{
        user      = @{ rate = $ru; n = [int]$nu }
        judge     = @{ rate = $rj; n = [int]$nj }
        heuristic = @{ rate = $rh; n = [int]$nh }
    }
}

function Get-CapabilityQualityDetail {
    <# Learned quality + its provenance. Pseudo-count Bayesian blend; shrinks to -Prior. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    $s  = Get-RoutingStats -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath
    $k  = 2.0; $Wu = 1.0; $Wj = 0.5; $Wh = 0.25
    $numer = ($Prior * $k) + ($Wu * $s.user.n * $s.user.rate) + ($Wj * $s.judge.n * $s.judge.rate) + ($Wh * $s.heuristic.n * $s.heuristic.rate)
    $denom = $k + ($Wu * $s.user.n) + ($Wj * $s.judge.n) + ($Wh * $s.heuristic.n)
    $q = if ($denom -gt 0) { $numer / $denom } else { $Prior }
    if ($q -lt 0.0) { $q = 0.0 }
    if ($q -gt 1.0) { $q = 1.0 }
    return @{
        quality   = [double]$q
        prior     = [double]$Prior
        user      = $s.user
        judge     = $s.judge
        heuristic = $s.heuristic
    }
}

function Get-CapabilityQuality {
    <# Learned quality in [0,1] for a (capability, candidate). Convenience wrapper. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Candidate,
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$RatingsPath = $script:DefaultRatingsPath,
        [double]$Prior = 0.5
    )
    return (Get-CapabilityQualityDetail -Capability $Capability -Candidate $Candidate -JournalPath $JournalPath -RatingsPath $RatingsPath -Prior $Prior).quality
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: PASS (Task 1 + Task 2).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): learned-quality blend (ratings + judge + heuristic)"
```

---

## Task 3: `Get-LastRoutedAttempt` (journal tail → last winner)

**Files:**
- Modify: `scripts/routing-learn.ps1`
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Add failing tests** before the `finally`:

```powershell
    # ===== Task 3: last routed attempt =====
    $jt = Join-Path $tmp 'tail-journal.jsonl'
    Check 'no journal -> null winner' ($null -eq (Get-LastRoutedAttempt -JournalPath $jt))

    Add-JRow 'code-gen' 'a' $false 0.0 'heuristic' $jt
    Add-JRow 'code-gen' 'b' $true  1.0 'heuristic' $jt   # winner of run 1
    Add-JRow 'summarize' 'c' $false 0.0 'heuristic' $jt
    Add-JRow 'summarize' 'd' $true  1.0 'llm-judge' $jt  # winner of run 2 (most recent)
    $last = Get-LastRoutedAttempt -JournalPath $jt
    Check 'last winner is most recent pass' ($last.candidate -eq 'd' -and $last.capability -eq 'summarize')

    # A trailing all-fail run leaves the previous winner as "last" only if we scan for passed;
    # but per spec the LAST run had no winner -> we still return the most recent PASSED row.
    Add-JRow 'code-gen' 'e' $false 0.0 'heuristic' $jt
    $last2 = Get-LastRoutedAttempt -JournalPath $jt
    Check 'last winner skips trailing fails' ($last2.candidate -eq 'd')

    # Malformed tail line tolerated.
    Add-Content -LiteralPath $jt -Value 'broken{{' -Encoding utf8NoBOM
    Check 'tail tolerates malformed line' ((Get-LastRoutedAttempt -JournalPath $jt).candidate -eq 'd')
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — `Get-LastRoutedAttempt` not defined.

- [ ] **Step 3: Add to `routing-learn.ps1`:**

```powershell
function Get-LastRoutedAttempt {
    <# The most recent PASSING attempt in the journal — the winner the user last saw.
       Returns $null when no passing attempt exists. #>
    param([string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'))
    $rows = Read-JsonlRows -Path $JournalPath
    for ($i = $rows.Count - 1; $i -ge 0; $i--) {
        if ($rows[$i].passed -eq $true) { return $rows[$i] }
    }
    return $null
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): Get-LastRoutedAttempt reads journal tail for last winner"
```

---

## Task 4: LLM-judge grader (`Invoke-LlmJudge`, `Get-LlmJudgeGrader`, `Get-CheapestLocalModel`)

**Files:**
- Modify: `scripts/routing-learn.ps1`
- Test: `scripts/test-routing-learn.ps1`

- [ ] **Step 1: Add failing tests** before the `finally`:

```powershell
    # ===== Task 4: LLM-judge grader =====
    # Injected judge dispatcher returns a fixed JSON; counts calls to prove short-circuit.
    $script:judgeCalls = 0
    $judgeDisp = { param($model,$prompt) $script:judgeCalls++; '{"score":0.9,"reason":"good output"}' }

    # Heuristic FAIL (empty) short-circuits -> no judge dispatch.
    $grader = Get-LlmJudgeGrader -JudgeModel 'judge-m' -JudgeDispatcher $judgeDisp
    $vEmpty = & $grader -Capability 'code-gen' -Result @{ stdout="  `n "; exit_code=0; duration_s=1 }
    Check 'judge: empty short-circuits'   ($vEmpty.passed -eq $false -and $vEmpty.grader -eq 'heuristic')
    Check 'judge: no dispatch on fail'    ($script:judgeCalls -eq 0)

    # Heuristic PASS -> judge runs, score>=threshold -> pass, tagged llm-judge.
    $vPass = & $grader -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: passes high score'      ($vPass.passed -eq $true -and $vPass.grader -eq 'llm-judge')
    Check 'judge: score surfaced'         ([math]::Abs($vPass.score - 0.9) -lt 1e-9)
    Check 'judge: dispatched once'        ($script:judgeCalls -eq 1)

    # Low judge score -> fail.
    $lowDisp = { param($model,$prompt) '{"score":0.2,"reason":"weak"}' }
    $graderLow = Get-LlmJudgeGrader -JudgeModel 'judge-m' -Threshold 0.6 -JudgeDispatcher $lowDisp
    $vLow = & $graderLow -Capability 'code-gen' -Result @{ stdout='meh'; exit_code=0; duration_s=1 }
    Check 'judge: low score fails'        ($vLow.passed -eq $false -and $vLow.grader -eq 'llm-judge')

    # Judge throws -> heuristic fallback, never blocks.
    $boomDisp = { param($model,$prompt) throw 'model down' }
    $graderBoom = Get-LlmJudgeGrader -JudgeModel 'judge-m' -JudgeDispatcher $boomDisp
    $vBoom = & $graderBoom -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: error -> heuristic fallback' ($vBoom.passed -eq $true -and $vBoom.grader -eq 'heuristic' -and $vBoom.reason -match 'judge unavailable')

    # No judge model available + no injected dispatcher -> heuristic fallback.
    $graderNone = Get-LlmJudgeGrader -FleetPath (Join-Path $tmp 'no-fleet.yaml')
    $vNone = & $graderNone -Capability 'code-gen' -Result @{ stdout='real output'; exit_code=0; duration_s=1 }
    Check 'judge: no model -> heuristic'  ($vNone.grader -eq 'heuristic' -and $vNone.reason -match 'judge unavailable')

    # Invoke-LlmJudge parses an embedded JSON object out of chatty output.
    $chatDisp = { param($model,$prompt) "Sure! Here is my rating:`n{\"score\": 0.75, \"reason\": \"ok\"}`nThanks" }
    $ij = Invoke-LlmJudge -Capability 'code-gen' -Output 'x' -JudgeModel 'j' -Dispatcher $chatDisp
    Check 'Invoke-LlmJudge parses embedded JSON' ([math]::Abs($ij.score - 0.75) -lt 1e-9)
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — judge functions not defined.

- [ ] **Step 3: Add to `routing-learn.ps1`:**

```powershell
function Get-CheapestLocalModel {
    <# Name of the first enabled local ($0) fleet model, or $null. #>
    param([string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'))
    if (-not (Test-Path $FleetPath)) { return $null }
    $local = @(Read-Fleet -Path $FleetPath | Where-Object { $_.enabled -eq $true -and $_.cost_tier -eq 'local' })
    if ($local.Count -eq 0) { return $null }
    return [string]$local[0].name
}

function Invoke-LlmJudge {
    <# Ask a cheap model to score an output 0..1 for a capability. Returns @{score;reason}.
       -Dispatcher (param: model, prompt -> raw string) is injected in tests; otherwise the
       judge dispatches via Invoke-Fleet -NoJournal. Throws on no-JSON / parse failure so the
       grader can fall back. #>
    param(
        [Parameter(Mandatory)][string]$Capability,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string]$JudgeModel,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [scriptblock]$Dispatcher
    )
    $rubric = @"
You are grading the OUTPUT of a tool that was asked to perform a '$Capability' task.
Score from 0.0 to 1.0 how well the OUTPUT satisfies such a request.
Reply with ONLY compact JSON: {"score": <number 0..1>, "reason": "<short>"}

OUTPUT:
$Output
"@
    if ($Dispatcher) {
        $raw = [string](& $Dispatcher $JudgeModel $rubric)
    } else {
        $r = Invoke-Fleet -Name $JudgeModel -Prompt $rubric -Path $FleetPath -NoJournal
        $raw = [string]$r.stdout
    }
    $m = [regex]::Match($raw, '\{.*\}', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $m.Success) { throw "judge returned no JSON object" }
    $obj = $m.Value | ConvertFrom-Json -ErrorAction Stop
    $score = [double]$obj.score
    if ($score -lt 0.0) { $score = 0.0 }
    if ($score -gt 1.0) { $score = 1.0 }
    return @{ score = $score; reason = [string]$obj.reason }
}

function Get-LlmJudgeGrader {
    <# Build a grader scriptblock for the Slice 2 -Grader seam. Heuristic gates first (no
       paid judge call on broken output); a passing output is scored by the judge model.
       Tags the verdict with grader='llm-judge' (or 'heuristic' on gate-fail/fallback). #>
    param(
        [string]$JudgeModel,
        [double]$Threshold = 0.6,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [scriptblock]$JudgeDispatcher
    )
    $jm = $JudgeModel; $th = $Threshold; $fp = $FleetPath; $jd = $JudgeDispatcher
    return {
        param($Capability, $Result)
        $h = Test-RoutingOutputHeuristic -Capability $Capability -Result $Result
        if (-not $h.passed) {
            return @{ passed = $false; score = $h.score; reason = $h.reason; grader = 'heuristic' }
        }
        $model = if ($jm) { $jm } else { Get-CheapestLocalModel -FleetPath $fp }
        if (-not $model) {
            return @{ passed = $h.passed; score = $h.score; reason = "$($h.reason) (judge unavailable: no local model)"; grader = 'heuristic' }
        }
        try {
            $j = Invoke-LlmJudge -Capability $Capability -Output ([string]$Result.stdout) -JudgeModel $model -FleetPath $fp -Dispatcher $jd
            return @{ passed = ($j.score -ge $th); score = $j.score; reason = $j.reason; grader = 'llm-judge' }
        } catch {
            return @{ passed = $h.passed; score = $h.score; reason = "$($h.reason) (judge unavailable: $($_.Exception.Message))"; grader = 'heuristic' }
        }
    }.GetNewClosure()
}
```

> The `.GetNewClosure()` binds `$jm/$th/$fp/$jd` into the returned scriptblock; the
> function references (`Test-RoutingOutputHeuristic`, `Invoke-LlmJudge`,
> `Get-CheapestLocalModel`) resolve from the session at call time — all are loaded because
> `test-routing-learn.ps1` dot-sources `routing-dispatch.ps1`.

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-learn.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): LLM-judge grader with free heuristic gate + fallback"
```

---

## Task 5: journal `grader` field + `Invoke-RoutedCapability -Judge` switch

**Files:**
- Modify: `scripts/routing-dispatch.ps1`
- Test: `scripts/test-routing-learn.ps1` (judge-path integration) and `scripts/test-routing-dispatch.ps1` (grader-field regression)

- [ ] **Step 1: Add a failing test** — append to `test-routing-learn.ps1` before the `finally`:

```powershell
    # ===== Task 5: -Judge switch wires the judge grader + journals the grader tag =====
    $tj = Join-Path $tmp 't5-tools.yaml'
    Set-Content -Path $tj -Value "tools: []" -Encoding utf8
    $fj = Join-Path $tmp 't5-fleet.yaml'
    Set-Content -Path $fj -Value @"
general_capabilities: [code-gen]

providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
"@ -Encoding utf8
    $jj = Join-Path $tmp 't5-journal.jsonl'

    # Candidate dispatcher returns good output; judge dispatcher scores it high.
    $candDisp  = { param($cand,$prompt) @{ stdout='generated code'; stderr=''; exit_code=0; duration_s=1 } }
    $jDisp     = { param($model,$prompt) '{"score":0.95,"reason":"great"}' }
    $oJ = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $candDisp `
            -Judge -JudgeModel 'local-a' -JudgeDispatcher $jDisp `
            -ToolsPath $tj -FleetPath $fj -JournalPath $jj
    Check 'judge path: passes'          ($oJ.status -eq 'passed' -and $oJ.winner -eq 'local-a')
    $jrow = (@(Get-Content $jj))[0] | ConvertFrom-Json
    Check 'judge path: grader logged'   ($jrow.grader -eq 'llm-judge')
    Check 'judge path: judge score logged' ([math]::Abs($jrow.score - 0.95) -lt 1e-9)

    # Default (no -Judge, no -Grader): heuristic, grader tag = heuristic.
    $jj2 = Join-Path $tmp 't5b-journal.jsonl'
    $oH = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $candDisp `
            -ToolsPath $tj -FleetPath $fj -JournalPath $jj2
    $hrow = (@(Get-Content $jj2))[0] | ConvertFrom-Json
    Check 'default path: grader=heuristic' ($hrow.grader -eq 'heuristic')
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — `-Judge`/`-JudgeModel`/`-JudgeDispatcher` params unknown; `grader` not in journal row.

- [ ] **Step 3a: Add the `grader` field to `Write-RoutingJournalLine`.** In `routing-dispatch.ps1`, add a `-Grader` param (default `'heuristic'`) and a `grader` row field. Change the param block:

```powershell
        [bool]$Passed, [double]$Score, [string]$Reason,
        [string]$Grader = 'heuristic',
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl'),
        [string]$Timestamp
```

and the `$row` ordered hashtable (add `grader` after `reason`):

```powershell
        passed = $Passed; score = $Score; reason = $Reason; grader = $Grader
```

- [ ] **Step 3b: Add the judge params + grader resolution to `Invoke-RoutedCapability`.** Add to its `param(...)` block (after `[scriptblock]$Dispatcher`):

```powershell
        [switch]$Judge,
        [string]$JudgeModel,
        [scriptblock]$JudgeDispatcher,
```

After `$candidates = Select-Capability @sel` (and before building `$attempts`), resolve the effective grader once:

```powershell
    # Slice 3: -Grader wins; else -Judge wires the LLM-judge grader; else heuristic default.
    $effGrader = if ($Grader) { $Grader }
                 elseif ($Judge) { Get-LlmJudgeGrader -JudgeModel $JudgeModel -FleetPath $FleetPath -JudgeDispatcher $JudgeDispatcher }
                 else { $null }
```

In the verify block, replace the existing `$Grader`/heuristic branch with `$effGrader`:

```powershell
        try {
            if ($effGrader) { $verdict = & $effGrader -Capability $Capability -Result $result }
            else            { $verdict = Test-RoutingOutputHeuristic -Capability $Capability -Result $result }
        } catch {
            $verdict = @{ passed=$false; score=0.0; reason="grader error: $($_.Exception.Message)" }
        }
```

Capture the grader tag (default `heuristic`) and pass it to the journal. After the verdict is computed, add:

```powershell
        $graderTag = if ($verdict.grader) { [string]$verdict.grader } else { 'heuristic' }
```

and add `-Grader $graderTag` to the `Write-RoutingJournalLine` call:

```powershell
        Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind `
            -CostTier $c.cost_tier -ExitCode ([int]$result.exit_code) -DurationS ([int]$result.duration_s) `
            -Passed ([bool]$verdict.passed) -Score ([double]$verdict.score) -Reason ([string]$verdict.reason) `
            -Grader $graderTag -JournalPath $JournalPath
```

> Note the non-cli-skip branch earlier in the loop also calls `Write-RoutingJournalLine`
> without `-Grader`; it inherits the `'heuristic'` default — leave it as-is.

- [ ] **Step 4a: Add a `grader`-field regression check to `test-routing-dispatch.ps1`.** After the existing Task 2 journal checks (around line 47), add:

```powershell
    Check 'journal grader defaults heuristic' ($obj.grader -eq 'heuristic')
```

- [ ] **Step 4b: Run both suites to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: BOTH PASS (Slice 2 suite still green — default path unchanged; new grader field present).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-learn.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(routing): journal grader field + Invoke-RoutedCapability -Judge switch"
```

---

## Task 6: feed learned quality into `Select-Capability`

**Files:**
- Modify: `scripts/routing-lib.ps1`
- Test: `scripts/test-routing-learn.ps1` (integration) and existing `scripts/test-routing-lib.ps1` (regression)

- [ ] **Step 1: Add failing tests** — append to `test-routing-learn.ps1` before the `finally`:

```powershell
    # ===== Task 6: learned quality flows into Select-Capability =====
    $t6tools = Join-Path $tmp 't6-tools.yaml'
    Set-Content -Path $t6tools -Value @"
tools:
  - name: tool-local
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
  - name: tool-paid
    kind: cli
    enabled: true
    cost_tier: paid
    capability: commit-msg
"@ -Encoding utf8
    $t6fleet = Join-Path $tmp 't6-fleet.yaml'
    Set-Content -Path $t6fleet -Value "general_capabilities: []`n`nproviders: []" -Encoding utf8
    $t6ratings = Join-Path $tmp 't6-ratings.jsonl'
    $t6journal = Join-Path $tmp 't6-journal.jsonl'

    # Give the PAID tool great ratings and the LOCAL tool terrible ones.
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'commit-msg' -Candidate 'tool-paid' -Source 'tools' -Rating 'good' -RatingsPath $t6ratings -Timestamp "2026-02-01T00:00:0$_Z" }
    1..5 | ForEach-Object { Add-CapabilityRating -Capability 'commit-msg' -Candidate 'tool-local' -Source 'tools' -Rating 'bad' -RatingsPath $t6ratings -Timestamp "2026-02-01T00:01:0$_Z" }

    $cands = Select-Capability -Capability 'commit-msg' -ToolsPath $t6tools -FleetPath $t6fleet -RatingsPath $t6ratings -JournalPath $t6journal
    # COST DOMINANCE: despite terrible ratings, the local tool still ranks first.
    Check 'cost tier still dominates' ($cands[0].name -eq 'tool-local')
    # Learned quality is surfaced and reflects the ratings.
    Check 'paid learned quality high'  ($cands | Where-Object { $_.name -eq 'tool-paid' }  | ForEach-Object { $_.quality -gt 0.7 })
    Check 'local learned quality low'  ($cands | Where-Object { $_.name -eq 'tool-local' } | ForEach-Object { $_.quality -lt 0.3 })
    # quality_detail attached for legibility.
    Check 'quality_detail attached'    ($null -ne ($cands[0].quality_detail))
    Check 'quality_detail user n'      (($cands | Where-Object { $_.name -eq 'tool-paid' }).quality_detail.user.n -eq 5)
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Expected: FAIL — `Select-Capability` has no `-RatingsPath`/`-JournalPath` params; quality is static; no `quality_detail`.

- [ ] **Step 3: Wire learned quality into `Select-Capability`** (`routing-lib.ps1`). Add two params to its `param(...)` block:

```powershell
        [string]$ToolsPath = $script:DefaultToolsPath,
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$RatingsPath = (Join-Path $HOME '.claude/knowledge/universal/routing-ratings.jsonl'),
        [string]$JournalPath = (Join-Path $HOME '.claude/routing-journal.jsonl')
```

In the **tools** loop, replace the quality assignment + object build:

```powershell
            $prior = if ($null -ne $t.quality) { [double]$t.quality } else { 0.5 }
            $detail = Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$t.name) -Prior $prior -JournalPath $JournalPath -RatingsPath $RatingsPath
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$t.name; kind = [string]$t.kind; source = 'tools'
                cost_tier = [string]$t.cost_tier; quality = $detail.quality
                quality_detail = $detail
                why = "specialized tool for $Capability ($($t.cost_tier))"
            })
```

In the **fleet** loop, the same:

```powershell
            $prior = if ($null -ne $p.quality) { [double]$p.quality } else { 0.5 }
            $detail = Get-CapabilityQualityDetail -Capability $Capability -Candidate ([string]$p.name) -Prior $prior -JournalPath $JournalPath -RatingsPath $RatingsPath
            [void]$candidates.Add([pscustomobject]@{
                name = [string]$p.name; kind = [string]$p.kind; source = 'fleet'
                cost_tier = [string]$p.cost_tier; quality = $detail.quality
                quality_detail = $detail
                why = "general model for $Capability ($($p.cost_tier) tier)"
            })
```

> The ranking block (`Select-Object *, @{n='score';...}` then `Sort-Object`) is **unchanged**
> — `score = cost_tier_rank − quality·0.001` keeps cost dominant; `quality` is now learned.
> `quality_detail` rides along via `Select-Object *`.

- [ ] **Step 4: Keep the Slice 1 suite hermetic.** `test-routing-lib.ps1` calls
`Select-Capability` without `-RatingsPath`/`-JournalPath`, so it would now read the *real*
`~/.claude` journal/ratings and could perturb within-tier tiebreaks non-deterministically.
Make those calls hermetic by pointing them at non-existent temp paths. If the suite has a
shared setup, add once near the top:

```powershell
$nopath = Join-Path ([System.IO.Path]::GetTempPath()) ("rl-none-" + [guid]::NewGuid().ToString('N'))
```

and append `-RatingsPath $nopath -JournalPath $nopath` to each `Select-Capability` call in
that file (non-existent path → empty stats → learned quality = prior → original ordering).
If the suite already passes unchanged (its fixture candidate names match nothing in the real
stores), this is a no-op safeguard — apply it anyway for determinism.

- [ ] **Step 4b: Run learn + lib suites to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-learn.ps1`
Run: `pwsh -NoProfile -File scripts/test-routing-lib.ps1`
Expected: BOTH PASS. With no ratings/journal the learned quality equals the prior (0.5 or
yaml), so existing ordering is preserved.

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-lib.ps1 scripts/test-routing-learn.ps1
git commit -m "feat(routing): feed learned quality into Select-Capability (cost still dominant)"
```

---

## Task 7: `/route` command — `--rate`, `--judge`, provenance column

**Files:**
- Modify: `commands/route.md`

- [ ] **Step 1: Update the front matter** (`description` + `argument-hint`):

```markdown
---
description: Recommend OR dispatch the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), now with LEARNED quality from your ratings + an LLM-judge. Reads tools.yaml + fleet.yaml + the routing journal/ratings. --run dispatches & verifies; --rate records whether the last run's output was good; --judge forces LLM-judge grading.
argument-hint: "<capability>" [--max-tier local|free|paid] [--local] [--run "<prompt>"] [--judge] | --rate good|bad [note]
---
```

- [ ] **Step 2: Update the intro paragraph** (the `# /route` body) to mention learned quality and the two new actions. Replace the existing intro with:

```markdown
# /route

Recommend **or dispatch** the optimal capability for a need. Reads the `tools.yaml`
(capability-specific tools + specialty models) and `fleet.yaml` (general models) registries,
ranks the candidates that serve `<capability>` cheapest cost-tier first, and breaks ties by
**learned quality** — a blend of your `--rate` thumbs, an LLM-judge score, and heuristic
pass-history (`~/.claude/routing-journal.jsonl` + `~/.claude/knowledge/universal/routing-ratings.jsonl`).
Cost tier always dominates; quality only reorders within a tier. **Without `--run`** it
recommends. **With `--run "<prompt>"`** it dispatches, verifies, escalates up the cost ladder,
and logs every attempt. **`--rate good|bad`** records whether the last run's output was good.
```

- [ ] **Step 3: Add a provenance column to recommendation mode (step 2).** Replace the table-print block with one that surfaces `quality_detail`:

```powershell
     $cands | Format-Table name, source, cost_tier,
         @{n='quality'; e={ '{0:0.00}' -f $_.quality }},
         @{n='provenance'; e={ $d=$_.quality_detail; "you {0}/{1} · judge {2:0.00}x{3} · heur {4:0.00}x{5}" -f $d.user.n, ($d.user.n), $d.judge.rate, $d.judge.n, $d.heuristic.rate, $d.heuristic.n }},
         why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
```

> (The `you {0}/{1}` shows total ratings count twice as a simple "n ratings" hint; keep it
> simple — the goal is that the user sees the learned signal exists and its sample size.)

- [ ] **Step 4: Add `--judge` to dispatch mode (step 3).** After parsing, when `--judge` is
present OR a local judge model exists, pass `-Judge` to `Invoke-RoutedCapability`. Update the
dispatch block:

```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $opt = @{ Capability = '<capability>'; Prompt = '<prompt>' }
   if ($local)   { $opt['RequireLocal'] = $true }
   if ($maxTier) { $opt['MaxCostTier']  = '<tier>' }
   # Cost-optimal judging: on if --judge OR a free local judge model is available.
   if ($judge -or (Get-CheapestLocalModel)) { $opt['Judge'] = $true }
   $outcome = Invoke-RoutedCapability @opt
```

(Keep the existing attempts-trace + status reporting; the trace already prints per-attempt
reasons, which now include judge reasons.)

- [ ] **Step 5: Add a `--rate` action** as a new step before "On any error":

```markdown
4. **With `--rate good|bad [note]` (rating mode):**

   ```powershell
   . "$HOME/.claude/scripts/routing-dispatch.ps1"
   $last = Get-LastRoutedAttempt
   if (-not $last) {
       Write-Host "No completed /route --run with a winning candidate to rate yet."
   } else {
       Add-CapabilityRating -Capability $last.capability -Candidate $last.candidate `
           -Source $last.source -Rating '<good|bad>' -Note '<note>'
       Write-Host "Recorded '<good|bad>' for $($last.candidate) on $($last.capability). It will weight future routing."
   }
   ```

   The rating lands in the GitHub-backed knowledge repo (`routing-ratings.jsonl`) — push it
   with the standing knowledge backup so it rolls to any machine.
```

(Renumber the former step 4 "On any error" to step 5.)

- [ ] **Step 6: Commit**

```bash
git add commands/route.md
git commit -m "docs(routing): /route --rate, --judge, and learned-quality provenance column"
```

---

## Task 8: bootstrap deploys `routing-learn.ps1`

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`

- [ ] **Step 1: Add the failing bootstrap test.** In `test-bootstrap.ps1`, next to the existing `routing-dispatch.ps1` assertion, add:

```powershell
Assert "would deploy routing-learn.ps1" ($out -match 'routing-learn\.ps1')
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — `routing-learn.ps1` not in the deploy list.

- [ ] **Step 3: Add `routing-learn.ps1` to the libs array** in `bootstrap.ps1` (the `$libs` list near line 250), immediately after `'routing-dispatch.ps1'`:

```powershell
        'routing-dispatch.ps1',
        'routing-learn.ps1',
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(routing): bootstrap deploys routing-learn.ps1"
```

---

## Final gate (after all tasks)

Run the full routing + bootstrap suite and confirm all green:

```powershell
pwsh -NoProfile -File scripts/test-routing-learn.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-fleet.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

Then redeploy and smoke-test the live command path:

```powershell
pwsh scripts/bootstrap.ps1 -Force
# Recommendation still works (learned quality = prior when no data):
pwsh -NoProfile -Command ". `"$HOME/.claude/scripts/routing-lib.ps1`"; Select-Capability -Capability 'code-gen' | Format-Table name, cost_tier, quality"
```

Expected: every suite `ALL PASS`; `Select-Capability` lists candidates with a `quality`
column (0.50 where there is no history). Then proceed to the comprehensive review and the
gated merge to master.
