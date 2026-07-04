# Acceptance-Gate Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the acceptance gate as a first-class economic instrument: hardening minors (Slice A), budget-gated reviewer spend (Slice B), a task-output bus + mid-DAG `gate` tasks (Slice C), and a bounded one-shot auto-polish pass (Slice D).

**Architecture:** Four ordered, independently-shippable slices over the existing gate/conductor stack. Slice A/B live in `gate-lib.ps1` + `fleet-gate.ps1` (plus two small conductor touches); Slice C/D live in `conductor-lib.ps1` + `fleet-go.ps1`. Everything is fail-open: a gate/coach/bus/polish failure can never fail the host run, and every no-flag path behaves exactly as today.

**Tech Stack:** PowerShell 7 (pwsh), house Assert/Check test style (no Pester), hermetic temp `BATON_HOME`.

**Spec:** `docs/superpowers/specs/2026-07-04-acceptance-gate-followups-design.md` (approved defaults; forks resolved: Slice D = exactly ONE polish iteration; A+B ship together in one RC).

## Global Constraints

Every task's requirements implicitly include these:

- **965-byte shell-arg ceiling:** no generated shell command argument may exceed 965 bytes; large content moves via files or stdin. (Consumed-output context rides the PROMPT, which Invoke-Fleet delivers via stdin for `stdin: true` providers — never a new shell arg.)
- **utf8NoBOM** for every file write (`-Encoding utf8NoBOM`).
- **CLI user errors:** `[Console]::Error.WriteLine('...')` then `exit 2` — NEVER `Write-Error; exit 2` (throws exit 1 first under `$ErrorActionPreference='Stop'`).
- **PowerShell automatic variables:** never name a variable/param `$args`, `$input`, `$event`, `$matches`, `$host` (nor `$Event`/`$Input` params). Event-record params are `$EventObj` in this codebase.
- **Unary-comma array flatten** (`return ,([array]$x)`) is for DIRECT-ASSIGNMENT returns only; use `@($x)` for values consumed by pipelines or placed inside hashtable literals.
- **Tests are hermetic:** temp `BATON_HOME` (created under `[System.IO.Path]::GetTempPath()`), try/finally restore of any env var touched, NEVER the real `~/.baton` or `~/.claude`.
- **Fail-open contract:** gate skipped ≠ run failed; bus absent ≠ dispatch failed; auto-polish error → the original `polish` verdict stands; a coach/footer failure never changes host exit codes.
- **No-flag paths byte-for-byte:** without `-AutoPolish` / `-MaxGateSpend` / `type:"gate"` / `consumes`, run **behavior** (statuses, events, report.md, exit codes) is unchanged. Known, deliberate exception (resolved plan ambiguity): `plan.json` gains two normalized fields (`type:"work"`, `consumes:[]`) on every task, exactly as `est_cost_tier`/`reversible` are already defaulted — report.md and all behavior stay identical.
- **d-cg-2 preserved:** exactly two interrupt kinds (budget, destructive). Nothing in this plan adds an interrupt; over-cap gate/polish paths SKIP with an honest event instead.
- **`Invoke-AcceptanceGate`'s result is an `[ordered]` dict** consumed untyped by `Complete-Run -Gate`; additive keys only, never reorder/remove existing keys.
- **Coach footers** (`Write-CoachFooter` calls in fleet-gate/fleet-go) stay exactly where they are — non-JSON success paths only.
- Branch: `feature/gate-followups` off master. Commit after every task.

## Baseline interfaces (read-only reference)

- `Invoke-AcceptanceGate` result today: `[ordered]@{ verdict; reason; counts; findings; polish_brief; reviews; unparsed }`.
- Spawner/executor result shape: `@{ ok; spend; chose; why; alternatives }` (this plan adds optional `output`).
- `Select-Capability` returns ranked `[pscustomobject]` candidates, cheapest cost-tier first, each with `.name`, `.cost_tier`.
- `Get-ConserveMode [-UsagePath <path>]` → `[bool]` (usage-lib, already in scope via routing-lib dot-source chain).
- `Get-TaskCostEstimate -Tier <t> [-PaidPerCall 0.05]` → paid ⇒ 0.05, else 0.0 (conductor-lib).
- Existing gate suite ends at check `G39`; conductor suite uses `T1–T88` + `SB*` — new checks use fresh prefixes (`G40+`, `GB*`, `ER*`, `PL*`, `BUS*`, `MG*`, `AP*`) to avoid collisions.

---

### Task 1: Slice A — robust findings JSON scan + degraded-review flag (gate-lib)

**Files:**
- Modify: `scripts/gate-lib.ps1` (`Get-FindingsJsonBlock`, `Invoke-AcceptanceGate`, `Format-GateReport`)
- Test: `scripts/test-gate-lib.ps1`

