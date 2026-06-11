# Cost-Engine Slice C — Cascade in the Autonomous Loop: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backlog items opt into the draft→finish cascade (full-text or advisory mode), and the concurrent driver gains effective-rank ordering, the paid-peak gate, and surge-scaled `-MaxParallel`.

**Architecture:** One additive seam in `routing-cascade.ps1` (`-NoFinisher` → new `drafts-only` status). `fleet-backlog.ps1` gains pure helpers (`Get-BacklogCascadeMode`, `Get-AdvisoryPrompt`, `Copy-BacklogItem`, `Get-EffectiveMaxParallel`), cascade support in both drivers (in-process for serial via an injectable `-CascadeInvoker`; child-process workers for concurrent), and Slice A parity in `Invoke-BacklogConcurrent`. Spec: `docs/superpowers/specs/2026-06-11-cost-engine-slice-c-loop-cascade-design.md`.

**Tech Stack:** PowerShell 7, existing test harness style (`Assert` + `$script:fail`, temp GUID dirs, throwaway git repos, injected `-GateNow`/configs, `ROUTING_RUNS_ROOT` isolation).

**Branch:** `feat/slice-c-loop-cascade` off `master`.

**HARD RULES (project standing orders):**
- Tests must NEVER touch real `~/.baton` or `~/.claude` state. Every config/journal path is explicit-temp. The two backlog suites already isolate `ROUTING_RUNS_ROOT` — keep all new tests inside their existing `try` blocks.
- Shell command args stay under 965 bytes — `Start-Job -ArgumentList` is in-process serialization and exempt; actual CLI invocations are not.
- `Select-Capability` returns a comma-protected array: index it directly, never `@()`-wrap the call. `@()`-wrap `Get-Content` before indexing.
- Run suites with `pwsh -NoProfile -File <suite>` and check `$LASTEXITCODE`.

---

### Task 1: `-NoFinisher` + `drafts-only` status in the cascade lib

**Files:**
- Modify: `scripts/routing-cascade.ps1`
- Test: `scripts/test-routing-cascade.ps1`

The cascade gets a switch that stops after drafting+judging. Short-circuit still fires (`draft-sufficient`); otherwise the new terminal `drafts-only` returns the best *usable* draft (non-empty stdout, passing or not — same predicate as the Slice B salvage pair).

- [ ] **Step 1: Write failing tests**

Open `scripts/test-routing-cascade.ps1`. It dot-sources `routing-cascade.ps1`, defines `Check($n,$c)` incrementing `$script:fail`, and builds fixture registries + injected `-Dispatcher`/`-Grader` scriptblocks (look at the existing "short-circuit" section for the fixture pattern — temp `fleet.yaml`/`tools.yaml` under a GUID dir, a dispatcher keyed on candidate name, a grader scriptblock returning `@{passed;score;reason}` with a grader tag applied by the dispatch layer). Add a new section **before** the final exit-code block, reusing the file's existing fixture registry and dispatcher conventions:

```powershell
# ===== Slice C: -NoFinisher / drafts-only =====
Write-Host "`n[no-finisher mode]" -ForegroundColor Cyan

# Grader: judge-tagged scores so the short-circuit CAN fire when warranted.
$nfScores = @{ 'cheap-a' = 0.95; 'cheap-b' = 0.4 }
$nfGrader = {
    param($Capability, $Result)
    $name = [string]$Result.candidate
    $s = if ($nfScores.ContainsKey($name)) { $nfScores[$name] } else { 0.0 }
    @{ passed = ($s -ge 0.3); score = $s; reason = 'judge'; grader = 'llm-judge' }
}.GetNewClosure()

# n1: short-circuit still fires under -NoFinisher (judge 0.95 >= 0.9)
$r = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'p' -NoFinisher `
    -Dispatcher $okDispatcher -Grader $nfGrader `
    -ToolsPath $toolsPath -FleetPath $fleetPath -JournalPath $journalPath
Check 'n1: short-circuit wins under -NoFinisher' ($r.status -eq 'draft-sufficient' -and $r.frontier_spent -eq $false)

# n2: below threshold -> drafts-only with best usable draft, no finisher dispatched
$nfScores['cheap-a'] = 0.5
$script:dispatchedNames = @()
$r = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'p' -NoFinisher `
    -Dispatcher $recordingDispatcher -Grader $nfGrader `
    -ToolsPath $toolsPath -FleetPath $fleetPath -JournalPath $journalPath
Check 'n2: drafts-only status' ($r.status -eq 'drafts-only')
Check 'n3: winner is best usable draft' ($r.winner -eq 'cheap-a')
Check 'n4: result carries the draft output' (-not [string]::IsNullOrWhiteSpace([string]$r.result.stdout))
Check 'n5: finish_attempt null + frontier_spent false' ($null -eq $r.finish_attempt -and $r.frontier_spent -eq $false)
Check 'n6: no finisher was dispatched' (@($script:dispatchedNames | Where-Object { $_ -eq 'frontier' }).Count -eq 0)

# n7: all drafts empty -> drafts-only with null winner/result
$r = Invoke-CapabilityCascade -Capability 'code-gen' -Prompt 'p' -NoFinisher `
    -Dispatcher $emptyDispatcher -Grader $nfGrader `
    -ToolsPath $toolsPath -FleetPath $fleetPath -JournalPath $journalPath
Check 'n7: empty drafts -> drafts-only, null winner' ($r.status -eq 'drafts-only' -and $null -eq $r.winner -and $null -eq $r.result)
```

Adapt the fixture variable names (`$okDispatcher`, `$recordingDispatcher`, `$emptyDispatcher`, `$toolsPath`, `$fleetPath`, `$journalPath`, registry candidate names like `cheap-a`/`cheap-b`/`frontier`) to what the existing suite actually defines — reuse its fixtures; only build a new dispatcher if no existing one records names or returns empty stdout. The assertions themselves must not be weakened.

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-routing-cascade.ps1`
Expected: new checks FAIL (`-NoFinisher` parameter does not exist → PowerShell binding error). Existing checks still pass.

- [ ] **Step 3: Implement**

In `scripts/routing-cascade.ps1`:

1. Add to the `Invoke-CapabilityCascade` `param(...)` block, after `[switch]$NoShortCircuit`:

```powershell
        [switch]$NoFinisher,
```

2. The salvage pair (`$bestUsableName`/`$bestUsableResult`, currently computed inside the finisher stage at lines ~121-127) moves UP to just after the short-circuit return block, and the `-NoFinisher` return goes right after it:

```powershell
    # ── Salvage pair: best USABLE draft (non-empty stdout, passing or not) ──
    # Used by drafts-only (Slice C), finisher-deferred, and escalate paths; the
    # no-finisher path stays passing-only (Slice B spec step 5).
    $bestUsableName   = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { $best.attempt.candidate } else { $null }
    $bestUsableResult = if ($best -and -not [string]::IsNullOrWhiteSpace([string]$best.result.stdout)) { $best.result } else { $null }

    # ── -NoFinisher: stop after drafting+judging (Slice C advisory mode) ──
    if ($NoFinisher) {
        return [pscustomobject]@{ status='drafts-only'; capability=$Capability
                                  winner=$bestUsableName; result=$bestUsableResult
                                  draft_attempts=$draftAttempts.ToArray(); finish_attempt=$null; frontier_spent=$false }
    }
```

