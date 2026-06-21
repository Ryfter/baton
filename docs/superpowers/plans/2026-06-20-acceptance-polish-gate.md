# Acceptance/Polish Gate (Sprint 7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/baton:gate` that runs a competitive review of a finished work artifact (≥2 reviewers, independent) and emits an `accept`/`polish`/`reject` verdict with deduped, severity-weighted findings plus a polish brief.

**Architecture:** Pure layer (`gate-lib.ps1`) parses each reviewer's strict-JSON findings, reconciles them deterministically (dedupe + agreed/solo tagging), and computes the verdict + formats output — no third LLM call. A seamed `Invoke-AcceptanceGate` runs the reviewers via an injectable `-Dispatcher` (default = routed `Invoke-Fleet`). A thin CLI (`fleet-gate.ps1`) resolves the artifact (file/diff/stdin) and prints the report. Advisory only — never blocks, never auto-polishes. Mirrors `research-gate-lib.ps1` + `fleet-research-gate.ps1` + `worker-lib.ps1`.

**Tech Stack:** PowerShell 7 (pwsh); the existing Baton fleet/routing libs; box-private `$BATON_HOME`; hermetic Check-harness tests.

## Global Constraints

- **Box-private:** reviewer roster, the real Codex+Opus pair, and any per-window budgets live ONLY in live `~/.baton/fleet.yaml`. The seed (`references/fleet.yaml`) carries the `review` capability + placeholder example grants — never real rosters/endpoints/budgets.
- **Hermetic tests:** never touch real `~/.baton` or `~/.claude`; temp dirs + try/finally cleanup; seams injected; **zero network**. Child-process CLI tests use a temp `$env:BATON_HOME` (and `Remove-Item Env:\BATON_HOME` after).
- **Fail-open:** a reviewer returning unparseable output degrades to one "unparsed" review — never crashes, never silently changes the verdict. All-unparsed → `accept` with a flagged reason.
- **Verdict rule (d-ag-5), parameterized:** any `critical` → `reject`; else any `important` → `polish`; else (`minor`/none) → `accept`. Defaults `-RejectAt critical -PolishAt important`.
- **Reviewers emit strict JSON (d-ag-3):** `[{"severity","area","summary"}]`, empty array = clean. The pure layer parses it; the seam never parses prose. Reviewer providers must be `stdin: true` so the prompt rides stdin (quote-safe).
- **PowerShell automatic-variable trap:** never name a param/local `$input`, `$args`, `$event`, `$host`, `$matches`. Read piped stdin via `[Console]::In.ReadToEnd()`, never `$input`.
- **Parser-precedence trap:** `Get-FindingSeverityRank $x -eq 0` parses as `Get-FindingSeverityRank ($x -eq 0)`. Always wrap: `(Get-FindingSeverityRank $x) -eq 0`.
- **Empty-array / unary-comma:** never return a bare array that can unroll to `$null`; functions here return hashtables holding array properties, so set the property to `@(...)` explicitly.
- **Version:** plugin `1.3.0-rc.1` → `1.3.0-rc.2` (continues the open, untagged v1.3.0 line).
- **Test file is cumulative:** every task APPENDS its checks to `scripts/test-gate-lib.ps1` and the whole suite must stay green at each task's end.

---

### Task 1: Severity rank + per-reviewer findings parse (pure)

**Files:**
- Create: `scripts/gate-lib.ps1`
- Create: `scripts/test-gate-lib.ps1`

**Interfaces:**
- Produces: `Get-FindingSeverityRank([string]$Severity) -> [int]` (critical=3, important=2, minor=1, unknown=0); `Get-FindingsJsonBlock([string]$Raw) -> [string]` (first `[`…last `]`, or `''`); `Get-ReviewFindings([string]$Output) -> @{ parsed=[bool]; findings=@(@{severity;area;summary}); raw=[string] }`.