**Interfaces:**
- Produces: `Get-FindingsJsonBlock -Raw <string>` → the first substring that PARSES as JSON (fenced ```` ```json ```` block preferred), `''` when none.
- Produces: gate result gains `degraded = <bool>` (true when <2 reviewers parsed); `Format-GateReport` prints a warning line when degraded.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-gate-lib.ps1`, insert immediately AFTER the `Check 'G35 no reviewers -> throws' ($threw)` line (and before the `# ---- Task 4: CLI` comment):

```powershell
    # ---- Slice A (2026-07-04): robust JSON scan + degraded flag ----
    $noisy = Get-ReviewFindings -Output 'Overall score: [8/10]. Findings: [{"severity":"minor","area":"style","summary":"naming"}]'
    Check 'G40 bracket noise before array still parses' ($noisy.parsed -and @($noisy.findings).Count -eq 1 -and $noisy.findings[0].area -eq 'style')
    $fenced = Get-ReviewFindings -Output ("Score [8/10]`n" + '```json' + "`n" + '[{"severity":"important","area":"x","summary":"y"}]' + "`n" + '```' + "`nDone.")
    Check 'G41 fenced array with outside noise parses' ($fenced.parsed -and @($fenced.findings).Count -eq 1 -and $fenced.findings[0].severity -eq 'important')
    $fenceEmpty = Get-ReviewFindings -Output ('```json' + "`n[]`n" + '```')
    Check 'G42 fenced empty array -> parsed, 0 findings' ($fenceEmpty.parsed -and @($fenceEmpty.findings).Count -eq 0)
    Check 'G43 still no-json -> empty block' ((Get-FindingsJsonBlock -Raw 'nothing structured here') -eq '')

    $gd1 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r3') -Dispatcher $disp
    Check 'G44 one parseable reviewer -> degraded true' ($gd1.degraded -eq $true)
    $gd2 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r2') -Dispatcher $disp
    Check 'G45 two parseable reviewers -> degraded false' ($gd2.degraded -eq $false)
    $gdRep = Format-GateReport -Result ([hashtable]$gd1)
    Check 'G46 degraded warning line in report' ($gdRep -match 'degraded review')
    $gdRep2 = Format-GateReport -Result ([hashtable]$gd2)
    Check 'G47 no degraded warning when healthy' ($gdRep2 -notmatch 'degraded review')
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `FAIL: G40`, `FAIL: G41` (current scanner grabs `[8/10 ... ]` span), `FAIL: G44`–`G47` (`degraded` key absent → comparisons to $true/$false fail or report lacks the line); G1–G39 still PASS; exits 1.

- [ ] **Step 3: Implement**

In `scripts/gate-lib.ps1`, replace the entire `Get-FindingsJsonBlock` function with:

```powershell
function Get-FindingsJsonBlock {
    <# Extract the findings JSON array from a possibly fenced/prose-wrapped reply.
       Sources tried in order: the first fenced ``` block's content, then the whole
       reply. Within each source, bracket spans are tried from each successive '['
       to the LAST ']' and the first span that PARSES as JSON wins — so bracket
       noise BEFORE the array (e.g. "[8/10]") can no longer defeat the scan.
       (Trailing bracket noise after the array remains a known limit.) Returns ''
       when nothing parses. #>
    param([Parameter(Mandatory)][string]$Raw)
    $sources = [System.Collections.ArrayList]@()
    $fence = [regex]::Match($Raw, '(?s)```(?:json)?\s*(.*?)```')
    if ($fence.Success) { [void]$sources.Add($fence.Groups[1].Value) }
    [void]$sources.Add($Raw)
    foreach ($src in $sources) {
        $close = $src.LastIndexOf(']')
        $open  = $src.IndexOf('[')
        while (($open -ge 0) -and ($close -gt $open)) {
            $span = $src.Substring($open, $close - $open + 1)
            try {
                [void]($span | ConvertFrom-Json -ErrorAction Stop)
                return $span
            } catch { }
            $open = $src.IndexOf('[', $open + 1)
        }
    }
    return ''
}
```

In `Invoke-AcceptanceGate`, replace the final `return [ordered]@{ ... }` block with (only `degraded` is new; key order preserved with the addition after `counts`):

```powershell
    $parseable = @($reviews | Where-Object { $_.parsed }).Count
    return [ordered]@{
        verdict = $verdict.verdict; reason = $verdict.reason; counts = $verdict.counts
        degraded = ($parseable -lt 2)
        findings = $merge.merged; polish_brief = $brief
        reviews = @($reviews | ForEach-Object { @{ reviewer = $_.reviewer; parsed = $_.parsed; count = @($_.findings).Count } })
        unparsed = $merge.unparsed
    }
```

In `Format-GateReport`, insert immediately after the existing `unparsed` note block (after its closing `}`):

```powershell
    if ($Result.degraded) {
        [void]$sb.AppendLine('Warning: degraded review — fewer than two reviewers produced usable findings; no finding could be corroborated (agreed).')
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (G1–G47), exit 0. G6/G7/G9/G10 (bare/empty/prose/unknown-severity) must all still pass — they prove the rewrite kept old behavior.

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/test-gate-lib.ps1
git commit -m "feat(gate): slice A — parse-validated findings scan + degraded-review flag"
```

---

### Task 2: Slice A — `--diff` exit check (CLI) + empty-resolve legibility event (conductor)

**Files:**
- Modify: `scripts/fleet-gate.ps1` (the `$Diff` branch)
- Modify: `scripts/conductor-lib.ps1` (`Invoke-Conductor` step 4)
- Test: `scripts/test-gate-lib.ps1`, `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Produces: `fleet-gate.ps1 run --diff <bad-range>` → stderr + exit 2 (was: git's error text became the artifact).
- Produces: a REQUESTED gate target that resolves empty emits one `gate`-kind warn event `gate-skipped: target resolved empty…`; an UNREQUESTED gate stays silent.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-gate-lib.ps1`, inside the CLI try block, insert after the `Check 'G39 ...'` line:

```powershell
        & pwsh -NoProfile -File $gateCli run --task 'do x' --diff 'no-such-ref-zzz..also-none-zzz' 2>$null | Out-Null
        Check 'G48 CLI bad --diff range -> exit 2' ($LASTEXITCODE -eq 2)
```

In `scripts/test-conductor-lib.ps1`, insert after the `Check 'T79 ...'` line (still inside the `$gtHome` block, before its `Remove-Item`):

```powershell
    # ---- Slice A (2026-07-04): empty-resolve legibility event ----
    $re = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-emptydiff') -Planner $gPlanner -Spawner $gSpawner -GateDiff 'no-such-ref-zzz..also-none-zzz'
    Check 'ER1 empty gate resolve -> completed' ($re.status -eq 'completed')
    Check 'ER2 empty gate resolve logs gate-skipped event' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-emptydiff/events.jsonl') -Raw) -match 'gate-skipped: target resolved empty')
    Check 'ER3 no gate request -> no gate events (regression)' (-not ((Get-Content -LiteralPath (Join-Path $gtHome 'r-none/events.jsonl') -Raw) -match '"kind":"gate"'))
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1` → `FAIL: G48` (bad diff currently proceeds with error text; exits 0 or non-2).
Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1` → `FAIL: ER2` (no event today).

- [ ] **Step 3: Implement**

In `scripts/fleet-gate.ps1`, replace the line `elseif ($Diff)     { $art = (& git diff $Diff 2>&1 | Out-String) }` with:

```powershell
        elseif ($Diff) {
            $art = (& git diff $Diff 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) {
                [Console]::Error.WriteLine("run: git diff '$Diff' failed — $($art.Trim())")
                exit 2
            }
        }
```

In `scripts/conductor-lib.ps1`, `Invoke-Conductor` step 4, replace:

```powershell
    $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
    if (-not [string]::IsNullOrWhiteSpace($art)) {
```

with:

```powershell
    $gateRequested = (-not [string]::IsNullOrWhiteSpace($GateArtifact)) -or (-not [string]::IsNullOrWhiteSpace($GateDiff))
    $art = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
    if ([string]::IsNullOrWhiteSpace($art) -and $gateRequested) {
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -Kind 'gate' -Level 'warn' -Message 'gate-skipped: target resolved empty (bad diff range or empty artifact) — acceptance phase skipped')
    }
    if (-not [string]::IsNullOrWhiteSpace($art)) {
```

- [ ] **Step 4: Run tests to verify pass**

Run both suites:
`pwsh -NoProfile -File scripts/test-gate-lib.ps1` → `ALL PASS` exit 0.
`pwsh -NoProfile -File scripts/test-conductor-lib.ps1` → `ALL PASS` exit 0 (T66/T67 regression proves the unrequested path is untouched).

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-gate.ps1 scripts/conductor-lib.ps1 scripts/test-gate-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(gate): slice A — --diff exit check + empty-resolve gate-skipped event"
```

---

### Task 3: Slice B — pure spend-gate helpers (gate-lib)

**Files:**
- Modify: `scripts/gate-lib.ps1` (two new functions, placed after `Get-FindingSeverityRank`)
- Test: `scripts/test-gate-lib.ps1`

**Interfaces:**
- Produces: `Get-ReviewerSpendEstimate -Candidates <array> [-PaidPerCall 0.05]` → `[double]` (paid candidates × per-call figure; local/free/unknown = 0 — mirrors conductor's `Get-TaskCostEstimate`).
- Produces: `Get-GateSpendDecision -Candidates <ranked array> [-Conserve <bool>] [-MaxGateSpend <double|null>] [-PaidPerCall 0.05]` → `@{ action='proceed'|'downgrade'|'skip'; reviewers=[string[]]; estimate=[double]; why=[string] }`.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-gate-lib.ps1`, insert after the Task-1 `G47` block:

```powershell
    # ---- Slice B (2026-07-04): pure spend-gate helpers ----
    $cFree  = [pscustomobject]@{ name='rev-free';  cost_tier='free' }
    $cPaid1 = [pscustomobject]@{ name='rev-paid1'; cost_tier='paid' }
    $cPaid2 = [pscustomobject]@{ name='rev-paid2'; cost_tier='paid' }
    Check 'GB1 estimate: 2 paid + 1 free = 0.10' ((Get-ReviewerSpendEstimate -Candidates @($cFree,$cPaid1,$cPaid2)) -eq 0.10)
    Check 'GB2 estimate: all free/local = 0' ((Get-ReviewerSpendEstimate -Candidates @($cFree)) -eq 0.0)

    $d1 = Get-GateSpendDecision -Candidates @($cFree,$cPaid1,$cPaid2)
    Check 'GB3 no conserve, no cap -> proceed with full set' ($d1.action -eq 'proceed' -and @($d1.reviewers).Count -eq 3)
    $d2 = Get-GateSpendDecision -Candidates @($cFree,$cPaid1,$cPaid2) -Conserve $true
    Check 'GB4 conserve -> downgrade to cheapest pair' ($d2.action -eq 'downgrade' -and @($d2.reviewers).Count -eq 2 -and $d2.reviewers[0] -eq 'rev-free')
    $d3 = Get-GateSpendDecision -Candidates @($cFree,$cPaid1,$cPaid2) -MaxGateSpend 0.06
    Check 'GB5 cap breach by full set -> downgrade' ($d3.action -eq 'downgrade' -and $d3.estimate -eq 0.05)
    $d4 = Get-GateSpendDecision -Candidates @($cPaid1,$cPaid2) -MaxGateSpend 0.01
    Check 'GB6 cap breach even by pair -> skip' ($d4.action -eq 'skip' -and @($d4.reviewers).Count -eq 0 -and $d4.why -match 'budget')
    $d5 = Get-GateSpendDecision -Candidates @($cFree,$cPaid1,$cPaid2) -MaxGateSpend 0.50
    Check 'GB7 generous cap -> proceed' ($d5.action -eq 'proceed')
    $d6 = Get-GateSpendDecision -Candidates @($cFree) -Conserve $true
    Check 'GB8 single candidate under conserve -> downgrade keeps the one' ($d6.action -eq 'downgrade' -and @($d6.reviewers).Count -eq 1)
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: hard error — `Get-ReviewerSpendEstimate` not recognized (suite exits 1 via the `$ErrorActionPreference='Stop'` throw path).

- [ ] **Step 3: Implement**

In `scripts/gate-lib.ps1`, insert after the closing `}` of `Get-FindingSeverityRank`:

```powershell
function Get-ReviewerSpendEstimate {
    <# Slice B: coarse reviewer-spend estimate mirroring conductor-lib's
       Get-TaskCostEstimate — each paid-tier candidate costs the per-call figure;
       local/free/unknown cost 0. #>
    param([array]$Candidates = @(), [double]$PaidPerCall = 0.05)
    $sum = 0.0
    foreach ($c in @($Candidates)) {
        if ($null -eq $c) { continue }
        if ([string]$c.cost_tier -eq 'paid') { $sum += $PaidPerCall }
    }
    return [math]::Round($sum, 4)
}

function Get-GateSpendDecision {
    <# Slice B: downgrade-then-skip. Candidates arrive RANKED cheapest-first
       (Select-Capability economy order). No conserve + no cap breach -> proceed
       with the full set (today's behavior). Conserve mode or a breached
       -MaxGateSpend -> downgrade to the cheapest pair; if even the pair breaches
       the cap -> skip. Pure — the caller acts on the decision. #>
    param(
        [Parameter(Mandatory)][array]$Candidates,
        [bool]$Conserve = $false,
        $MaxGateSpend = $null,
        [double]$PaidPerCall = 0.05
    )
    $all = @($Candidates | Where-Object { $null -ne $_ })
    $fullCost = Get-ReviewerSpendEstimate -Candidates $all -PaidPerCall $PaidPerCall
    $capBreached = ($null -ne $MaxGateSpend) -and ($fullCost -gt [double]$MaxGateSpend)
    if ((-not $Conserve) -and (-not $capBreached)) {
        return @{ action = 'proceed'; reviewers = @($all | ForEach-Object { [string]$_.name }); estimate = $fullCost; why = 'within budget posture' }
    }
    $pair = @($all | Select-Object -First 2)
    $pairCost = Get-ReviewerSpendEstimate -Candidates $pair -PaidPerCall $PaidPerCall
    if (($null -ne $MaxGateSpend) -and ($pairCost -gt [double]$MaxGateSpend)) {
        return @{ action = 'skip'; reviewers = @(); estimate = $pairCost; why = "budget: even the cheapest reviewer pair (est $pairCost) exceeds the gate spend cap $MaxGateSpend" }
    }
    $why = if ($Conserve) { 'conserve mode: downgraded to the cheapest reviewer pair' }
           else { "gate spend cap: full reviewer set (est $fullCost) exceeds $MaxGateSpend; downgraded to the cheapest pair" }
    return @{ action = 'downgrade'; reviewers = @($pair | ForEach-Object { [string]$_.name }); estimate = $pairCost; why = $why }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1`
Expected: `ALL PASS` (through GB8), exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/test-gate-lib.ps1
git commit -m "feat(gate): slice B — pure downgrade-then-skip spend-gate helpers"
```

---

### Task 4: Slice B — wire the spend gate into Invoke-AcceptanceGate, CLI, and Conductor

**Files:**
- Modify: `scripts/gate-lib.ps1` (`Invoke-AcceptanceGate`, `Format-GateReport`)
- Modify: `scripts/fleet-gate.ps1` (`-MaxGateSpend` param + skip rendering)
- Modify: `scripts/conductor-lib.ps1` (`Invoke-Conductor`: `$MaxGateSpend` threading + skip-aware no-verdict message)
- Modify: `scripts/fleet-go.ps1` (`-MaxGateSpend` param)
- Test: `scripts/test-gate-lib.ps1`, `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Consumes: `Get-GateSpendDecision` (Task 3).
- Produces: `Invoke-AcceptanceGate` gains `-MaxGateSpend <double|null>` and `-UsagePath <path>`; on skip it returns `[ordered]@{ verdict=$null; skipped='budget'; reason=<why>; degraded=$false; counts=@{critical=0;important=0;minor=0}; findings=@(); polish_brief=''; reviews=@(); unparsed=@() }`; on downgrade the result gains `budget_note=<why>`. **Explicit `-Reviewers` bypasses the spend gate entirely** (the operator chose).
- Produces: conductor no-verdict event message becomes `gate-skipped: budget — <reason>` when the gate reported a skip.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-gate-lib.ps1`, insert after the GB8 block (this block pins `BATON_HOME` because `Select-Capability`'s journal/usage defaults read it):

```powershell
    # ---- Slice B (2026-07-04): Invoke-AcceptanceGate wiring ----
    $sbHome = Join-Path ([System.IO.Path]::GetTempPath()) "gate-spend-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $sbHome | Out-Null
    $prevBH = $env:BATON_HOME
    $env:BATON_HOME = $sbHome
    try {
        $sbFleet = Join-Path $sbHome 'fleet.yaml'
        Set-Content -LiteralPath $sbFleet -Encoding utf8 -Value @'
providers:
  - name: rev-free
    kind: cli
    enabled: true
    cost_tier: free
    capabilities: [review]
    command_template: 'echo {{prompt}}'
  - name: rev-paid1
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [review]
    command_template: 'echo {{prompt}}'
  - name: rev-paid2
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [review]
    command_template: 'echo {{prompt}}'
'@
        $sbTools = Join-Path $sbHome 'tools.yaml'
        Set-Content -LiteralPath $sbTools -Encoding utf8 -Value "tools: []`n"
        $sbUsage = Join-Path $sbHome 'usage-journal.jsonl'
        $called = [System.Collections.ArrayList]@()
        $sbDisp = { param($n,$p) [void]$called.Add([string]$n); @{ stdout='[]'; stderr=''; exit_code=0 } }

        # no journal, no cap -> all three reviewers dispatched (unchanged behavior)
        $called.Clear()
        $r0 = Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -FleetPath $sbFleet -ToolsPath $sbTools -UsagePath $sbUsage -Dispatcher $sbDisp
        Check 'GB9 no posture -> full reviewer set dispatched' (@($called).Count -eq 3 -and $r0.verdict -eq 'accept')

        # conserve on -> cheapest pair only, result carries budget_note
        Set-Content -LiteralPath $sbUsage -Encoding utf8NoBOM -Value '{"ts":"2026-07-04T00:00:00Z","worker":"*","event":"conserve","on":true}'
        $called.Clear()
        $r1 = Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -FleetPath $sbFleet -ToolsPath $sbTools -UsagePath $sbUsage -Dispatcher $sbDisp
        Check 'GB10 conserve -> exactly 2 reviewers dispatched' (@($called).Count -eq 2)
        Check 'GB11 conserve pair includes the free reviewer' (@($called) -contains 'rev-free')
        Check 'GB12 downgrade carries budget_note' ($r1.budget_note -match 'conserve')
        $r1rep = Format-GateReport -Result ([hashtable]$r1)
        Check 'GB13 report shows the budget note' ($r1rep -match 'conserve')

        # tiny cap + paid-only pair -> skip (verdict null, skipped=budget)
        Remove-Item -LiteralPath $sbUsage -Force
        $paidFleet = Join-Path $sbHome 'fleet-paid.yaml'
        Set-Content -LiteralPath $paidFleet -Encoding utf8 -Value @'
providers:
  - name: rev-paid1
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [review]
    command_template: 'echo {{prompt}}'
  - name: rev-paid2
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [review]
    command_template: 'echo {{prompt}}'
'@
        $called.Clear()
        $r2 = Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -FleetPath $paidFleet -ToolsPath $sbTools -UsagePath $sbUsage -MaxGateSpend 0.01 -Dispatcher $sbDisp
        Check 'GB14 cap skip -> null verdict + skipped=budget' ($null -eq $r2.verdict -and $r2.skipped -eq 'budget')
        Check 'GB15 cap skip -> zero reviewers dispatched' (@($called).Count -eq 0)

        # explicit -Reviewers bypasses the spend gate even under conserve
        Set-Content -LiteralPath $sbUsage -Encoding utf8NoBOM -Value '{"ts":"2026-07-04T00:00:00Z","worker":"*","event":"conserve","on":true}'
        $called.Clear()
        [void](Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -Reviewers @('rev-paid1','rev-paid2') -FleetPath $paidFleet -ToolsPath $sbTools -UsagePath $sbUsage -Dispatcher $sbDisp)
        Check 'GB16 explicit -Reviewers bypasses the spend gate' (@($called).Count -eq 2)
    }
    finally {
        if ($null -ne $prevBH) { $env:BATON_HOME = $prevBH } else { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
        Remove-Item -Recurse -Force $sbHome -ErrorAction SilentlyContinue
    }
```

In `scripts/test-conductor-lib.ps1`, insert after the ER3 block:

```powershell
    # ---- Slice B (2026-07-04): conductor honors a gate budget skip ----
    $gaterSkip = { param($art,$goal) [ordered]@{ verdict = $null; skipped = 'budget'; reason = 'even the cheapest pair exceeds the cap' } }
    $rsk = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-skip') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterSkip
    Check 'GB17 gate budget skip -> completed (fail-open)' ($rsk.status -eq 'completed')
    Check 'GB18 gate budget skip event message' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-skip/events.jsonl') -Raw) -match 'gate-skipped: budget')
    Check 'GB19 gate budget skip -> no acceptance.json' (-not (Test-Path (Join-Path $gtHome 'r-skip/acceptance.json')))
```

- [ ] **Step 2: Run to verify failure**

Both suites: GB9+ fail (`-UsagePath` / `-MaxGateSpend` params don't exist yet → binding error caught as suite failure), GB18 fails (message says `produced no verdict`).

- [ ] **Step 3: Implement**

In `scripts/gate-lib.ps1`, `Invoke-AcceptanceGate`:

(a) extend the param block — after the `[scriptblock]$Dispatcher` line add (with a comma after `$Dispatcher`):

```powershell
        $MaxGateSpend = $null,
        [string]$UsagePath = (Join-Path (Get-BatonHome) 'usage-journal.jsonl')
```

(b) replace the reviewer-resolution block:

```powershell
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        $cands = Select-Capability -Capability review -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath
        $Reviewers = @($cands | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.name })
    }
```

with:

```powershell
    $budgetNote = ''
    if (-not $Reviewers -or $Reviewers.Count -lt 1) {
        $cands = @((Select-Capability -Capability review -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath) | Where-Object { $null -ne $_ })
        $conserve = $false
        try { $conserve = [bool](Get-ConserveMode -UsagePath $UsagePath) } catch { $conserve = $false }
        $decision = Get-GateSpendDecision -Candidates $cands -Conserve $conserve -MaxGateSpend $MaxGateSpend
        if ($decision.action -eq 'skip') {
            return [ordered]@{
                verdict = $null; skipped = 'budget'; reason = [string]$decision.why
                degraded = $false; counts = @{ critical = 0; important = 0; minor = 0 }
                findings = @(); polish_brief = ''; reviews = @(); unparsed = @()
            }
        }
        if ($decision.action -eq 'downgrade') { $budgetNote = [string]$decision.why }
        $Reviewers = @($decision.reviewers)
    }
```

(c) in the final `[ordered]@{...}` return (from Task 1), add after the `degraded` line:

```powershell
        budget_note = $budgetNote
```

In `Format-GateReport`, after the Task-1 degraded warning block, add:

```powershell
    if ($Result.budget_note) {
        [void]$sb.AppendLine("Budget: $($Result.budget_note)")
    }
```

In `scripts/fleet-gate.ps1`: add param `[double]$MaxGateSpend` after `[switch]$Json,` (as `[double]$MaxGateSpend,`); after the `$callArgs = @{...}` line add:

```powershell
        if ($PSBoundParameters.ContainsKey('MaxGateSpend')) { $callArgs['MaxGateSpend'] = $MaxGateSpend }
```

and replace the non-JSON output block:

```powershell
        else {
            Write-Host (Format-GateReport -Result ([hashtable]$res))
            Write-Host '---'
            Write-Host $res.polish_brief
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
        }
```

with:

```powershell
        else {
            if ((-not $res.verdict) -and $res.skipped) {
                Write-Host "ACCEPTANCE GATE — SKIPPED ($($res.skipped)): $($res.reason)"
            } else {
                Write-Host (Format-GateReport -Result ([hashtable]$res))
                Write-Host '---'
                Write-Host $res.polish_brief
            }
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter }
        }
```

In `scripts/conductor-lib.ps1`, `Invoke-Conductor`: add param `$MaxGateSpend = $null,` after `[string]$GateDiff,`; replace the real-gate call:

```powershell
            $gate = if ($Gater) { & $Gater $art $plan.goal }
                    else { Invoke-AcceptanceGate -Artifact $art -Task $plan.goal -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath }
```

with:

```powershell
            $gateParams = @{ Artifact = $art; Task = $plan.goal; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
            if ($null -ne $MaxGateSpend) { $gateParams.MaxGateSpend = $MaxGateSpend }
            $gate = if ($Gater) { & $Gater $art $plan.goal }
                    else { Invoke-AcceptanceGate @gateParams }
```

and replace the no-verdict message line:

```powershell
            $msg = if ($gateErr) { "acceptance gate failed: $gateErr" } else { 'acceptance gate produced no verdict (fail-open)' }
```

with:

```powershell
            $msg = if ($gateErr) { "acceptance gate failed: $gateErr" }
                   elseif ($gate -and $gate.skipped) { "gate-skipped: $($gate.skipped) — $($gate.reason)" }
                   else { 'acceptance gate produced no verdict (fail-open)' }
```

In `scripts/fleet-go.ps1`: add param `[double]$MaxGateSpend,` after `[string]$GateDiff,`; after the GateDiff threading line add:

```powershell
if ($PSBoundParameters.ContainsKey('MaxGateSpend')) { $go['MaxGateSpend'] = $MaxGateSpend }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1` → `ALL PASS` exit 0.
Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1` → `ALL PASS` exit 0 (T75–T79 fail-open regressions must stay green — the skip result flows through the existing no-verdict branch).

- [ ] **Step 5: Commit**

```bash
git add scripts/gate-lib.ps1 scripts/fleet-gate.ps1 scripts/conductor-lib.ps1 scripts/fleet-go.ps1 scripts/test-gate-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(gate): slice B — budget-gated reviewer spend (downgrade-then-skip, -MaxGateSpend)"
```

---

### Task 5: Slices A+B docs + RC bump (first ship point)

**Files:**
- Modify: `commands/gate.md`, `commands/go.md`, `docs/COMMANDS.md`, `.claude-plugin/plugin.json`

**Interfaces:** none (docs only).

- [ ] **Step 1: Document**

In `commands/gate.md`, add under the existing options/behavior section:

```markdown
- `-MaxGateSpend <usd>` — cap the estimated reviewer spend. Over the cap the
  gate first downgrades to the cheapest capable reviewer pair; if even the pair
  exceeds the cap it SKIPS with `ACCEPTANCE GATE — SKIPPED (budget)` (exit 0 —
  advisory). Conserve mode (`/baton:usage conserve on`) always downgrades to the
  cheapest pair. Explicit `--reviewers` bypasses the spend gate.
- A bad `--diff` range now errors (exit 2) instead of reviewing git's error text.
- Fewer than two usable reviews marks the result `degraded: true` with a report
  warning — no finding can be corroborated by a single voice.
```

In `commands/go.md`, add one line to the acceptance-gate notes:

```markdown
- `-MaxGateSpend <usd>` threads the reviewer spend cap into the run-level gate;
  a budget skip logs a `gate-skipped: budget` event and the run completes
  ungated (fail-open). A gate target that resolves empty (bad diff range) now
  logs `gate-skipped: target resolved empty` instead of silence.
```

In `docs/COMMANDS.md`, mirror both notes in the gate/go entries (same wording, one line each).

In `.claude-plugin/plugin.json`, bump `"version"` to the next free RC at build time (from 1.8.0 the expected value is `1.8.1-rc.1`; if master has moved, use the next free RC and say so in the commit body).

- [ ] **Step 2: Run the full regression pair**

Run: `pwsh -NoProfile -File scripts/test-gate-lib.ps1` and `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: both `ALL PASS`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add commands/gate.md commands/go.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "docs(gate): slices A+B notes + version bump (A+B ship point)"
```

---

### Task 6: Slice C — plan schema: `type` + `consumes` (parser, planner schema, templates)

**Files:**
- Modify: `scripts/conductor-lib.ps1` (`ConvertTo-PlanObject`, `Build-PlannerPrompt`'s `$schema`, `$script:DefaultPlannerPrompt`)
- Modify: `prompts/conductor-planner.txt`
- Test: `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Produces: normalized plan tasks gain `type` (`'gate'` when the raw task says so, else `'work'`) and `consumes` (string array, default `@()`). Later tasks (7–9) rely on exactly these names.
- NOTE: the `$schema` here-string is substituted into EVERY planner variant (live, tuned, challenger) via `{{schema}}` — updating it updates them all. The template FILES only gain a Rules sentence; the live BATON_HOME prompt is seed-if-absent and keeps its old Rules text (acceptable: the schema carries the field; pool evolution can learn the rest).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, insert after the `Check 'T11 ...'` line:

```powershell
    # ---- Slice C (2026-07-04): plan schema gains type + consumes ----
    $pGate = ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"build"},{"id":"g1","desc":"check t1","type":"gate","consumes":["t1"],"depends_on":["t1"]}]}'
    Check 'PC1 absent type defaults to work' ($pGate.tasks[0].type -eq 'work')
    Check 'PC2 gate type honored' ($pGate.tasks[1].type -eq 'gate')
    Check 'PC3 consumes parsed as array' (@($pGate.tasks[1].consumes) -contains 't1')
    Check 'PC4 absent consumes defaults empty' (@($pGate.tasks[0].consumes).Count -eq 0)
    Check 'PC5 unknown type coerced to work' ((ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"a","desc":"d","type":"banana"}]}').tasks[0].type -eq 'work')
    Check 'PC6 planner schema advertises the new fields' ((Build-PlannerPrompt -Goal 'g') -match '"type": "work\|gate"')
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `FAIL: PC1`–`PC6` (properties absent / schema unchanged); everything else PASS.