3. Delete the old `$bestUsableName`/`$bestUsableResult` computation from the finisher stage (keep `$bestPassedName`/`$bestPassedResult` where they are). Update the function's doc-comment status list to `draft-sufficient | drafts-only | finished | finisher-deferred | no-finisher | no-candidate | escalate-to-conductor`.

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-routing-cascade.ps1`
Expected: ALL checks pass, exit 0. Also run `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1` and `scripts/test-routing-lib.ps1` (regression, both exit 0).

- [ ] **Step 5: Commit**

```bash
git add scripts/routing-cascade.ps1 scripts/test-routing-cascade.ps1
git commit -m "feat(slice-c): -NoFinisher cascade seam -> drafts-only status with best usable draft"
```

---

### Task 2: Pure backlog helpers

**Files:**
- Modify: `scripts/fleet-backlog.ps1`
- Test: `scripts/test-fleet-backlog.ps1`

Four small pure functions. Note: backlog items arrive as **hashtables** (tests, dashboard) or **PSCustomObjects** (`run-backlog.ps1` via `ConvertFrom-Json`) — dot-access (`$Item.cascade`) works on both, but cloning does not, hence `Copy-BacklogItem`.

- [ ] **Step 1: Write failing tests**

In `scripts/test-fleet-backlog.ps1`, add after the `[effective ranks]` section (inside the runs-root-isolation `try`):

```powershell
# ===== Slice C: pure helpers =====
Write-Host "`n[cascade helpers]" -ForegroundColor Cyan
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$true; output_file='docs/x.md' }) -eq 'full')     'mode: full'
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$true })                          -eq 'advisory') 'mode: advisory'
Assert ((Get-BacklogCascadeMode -Item @{ id='x' })                                 -eq 'none')     'mode: none (no field)'
Assert ((Get-BacklogCascadeMode -Item @{ cascade=$false; output_file='y' })        -eq 'none')     'mode: none (cascade false)'
Assert ((Get-BacklogCascadeMode -Item ([pscustomobject]@{ cascade=$true; output_file='d.md' })) -eq 'full') 'mode: full (pscustomobject)'

$adv = Get-AdvisoryPrompt -Prompt 'ORIGINAL TASK' -Draft 'DRAFT BODY'
Assert ($adv -like '*ORIGINAL TASK*' -and $adv -like '*DRAFT BODY*') 'advisory prompt embeds both'
Assert ($adv.IndexOf('ORIGINAL TASK') -lt $adv.IndexOf('DRAFT BODY')) 'original precedes draft'
Assert ($adv -like '*Verify it independently*') 'advisory prompt carries the verify framing'

$cp = Copy-BacklogItem -Item @{ id='a'; prompt='p'; rank=2 }
$cp.prompt = 'changed'
Assert ($cp.id -eq 'a' -and $cp.rank -eq 2) 'hashtable copy keeps fields'
$src = [pscustomobject]@{ id='b'; prompt='orig' }
$cp2 = Copy-BacklogItem -Item $src
$cp2.prompt = 'changed'
Assert ($src.prompt -eq 'orig' -and $cp2.id -eq 'b') 'pscustomobject copy does not mutate source'

Assert ((Get-EffectiveMaxParallel -MaxParallel 0 -Capacity @{ surge=$true;  concurrency_factor=2 }) -eq 0) 'cap: 0 stays unbounded'
Assert ((Get-EffectiveMaxParallel -MaxParallel 2 -Capacity @{ surge=$false; concurrency_factor=2 }) -eq 2) 'cap: no surge -> unchanged'
Assert ((Get-EffectiveMaxParallel -MaxParallel 2 -Capacity @{ surge=$true;  concurrency_factor=2 }) -eq 4) 'cap: surge multiplies'
Assert ((Get-EffectiveMaxParallel -MaxParallel 3 -Capacity @{ surge=$true;  concurrency_factor=1.5 }) -eq 5) 'cap: ceil(3*1.5)=5'
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
Expected: FAIL — `Get-BacklogCascadeMode` not recognized.

- [ ] **Step 3: Implement**

In `scripts/fleet-backlog.ps1`, after the dot-source block at the top, add `. (Join-Path $PSScriptRoot 'routing-cascade.ps1')` (pulls `Invoke-CapabilityCascade` into scope for Task 3; co-located in both the repo and the deployed `~/.claude/scripts` layout). Then add after `Get-EffectiveRanks`:

```powershell
function Get-BacklogCascadeMode {
    <# 'full' = cascade+output_file (text deliverable, full draft->finish cascade);
       'advisory' = cascade only (draft injected into the agentic prompt); 'none'. #>
    param([Parameter(Mandatory)]$Item)
    if (-not $Item.cascade) { return 'none' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.output_file)) { return 'full' }
    return 'advisory'
}

function Get-AdvisoryPrompt {
    <# Single source of truth for the advisory draft->finisher prompt (test-asserted).
       The concurrent worker receives this with placeholder tokens (see AdvisoryJobWorker). #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Draft
    )
    return @"
$Prompt

A cheaper model produced this DRAFT. Verify it independently; keep what is
correct, fix what is not, and complete the task:

$Draft
"@
}

function Copy-BacklogItem {
    <# Shallow item copy as a hashtable: items arrive as hashtables (tests/dashboard)
       or PSCustomObjects (run-backlog via ConvertFrom-Json); advisory mode mutates
       prompt on a copy, never the caller's object. #>
    param([Parameter(Mandatory)]$Item)
    $h = @{}
    if ($Item -is [hashtable]) { foreach ($k in $Item.Keys) { $h[$k] = $Item[$k] } }
    else { foreach ($p in $Item.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Get-EffectiveMaxParallel {
    <# Surge consumption (parent spec A.2): an explicit cap is multiplied by the
       surge concurrency_factor; 0 = unbounded stays unbounded (back-compat). #>
    param(
        [Parameter(Mandatory)][int]$MaxParallel,
        [Parameter(Mandatory)]$Capacity
    )
    if ($MaxParallel -le 0) { return 0 }
    if ($Capacity.surge) { return [int][math]::Ceiling($MaxParallel * [double]$Capacity.concurrency_factor) }
    return $MaxParallel
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1` → ALL pass, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-backlog.ps1 scripts/test-fleet-backlog.ps1
git commit -m "feat(slice-c): cascade mode/advisory-prompt/item-copy/surge-cap helpers"
```

---

### Task 3: Serial driver — full cascade, advisory mode, deferral dep-block fix

**Files:**
- Modify: `scripts/fleet-backlog.ps1` (`Invoke-BacklogItem`, `Invoke-Backlog`)
- Test: `scripts/test-fleet-backlog.ps1`

- [ ] **Step 1: Write failing tests**

Add to `scripts/test-fleet-backlog.ps1` after the `[prime-hours gate]` section (inside the isolation `try`). The section builds a fresh throwaway repo using the exact fixture pattern of the `[backlog driver e2e]` section (git init -b master, `scripts/seed.ps1`, `docs/` dir added too):

```powershell
# ===== Slice C: serial driver cascade modes =====
Write-Host "`n[serial cascade]" -ForegroundColor Cyan
$croot  = Join-Path $env:TEMP ("cao-sc-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$cwt    = Join-Path $env:TEMP ("cao-scwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$cout   = Join-Path $env:TEMP ("cao-scout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $croot, $cout | Out-Null
Push-Location $croot
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts','docs' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Injected cascade invoker: scripted per item id. Contract:
#   param($Item, $EffRank, $NoFinisher, $Opts) -> cascade result object
$script:cascadeCalls = @()
$fakeCascade = {
    param($Item, $EffRank, $NoFinisher, $Opts)
    $script:cascadeCalls += @{ id = $Item.id; rank = $EffRank; nofin = [bool]$NoFinisher }
    switch ($Item.id) {
        'F-ok'   { [pscustomobject]@{ status='draft-sufficient'; winner='cheapo'; frontier_spent=$false
                                      result=[pscustomobject]@{ stdout="CASCADE BODY for $($Item.id)" } } }
        'F-def'  { [pscustomobject]@{ status='finisher-deferred'; winner='cheapo'; frontier_spent=$false
                                      result=[pscustomobject]@{ stdout='provisional' } } }
        'F-esc'  { [pscustomobject]@{ status='escalate-to-conductor'; winner=$null; frontier_spent=$true; result=$null } }
        'A-draft'{ [pscustomobject]@{ status='drafts-only'; winner='cheapo'; frontier_spent=$false
                                      result=[pscustomobject]@{ stdout='DRAFT IDEA' } } }
        'A-none' { [pscustomobject]@{ status='drafts-only'; winner=$null; frontier_spent=$false; result=$null } }
        'A-boom' { throw 'cascade exploded' }
    }
}

# Advisory implementer records the prompt it actually received.
$script:seenPrompts = @{}
$advImpl = {
    param($wtPath, $item)
    $script:seenPrompts[$item.id] = [string]$item.prompt
    Set-Content (Join-Path $wtPath "scripts/$($item.id).ps1") "x" -Encoding utf8NoBOM
}

$cTasks = @(
    @{ id='F-ok';   cascade=$true; output_file='docs/out.md'; allowed_paths=@('docs/*');  test_command='exit 0'; depends_on=@() },
    @{ id='F-def';  cascade=$true; output_file='docs/d.md';   allowed_paths=@('docs/*');  depends_on=@() },
    @{ id='F-dep';  model='adv';   prompt='dep';  allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('F-def') },
    @{ id='F-esc';  cascade=$true; output_file='docs/e.md';   allowed_paths=@('docs/*');  depends_on=@() },
    @{ id='F-bad';  cascade=$true; output_file='..\evil.md';  allowed_paths=@('*');       depends_on=@() },
    @{ id='A-draft';cascade=$true; model='adv'; prompt='ORIGINAL A-draft'; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='A-none'; cascade=$true; model='adv'; prompt='ORIGINAL A-none';  allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='A-boom'; cascade=$true; model='adv'; prompt='ORIGINAL A-boom';  allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() }
)
$cRes = Invoke-Backlog -RepoRoot $croot -Tasks $cTasks -Implementers @{ adv = $advImpl } `
    -Integration 'integration/backlog' -IntegrationBase 'master' -OutputDir $cout -WorktreeRoot $cwt `
    -CascadeInvoker $fakeCascade
$cById = @{}; foreach ($r in $cRes) { $cById[$r.id] = $r }

Assert ($cById['F-ok'].merged -eq $true) 'full: draft-sufficient merges'
Push-Location $croot
try { Assert ((git show "integration/backlog:docs/out.md" 2>$null) -match 'CASCADE BODY') 'full: output_file content on integration' }
finally { Pop-Location }
Assert ($cById['F-ok'].frontier_spent -eq $false) 'full: frontier_spent surfaced'
Assert ($cById['F-def'].deferred -eq $true -and $cById['F-def'].merged -eq $false) 'full: finisher-deferred -> deferred'
Assert ($cById['F-dep'].merged -eq $false -and (@($cById['F-dep'].reasons) -join ' ') -like '*dep-blocked*') 'deferred item dep-blocks dependents'
Assert ($cById['F-esc'].merged -eq $false -and (@($cById['F-esc'].reasons) -join ' ') -like '*escalate*') 'full: escalate -> blocked'
Assert ($cById['F-bad'].merged -eq $false -and (@($cById['F-bad'].reasons) -join ' ') -like '*output_file*') 'full: traversal guard blocks'
Assert ($cById['A-draft'].merged -eq $true) 'advisory: merged'
Assert ($script:seenPrompts['A-draft'] -like '*ORIGINAL A-draft*' -and $script:seenPrompts['A-draft'] -like '*DRAFT IDEA*') 'advisory: composed prompt has original + draft'
Assert ($script:seenPrompts['A-none'] -eq 'ORIGINAL A-none') 'advisory: no usable draft -> original prompt'
Assert ($script:seenPrompts['A-boom'] -eq 'ORIGINAL A-boom') 'advisory: cascade error -> fail-open to original prompt'
Assert (@($script:cascadeCalls | Where-Object { $_.id -eq 'A-draft' -and $_.nofin }).Count -eq 1) 'advisory: invoked with NoFinisher'
$fLive = Get-Content (Join-Path $cout 'F-def.live.json') -Raw | ConvertFrom-Json
Assert ($fLive.state -eq 'deferred') 'full: F-def.live.json state == deferred'

Push-Location $croot; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $croot, $cwt, $cout -ErrorAction SilentlyContinue
```

Also fix the EXISTING gate test's dep-block expectation: add one task + assertion to the `[prime-hours gate]` section proving a gate-deferred prereq dep-blocks its dependent:

```powershell
# (append to $gateTasks)
    @{ id='lodep'; model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('lo') }
# (append after the existing gate assertions)
Assert ($gById['lodep'].merged -eq $false -and (@($gById['lodep'].reasons) -join ' ') -like '*dep-blocked*') "gate-deferred prereq dep-blocks dependent (Slice A gap fix)"
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
Expected: FAIL — `Invoke-Backlog` has no `-CascadeInvoker`; the new gate dep-block assertion also fails (current code doesn't set `$blocked` on deferral).

- [ ] **Step 3: Implement**

In `scripts/fleet-backlog.ps1`:

1. Add the default invoker (after `Copy-BacklogItem`):

```powershell
$script:DefaultCascadeInvoker = {
    # Contract: param($Item, $EffRank, $NoFinisher, $Opts) -> Invoke-CapabilityCascade result.
    # $Opts keys (all optional): FleetPath, ToolsPath, PrimeHoursConfig, GateNow, JournalPath.
    param($Item, $EffRank, $NoFinisher, $Opts)
    $a = @{ Capability = $(if ($Item.capability) { [string]$Item.capability } else { 'code-gen' })
            Prompt     = [string]$Item.prompt }
    if ($null -ne $EffRank)        { $a.Rank = [int]$EffRank }
    if ($NoFinisher)               { $a.NoFinisher = $true }
    if ($Opts) {
        if ($Opts.FleetPath)        { $a.FleetPath        = $Opts.FleetPath }
        if ($Opts.ToolsPath)        { $a.ToolsPath        = $Opts.ToolsPath }
        if ($Opts.PrimeHoursConfig) { $a.PrimeHoursConfig = $Opts.PrimeHoursConfig }
        if ($null -ne $Opts.GateNow){ $a.GateNow          = $Opts.GateNow }
        if ($Opts.JournalPath)      { $a.JournalPath      = $Opts.JournalPath }
    }
    Invoke-CapabilityCascade @a
}
```

2. `Invoke-BacklogItem`: make `-Implementer` non-mandatory, add `-EffectiveRank`, `-CascadeInvoker`, `-CascadeOpts`:

```powershell
function Invoke-BacklogItem {
    <# One item: worktree -> implement -> gate -> merge-or-block. Emits live status.
       Slice C: cascade items run Invoke-CapabilityCascade instead of (full) or
       before (advisory) the agentic implementer. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Item,
        [scriptblock]$Implementer,
        [string]$Integration = 'integration/backlog',
        [string]$OutputDir,
        [string]$WorktreeRoot,
        [int]$EffectiveRank = 3,
        [scriptblock]$CascadeInvoker,
        [hashtable]$CascadeOpts
    )
    $id = $Item.id
    $mode = Get-BacklogCascadeMode -Item $Item
    $model = if ($mode -eq 'full' -and [string]::IsNullOrWhiteSpace([string]$Item.model)) { 'cascade' } else { [string]$Item.model }
    $allowed = if ($Item.allowed_paths) { @($Item.allowed_paths) } else { @('*') }
    $maxFiles = if ($Item.max_files) { [int]$Item.max_files } else { 20 }
    $testCmd  = $Item.test_command
    $invoker  = if ($CascadeInvoker) { $CascadeInvoker } else { $script:DefaultCascadeInvoker }

    if ($mode -eq 'full') {
        # Text-deliverable cascade: no agentic implementer; the winning text becomes
        # output_file in a fresh worktree, then the normal merge gate judges it.
        $of = [string]$Item.output_file
        if ([System.IO.Path]::IsPathRooted($of) -or $of -match '\.\.') {
            $reasons = @("cascade-error: output_file outside worktree: '$of'")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full' } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id=$id; model=$model; merged=$false; reasons=$reasons; changed=@() }
        }
        if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'running' -Extra @{ cascade = 'full' } }
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running' }
        $cres = $null; $cerr = $null
        try { $cres = & $invoker $Item $EffectiveRank $false $CascadeOpts } catch { $cerr = $_.Exception.Message }
        if ($cerr -or -not $cres) {
            $reasons = @("cascade-error: $(if ($cerr) { $cerr } else { 'no result' })")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full' } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id=$id; model=$model; merged=$false; reasons=$reasons; changed=@() }
        }
        if ($cres.status -eq 'finisher-deferred') {
            $reasons = @("deferred: cascade finisher gated until off-peak")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'deferred' -Extra @{ reasons = $reasons; cascade = 'full'; cascade_status = $cres.status } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'deferred'; Reasons = $reasons }
            return [pscustomobject]@{ id=$id; model=$model; merged=$false; deferred=$true; reasons=$reasons; changed=@() }
        }
        if ($cres.status -notin @('draft-sufficient','finished')) {
            $reasons = @("cascade: $($cres.status)")
            if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = $reasons; cascade = 'full'; cascade_status = $cres.status } }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = $reasons }
            return [pscustomobject]@{ id=$id; model=$model; merged=$false; reasons=$reasons; changed=@() }
        }
        $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
        $dest = Join-Path $wt.path $of
        $destDir = Split-Path $dest -Parent
        if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Set-Content -LiteralPath $dest -Value ([string]$cres.result.stdout) -Encoding utf8NoBOM
        $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $wt.path -Branch $wt.branch `
            -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
            -TestCommand $testCmd -WorktreeRoot $WorktreeRoot -AutoCommit
        $state = if ($res.merged) { 'done' } else { 'blocked' }
        if ($OutputDir) {
            Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State $state `
                -Extra @{ branch = $wt.branch; merged = $res.merged; reasons = @($res.gate.reasons); changed = @($res.gate.changed)
                          cascade = 'full'; cascade_status = $cres.status; winner = $cres.winner; frontier_spent = [bool]$cres.frontier_spent }
        }
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = $state; Branch = $wt.branch }
        return [pscustomobject]@{
            id=$id; model=$model; branch=$wt.branch; path=$wt.path
            merged=$res.merged; reasons=@($res.gate.reasons); changed=@($res.gate.changed)
            cascade_status=$cres.status; winner=$cres.winner; frontier_spent=[bool]$cres.frontier_spent
        }
    }

    if ($mode -eq 'advisory') {
        # Draft pre-step (fail-open): a usable draft rides into the agentic prompt.
        try {
            $d = & $invoker $Item $EffectiveRank $true $CascadeOpts
            if ($d -and $d.winner -and $d.result -and -not [string]::IsNullOrWhiteSpace([string]$d.result.stdout)) {
                $Item = Copy-BacklogItem -Item $Item
                $Item.prompt = Get-AdvisoryPrompt -Prompt ([string]$Item.prompt) -Draft ([string]$d.result.stdout)
                $Item.advisory_draft_winner = $d.winner
            }
        } catch { Write-Verbose "advisory draft failed (fail-open): $_" }
    }

    # ── existing agentic flow (unchanged below this line, but uses $model) ──
    $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'running' -Extra @{ branch = $wt.branch } }
    Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }

    $implErr = $null
    try { & $Implementer $wt.path $Item } catch { $implErr = $_.Exception.Message }

    $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $wt.path -Branch $wt.branch `
        -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
        -TestCommand $testCmd -WorktreeRoot $WorktreeRoot -AutoCommit

    $reasons = @($res.gate.reasons)
    if ($implErr) { $reasons = @("implementer-error: $implErr") + $reasons }
    $state = if ($res.merged) { 'done' } else { 'blocked' }
    if ($OutputDir) {
        Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State $state `
            -Extra @{ branch = $wt.branch; merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed) }
    }
    if ($res.merged) {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'done'; Branch = $wt.branch }
    } else {
        Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Branch = $wt.branch; Reasons = $reasons }
    }
    return [pscustomobject]@{
        id = $id; model = $model; branch = $wt.branch; path = $wt.path
        merged = $res.merged; reasons = $reasons; changed = @($res.gate.changed)
    }
}
```

3. `Invoke-Backlog`: add params `[scriptblock]$CascadeInvoker`, `[string]$ToolsPath`, `[string]$JournalPath`. Build opts once before the loop:

```powershell
    $cascadeOpts = @{}
    if ($FleetPath)                                  { $cascadeOpts.FleetPath        = $FleetPath }
    if ($ToolsPath)                                  { $cascadeOpts.ToolsPath        = $ToolsPath }
    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $cascadeOpts.PrimeHoursConfig = $PrimeHoursConfig }
    if ($PSBoundParameters.ContainsKey('GateNow'))   { $cascadeOpts.GateNow          = $GateNow }
    if ($JournalPath)                                { $cascadeOpts.JournalPath      = $JournalPath }
```

Inside the dispatch loop:
- Replace the dead `$cap = Get-CapacityProfile @capArgs` block (and `$capArgs` construction) with nothing — **delete it** (serial dispatch has nothing to scale; the concurrent driver consumes capacity in Task 4).
- Compute `$mode = Get-BacklogCascadeMode -Item $item` right after `$item = $byId[$id]`.
- No-implementer check becomes: `$impl = if ($mode -ne 'full') { $Implementers[[string]$item.model] } else { $null }` and the block condition `if ($mode -ne 'full' -and -not $impl)`.
- Prime-hours gate block gains the condition `if ($mode -ne 'full' -and $prov -and $prov.cost_tier -eq 'paid')` (full-cascade items gate INSIDE the cascade) — and in its `defer` branch add the gap fix line `$blocked[$id] = $true` before `continue`.
- The `Invoke-BacklogItem` call becomes:

```powershell
        $r = Invoke-BacklogItem -RepoRoot $RepoRoot -Item $item -Implementer $impl `
            -Integration $Integration -OutputDir $OutputDir -WorktreeRoot $WorktreeRoot `
            -EffectiveRank ([int]$eff[$id]) -CascadeInvoker $CascadeInvoker -CascadeOpts $cascadeOpts
```

(`-Implementer $null` binds fine now that the param is non-mandatory; full-mode never touches it.) The existing `if (-not $r.merged) { $blocked[$id] = $true }` already dep-blocks cascade-deferred items.

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1` → ALL pass, exit 0. Run `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1` (regression) → exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-backlog.ps1 scripts/test-fleet-backlog.ps1
git commit -m "feat(slice-c): serial driver cascade modes + deferral dep-block fix; drop dead capacity read"
```

---

### Task 4: Concurrent driver — rank ordering, paid-peak gate, surge-scaled MaxParallel

**Files:**
- Modify: `scripts/fleet-backlog.ps1` (`Invoke-BacklogConcurrent`)
- Test: `scripts/test-fleet-backlog-concurrent.ps1`

- [ ] **Step 1: Write failing tests**

Add to `scripts/test-fleet-backlog-concurrent.ps1` after the existing e2e section (inside the isolation `try`):

```powershell
# ===== Slice C: rank order + paid-peak gate + MaxParallel =====
Write-Host "`n[rank + gate + cap]" -ForegroundColor Cyan
$groot  = Join-Path $env:TEMP ("cao-ccg-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$gwt    = Join-Path $env:TEMP ("cao-ccgwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$gout   = Join-Path $env:TEMP ("cao-ccgout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $groot, $gout | Out-Null
Push-Location $groot
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

# Ledger records DISPATCH ORDER: each child appends its worktree leaf ("<id>-<model>").
$ledger = Join-Path $gout 'ledger.txt'
$env:CC_LEDGER = $ledger
$ledgerScript = '$leaf = Split-Path (Get-Location) -Leaf; Add-Content -Path $env:CC_LEDGER -Value $leaf; Set-Content (Join-Path "scripts" "$leaf.ps1") "x" -Encoding utf8NoBOM'
$gspecs = @{ paidmodel = @{ exe = 'pwsh'; args = @('-NoProfile','-Command', $ledgerScript) } }

$gfleet = Join-Path $gout 'fleet.yaml'
Set-Content -LiteralPath $gfleet -Encoding utf8NoBOM -Value @"
providers:
  - name: paidmodel
    kind: cli
    cost_tier: paid
"@
$gph = Join-Path $gout 'prime-hours.yaml'
Set-Content -LiteralPath $gph -Encoding utf8NoBOM -Value @"
timezone: local
default_rank: 3
windows:
  - name: all-day-peak
    days: [mon, tue, wed, thu, fri]
    kind: peak
"@
$gnow = [datetime]'2026-06-10T12:00:00'   # Wednesday inside the all-day weekday peak

# r3 deferred (paid+peak+rank3); prereq3 is rank-3 BUT inherits rank 1 from dep1 -> runs;
# rank ordering observable with MaxParallel 1: prereq3 (eff 1) then dep1 then r2.
$gtasks = @(
    @{ id='r2';      model='paidmodel'; rank=2; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='r3';      model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='r3dep';   model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('r3') },
    @{ id='prereq3'; model='paidmodel'; rank=3; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() },
    @{ id='dep1';    model='paidmodel'; rank=1; allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@('prereq3') }
)
# NOTE: rank 2 unattended default = defer (parent spec rank table) -> r2 also defers.
$gres = Invoke-BacklogConcurrent -RepoRoot $groot -Tasks $gtasks -ModelSpecs $gspecs `
    -Integration 'master' -IntegrationBase 'master' -OutputDir $gout -WorktreeRoot $gwt -TimeoutS 120 `
    -MaxParallel 1 -FleetPath $gfleet -PrimeHoursConfig $gph -GateNow $gnow
$gById = @{}; foreach ($r in $gres) { if ($r) { $gById[$r.id] = $r } }

Assert ($gById['r3'].deferred -eq $true -and $gById['r3'].merged -eq $false) 'paid rank-3 deferred at peak'
Assert ($gById['r2'].deferred -eq $true) 'paid rank-2 deferred (unattended ask->defer)'
Assert ($gById['r3dep'].merged -eq $false -and (@($gById['r3dep'].reasons) -join ' ') -like '*dep-blocked*') 'deferred prereq dep-blocks dependent'
Assert ($gById['prereq3'].merged -eq $true) 'rank-3 prereq inherits rank 1 -> runs at peak'
Assert ($gById['dep1'].merged -eq $true) 'rank-1 dependent runs'
$gOrder = @(Get-Content -LiteralPath $ledger | ForEach-Object { ($_ -split '-paidmodel')[0] })
Assert ($gOrder.Count -eq 2 -and $gOrder[0] -eq 'prereq3' -and $gOrder[1] -eq 'dep1') "dispatch order ascending effective rank ($($gOrder -join ','))"
$r3Live = Get-Content (Join-Path $gout 'r3.live.json') -Raw | ConvertFrom-Json
Assert ($r3Live.state -eq 'deferred') 'r3.live.json state == deferred'

Remove-Item Env:CC_LEDGER -ErrorAction SilentlyContinue
Push-Location $groot; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $groot, $gwt, $gout -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1`
Expected: FAIL — `-MaxParallel` parameter does not exist.

- [ ] **Step 3: Implement**

In `Invoke-BacklogConcurrent`:

1. Add params (after `[int]$TimeoutS = 900`):

```powershell
        [int]$MaxParallel = 0,
        [string]$FleetPath,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow
```

2. After the `$orderIndex` construction, add rank + capacity setup:

```powershell
    $eff = Get-EffectiveRanks -Tasks $Tasks
    $capArgs = @{}
    if ($PSBoundParameters.ContainsKey('GateNow'))          { $capArgs.Now        = $GateNow }
    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $capArgs.ConfigPath = $PrimeHoursConfig }
    $capN = Get-EffectiveMaxParallel -MaxParallel $MaxParallel -Capacity (Get-CapacityProfile @capArgs)
```

3. In the wave loop, replace the `# 2. ready = ...` block so ready items are **rank-sorted, gated, then capped** before launch:

```powershell
        # 2. ready = unprocessed, every dependency processed AND merged — sorted by
        #    ascending effective rank (topo index tiebreak), then paid-peak gated,
        #    then capped to the surge-scaled MaxParallel.
        $ready = @($byId.Keys | Where-Object {
            -not $proc.ContainsKey($_) -and
            (@(@($byId[$_].depends_on) | Where-Object { $_ -and -not ($proc.ContainsKey($_) -and $proc[$_].merged) }).Count -eq 0)
        } | Sort-Object @{ e = { $eff[$_] } }, @{ e = { $orderIndex[$_] } })
        if ($ready.Count -eq 0) { break }

        # Paid-peak gate (unattended; full-cascade items gate INSIDE the cascade).
        $gated = [System.Collections.ArrayList]@()
        foreach ($id in $ready) {
            $item = $byId[$id]
            if ((Get-BacklogCascadeMode -Item $item) -ne 'full') {
                $provArgs = @{ Name = [string]$item.model }
                if ($FleetPath) { $provArgs.Path = $FleetPath }
                $prov = try { Get-FleetProvider @provArgs } catch { $null }
                if ($prov -and $prov.cost_tier -eq 'paid') {
                    $gateArgs = @{ Rank = [int]$eff[$id]; CostTier = 'paid' }
                    if ($PSBoundParameters.ContainsKey('GateNow'))          { $gateArgs.Now        = $GateNow }
                    if ($PSBoundParameters.ContainsKey('PrimeHoursConfig')) { $gateArgs.ConfigPath = $PrimeHoursConfig }
                    $gate = Test-PrimeHoursGate @gateArgs
                    $eff2 = if ($gate.decision -eq 'ask') { $gate.default } else { $gate.decision }
                    if ($eff2 -eq 'defer') {
                        $reasons = @("deferred until off-peak: $($gate.reason)")
                        if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $item.model -State 'deferred' -Extra @{ reasons = $reasons } }
                        Publish-ItemRunSafe @{ Id = $id; Model = $item.model; State = 'deferred'; Reasons = $reasons }
                        $proc[$id] = [pscustomobject]@{ id = $id; model = $item.model; merged = $false; deferred = $true; reasons = $reasons; changed = @() }
                        continue
                    }
                }
            }
            [void]$gated.Add($id)
        }
        $ready = @($gated)
        if ($capN -gt 0 -and $ready.Count -gt $capN) { $ready = @($ready | Select-Object -First $capN) }
        if ($ready.Count -eq 0) { continue }
```

(The old `if ($ready.Count -eq 0) { break }` must stay BEFORE gating — gating writes `$proc` entries, so the post-gate empty case is `continue`, not `break`: newly-deferred items unblock nothing, but dep-blocking in step 1 of the next iteration must still run; the loop terminates because `$proc.Count` grew.)

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1` → ALL pass, exit 0. Run `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1` (regression) → exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-backlog.ps1 scripts/test-fleet-backlog-concurrent.ps1
git commit -m "feat(slice-c): concurrent driver gains effective-rank order, paid-peak gate, surge-scaled MaxParallel"
```

---

### Task 5: Concurrent cascade workers

**Files:**
- Modify: `scripts/fleet-backlog.ps1` (`$script:CascadeJobWorker`, `$script:AdvisoryJobWorker`, launch + merge wiring in `Invoke-BacklogConcurrent`)
- Test: `scripts/test-fleet-backlog-concurrent.ps1`

Full-cascade and advisory items run in child processes. The child receives every path explicitly (cascade lib, fleet/tools/journal/prime-hours, result JSON) — no real-state defaults. The advisory template reaches the child as a parent-rendered placeholder string (`__BATON_PROMPT__`/`__BATON_DRAFT__`), keeping `Get-AdvisoryPrompt` the single source of truth.

- [ ] **Step 1: Write failing tests**

Add to `scripts/test-fleet-backlog-concurrent.ps1` after the Task 4 section (inside the isolation `try`). Echo-template providers make the REAL cascade run hermetically: the judge auto-discovery finds only echo models, so judge output is unparseable → heuristic fallback (binary, never short-circuits) → the explicit `role: finisher` free entry finishes. Deterministic, zero LLM calls.

```powershell
# ===== Slice C: cascade items through child workers =====
Write-Host "`n[concurrent cascade]" -ForegroundColor Cyan
$kroot  = Join-Path $env:TEMP ("cao-cck-"   + [guid]::NewGuid().ToString('N').Substring(0,8))
$kwt    = Join-Path $env:TEMP ("cao-cckwt-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$kout   = Join-Path $env:TEMP ("cao-cckout-"+ [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $kroot, $kout | Out-Null
Push-Location $kroot
try {
    git init -q -b master 2>&1 | Out-Null
    git config user.email t@e.com; git config user.name t; git config commit.gpgsign false
    New-Item -ItemType Directory -Force -Path 'scripts','docs' | Out-Null
    Set-Content scripts/seed.ps1 "seed" -Encoding utf8NoBOM
    git add -A 2>&1 | Out-Null; git commit -q -m init 2>&1 | Out-Null
} finally { Pop-Location }

$kfleet = Join-Path $kout 'fleet.yaml'
Set-Content -LiteralPath $kfleet -Encoding utf8NoBOM -Value @"
general_capabilities: [code-gen]
providers:
  - name: drafty
    kind: cli
    enabled: true
    cost_tier: local
    role: draft
    command_template: 'pwsh -NoProfile -Command "Write-Output DRAFTTEXT"'
  - name: finny
    kind: cli
    enabled: true
    cost_tier: free
    role: finisher
    command_template: 'pwsh -NoProfile -Command "Write-Output FINISHEDTEXT"'
"@
$ktools = Join-Path $kout 'tools.yaml'
Set-Content -LiteralPath $ktools -Encoding utf8NoBOM -Value "tools: []"
$kjournal = Join-Path $kout 'journal.jsonl'

# Advisory agentic fake: writes the piped-in (composed) prompt into a scoped file.
$advScript = '$p = @($input) -join "`n"; $leaf = Split-Path (Get-Location) -Leaf; Set-Content (Join-Path "scripts" "$leaf.ps1") $p -Encoding utf8NoBOM'
$kspecs = @{ agentic = @{ exe = 'pwsh'; args = @('-NoProfile','-Command', $advScript) } }

$ktasks = @(
    @{ id='K-full'; cascade=$true; output_file='docs/k.md'; capability='code-gen'
       allowed_paths=@('docs/*'); test_command='exit 0'; depends_on=@() },
    @{ id='K-adv';  cascade=$true; model='agentic'; prompt='ADVISORY ORIGINAL'; capability='code-gen'
       allowed_paths=@('scripts/*'); test_command='exit 0'; depends_on=@() }
)
$kres = Invoke-BacklogConcurrent -RepoRoot $kroot -Tasks $ktasks -ModelSpecs $kspecs `
    -Integration 'master' -IntegrationBase 'master' -OutputDir $kout -WorktreeRoot $kwt -TimeoutS 300 `
    -FleetPath $kfleet -ToolsPath $ktools -JournalPath $kjournal
$kById = @{}; foreach ($r in $kres) { if ($r) { $kById[$r.id] = $r } }

Assert ($kById['K-full'].merged -eq $true) 'full cascade item merged'
Assert ($kById['K-full'].cascade_status -in @('finished','draft-sufficient')) "cascade_status terminal ($($kById['K-full'].cascade_status))"
Push-Location $kroot
try {
    $kbody = git show "master:docs/k.md" 2>$null
    Assert ($kbody -match 'FINISHEDTEXT|DRAFTTEXT') 'output_file content from cascade on master'
    $advBody = git show "master:scripts/K-adv-agentic.ps1" 2>$null
    Assert ($advBody -match 'ADVISORY ORIGINAL') 'advisory: original prompt reached the agentic model'
    Assert ($advBody -match 'DRAFTTEXT') 'advisory: draft text was injected into the prompt'
    Assert ($advBody -match 'Verify it independently') 'advisory: Get-AdvisoryPrompt template used'
} finally { Pop-Location }
Assert ($kById['K-adv'].merged -eq $true) 'advisory item merged'
$kLive = Get-Content (Join-Path $kout 'K-full.live.json') -Raw | ConvertFrom-Json
Assert ($kLive.state -eq 'done') 'K-full live state done'

Push-Location $kroot; try { git worktree prune 2>&1 | Out-Null } finally { Pop-Location }
Remove-Item -Recurse -Force $kroot, $kwt, $kout -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1`
Expected: FAIL — `-ToolsPath`/`-JournalPath` unknown params; cascade items would block as `no-implementer`.

- [ ] **Step 3: Implement**

In `scripts/fleet-backlog.ps1`:

1. Add the two workers after `$script:BacklogJobWorker`:

```powershell
# Full-cascade child: dot-source the cascade lib, run, write output_file on success,
# always write a result JSON the parent maps. All paths are explicit args (no real-
# state defaults; tests pass temp fixtures).
$script:CascadeJobWorker = {
    param($libPath, $capability, $prompt, $rank, $outputFile, $wtPath, $fleetPath, $toolsPath,
          $primeCfg, $gateNowTicks, $journalPath, $resultPath, $outDir, $id)
    $live = Join-Path $outDir "$id.live.json"
    $writeLive = { param($obj) $j = $obj | ConvertTo-Json -Compress; Set-Content -LiteralPath "$live.tmp" -Value $j -Encoding utf8NoBOM; Move-Item -LiteralPath "$live.tmp" -Destination $live -Force }
    & $writeLive @{ label = $id; provider = 'cascade'; state = 'running'; started = (Get-Date).ToString('o') }
    $res = $null; $err = $null
    try {
        . $libPath
        $a = @{ Capability = $capability; Prompt = $prompt }
        if ($null -ne $rank -and $rank -ne [int]::MinValue) { $a.Rank = [int]$rank }
        if ($fleetPath)   { $a.FleetPath = $fleetPath }
        if ($toolsPath)   { $a.ToolsPath = $toolsPath }
        if ($primeCfg)    { $a.PrimeHoursConfig = $primeCfg }
        if ($gateNowTicks){ $a.GateNow = [datetime][long]$gateNowTicks }
        if ($journalPath) { $a.JournalPath = $journalPath }
        $res = Invoke-CapabilityCascade @a
        if ($res.status -in @('draft-sufficient','finished') -and $res.result -and
            -not [string]::IsNullOrWhiteSpace([string]$res.result.stdout)) {
            $dest = Join-Path $wtPath $outputFile
            $destDir = Split-Path $dest -Parent
            if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Set-Content -LiteralPath $dest -Value ([string]$res.result.stdout) -Encoding utf8NoBOM
        }
    } catch { $err = $_.Exception.Message }
    $payload = @{ status = $(if ($res) { $res.status } else { 'cascade-error' })
                  winner = $(if ($res) { $res.winner } else { $null })
                  frontier_spent = $(if ($res) { [bool]$res.frontier_spent } else { $false })
                  error = $err }
    Set-Content -LiteralPath "$resultPath.tmp" -Value ($payload | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    Move-Item -LiteralPath "$resultPath.tmp" -Destination $resultPath -Force
}

# Advisory child: -NoFinisher draft pre-step (fail-open) composes the prompt via the
# parent-rendered template (placeholders keep Get-AdvisoryPrompt the single source of
# truth), then runs the agentic exe exactly like BacklogJobWorker.
$script:AdvisoryJobWorker = {
    param($libPath, $capability, $rank, $fleetPath, $toolsPath, $primeCfg, $gateNowTicks, $journalPath,
          $template, $wtPath, $promptFile, $id, $outDir, $model, $exe, $argsJson, $resultPath)
    $live = Join-Path $outDir "$id.live.json"
    $writeLive = { param($obj) $j = $obj | ConvertTo-Json -Compress; Set-Content -LiteralPath "$live.tmp" -Value $j -Encoding utf8NoBOM; Move-Item -LiteralPath "$live.tmp" -Destination $live -Force }
    $started = (Get-Date).ToString('o')
    & $writeLive @{ label = $id; provider = $model; state = 'running'; started = $started }
    $draftWinner = $null
    try {
        . $libPath
        $orig = Get-Content -LiteralPath $promptFile -Raw
        $a = @{ Capability = $capability; Prompt = $orig; NoFinisher = $true }
        if ($null -ne $rank -and $rank -ne [int]::MinValue) { $a.Rank = [int]$rank }
        if ($fleetPath)   { $a.FleetPath = $fleetPath }
        if ($toolsPath)   { $a.ToolsPath = $toolsPath }
        if ($primeCfg)    { $a.PrimeHoursConfig = $primeCfg }
        if ($gateNowTicks){ $a.GateNow = [datetime][long]$gateNowTicks }
        if ($journalPath) { $a.JournalPath = $journalPath }
        $d = Invoke-CapabilityCascade @a
        if ($d -and $d.winner -and $d.result -and -not [string]::IsNullOrWhiteSpace([string]$d.result.stdout)) {
            $draftWinner = $d.winner
            $composed = $template.Replace('__BATON_PROMPT__', $orig).Replace('__BATON_DRAFT__', [string]$d.result.stdout)
            Set-Content -LiteralPath $promptFile -Value $composed -Encoding utf8NoBOM
        }
    } catch { }   # fail-open: plain prompt
    Set-Location $wtPath
    $exit = 0
    try {
        $argList = @($argsJson | ConvertFrom-Json)
        Get-Content -LiteralPath $promptFile -Raw | & $exe @argList 2>&1 | Out-Null
        $exit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    } catch { $exit = -1 }
    & $writeLive @{ label = $id; provider = $model; state = 'implemented'; started = $started
                    ended = (Get-Date).ToString('o'); exit = $exit; draft_winner = $draftWinner }
    Set-Content -LiteralPath "$resultPath.tmp" -Value (@{ draft_winner = $draftWinner } | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    Move-Item -LiteralPath "$resultPath.tmp" -Destination $resultPath -Force
}
```

2. `Invoke-BacklogConcurrent` gains params `[string]$ToolsPath`, `[string]$JournalPath`, `[string]$CascadeLibPath = (Join-Path $PSScriptRoot 'routing-cascade.ps1')` (co-located in repo AND deployed layouts). Compute once before the loop: `$gateNowTicks = if ($PSBoundParameters.ContainsKey('GateNow')) { $GateNow.Ticks } else { $null }`.

3. In the launch step (step 3 of the wave loop), branch on mode. Replace the body of the `foreach ($id in $ready)` launch loop:

```powershell
            $item = $byId[$id]; $model = [string]$item.model
            $mode = Get-BacklogCascadeMode -Item $item
            $cap2 = $(if ($item.capability) { [string]$item.capability } else { 'code-gen' })
            if ($mode -eq 'full') {
                $of = [string]$item.output_file
                if ([System.IO.Path]::IsPathRooted($of) -or $of -match '\.\.') {
                    $reasons = @("cascade-error: output_file outside worktree: '$of'")
                    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model 'cascade' -State 'blocked' -Extra @{ reasons = $reasons } }
                    Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = 'blocked'; Reasons = $reasons }
                    $proc[$id] = [pscustomobject]@{ id = $id; model = 'cascade'; merged = $false; reasons = $reasons; changed = @() }
                    continue
                }
                $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model 'cascade' -Base $Integration -WorktreeRoot $WorktreeRoot
                $resultPath = Join-Path $OutputDir "$id.cascade.json"
                $job = Start-Job -ScriptBlock $script:CascadeJobWorker -ArgumentList `
                    $CascadeLibPath, $cap2, ([string]$item.prompt), ([int]$eff[$id]), $of, $wt.path, `
                    $FleetPath, $ToolsPath, $PrimeHoursConfig, $gateNowTicks, $JournalPath, $resultPath, $OutputDir, $id
                $jobs[$id] = @{ job = $job; wt = $wt; pf = $null; item = $item; mode = 'full'; resultPath = $resultPath }
                Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = 'running'; Branch = $wt.branch }
                continue
            }
            if (-not $ModelSpecs[$model]) {
                if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model $model -State 'blocked' -Extra @{ reasons = @("no-implementer: '$model'") } }
                Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'blocked'; Reasons = @("no-implementer: '$model'") }
                $proc[$id] = [pscustomobject]@{ id = $id; model = $model; merged = $false; reasons = @("no-implementer: '$model'"); changed = @() }
                continue
            }
            $wt = New-ItemWorktree -RepoRoot $RepoRoot -ItemId $id -Model $model -Base $Integration -WorktreeRoot $WorktreeRoot
            $pf = Join-Path ([System.IO.Path]::GetTempPath()) "cao-prompt-$id-$($model -replace '[^\w]','_').txt"
            Set-Content -LiteralPath $pf -Value $item.prompt -Encoding utf8NoBOM
            $spec = $ModelSpecs[$model]
            $argsJson = (@($spec.args) | ConvertTo-Json -Compress)
            if (-not $argsJson) { $argsJson = '[]' }
            if ($mode -eq 'advisory') {
                $template = Get-AdvisoryPrompt -Prompt '__BATON_PROMPT__' -Draft '__BATON_DRAFT__'
                $resultPath = Join-Path $OutputDir "$id.cascade.json"
                $job = Start-Job -ScriptBlock $script:AdvisoryJobWorker -ArgumentList `
                    $CascadeLibPath, $cap2, ([int]$eff[$id]), $FleetPath, $ToolsPath, $PrimeHoursConfig, $gateNowTicks, $JournalPath, `
                    $template, $wt.path, $pf, $id, $OutputDir, $model, $spec.exe, $argsJson, $resultPath
                $jobs[$id] = @{ job = $job; wt = $wt; pf = $pf; item = $item; mode = 'advisory'; resultPath = $resultPath }
            } else {
                $job = Start-Job -ScriptBlock $script:BacklogJobWorker -ArgumentList $wt.path, $pf, $id, $OutputDir, $model, $spec.exe, $argsJson
                $jobs[$id] = @{ job = $job; wt = $wt; pf = $pf; item = $item }
            }
            Publish-ItemRunSafe @{ Id = $id; Model = $model; State = 'running'; Branch = $wt.branch }
```

(`$OutputDir` may be empty in theory; cascade/advisory items REQUIRE it for the result JSON — if `$OutputDir` is empty, fall back to `[System.IO.Path]::GetTempPath()` for `$resultPath`: `$resultBase = if ($OutputDir) { $OutputDir } else { [System.IO.Path]::GetTempPath() }` — use `$resultBase` in both `$resultPath` assignments, and pass `$resultBase` as the worker's `$outDir` live-JSON base too.)

4. In the merge step (step 4), inside the `foreach ($id in ($jobs.Keys | Sort-Object ...))` loop, after `Remove-Item -LiteralPath $info.pf` (guard it: `if ($info.pf) { Remove-Item ... }`), add full-mode mapping BEFORE the unconditional `Merge-ItemToIntegration`:

```powershell
            if ($info.mode -eq 'full') {
                $cj = $null
                if (Test-Path $info.resultPath) { $cj = Get-Content -LiteralPath $info.resultPath -Raw | ConvertFrom-Json }
                if (-not $cj) {
                    $reasons = @('cascade-error: worker produced no result')
                    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model 'cascade' -State 'blocked' -Extra @{ reasons = $reasons } }
                    Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = 'blocked'; Reasons = $reasons }
                    $proc[$id] = [pscustomobject]@{ id = $id; model = 'cascade'; merged = $false; reasons = $reasons; changed = @() }
                    continue
                }
                if ($cj.status -eq 'finisher-deferred') {
                    $reasons = @('deferred: cascade finisher gated until off-peak')
                    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model 'cascade' -State 'deferred' -Extra @{ reasons = $reasons; cascade_status = $cj.status } }
                    Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = 'deferred'; Reasons = $reasons }
                    $proc[$id] = [pscustomobject]@{ id = $id; model = 'cascade'; merged = $false; deferred = $true; reasons = $reasons; changed = @() }
                    continue
                }
                if ($cj.status -notin @('draft-sufficient','finished')) {
                    $reasons = @("cascade: $($cj.status)$(if ($cj.error) { " ($($cj.error))" })")
                    if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model 'cascade' -State 'blocked' -Extra @{ reasons = $reasons; cascade_status = $cj.status } }
                    Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = 'blocked'; Reasons = $reasons }
                    $proc[$id] = [pscustomobject]@{ id = $id; model = 'cascade'; merged = $false; reasons = $reasons; changed = @() }
                    continue
                }
                $res = Merge-ItemToIntegration -RepoRoot $RepoRoot -WorktreePath $info.wt.path -Branch $info.wt.branch `
                    -Integration $Integration -AllowedPathPatterns $allowed -MaxChangedFiles $maxFiles `
                    -TestCommand $item.test_command -WorktreeRoot $WorktreeRoot -AutoCommit
                $state = if ($res.merged) { 'done' } else { 'blocked' }
                if ($OutputDir) { Write-ItemLive -OutputDir $OutputDir -Id $id -Model 'cascade' -State $state -Extra @{ merged = $res.merged; reasons = @($res.gate.reasons); changed = @($res.gate.changed); branch = $info.wt.branch; cascade_status = $cj.status; winner = $cj.winner; frontier_spent = [bool]$cj.frontier_spent } }
                Publish-ItemRunSafe @{ Id = $id; Model = 'cascade'; State = $state; Branch = $info.wt.branch }
                $proc[$id] = [pscustomobject]@{ id = $id; model = 'cascade'; merged = $res.merged; reasons = @($res.gate.reasons); changed = @($res.gate.changed); branch = $info.wt.branch
                                                cascade_status = $cj.status; winner = $cj.winner; frontier_spent = [bool]$cj.frontier_spent }
                continue
            }