- [ ] **Step 1: Write the failing test** — create `scripts/test-gate-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: severity rank + per-reviewer parse (pure) ----
    Check 'G1 critical -> 3'  ((Get-FindingSeverityRank 'critical')  -eq 3)
    Check 'G2 important -> 2' ((Get-FindingSeverityRank 'important') -eq 2)
    Check 'G3 minor -> 1'     ((Get-FindingSeverityRank 'minor')     -eq 1)
    Check 'G4 unknown -> 0'   ((Get-FindingSeverityRank 'banana')    -eq 0)
    Check 'G5 case-insensitive' ((Get-FindingSeverityRank 'CRITICAL') -eq 3)

    $bare = Get-ReviewFindings -Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
    Check 'G6 bare array parses' ($bare.parsed -and @($bare.findings).Count -eq 1 -and $bare.findings[0].severity -eq 'important')
    $empty = Get-ReviewFindings -Output '[]'
    Check 'G7 empty array -> parsed, 0 findings' ($empty.parsed -and @($empty.findings).Count -eq 0)
    $bad = Get-ReviewFindings -Output 'I could not find any structured issues, sorry.'
    Check 'G8 garbage -> not parsed' (-not $bad.parsed -and @($bad.findings).Count -eq 0)
    $prose = Get-ReviewFindings -Output 'Here are my findings: [{"severity":"minor","area":"style","summary":"naming"}] — done.'
    Check 'G9 array-in-prose parses' ($prose.parsed -and @($prose.findings).Count -eq 1 -and $prose.findings[0].area -eq 'style')
    $unk = Get-ReviewFindings -Output '[{"severity":"blocker","area":"x","summary":"y"}]'
    Check 'G10 unknown severity floored to minor, not dropped' ($unk.parsed -and @($unk.findings).Count -eq 1 -and $unk.findings[0].severity -eq 'minor')
    $trim = Get-ReviewFindings -Output '[{"severity":" Important ","area":"  perf ","summary":" slow "}]'
    Check 'G11 fields normalized/trimmed' ($trim.findings[0].severity -eq 'important' -and $trim.findings[0].area -eq 'perf' -and $trim.findings[0].summary -eq 'slow')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: FAIL — `gate-lib.ps1` does not exist / functions not defined.

- [ ] **Step 3: Write minimal implementation** — create `scripts/gate-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Acceptance/Polish Gate (Sprint 7). Runs a competitive review of a finished work
  artifact (>=2 reviewers, independent) and emits an accept/polish/reject verdict
  with deduped, severity-weighted findings + a polish brief. Advisory — never blocks.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-gate.ps1 wraps it for
  /baton:gate. routing-lib brings Select-Capability and, via fleet-lib, Invoke-Fleet.
.NOTES
  See docs/superpowers/specs/2026-06-20-acceptance-polish-gate-sprint7-design.md (d-ag-1..5).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/routing-lib.ps1"   # Select-Capability (+ fleet-lib: Invoke-Fleet)

function Get-FindingSeverityRank {
    <# critical=3, important=2, minor=1, unknown/absent=0. Case-insensitive. #>
    param([string]$Severity)
    switch (([string]$Severity).Trim().ToLowerInvariant()) {
        'critical'  { return 3 }
        'important' { return 2 }
        'minor'     { return 1 }
        default     { return 0 }
    }
}

function Get-FindingsJsonBlock {
    <# Extract the JSON array from a reply that may be fenced or prose-wrapped:
       first '[' to last ']'. Returns '' when none. #>
    param([Parameter(Mandatory)][string]$Raw)
    $open  = $Raw.IndexOf('[')
    $close = $Raw.LastIndexOf(']')
    if ($open -lt 0 -or $close -lt $open) { return '' }
    return $Raw.Substring($open, $close - $open + 1)
}