- [ ] **Step 3: Implement**

In `ConvertTo-PlanObject`, inside the `[pscustomobject]@{ ... }` task literal, add after the `reversible` line:

```powershell
            type          = if (([string]$t.type) -eq 'gate') { 'gate' } else { 'work' }
            consumes      = @($t.consumes | Where-Object { $_ } | ForEach-Object { [string]$_ })
```

In `Build-PlannerPrompt`, replace the `$schema` here-string's task line so the schema reads:

```powershell
    $schema = @'
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<capability or empty>", "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true,
      "type": "work|gate", "consumes": [] }
  ]
}
'@
```

In BOTH `$script:DefaultPlannerPrompt` (conductor-lib) and `prompts/conductor-planner.txt` (they are kept in sync by hand — change both identically), append to the `Rules:` paragraph:

```
You may insert checkpoint tasks {"type":"gate","consumes":["<upstream ids>"]}
after load-bearing steps — a gate task reviews the consumed outputs and fails
its branch on reject. Give a work task "consumes" only when it needs an
upstream task's output as context.
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL PASS`, exit 0 (T2/T4–T11 prove existing parse behavior held).

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 prompts/conductor-planner.txt scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): slice C — plan schema gains type:gate + consumes"
```

---

### Task 7: Slice C — task-output bus (write, read, prompt append)

**Files:**
- Modify: `scripts/conductor-lib.ps1` (two new functions + `Invoke-TaskViaFleet` + the walk in `Invoke-Conductor`)
- Test: `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Produces: `Write-TaskOutput -RunDir <dir> -TaskId <id> -Output <text>` → writes `<RunDir>/outputs/<id>.txt` (utf8NoBOM); empty output writes nothing; IO errors swallowed.
- Produces: `Get-ConsumedOutputs -RunDir <dir> -TaskIds <ids> [-CharCap 6000]` → concatenated `### Output of <id>` sections, each truncated at the cap with a `[truncated]` marker; missing/empty files skipped; `''` when nothing.
- Produces: `Invoke-TaskViaFleet` gains `-ConsumedContext <string>` (appended to the prompt under `## Upstream outputs`) and its result gains `output = <stdout>`.
- Produces: the walk passes the bus context as a SECOND argument to an injected `-Spawner` (`& $Spawner $task $busContext` — existing single-param stubs ignore it), and persists `$r.output` after each successful task.

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, insert after the PC6 block:

```powershell
    # ---- Slice C (2026-07-04): task-output bus ----
    $busHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-bus-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $busHome | Out-Null
    $busRun = Join-Path $busHome 'r-bus'
    New-Item -ItemType Directory -Force -Path $busRun | Out-Null

    Write-TaskOutput -RunDir $busRun -TaskId 't1' -Output 'the draft text'
    Check 'BUS1 output file written' ((Get-Content -Raw -LiteralPath (Join-Path $busRun 'outputs/t1.txt')).Trim() -eq 'the draft text')
    Write-TaskOutput -RunDir $busRun -TaskId 't2' -Output ''
    Check 'BUS2 empty output writes nothing' (-not (Test-Path (Join-Path $busRun 'outputs/t2.txt')))
    $ctx = Get-ConsumedOutputs -RunDir $busRun -TaskIds @('t1','missing')
    Check 'BUS3 consumed context carries the output, skips missing' (($ctx -match 'Output of t1') -and ($ctx -match 'the draft text') -and ($ctx -notmatch 'missing'))
    Check 'BUS4 no ids -> empty context' ((Get-ConsumedOutputs -RunDir $busRun -TaskIds @()) -eq '')
    Write-TaskOutput -RunDir $busRun -TaskId 'big' -Output ('x' * 7000)
    $ctxBig = Get-ConsumedOutputs -RunDir $busRun -TaskIds @('big') -CharCap 6000
    Check 'BUS5 oversize output truncated with marker' (($ctxBig.Length -lt 6300) -and ($ctxBig -match '\[truncated\]'))

    # end-to-end: producer output reaches the consumer's spawner call
    $busSeen = [System.Collections.ArrayList]@()
    $busSpawner = {
        param($task, $ctx)
        [void]$busSeen.Add(@{ id = $task.id; ctx = [string]$ctx })
        @{ ok = $true; spend = 0.0; chose = 'stub'; why = ''; alternatives = @(); output = "out-of-$($task.id)" }
    }
    $busPlanner = { param($goal) ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"produce"},{"id":"t2","desc":"consume","depends_on":["t1"],"consumes":["t1"]}]}' }
    $rb = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $busHome 'r-e2e') -Planner $busPlanner -Spawner $busSpawner
    Check 'BUS6 run completed' ($rb.status -eq 'completed')
    Check 'BUS7 producer output persisted to the bus' ((Get-Content -Raw -LiteralPath (Join-Path $busHome 'r-e2e/outputs/t1.txt')).Trim() -eq 'out-of-t1')
    $consumerCall = @($busSeen | Where-Object { $_.id -eq 't2' })[0]
    Check 'BUS8 consumer received upstream context' ($consumerCall.ctx -match 'out-of-t1')
    $producerCall = @($busSeen | Where-Object { $_.id -eq 't1' })[0]
    Check 'BUS9 non-consuming task received empty context' ([string]::IsNullOrEmpty($producerCall.ctx))

    # regression: a plan with no consumes/outputs -> no outputs dir from stub spawners without output
    $plainSpawner = { param($task) @{ ok = $true; spend = 0.0; chose = 'stub'; why = ''; alternatives = @() } }
    $rp2 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $busHome 'r-plain') -Planner $gPlanner -Spawner $plainSpawner
    Check 'BUS10 outputless spawner -> no outputs dir' (($rp2.status -eq 'completed') -and (-not (Test-Path (Join-Path $busHome 'r-plain/outputs'))))
    Remove-Item -Recurse -Force $busHome -ErrorAction SilentlyContinue
```