```

(Note `$allowed`/`$maxFiles` are computed a few lines below in the existing code — move those two assignments UP so the full-mode branch can use them.) For advisory items the existing merge path runs unchanged; afterwards enrich the result: `if ($info.mode -eq 'advisory' -and (Test-Path $info.resultPath)) { $aj = Get-Content -LiteralPath $info.resultPath -Raw | ConvertFrom-Json; $proc[$id] | Add-Member -NotePropertyName draft_winner -NotePropertyValue $aj.draft_winner -Force }`.

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog-concurrent.ps1` → ALL pass, exit 0 (child jobs make this suite slower — allow a few minutes). Regression: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1` → exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-backlog.ps1 scripts/test-fleet-backlog-concurrent.ps1
git commit -m "feat(slice-c): cascade child workers in the concurrent driver (full + advisory modes)"
```

---

### Task 6: `run-backlog.ps1` passthrough + summary

**Files:**
- Modify: `scripts/run-backlog.ps1`

No new test suite (thin wrapper; drivers are covered). Three edits:

- [ ] **Step 1: Implement**

1. Header doc: extend the `.PARAMETER TasksPath` description to:

```
  JSON file: array of { id, model, prompt, allowed_paths[], max_files, test_command, depends_on[],
  rank, cascade, output_file, capability }. Slice C: cascade:true + output_file -> full
  draft->finish cascade writes the file (zero-frontier short-circuit possible); cascade:true
  without output_file -> advisory (local draft injected into the agentic prompt).
```