function Get-ReviewFindings {
    <# Parse one reviewer's output into @{parsed; findings; raw}. Tolerant: accepts a
       bare or prose-embedded JSON array. Each finding normalized to
       @{severity;area;summary}; unknown severities floored to 'minor' (never dropped).
       Unparseable -> parsed=$false, findings=@(). Empty array -> parsed=$true, @(). #>
    param([string]$Output)
    $result = @{ parsed = $false; findings = @(); raw = [string]$Output }
    $text = [string]$Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $result }
    $block = Get-FindingsJsonBlock -Raw $text
    if (-not $block) { return $result }
    try { $arr = $block | ConvertFrom-Json -ErrorAction Stop } catch { return $result }
    $norm = [System.Collections.ArrayList]@()
    foreach ($f in @($arr)) {
        if ($null -eq $f) { continue }
        $sev = ([string]$f.severity).Trim().ToLowerInvariant()
        if ((Get-FindingSeverityRank $sev) -eq 0) { $sev = 'minor' }  # unknown -> floor, never drop
        [void]$norm.Add(@{
            severity = $sev
            area     = ([string]$f.area).Trim()
            summary  = ([string]$f.summary).Trim()
        })
    }
    $result.parsed = $true
    $result.findings = @($norm.ToArray())
    return $result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (11 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/test-gate-lib.ps1
git commit -m "feat(gate): severity rank + per-reviewer findings parse (pure)"
```

---

### Task 2: Reconcile findings + acceptance verdict (pure)

**Files:**
- Modify: `scripts/gate-lib.ps1` (append functions)
- Modify: `scripts/test-gate-lib.ps1` (append checks)

**Interfaces:**
- Consumes: `Get-FindingSeverityRank`, the `@{severity;area;summary}` finding shape from Task 1.
- Produces: `Get-FindingKey([hashtable]$Finding) -> [string]` (normalized `area|summary`); `Merge-ReviewFindings([array]$Reviews) -> @{ merged=@(@{severity;area;summary;raised_by=@();agreed=[bool]}); unparsed=@([string]) }` (input = per-reviewer `@{reviewer;parsed;findings}`); `Get-AcceptanceVerdict([array]$MergedFindings,[string]$RejectAt='critical',[string]$PolishAt='important') -> @{ verdict; reason; counts=@{critical;important;minor} }`.

- [ ] **Step 1: Write the failing test** — append before the `finally` block in `scripts/test-gate-lib.ps1`:

```powershell
    # ---- Task 2: reconcile + verdict (pure) ----
    $r1 = @{ reviewer='r1'; parsed=$true; findings=@(
        @{severity='important';area='correctness';summary='off by one'},
        @{severity='minor';area='style';summary='naming'}) }
    $r2 = @{ reviewer='r2'; parsed=$true; findings=@(
        @{severity='critical';area='correctness';summary='off by one'}) }
    $m = Merge-ReviewFindings -Reviews @($r1,$r2)
    Check 'G12 same finding merges to one' (@($m.merged).Count -eq 2)
    $corr = @($m.merged | Where-Object { $_.area -eq 'correctness' })[0]
    Check 'G13 merge keeps higher severity' ($corr.severity -eq 'critical')
    Check 'G14 merged finding agreed + both raisers' ($corr.agreed -and $corr.raised_by.Count -eq 2)
    $styl = @($m.merged | Where-Object { $_.area -eq 'style' })[0]
    Check 'G15 solo finding not agreed' (-not $styl.agreed -and $styl.raised_by.Count -eq 1)

    $rbad = @{ reviewer='r3'; parsed=$false; findings=@() }
    $m2 = Merge-ReviewFindings -Reviews @($r1,$rbad)
    Check 'G16 unparsed reviewer listed' (@($m2.unparsed) -contains 'r3' -and @($m2.merged).Count -eq 2)
    $m3 = Merge-ReviewFindings -Reviews @($rbad)
    Check 'G17 all-unparsed -> empty merged' (@($m3.merged).Count -eq 0)

    $vc = Get-AcceptanceVerdict -MergedFindings @(@{severity='critical';area='a';summary='b'})
    Check 'G18 critical -> reject' ($vc.verdict -eq 'reject' -and $vc.counts.critical -eq 1)
    $vp = Get-AcceptanceVerdict -MergedFindings @(@{severity='important';area='a';summary='b'})
    Check 'G19 important -> polish' ($vp.verdict -eq 'polish' -and $vp.counts.important -eq 1)
    $vm = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'})
    Check 'G20 minor only -> accept' ($vm.verdict -eq 'accept' -and $vm.counts.minor -eq 1)
    $vn = Get-AcceptanceVerdict -MergedFindings @()
    Check 'G21 none -> accept, reason no findings' ($vn.verdict -eq 'accept' -and $vn.reason -match 'no findings')
    $vt = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'}) -PolishAt 'minor'
    Check 'G22 tunable threshold: minor -> polish when PolishAt=minor' ($vt.verdict -eq 'polish')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: FAIL — `Merge-ReviewFindings` / `Get-AcceptanceVerdict` not defined.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/gate-lib.ps1`:

```powershell
function Get-FindingKey {
    <# Dedupe key: lowercased, whitespace-collapsed area|summary. Deliberately
       conservative — divergent wordings stay separate (solo) rather than false-merge. #>
    param([Parameter(Mandatory)][hashtable]$Finding)
    $a = (([string]$Finding.area)    -replace '\s+',' ').Trim().ToLowerInvariant()
    $s = (([string]$Finding.summary) -replace '\s+',' ').Trim().ToLowerInvariant()
    return "$a|$s"
}

function Merge-ReviewFindings {
    <# Reconcile per-reviewer parse results into one deduped set. Input items:
       @{reviewer;parsed;findings}. Same key from >=2 reviewers -> one merged finding,
       higher severity kept, agreed=$true. Unparsed reviewers collected by name. #>
    param([array]$Reviews)
    $unparsed = [System.Collections.ArrayList]@()
    $byKey = [ordered]@{}
    foreach ($rv in @($Reviews)) {
        if ($null -eq $rv) { continue }
        if (-not $rv.parsed) { [void]$unparsed.Add([string]$rv.reviewer); continue }
        foreach ($f in @($rv.findings)) {
            $key = Get-FindingKey -Finding $f
            if ($byKey.Contains($key)) {
                $m = $byKey[$key]
                if ((Get-FindingSeverityRank $f.severity) -gt (Get-FindingSeverityRank $m.severity)) {
                    $m.severity = $f.severity
                }
                if ($m.raised_by -notcontains $rv.reviewer) { $m.raised_by += [string]$rv.reviewer }
                $m.agreed = ($m.raised_by.Count -ge 2)
            } else {
                $byKey[$key] = @{
                    severity  = $f.severity; area = $f.area; summary = $f.summary
                    raised_by = @([string]$rv.reviewer); agreed = $false
                }
            }
        }
    }
    return @{ merged = @($byKey.Values); unparsed = @($unparsed.ToArray()) }
}

function Get-AcceptanceVerdict {
    <# Severity-driven verdict over the merged set. any >=RejectAt -> reject;
       else any >=PolishAt -> polish; else accept. Counts each tier. #>
    param(
        [array]$MergedFindings,
        [string]$RejectAt = 'critical',
        [string]$PolishAt = 'important'
    )
    $counts = @{ critical = 0; important = 0; minor = 0 }
    $maxRank = 0
    foreach ($f in @($MergedFindings)) {
        $r = Get-FindingSeverityRank $f.severity
        if ($r -gt $maxRank) { $maxRank = $r }
        switch ($r) { 3 { $counts.critical++ } 2 { $counts.important++ } 1 { $counts.minor++ } }
    }
    $rejRank = Get-FindingSeverityRank $RejectAt
    $polRank = Get-FindingSeverityRank $PolishAt
    if ($maxRank -ge $rejRank)     { $verdict = 'reject' }
    elseif ($maxRank -ge $polRank) { $verdict = 'polish' }
    else                           { $verdict = 'accept' }
    $reason = switch ($verdict) {
        'reject' { "$($counts.critical) critical finding(s)" }
        'polish' { "$($counts.important) important finding(s)" }
        'accept' { if ($counts.minor -gt 0) { "$($counts.minor) minor finding(s), none blocking" } else { 'no findings' } }
    }
    return @{ verdict = $verdict; reason = $reason; counts = $counts }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (22 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/test-gate-lib.ps1
git commit -m "feat(gate): reconcile findings + acceptance verdict (pure)"
```

---

### Task 3: Polish brief + gate report formatters (pure)

**Files:**
- Modify: `scripts/gate-lib.ps1` (append functions)
- Modify: `scripts/test-gate-lib.ps1` (append checks)

**Interfaces:**
- Consumes: the verdict hashtable from `Get-AcceptanceVerdict`; the merged-finding shape from `Merge-ReviewFindings`.
- Produces: `Format-PolishBrief([hashtable]$Verdict,[array]$MergedFindings) -> [string]`; `Format-GateReport([hashtable]$Result) -> [string]` (reads `$Result.verdict/reason/counts/findings/unparsed`).

- [ ] **Step 1: Write the failing test** — append before the `finally` block:

```powershell
    # ---- Task 3: formatters (pure) ----
    $fset = @(
        @{severity='critical';area='correctness';summary='off by one';agreed=$true;raised_by=@('r1','r2')},
        @{severity='important';area='security';summary='unescaped input';agreed=$false;raised_by=@('r1')},
        @{severity='minor';area='style';summary='naming';agreed=$false;raised_by=@('r2')})
    $brief = Format-PolishBrief -Verdict @{verdict='polish'} -MergedFindings $fset
    Check 'G23 brief lists critical + important' ($brief -match 'off by one' -and $brief -match 'unescaped input')
    Check 'G24 brief excludes minor' ($brief -notmatch 'naming')
    Check 'G25 brief agreed before solo' ($brief.IndexOf('off by one') -lt $brief.IndexOf('unescaped input'))
    $acc = Format-PolishBrief -Verdict @{verdict='accept'} -MergedFindings @()
    Check 'G26 accept brief says no polish' ($acc -match 'No polish needed')

    $rep = Format-GateReport -Result @{
        verdict='polish'; reason='1 important finding(s)'
        counts=@{critical=0;important=1;minor=1}; findings=$fset[1..2]; unparsed=@('r3') }
    Check 'G27 report shows verdict + counts' ($rep -match 'POLISH' -and $rep -match '1 important')
    Check 'G28 report groups solo + notes unparsed' ($rep -match 'Solo' -and $rep -match 'r3')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: FAIL — `Format-PolishBrief` / `Format-GateReport` not defined.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/gate-lib.ps1`:

```powershell
function Format-PolishBrief {
    <# The must-fix brief for a premium polish pass: critical+important findings,
       agreed-first then severity-desc. 'accept' -> a one-line no-op. #>
    param([Parameter(Mandatory)][hashtable]$Verdict, [array]$MergedFindings)
    if ($Verdict.verdict -eq 'accept') { return 'No polish needed — artifact accepted as-is.' }
    $mustFix = @($MergedFindings | Where-Object { (Get-FindingSeverityRank $_.severity) -ge 2 })
    $ordered = @($mustFix | Sort-Object `
        @{ Expression = { if ($_.agreed) { 0 } else { 1 } } }, `
        @{ Expression = { -(Get-FindingSeverityRank $_.severity) } })
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('POLISH BRIEF — fix the following before this ships as polished:')
    foreach ($f in $ordered) {
        $tag = if ($f.agreed) { 'agreed' } else { 'solo' }
        [void]$sb.AppendLine("  • [$($f.severity)][$tag] $($f.area): $($f.summary)")
    }
    return $sb.ToString().TrimEnd()
}

function Format-GateReport {
    <# Human-readable verdict + counts, findings grouped agreed/solo, unparsed note. #>
    param([Parameter(Mandatory)][hashtable]$Result)
    $v = ([string]$Result.verdict).ToUpperInvariant()
    $c = $Result.counts
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("ACCEPTANCE GATE — verdict: $v  ($($Result.reason))")
    [void]$sb.AppendLine("Findings: $($c.critical) critical, $($c.important) important, $($c.minor) minor")
    $agreed = @($Result.findings | Where-Object { $_.agreed })
    $solo   = @($Result.findings | Where-Object { -not $_.agreed })
    if ($agreed.Count) {
        [void]$sb.AppendLine('Agreed (raised by multiple reviewers):')
        foreach ($f in $agreed) { [void]$sb.AppendLine("  • [$($f.severity)] $($f.area): $($f.summary)") }
    }
    if ($solo.Count) {
        [void]$sb.AppendLine('Solo (one reviewer):')
        foreach ($f in $solo) { [void]$sb.AppendLine("  • [$($f.severity)] $($f.area): $($f.summary) (by $($f.raised_by -join ', '))") }
    }
    if ($Result.unparsed -and @($Result.unparsed).Count) {
        [void]$sb.AppendLine("Note: $((@($Result.unparsed)) -join ', ') returned no usable review.")
    }
    return $sb.ToString().TrimEnd()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (28 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/test-gate-lib.ps1
git commit -m "feat(gate): polish brief + gate report formatters (pure)"
```

---

### Task 4: Seamed gate + CLI + command + fleet seed

**Files:**
- Modify: `scripts/gate-lib.ps1` (append `Build-ReviewPrompt` + `Invoke-AcceptanceGate`)
- Create: `scripts/fleet-gate.ps1`
- Create: `commands/gate.md`
- Modify: `references/fleet.yaml` (add `review` to taxonomy + grant on two seed entries)
- Modify: `scripts/test-gate-lib.ps1` (append seamed + CLI checks)

**Interfaces:**
- Consumes: `Get-ReviewFindings`, `Merge-ReviewFindings`, `Get-AcceptanceVerdict`, `Format-PolishBrief`, `Format-GateReport`; `Select-Capability`, `Invoke-Fleet`.
- Produces: `Build-ReviewPrompt([string]$Task,[string]$Artifact) -> [string]`; `Invoke-AcceptanceGate(-Artifact,-Task,-Reviewers[string[]],-RejectAt,-PolishAt,-MaxCostTier,-FleetPath,-ToolsPath,-Dispatcher) -> [ordered]@{verdict;reason;counts;findings;polish_brief;reviews;unparsed}`; CLI `fleet-gate.ps1 run`.

- [ ] **Step 1: Write the failing test** — append before the `finally` block:

```powershell
    # ---- Task 4: seamed Invoke-AcceptanceGate (injected dispatcher) ----
    Check 'G29 prompt carries schema + task + artifact' (
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'severity' -and
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'do x' -and
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'fn foo')

    $disp = {
        param($n,$p)
        if ($n -eq 'r1') { return @{ stdout='[{"severity":"important","area":"correctness","summary":"off by one"},{"severity":"minor","area":"style","summary":"naming"}]'; stderr=''; exit_code=0 } }
        elseif ($n -eq 'r2') { return @{ stdout='[{"severity":"important","area":"correctness","summary":"off by one"}]'; stderr=''; exit_code=0 } }
        else { return @{ stdout='no json here'; stderr=''; exit_code=0 } }
    }
    $g = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r2') -Dispatcher $disp
    Check 'G30 two reviewers -> polish, 2 findings' ($g.verdict -eq 'polish' -and @($g.findings).Count -eq 2)
    $corrG = @($g.findings | Where-Object { $_.area -eq 'correctness' })[0]
    Check 'G31 shared finding agreed' ($corrG.agreed)
    Check 'G32 result shape' ($g.Contains('polish_brief') -and $g.Contains('reviews') -and @($g.reviews).Count -eq 2)

    $g2 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r3') -Dispatcher $disp
    Check 'G33 garbage reviewer degraded, survivor counted' (@($g2.unparsed) -contains 'r3' -and $g2.verdict -eq 'polish')
    $g3 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r3') -Dispatcher $disp
    Check 'G34 all-unparsed -> accept, flagged' ($g3.verdict -eq 'accept' -and $g3.reason -match 'no usable review')

    # zero reviewers + a fleet with no review-capable provider -> throws
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "gate-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $emptyFleet = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -LiteralPath $emptyFleet -Encoding utf8 -Value @'
providers:
  - name: plain-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'echo {{prompt}}'
'@
    $emptyTools = Join-Path $tmpDir 'tools.yaml'
    Set-Content -LiteralPath $emptyTools -Encoding utf8 -Value "tools: []`n"
    $threw = $false
    try { Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -Reviewers @() -FleetPath $emptyFleet -ToolsPath $emptyTools } catch { $threw = $true }
    Check 'G35 no reviewers -> throws' ($threw)

    # ---- Task 4: CLI (child process, hermetic BATON_HOME) ----
    $canned = Join-Path $tmpDir 'canned-review.ps1'
    Set-Content -LiteralPath $canned -Encoding utf8 -Value @'
[void]([Console]::In.ReadToEnd())
Write-Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
'@
    $cliFleet = Join-Path $tmpDir 'cli-fleet.yaml'
    Set-Content -LiteralPath $cliFleet -Encoding utf8 -Value @"
providers:
  - name: rev-canned
    kind: cli
    enabled: true
    cost_tier: paid
    stdin: true
    capabilities: [review]
    command_template: 'pwsh -NoProfile -File "$canned"'
"@
    $artFx = Join-Path $tmpDir 'artifact.txt'
    Set-Content -LiteralPath $artFx -Encoding utf8 -Value 'function foo() { return 1 }'
    $gateCli = Join-Path $PSScriptRoot 'fleet-gate.ps1'
    $env:BATON_HOME = $tmpDir
    Copy-Item -LiteralPath $cliFleet -Destination (Join-Path $tmpDir 'fleet.yaml') -Force
    try {
        $cliOut = & pwsh -NoProfile -File $gateCli run --task 'do x' --file $artFx --reviewers 'rev-canned' 2>&1 | Out-String
        Check 'G36 CLI run prints verdict' ($cliOut -match 'ACCEPTANCE GATE' -and $cliOut -match 'POLISH')
        $cliJson = & pwsh -NoProfile -File $gateCli run --task 'do x' --file $artFx --reviewers 'rev-canned' --json 2>&1 | Out-String
        Check 'G37 CLI --json has verdict key' ($cliJson -match '"verdict"')
        & pwsh -NoProfile -File $gateCli run --file $artFx --reviewers 'rev-canned' 2>$null | Out-Null
        Check 'G38 CLI missing --task -> exit 2' ($LASTEXITCODE -eq 2)
        & pwsh -NoProfile -File $gateCli bogus 2>$null | Out-Null
        Check 'G39 CLI unknown subcommand -> exit 2' ($LASTEXITCODE -eq 2)
    }
    finally {
        Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: FAIL — `Build-ReviewPrompt` / `Invoke-AcceptanceGate` not defined; `fleet-gate.ps1` missing.

- [ ] **Step 3a: Implement the seam** — append to `scripts/gate-lib.ps1`:

```powershell
function Build-ReviewPrompt {
    <# Compose one reviewer's instruction: role + strict-JSON findings schema +
       the task + the artifact. The whole prompt rides stdin for stdin:true providers. #>
    param(
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Artifact
    )
    $schema = @'
[
  { "severity": "critical|important|minor",
    "area": "<short area, e.g. correctness, security, style>",
    "summary": "<one line: the specific issue>" }
]
'@
    return @"
You are a strict code/work reviewer. Review the ARTIFACT below against its TASK.
Report real defects only. Respond with ONLY a JSON array matching this schema
exactly — no prose, no markdown fences. Return [] if there are no findings.

Schema:
$schema

Severity: critical = wrong/broken/unsafe; important = should fix before shipping;
minor = nit/style. Be specific in each summary.

## Task
$Task

## Artifact
$Artifact
"@
}

function Invoke-AcceptanceGate {
    <# Run a competitive review of an artifact and return an accept/polish/reject
       verdict with deduped findings + a polish brief. Each reviewer reviews
       INDEPENDENTLY (no cross-talk); reconciliation/verdict are pure. Reviewers
       default to providers claiming the 'review' capability. -Dispatcher injects
       for tests; real path dispatches via Invoke-Fleet. Advisory — never blocks. #>
    param(
        [Parameter(Mandatory)][string]$Artifact,
        [Parameter(Mandatory)][string]$Task,
        [string[]]$Reviewers,
        [string]$RejectAt = 'critical',
        [string]$PolishAt = 'important',
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher
    )
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        $cands = Select-Capability -Capability review -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        $Reviewers = @($cands | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name })
    }
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        throw "Invoke-AcceptanceGate: no reviewers configured (grant the 'review' capability to >=1 provider, or pass -Reviewers)."
    }
    $dispatch = {
        param($name, $prompt)
        if ($Dispatcher) { return (& $Dispatcher $name $prompt) }
        return Invoke-Fleet -Name $name -Prompt $prompt -Path $FleetPath -NoJournal
    }
    $prompt  = Build-ReviewPrompt -Task $Task -Artifact $Artifact
    $reviews = [System.Collections.ArrayList]@()
    foreach ($r in $Reviewers) {
        $pf = @{ reviewer = $r; parsed = $false; findings = @() }
        try {
            $res = & $dispatch $r $prompt
            if ([int]$res.exit_code -eq 0) {
                $parsed = Get-ReviewFindings -Output ([string]$res.stdout)
                $pf.parsed   = $parsed.parsed
                $pf.findings = $parsed.findings
            }
        } catch {
            Write-Debug "reviewer $r failed: $($_.Exception.Message)"
        }
        [void]$reviews.Add($pf)
    }
    $merge   = Merge-ReviewFindings -Reviews $reviews.ToArray()
    $verdict = Get-AcceptanceVerdict -MergedFindings $merge.merged -RejectAt $RejectAt -PolishAt $PolishAt
    if (@($merge.unparsed).Count -ge $Reviewers.Count) {
        $verdict.reason = 'no usable review obtained (fail-open accept)'
    }
    $brief = Format-PolishBrief -Verdict $verdict -MergedFindings $merge.merged
    return [ordered]@{
        verdict = $verdict.verdict; reason = $verdict.reason; counts = $verdict.counts
        findings = $merge.merged; polish_brief = $brief
        reviews = @($reviews | ForEach-Object { @{ reviewer = $_.reviewer; parsed = $_.parsed; count = @($_.findings).Count } })
        unparsed = $merge.unparsed
    }
}
```

- [ ] **Step 3b: Create the CLI** — `scripts/fleet-gate.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:gate runner. Runs a competitive acceptance review of a work artifact
  (file / git diff / stdin) and prints an accept/polish/reject verdict with
  deduped findings + a polish brief. Advisory only — never blocks.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'run',
    [string]$Task,
    [string]$Artifact,
    [string]$File,
    [string]$Diff,
    [string]$Reviewers,
    [switch]$Json,
    [string]$FleetPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gate-lib.ps1')

switch ($Subcommand) {
    'run' {
        if (-not $Task) { Write-Error 'run requires --task (what the artifact was supposed to do)'; exit 2 }
        $art = $null
        if     ($File)     { $art = Get-Content -LiteralPath $File -Raw }
        elseif ($Diff)     { $art = (& git diff $Diff 2>&1 | Out-String) }
        elseif ($Artifact) { $art = $Artifact }
        elseif ([Console]::IsInputRedirected) { $art = [Console]::In.ReadToEnd() }
        else { Write-Error 'run requires --file, --diff, --artifact, or piped stdin'; exit 2 }
        if ([string]::IsNullOrWhiteSpace($art)) { Write-Error 'run: artifact is empty'; exit 2 }
        $revList = if ($Reviewers) { @($Reviewers -split '\s*,\s*' | Where-Object { $_ }) } else { @() }
        $callArgs = @{ Artifact = $art; Task = $Task; FleetPath = $FleetPath }
        if ($revList.Count) { $callArgs['Reviewers'] = $revList }
        $res = Invoke-AcceptanceGate @callArgs
        if ($Json) { [pscustomobject]$res | ConvertTo-Json -Depth 6 }
        else {
            Write-Host (Format-GateReport -Result ([hashtable]$res))
            Write-Host '---'
            Write-Host $res.polish_brief
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use run)"; exit 2 }
}
```

- [ ] **Step 3c: Create the command** — `commands/gate.md`:

```markdown
---
description: Run a competitive acceptance review of a work artifact and get an accept/polish/reject verdict with findings and a polish brief.
argument-hint: "run --task \"...\" [--file F | --diff <range> | --artifact \"...\"] [--reviewers a,b] [--json]"
---

# /baton:gate

The after-work quality gate. Feed it a finished artifact (a file, a git diff, or
piped text) and what it was supposed to do; Baton runs a competitive review (≥2
reviewers review independently), reconciles their findings (deduped, tagged agreed
vs solo, severity-weighted), and returns a verdict: **accept** (ship the cheap
artifact as-is), **polish** (a premium pass should fix the listed findings — a
ready-to-use polish brief is emitted), or **reject** (a critical defect). Advisory
only; never blocks and never auto-runs the polish pass.

## Steps

1. Run the runner with the user's arguments, e.g.:

   ```powershell
   pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-gate.ps1" $ARGUMENTS
   ```

2. Common forms:
   - `run --task "add retry to the fetch helper" --diff HEAD~1` — review the last commit's diff.
   - `run --task "summary memo" --file draft.md` — review a file.
   - `run --task "..." --file x.ps1 --reviewers codex,opus --json` — explicit reviewer pair, machine-readable.

3. Summarize in plain language: the verdict and why, the agreed-vs-solo findings,
   and — when the verdict is polish — hand the polish brief to whoever (operator or
   `/baton:go` Conductor) will run the premium pass.
```

- [ ] **Step 3d: Update the fleet seed** — `references/fleet.yaml`:

  1. In the `capabilities` taxonomy comment block, add `review` to the canonical list line and add a gloss line beneath the `triage / classify` gloss:

  ```
  #   review            — competitive acceptance review: emit JSON findings
  #                       (severity/area/summary) for the Acceptance/Polish Gate
  ```

  2. Grant the `review` capability on two existing `stdin: true` seed entries so the default reviewer pool has ≥2 members. Change `claude-haiku`'s capabilities line to include `review`:

  ```yaml
    capabilities: [triage, classify, research, summarize-short, review]
  ```

  and `claude-sonnet`'s:

  ```yaml
    capabilities: [triage, research, code-gen, reasoning, summarize, review]
  ```

  3. Above the `claude-haiku` block, extend the existing "Triage workers" comment with a one-line box-private note:

  ```
  # The real competitive reviewer pair (e.g. Codex + Opus) is BOX-PRIVATE — set it
  # in your live ~/.baton/fleet.yaml; these seed grants are an example pool only.
  ```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (39 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/fleet-gate.ps1 commands/gate.md references/fleet.yaml scripts/test-gate-lib.ps1
git commit -m "feat(gate): seamed Invoke-AcceptanceGate + /baton:gate CLI + review-capable fleet seed"
```

---

### Task 5: Bootstrap manifest + plugin bump

**Files:**
- Modify: `scripts/bootstrap.ps1` (manifest list)
- Modify: `scripts/test-bootstrap.ps1` (2 new asserts)
- Modify: `.claude-plugin/plugin.json` (version)

**Interfaces:**
- Consumes: nothing new — wires the Task-1..4 files into the deploy manifest.
- Produces: `gate-lib.ps1` + `fleet-gate.ps1` deployed by `bootstrap.ps1`; version `1.3.0-rc.2`.

- [ ] **Step 1: Write the failing test** — in `scripts/test-bootstrap.ps1`, after the two worker asserts (the `fleet-worker script` line), add:

```powershell
Assert "deploys gate-lib script"   ($out -match 'gate-lib\.ps1')
Assert "deploys fleet-gate script" ($out -match 'fleet-gate\.ps1')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — the manifest does not yet copy `gate-lib.ps1` / `fleet-gate.ps1`.

- [ ] **Step 3: Write minimal implementation**

In `scripts/bootstrap.ps1`, in the `foreach ($script in @(...))` manifest list (the single long array around line 259), insert `'gate-lib.ps1', 'fleet-gate.ps1'` immediately after `'fleet-worker.ps1',`:

```powershell
..., 'worker-lib.ps1', 'fleet-worker.ps1', 'gate-lib.ps1', 'fleet-gate.ps1', 'idea-lib.ps1')) {
```

In `.claude-plugin/plugin.json`, bump the version:

```json
  "version": "1.3.0-rc.2",
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: `ALL PASS` (43 asserts).

Run (full gate suite, still green): `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (39 checks).

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 .claude-plugin/plugin.json
git commit -m "feat(gate): wire gate-lib + fleet-gate into bootstrap; plugin 1.3.0-rc.2"
```

---

## Notes for the executor

- **Run from repo root** (`D:\Dev\Baton`); paths are repo-relative.
- **Reviewer providers must be `stdin: true`** — the review prompt (artifact included) rides stdin, which is quote-safe and avoids the pwsh inherited-stdin hang that bit Sprint 6. The seed grants land on `claude-haiku`/`claude-sonnet`, both already `stdin: true`.
- **Do NOT put real reviewer names, endpoints, or budgets in `references/fleet.yaml`** — box-private; the seed carries only the example `review` grant.
- **No live smoke is required to pass the plan** (hermetic suite proves the loop), but a post-merge live smoke against the box's real reviewer pair is the deploy-verification step, consistent with prior sprints.