NOTE: `$gPlanner`/`$gSpawner` are defined earlier in the suite ($gtHome block) — this block must be placed AFTER them; if placed before, reuse `$busPlanner` with a single-task plan instead.

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: hard failure at BUS1 (`Write-TaskOutput` not recognized).

- [ ] **Step 3: Implement**

In `scripts/conductor-lib.ps1`, insert after `Format-AcceptanceSection`'s closing `}`:

```powershell
$script:ConsumedOutputCharCap = 6000

function Write-TaskOutput {
    <# Slice C bus write: persist a completed task's textual output to
       outputs/<id>.txt so downstream tasks can consume it. Fail-open: empty
       output writes nothing; an IO error never fails the task. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$TaskId,
        [string]$Output
    )
    if ([string]::IsNullOrWhiteSpace($Output)) { return }
    try {
        $dir = Join-Path $RunDir 'outputs'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "$TaskId.txt") -Value $Output -Encoding utf8NoBOM
    } catch { }
}

function Get-ConsumedOutputs {
    <# Slice C bus read: concatenate the named upstream outputs, each truncated at
       the char cap (context rides the PROMPT — stdin for stdin:true providers —
       never a new shell arg; the cap keeps prompts bounded). Missing/unreadable/
       empty files are skipped (fail-open). '' when nothing consumable. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [string[]]$TaskIds = @(),
        [int]$CharCap = $script:ConsumedOutputCharCap
    )
    if (@($TaskIds).Count -eq 0) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($tid in @($TaskIds)) {
        $p = Join-Path $RunDir "outputs/$tid.txt"
        if (-not (Test-Path $p)) { continue }
        $txt = ''
        try { $txt = Get-Content -Raw -LiteralPath $p } catch { continue }
        if ([string]::IsNullOrWhiteSpace($txt)) { continue }
        if ($txt.Length -gt $CharCap) { $txt = $txt.Substring(0, $CharCap) + "`n[truncated]" }
        [void]$sb.AppendLine("### Output of $tid")
        [void]$sb.AppendLine($txt.TrimEnd())
        [void]$sb.AppendLine('')
    }
    return $sb.ToString().TrimEnd()
}
```

In `Invoke-TaskViaFleet`: add param `[string]$ConsumedContext = '',` after `[ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',`; replace the prompt line and the return:

```powershell
    $prompt = "Task: $($Task.desc)"
    if (-not [string]::IsNullOrWhiteSpace($ConsumedContext)) {
        $prompt = $prompt + "`n`n## Upstream outputs`n" + $ConsumedContext
    }
    $res = if ($Dispatcher) { & $Dispatcher $pick $prompt } else { Invoke-Fleet -Name $pick.name -Prompt $prompt -Path $FleetPath -NoJournal }
    $alts = @($cands | Select-Object -Skip 1 | ForEach-Object { $_.name })
    return @{ ok = ([int]$res.exit_code -eq 0); spend = 0.0; chose = $pick.name; why = "routed $cap -> $($pick.name)"; alternatives = $alts; output = [string]$res.stdout }
```

In `Invoke-Conductor`'s walk, replace:

```powershell
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'started' -Message $task.desc)
        $r = if ($Spawner) { & $Spawner $task }
             else { Invoke-TaskViaFleet -Task $task -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher }
```

with:

```powershell
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'started' -Message $task.desc)
        $busContext = Get-ConsumedOutputs -RunDir $RunDir -TaskIds @($task.consumes)
        $r = if ($Spawner) { & $Spawner $task $busContext }
             else { Invoke-TaskViaFleet -Task $task -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher -ConsumedContext $busContext }
```

and immediately BEFORE the `$kind = if ($r.ok) { 'finished' } else { 'error' }` line add:

```powershell
        if ($r.ok -and ($null -ne $r.output)) { Write-TaskOutput -RunDir $RunDir -TaskId $task.id -Output ([string]$r.output) }