2. Params: add `[int]$MaxParallel = 0` after `[int]$TimeoutS = 900`, and pass `-MaxParallel $MaxParallel` to the `Invoke-BacklogConcurrent` call.

3. Summary loop becomes:

```powershell
foreach ($r in $results) {
    $tag = if ($r.merged) { 'MERGED ' } elseif ($r.deferred) { 'DEFERRED' } else { 'blocked' }
    Write-Host ("  [{0}] {1} {2}" -f $tag, $r.id, $r.model)
    if (-not $r.merged) { Write-Host ("      reasons: {0}" -f (($r.reasons) -join '; ')) }
    if ($r.changed)     { Write-Host ("      changed: {0}" -f (($r.changed) -join ', ')) }
    if ($r.PSObject.Properties['cascade_status']) {
        $fs = if ($r.frontier_spent) { 'frontier spend: yes' } else { 'frontier spend: none' }
        Write-Host ("      cascade: {0} | winner: {1} | {2}" -f $r.cascade_status, $r.winner, $fs)
    }
    if ($r.PSObject.Properties['draft_winner'] -and $r.draft_winner) {
        Write-Host ("      advisory draft: {0}" -f $r.draft_winner)
    }
}
```

- [ ] **Step 2: Syntax check + commit**

Run: `pwsh -NoProfile -Command ". scripts/run-backlog.ps1 -TasksPath nonexistent.json" ` — expect a clean file-not-found error from `Get-Content` (proves the script parses). Then:

```bash
git add scripts/run-backlog.ps1
git commit -m "feat(slice-c): run-backlog passthrough (-MaxParallel) + cascade-aware summary"
```

---

### Task 7: Version bump

**Files:**
- Modify: `.claude-plugin/plugin.json` (version `1.2.0-rc.5` → `1.2.0-rc.6`), `README.md` status banner (rc.5 → rc.6)

- [ ] **Step 1: Edit both files, then commit**

```bash
git add .claude-plugin/plugin.json README.md
git commit -m "chore: bump to v1.2.0-rc.6 (Engine Slice C)"
```

---

### Task 8: Final gate, adversarial review, merge, deploy, closeout

(Executed by the conductor, not a fresh subagent.)

- [ ] Run the full battery at branch tip; ALL must exit 0:
  `test-routing-lib.ps1`, `test-routing-dispatch.ps1`, `test-routing-learn.ps1`, `test-routing-calibrate.ps1`, `test-routing-cascade.ps1`, `test-prime-hours.ps1`, `test-fleet-backlog.ps1`, `test-fleet-backlog-concurrent.ps1`, `test-bootstrap.ps1`, `test-baton-home.ps1`, `test-mcp-bridge.ps1`
- [ ] One comprehensive adversarial review (opus, octo-code-reviewer) of the full branch diff against the spec; fix BLOCKs, judge NITs
- [ ] PR → master (gated merge, `Closes` not applicable — no issue), deploy live via `pwsh scripts/bootstrap.ps1 -Force`, zero-cost live smoke (`Invoke-Backlog` with a trivial full-cascade item against the real local fleet, temp repo)
- [ ] Closeout: decision capture (already d042), memory + `docs/next-session.md`, KB push, compact prompt

---

## Self-review notes (already applied)

- Spec C.2 `drafts-only` ↔ Task 1 return shape consistent (`winner`/`result` = usable-draft pair).
- Spec C.3 serial mapping ↔ Task 3 (`deferred` dep-block via existing `-not $r.merged` line + the gate-path one-liner).
- Spec C.6 test 14 (template sync) superseded by construction: the worker template is parent-rendered from `Get-AdvisoryPrompt` with placeholders — no sync test needed.
- Property names used across tasks: `cascade_status`, `winner`, `frontier_spent`, `draft_winner`, `deferred` — consistent in Tasks 3/5/6.