```

GUARD NOTE: `@($task.consumes)` on a task object that predates Task 6's parser (hand-built test fixtures) yields `@($null)` → `Get-ConsumedOutputs` receives `@()` after its own `Where-Object`-free path? It does NOT filter nulls — so ALSO harden `Get-ConsumedOutputs`' first line to `$TaskIds = @($TaskIds | Where-Object { $_ })` before the count check:

```powershell
    $TaskIds = @($TaskIds | Where-Object { $_ })
    if (@($TaskIds).Count -eq 0) { return '' }
```

(Include this in the function as written — the fixture tasks built by `$mk`/`$mkTask` in the existing suite have no `consumes` member, and `$task.consumes` on a pscustomobject without the property is `$null`.)

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL PASS` exit 0 — including T44–T55 (walk regressions with property-less fixture tasks) and BUS10.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): slice C — task-output bus (outputs/<id>.txt + consumes context)"
```

---

### Task 8: Slice C — mid-DAG `gate` task execution

**Files:**
- Modify: `scripts/conductor-lib.ps1` (`Invoke-Conductor` walk: gate-task branch)
- Test: `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Consumes: `Get-ConsumedOutputs` (Task 7), `Invoke-AcceptanceGate`/`-Gater` seam (existing).
- Produces: a task with `type:'gate'` reviews its consumed outputs mid-walk: `reject` → the task FAILS (run status `failed`, downstream never runs — existing DAG failure semantics, no new interrupt); `accept`/`polish` → task ok, `polish_brief` becomes the gate task's bus output; no verdict / empty context → ok + warn event (fail-open).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, insert after the BUS10 block:

```powershell
    # ---- Slice C (2026-07-04): mid-DAG gate task ----
    $mgHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-midgate-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $mgHome | Out-Null
    $mgPlanner = { param($goal) ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"produce"},{"id":"g1","desc":"review the draft","type":"gate","consumes":["t1"],"depends_on":["t1"]},{"id":"t3","desc":"after","depends_on":["g1"]}]}' }
    $mgSpawner = { param($task, $ctx) @{ ok = $true; spend = 0.0; chose = 'stub'; why = ''; alternatives = @(); output = "out-of-$($task.id)" } }

    $mgAccept = { param($art, $goal) @{ verdict='accept'; reason='clean'; counts=@{critical=0;important=0;minor=0}; polish_brief='No polish needed'; findings=@(); reviews=@(); unparsed=@() } }
    $rga = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $mgHome 'r-acc') -Planner $mgPlanner -Spawner $mgSpawner -Gater $mgAccept
    Check 'MG1 mid-DAG accept -> completed, downstream ran' ($rga.status -eq 'completed')
    Check 'MG2 mid-DAG gate event logged' ((Get-Content -LiteralPath (Join-Path $mgHome 'r-acc/events.jsonl') -Raw) -match 'mid-DAG gate g1: accept')

    $mgReject = { param($art, $goal) @{ verdict='reject'; reason='1 critical'; counts=@{critical=1;important=0;minor=0}; polish_brief='[critical] broken'; findings=@(); reviews=@(); unparsed=@() } }
    $rgr = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $mgHome 'r-rej') -Planner $mgPlanner -Spawner $mgSpawner -Gater $mgReject
    Check 'MG3 mid-DAG reject -> run failed at the gate task' (($rgr.status -eq 'failed') -and ($rgr.pending_task_id -eq 'g1'))
    Check 'MG4 downstream task skipped on reject' (-not ((Get-Content -LiteralPath (Join-Path $mgHome 'r-rej/events.jsonl') -Raw) -match '"task_id":"t3","kind":"started"'))

    $mgThrow = { param($art, $goal) throw 'reviewers exploded' }
    $rgt = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $mgHome 'r-throw') -Planner $mgPlanner -Spawner $mgSpawner -Gater $mgThrow
    Check 'MG5 mid-DAG gate error -> fail-open pass, run completed' ($rgt.status -eq 'completed')

    # gate task with nothing consumable -> fail-open pass + warn
    $mgPlanner2 = { param($goal) ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"g1","desc":"review nothing","type":"gate","consumes":["nope"]}]}' }
    $rgn = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $mgHome 'r-empty') -Planner $mgPlanner2 -Spawner $mgSpawner -Gater $mgAccept
    Check 'MG6 gate with no consumable outputs -> pass + warn event' (($rgn.status -eq 'completed') -and ((Get-Content -LiteralPath (Join-Path $mgHome 'r-empty/events.jsonl') -Raw) -match 'no consumable outputs'))
    Remove-Item -Recurse -Force $mgHome -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: MG2 fails (gate task currently dispatched to the Spawner like any task — no gate event), MG3/MG4 fail (reject never happens).

- [ ] **Step 3: Implement**

In `Invoke-Conductor`'s walk (as modified by Task 7), replace:

```powershell
        $busContext = Get-ConsumedOutputs -RunDir $RunDir -TaskIds @($task.consumes)
        $r = if ($Spawner) { & $Spawner $task $busContext }
             else { Invoke-TaskViaFleet -Task $task -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher -ConsumedContext $busContext }
```

with:

```powershell
        $busContext = Get-ConsumedOutputs -RunDir $RunDir -TaskIds @($task.consumes)
        if (([string]$task.type) -eq 'gate') {
            # Slice C: mid-DAG gate task — review consumed outputs, never spawn.
            # reject -> task failure (existing DAG semantics); errors fail open.
            if ([string]::IsNullOrWhiteSpace($busContext)) {
                Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'gate' -Level 'warn' -Message "mid-DAG gate $($task.id): no consumable outputs — skipped (fail-open pass)")
                $r = @{ ok = $true; spend = 0.0; chose = ''; why = 'gate skipped: nothing to review'; alternatives = @(); output = '' }
            } else {
                $gv = $null
                try {
                    $gateParams = @{ Artifact = $busContext; Task = [string]$task.desc; MaxCostTier = $MaxCostTier; FleetPath = $FleetPath; ToolsPath = $ToolsPath }
                    if ($null -ne $MaxGateSpend) { $gateParams.MaxGateSpend = $MaxGateSpend }
                    $gv = if ($Gater) { & $Gater $busContext $task.desc } else { Invoke-AcceptanceGate @gateParams }
                } catch { $gv = $null }
                if ($null -eq $gv -or -not $gv.verdict) {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'gate' -Level 'warn' -Message "mid-DAG gate $($task.id) produced no verdict (fail-open pass)"))
                    $r = @{ ok = $true; spend = 0.0; chose = ''; why = 'gate produced no verdict'; alternatives = @(); output = '' }
                } else {
                    Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'gate' -Message "mid-DAG gate $($task.id): $($gv.verdict) — $($gv.reason)")
                    $r = @{ ok = ($gv.verdict -ne 'reject'); spend = 0.0; chose = 'acceptance-gate'; why = "mid-DAG verdict $($gv.verdict)"; alternatives = @(); output = [string]$gv.polish_brief }
                }
            }
        } else {
            $r = if ($Spawner) { & $Spawner $task $busContext }
                 else { Invoke-TaskViaFleet -Task $task -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher -ConsumedContext $busContext }
        }
```

(TRANSCRIPTION WARNING: the `no verdict` Add-RunEvent line above must have exactly balanced parens — `...-Message "...")` then the outer `)` — write it as one line and count.)

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL PASS` exit 0. MG3 relies on the existing failed-task return path (`Status 'failed' -PendingTaskId $task.id`) — no change needed there.

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): slice C — mid-DAG gate tasks (reject fails the branch, fail-open otherwise)"
```

---

### Task 9: Slice D — bounded one-shot auto-polish

**Files:**
- Modify: `scripts/conductor-lib.ps1` (`Invoke-AutoPolish` + `Format-AutoPolishSection` new; `Invoke-TaskViaFleet` `-SelectionMode`; `Complete-Run` `-PolishInfo`; `Invoke-Conductor` wiring)
- Modify: `scripts/fleet-go.ps1` (`-AutoPolish` flag + validation + multi-verdict gate seam)
- Test: `scripts/test-conductor-lib.ps1`

**Interfaces:**
- Produces: `Invoke-AutoPolish` → `@{ gate; spend; attempted; chose; before; after; note }` — dispatches the polish brief ONCE via champion-mode selection, re-gates ONCE on the re-resolved artifact; any error/skip returns the ORIGINAL gate untouched.
- Produces: `Invoke-TaskViaFleet -SelectionMode economy|champion` (default economy — all existing calls unchanged).
- Produces: `Complete-Run -PolishInfo <hashtable|null>` appends `## Auto-polish` after `## Acceptance`.
- Produces: `fleet-go.ps1 -AutoPolish` (requires a gate target → else exit 2); `BATON_GO_TEST_GATE` accepts a comma list (`'polish,accept'`) consumed one verdict per gate call (single value = old behavior, T60c safe).

- [ ] **Step 1: Write the failing tests**

In `scripts/test-conductor-lib.ps1`, insert after the MG6 block:

```powershell
    # ---- Slice D (2026-07-04): bounded one-shot auto-polish ----
    $apHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-ap-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $apHome | Out-Null
    $apPolish = @{ verdict='polish'; reason='1 important'; counts=@{critical=0;important=1;minor=0}; polish_brief='[important][x] tighten it'; findings=@(); reviews=@(); unparsed=@() }
    $apAccept = @{ verdict='accept'; reason='clean now'; counts=@{critical=0;important=0;minor=0}; polish_brief='No polish needed'; findings=@(); reviews=@(); unparsed=@() }
    $apReject = @{ verdict='reject'; reason='worse'; counts=@{critical=1;important=0;minor=0}; polish_brief='[critical] broke it'; findings=@(); reviews=@(); unparsed=@() }
    $mkStagedGater = {
        param([array]$Verdicts)
        $state = @{ n = 0 }
        { param($art, $goal)
            $i = [Math]::Min($state.n, $Verdicts.Count - 1)
            $state.n++
            $Verdicts[$i]
        }.GetNewClosure()
    }

    # polish -> auto-polish -> accept: completed, section + spend + final verdict accept
    $g1 = & $mkStagedGater @($apPolish, $apAccept)
    $ap1 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $apHome 'r-pa') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $g1 -AutoPolish
    Check 'AP1 polish->accept sticks: completed' ($ap1.status -eq 'completed')
    Check 'AP2 final acceptance.json is the re-gate verdict' (((Get-Content -Raw -LiteralPath (Join-Path $apHome 'r-pa/acceptance.json')) | ConvertFrom-Json).verdict -eq 'accept')
    Check 'AP3 report has Auto-polish section' ((Get-Content -Raw -LiteralPath (Join-Path $apHome 'r-pa/report.md')) -match '## Auto-polish')
    Check 'AP4 polish events logged' ((Get-Content -LiteralPath (Join-Path $apHome 'r-pa/events.jsonl') -Raw) -match '"kind":"polish"')
    Check 'AP5 polish spend accrued' ($ap1.spend -eq 0.05)

    # polish -> auto-polish -> reject: rejected
    $g2 = & $mkStagedGater @($apPolish, $apReject)
    $ap2 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $apHome 'r-pr') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $g2 -AutoPolish
    Check 'AP6 polish->reject after auto-polish -> rejected' ($ap2.status -eq 'rejected')

    # budget cap already at the line -> polish skipped, original verdict stands
    $g3 = & $mkStagedGater @($apPolish, $apAccept)
    $ap3 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $apHome 'r-cap') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $g3 -AutoPolish -BudgetCap 0.0
    Check 'AP7 cap breach -> skip note event, verdict stays polish' ((($ap3.acceptance).verdict -eq 'polish') -and ((Get-Content -LiteralPath (Join-Path $apHome 'r-cap/events.jsonl') -Raw) -match 'auto-polish skipped'))
    Check 'AP8 cap breach -> completed (never a new interrupt)' ($ap3.status -eq 'completed')

    # no -AutoPolish -> byte-identical behavior (no polish events)
    $g4 = & $mkStagedGater @($apPolish, $apAccept)
    $ap4 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $apHome 'r-off') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $g4
    Check 'AP9 no flag -> polish verdict stands, no polish events' ((($ap4.acceptance).verdict -eq 'polish') -and (-not ((Get-Content -LiteralPath (Join-Path $apHome 'r-off/events.jsonl') -Raw) -match '"kind":"polish"')))
    Remove-Item -Recurse -Force $apHome -ErrorAction SilentlyContinue
```

And extend the CLI section (after T60c's `Remove-Item Env:\BATON_GO_TEST_GATE` line, re-using `$cliHome` while `BATON_HOME`/plan/spawn env are still set):

```powershell
    # Slice D CLI: staged verdicts + -AutoPolish
    $env:BATON_GO_TEST_GATE = 'polish,accept'
    $outAP = & pwsh -NoProfile -File $cli -Goal 'convert pdfs' -GateArtifact 'finished work' -AutoPolish -Json 2>&1 | Out-String
    Check 'AP10 CLI auto-polish polish->accept -> completed' ($outAP -match '"status": *"completed"')
    Remove-Item Env:\BATON_GO_TEST_GATE -ErrorAction SilentlyContinue
    & pwsh -NoProfile -File $cli -Goal 'x' -AutoPolish 2>$null | Out-Null
    Check 'AP11 CLI -AutoPolish without gate target -> exit 2' ($LASTEXITCODE -eq 2)
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: AP1+ fail (`-AutoPolish` parameter does not exist on `Invoke-Conductor`).

- [ ] **Step 3: Implement**

**(a)** `Invoke-TaskViaFleet`: add param `[ValidateSet('economy','champion')][string]$SelectionMode = 'economy',` after `-MaxCostTier`'s line, and pass it: change the `Select-Capability` call to include `-SelectionMode $SelectionMode`.

**(b)** New functions in `scripts/conductor-lib.ps1`, after `Get-ConsumedOutputs`:

```powershell
function Format-AutoPolishSection {
    <# Render the ## Auto-polish report block from Invoke-AutoPolish's result. #>
    param([Parameter(Mandatory)][hashtable]$Info)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('## Auto-polish')
    [void]$sb.AppendLine('')
    if (-not $Info.attempted) {
        [void]$sb.AppendLine("**Attempted:** no — $($Info.note)")
    } else {
        $via = if ($Info.chose) { " via $($Info.chose)" } else { '' }
        [void]$sb.AppendLine("**Attempted:** yes (one bounded pass$via)")
        [void]$sb.AppendLine("**Verdict:** $($Info.before) -> $($Info.after)")
        if ($Info.note) { [void]$sb.AppendLine("**Note:** $($Info.note)") }
    }
    return $sb.ToString().TrimEnd()
}

function Invoke-AutoPolish {
    <# Slice D: EXACTLY ONE premium polish pass + ONE re-gate. Bounded by design
       (the shadow-auto-retire discipline: Baton acts alone only in bounded,
       logged ways). Fail-open everywhere — any error returns the original gate
       untouched. Returns @{ gate; spend; attempted; chose; before; after; note }. #>
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Plan,
        [Parameter(Mandatory)]$Gate,
        [string]$GateArtifact, [string]$GateDiff,
        [double]$Spend = 0.0, $BudgetCap = $null, [double]$PaidPerCall = 0.05,
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [string]$ToolsPath = (Join-Path (Get-BatonHome) 'tools.yaml'),
        [scriptblock]$Dispatcher, [scriptblock]$Spawner, [scriptblock]$Gater
    )
    $out = @{ gate = $Gate; spend = 0.0; attempted = $false; chose = ''; before = [string]$Gate.verdict; after = [string]$Gate.verdict; note = '' }
    try {
        $est = Get-TaskCostEstimate -Tier 'paid' -PaidPerCall $PaidPerCall
        if (Test-BudgetExceeded -CumulativeSpend $Spend -TaskEstimate $est -BudgetCap $BudgetCap) {
            $out.note = 'auto-polish skipped: the pass would cross the budget cap'
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Level 'warn' -Message $out.note)
            return $out
        }
        $polishTask = [pscustomobject]@{
            id = 'auto-polish'
            desc = "Polish pass for goal '$($Plan.goal)'. Apply this brief:`n$($Gate.polish_brief)"
            command = ''; capability = 'reasoning'; model_pick = ''
            depends_on = @(); est_cost_tier = 'paid'; reversible = $true
            type = 'work'; consumes = @()
        }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Message 'auto-polish: dispatching one premium pass')
        $r = if ($Spawner) { & $Spawner $polishTask '' }
             else { Invoke-TaskViaFleet -Task $polishTask -FleetPath $FleetPath -ToolsPath $ToolsPath -MaxCostTier $MaxCostTier -Dispatcher $Dispatcher -SelectionMode champion }
        $out.attempted = $true
        $out.spend = $est
        $out.chose = [string]$r.chose
        if ($r.chose) {
            Add-RunDecision -RunDir $RunDir -Decision (New-RunDecision -TaskId 'auto-polish' -Chose ([string]$r.chose) -Alternatives (@($r.alternatives)) -Why 'premium polish pass (champion selection)' -CostTier 'paid')
        }
        if (-not $r.ok) {
            $out.note = 'polish pass failed; original polish verdict stands'
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Level 'warn' -Message $out.note)
            return $out
        }
        $art2 = Resolve-GateArtifact -Artifact $GateArtifact -Diff $GateDiff
        if ([string]::IsNullOrWhiteSpace($art2)) {
            $out.note = 're-gate target resolved empty; original polish verdict stands'
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Level 'warn' -Message $out.note)
            return $out
        }
        $g2 = $null
        try {
            $g2 = if ($Gater) { & $Gater $art2 $Plan.goal }
                  else { Invoke-AcceptanceGate -Artifact $art2 -Task $Plan.goal -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath }
        } catch { $g2 = $null }
        if ($null -eq $g2 -or -not $g2.verdict) {
            $out.note = 're-gate produced no verdict; original polish verdict stands'
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Level 'warn' -Message $out.note)
            return $out
        }
        Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Message "auto-polish re-gate verdict: $($g2.verdict) — $($g2.reason)")
        $out.gate = $g2
        $out.after = [string]$g2.verdict
        return $out
    } catch {
        $out.note = "auto-polish error (fail-open): $($_.Exception.Message)"
        try { Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId 'auto-polish' -Kind 'polish' -Level 'warn' -Message $out.note) } catch { }
        return $out
    }
}
```

**(c)** `Complete-Run`: add param `$PolishInfo = $null,` after `$Gate = $null,`; after the `if ($Gate) { ... }` acceptance-section block add:

```powershell
    if ($PolishInfo) {
        $report = $report + "`n`n" + (Format-AutoPolishSection -Info ([hashtable]$PolishInfo))
    }
```

(This must run BEFORE the effective-cost block so the section order is Acceptance → Auto-polish → Effective cost; the effective-cost block already recomputes from `$Gate`, which the caller has replaced with the FINAL gate.)

**(d)** `Invoke-Conductor`: add params `[switch]$AutoPolish,` (after `$MaxGateSpend = $null,`). Replace the final return line:

```powershell
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts)
```

with:

```powershell
    # Slice D: bounded one-shot auto-polish (opt-in; polish verdict only).
    $polishInfo = $null
    if ($AutoPolish -and $gate -and ($gate.verdict -eq 'polish')) {
        $polishInfo = Invoke-AutoPolish -RunDir $RunDir -Plan $plan -Gate $gate -GateArtifact $GateArtifact -GateDiff $GateDiff `
            -Spend $spend -BudgetCap $BudgetCap -PaidPerCall $PaidPerCall -MaxCostTier $MaxCostTier -FleetPath $FleetPath -ToolsPath $ToolsPath `
            -Dispatcher $Dispatcher -Spawner $Spawner -Gater $Gater
        if ($polishInfo.attempted) {
            $spend += [double]$polishInfo.spend
            [void]$taskCosts.Add(@{ id = 'auto-polish'; worker = ([string]$polishInfo.chose); cost = [double]$polishInfo.spend })
        }
        $gate = $polishInfo.gate
        if ($gate.verdict -eq 'reject') { $finalStatus = 'rejected' }
        elseif ($finalStatus -eq 'rejected') { $finalStatus = 'completed' }
    }
    return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status $finalStatus -Gate $gate -TaskCosts $taskCosts -PolishInfo $polishInfo)
```

(The `elseif` is defensive symmetry: auto-polish only fires on `polish`, which never sets `rejected` — but a future edit must not leave a stale status.)

**(e)** `scripts/fleet-go.ps1`: add param `[switch]$AutoPolish,` after `[string]$GateDiff,`. After the goal-validation line, add:

```powershell
if ($AutoPolish -and -not ($GateArtifact -or $GateDiff -or $env:BATON_GO_TEST_GATE)) {
    [Console]::Error.WriteLine('-AutoPolish requires a gate target (-GateArtifact or -GateDiff).')
    exit 2
}
```

Thread it: after the MaxGateSpend threading line add `if ($AutoPolish) { $go['AutoPolish'] = $true }`.

Replace the `BATON_GO_TEST_GATE` seam block with the staged-verdict version:

```powershell
if ($env:BATON_GO_TEST_GATE) {
    $cannedVerdicts = @($env:BATON_GO_TEST_GATE -split ',')
    $gateState = @{ n = 0 }
    $go['Gater'] = { param($art, $goal)
        $i = [Math]::Min($gateState.n, $cannedVerdicts.Count - 1)
        $gateState.n++
        @{ verdict = $cannedVerdicts[$i]; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() }
    }.GetNewClosure()
    if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: `ALL PASS` exit 0 — including T60c (single-value seam), T50–T52 (budget interrupts untouched), SB* (shadow accrual reads the FINAL gate — with auto-polish the pool learns the post-polish verdict, which is the honest quality signal).

- [ ] **Step 5: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/fleet-go.ps1 scripts/test-conductor-lib.ps1
git commit -m "feat(conductor): slice D — bounded one-shot auto-polish (-AutoPolish)"
```

---

### Task 10: Slices C+D docs, RC bump, full regression sweep

**Files:**
- Modify: `commands/go.md`, `docs/COMMANDS.md`, `.claude-plugin/plugin.json`

- [ ] **Step 1: Document**

In `commands/go.md` (and mirrored one-liners in `docs/COMMANDS.md`):

```markdown
- **Task-output bus:** each task's output lands in `<run>/outputs/<id>.txt`; a
  plan task with `"consumes": ["t1"]` gets those outputs appended to its prompt
  (capped, truncated with a marker). Absent bus files never fail a task.
- **Mid-DAG gate tasks:** the planner may schedule
  `{"type":"gate","consumes":[...]}` checkpoints — the gate reviews the consumed
  outputs mid-walk; `reject` fails that branch (downstream skipped, normal DAG
  failure — never a new interrupt); errors and empty context fail open to a pass.
- `-AutoPolish` — on a run-level `polish` verdict, ONE premium polish pass
  (champion selection) + ONE re-gate; the improved verdict sticks, `reject`
  after polish → `rejected`, any error leaves the original `polish` verdict.
  Requires a gate target; the pass is budget-guarded (over cap → skipped with an
  event, never an interrupt). Report gains an `## Auto-polish` section.
```

Bump `.claude-plugin/plugin.json` `"version"` to the next free RC at build time (expected `1.9.0-rc.1` — C+D are feature-tier).

- [ ] **Step 2: Full regression sweep**

Run each; every one must exit 0:

```powershell
pwsh -NoProfile -File scripts/test-gate-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-coach-lib.ps1
pwsh -NoProfile -File scripts/test-coach-footers.ps1
pwsh -NoProfile -File scripts/test-prompt-pool-lib.ps1
pwsh -NoProfile -File scripts/test-optimize-prompt-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

(If any additional suites exist matching `scripts/test-*.ps1` that dot-source conductor-lib or gate-lib, run those too.)

- [ ] **Step 3: Commit**

```bash
git add commands/go.md docs/COMMANDS.md .claude-plugin/plugin.json
git commit -m "docs(conductor): slices C+D notes + version bump; full regression green"
```

---

## Execution Handoff

Subagent-driven (superpowers:subagent-driven-development), streamlined ceremony (no per-task reviewers; one final whole-branch opus review). Branch `feature/gate-followups` off master. Ship points: after Task 5 (A+B, one RC — spec fork 2 default) and after Task 10 (C+D).

Model ladder per task (plan text contains complete code → transcription tier where possible):

| Task | Model | Why |
|---|---|---|
| 1, 2, 3 | haiku | complete code in plan, 1–2 files each |
| 4 | sonnet | four-file wiring, param threading across seams |
| 5 | haiku | docs + version bump |
| 6, 7 | haiku | complete code in plan |
| 8 | sonnet | walk-loop surgery inside Invoke-Conductor |
| 9 | sonnet | multi-function + CLI seam rework, closure-based staged gater |
| 10 | haiku | docs + regression runner |
| Final review | opus | whole-branch, most capable |

## Self-review notes (ambiguities resolved)

1. Spec said the JSON-block fix should copy "the fenced-block-first scan pattern proven in triage's `Get-TriageJsonBlock`" — the actual triage function is a plain first-`{`/last-`}` scan with no fence handling. Resolved by writing a genuinely robust scanner (fence-preferred + parse-validated bracket spans); trailing-bracket noise documented as a known limit.
2. Spec's "plan without gate tasks byte-for-byte unchanged" cannot hold for `plan.json` once the parser normalizes `type`/`consumes` (same normalization the schema already applies to `est_cost_tier`/`reversible`). Resolved: behavior (report.md, statuses, events, exit codes) is asserted unchanged; `plan.json` gains the two defaulted fields — noted in Global Constraints.
3. Spec's Slice D "budget cap covers the polish spend (guard-before-spawn)" vs d-cg-2 "no new interrupts": resolved as skip-with-event (never an interrupt), matching the spec's own error-handling line "polish error → verdict stands as polish".
4. `-MaxGateSpend` deliberately untyped (`$null` default) across all four signatures so "not set" is distinguishable from 0.
5. Explicit `-Reviewers` bypasses the Slice B spend gate (operator intent wins); documented in gate.md.
6. Slice D re-gates on the RE-RESOLVED artifact (`Resolve-GateArtifact` again) so a real `-Spawner`'s repo changes are re-reviewed; with a literal `-GateArtifact` the same text is re-gated (advisory-dispatcher reality today).
7. Shadow A/B accrual (`Complete-Run`) sees the FINAL post-polish gate — deliberate: cost_per_accept should reflect the outcome the run actually shipped with, and the polish spend is in `TaskCosts`.
