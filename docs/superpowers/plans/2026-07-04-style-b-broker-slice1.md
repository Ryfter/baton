# Style-B Broker — Slice 1 (daemon + queue protocol) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A headless broker that executes queued `/baton:go` runs out-of-session, with the two structural interrupts (budget, destructive) parked as files and answered as files — artifacts byte-compatible with a Style-A run.

**Architecture:** New `broker-lib.ps1` implements the file protocol under `$BATON_HOME/broker/` (queue → atomic-rename claim → done/orphaned; interrupts + answers; heartbeat + lock). `conductor-lib.ps1` gains one injectable seam: `-InterruptHandler`, consulted at the two existing guard sites; absent handler = today's behavior exactly. `baton-broker.ps1` is the watcher CLI (start|status|stop) that dot-sources conductor-lib and runs claims in-process. `fleet-go.ps1 -Queue` writes a queue entry instead of running.

**Interrupt-handling decision (recorded):** the broker's handler does a **blocking wait** — it writes the interrupt file, then polls for the answer file (refreshing the heartbeat each cycle) *before* the walk proceeds. Chosen because the engine has NO resume machinery today: both guards `return (Complete-Run … -Status 'interrupted-*')` and the run simply ends (conductor-lib.ps1:526–533); true park-and-resume would mean serializing mid-walk state (spend, decisions, taskCosts, position in `$order`) and re-entering the loop — an invasive restructuring. Tradeoff accepted: the serial v1 broker cannot start another queued run while one is parked on an unanswered interrupt (mitigated by an optional answer timeout env seam; cockpit slices 2–3 may revisit with persisted park state). A `proceed` answer approves **that one task only** — the budget guard re-fires on the next task that would cross the cap, each firing a new interrupt file with a fresh sequence number.

**Tech Stack:** PowerShell 7 (pwsh), JSON file protocol, existing conductor/routing libs. No new dependencies.

## Global Constraints

House rules (binding on every task):

- Every shell command **argument** stays under **965 bytes** (larger content goes through files).
- All file writes use `-Encoding utf8NoBOM`.
- CLI user-error exits: `[Console]::Error.WriteLine('…'); exit 2` — never `Write-Error` under `$ErrorActionPreference = 'Stop'`.
- Never name a parameter or local `$args`, `$input`, `$event`, `$matches`, `$host`, `$pid` (read `$PID`, but param names use `$BrokerPid`).
- The unary-comma return wrap (`return ,([array]$x)`) is for **direct-assignment** consumers only; use `return @($x)` when callers may pipe (the coach-lib lesson).
- `ConvertFrom-Json` auto-parses ISO timestamps into `[datetime]` — re-stringify known stamp fields after parsing (the `Read-BrokerJson` helper centralizes this).
- Tests are hermetic: temp `BATON_HOME` via `try/finally` env restore; never touch the real `~/.baton` or `~/.claude`; zero model/network calls (use `BATON_GO_TEST_PLAN` / `BATON_GO_TEST_SPAWN` / `BATON_GO_TEST_GATE` seams).

Slice-specific invariants (binding):

- **Atomic rename is the claim primitive.** `Move-Item` within the same volume; a lost race returns `$null`, never throws to the caller.
- **The broker loop never throws.** Per-run `try/catch` → claim moved to `done` with `status='failed'` + error message, loop continues.
- **No `-InterruptHandler` passed → conductor behavior is byte-for-byte unchanged.** All existing suites (test-conductor-lib T1–T88/SB1–SB12) must stay green untouched.
- **A run that began spawning is NEVER auto-resumed after a broker crash.** Startup sweeps every leftover `active/` claim to `orphaned/` — the broker cannot know how far a dead predecessor got, so it never guesses.
- **No plugin version bump in this plan** — multiple tracks are in flight; the controller assigns the RC number at merge time.
- Branch: `feature/style-b-broker-slice1` (create from master before Task 1).

---

### Task 1: broker-lib.ps1 — the file protocol

**Files:**
- Create: `scripts/broker-lib.ps1`
- Create: `scripts/test-broker-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` from `scripts/baton-home.ps1` (dot-sourced).
- Produces (used verbatim by Tasks 3–4): `Get-BrokerRoot`, `Initialize-BrokerDirs`, `Read-BrokerJson`, `New-QueueEntry -Goal -BudgetCap -GateArtifact -GateDiff -MaxCostTier -BatonHome -Now → [string]$id`, `Get-QueueEntries → @(hashtable)`, `Invoke-QueueClaim -Id → hashtable|$null`, `Write-BrokerHeartbeat -BrokerPid`, `Test-BrokerAlive → bool`, `Lock-Broker -BrokerPid → bool`, `Unlock-Broker`, `Write-RunInterrupt -RunId -Seq -Kind -TaskId -Message → [string]$path`, `Read-InterruptAnswer -RunId -Seq → hashtable|$null`, `Wait-InterruptAnswer -RunId -Seq -PollSeconds -TimeoutSeconds → hashtable|$null`, `Move-ClaimTo -Id -State -Result`, `Invoke-OrphanSweep → @(string)`.

- [ ] **Step 1: Write `scripts/broker-lib.ps1`** with exactly this content:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Style-B broker file protocol (slice 1). Queue -> atomic-rename claim ->
  done/orphaned; interrupts + answers carry the two structural guard questions
  out of process; heartbeat + lock give single-instance semantics.
.NOTES
  Everything lives under $BATON_HOME/broker/ (box-private). See
  docs/superpowers/specs/2026-07-04-style-b-broker-cockpit-design.md.
#>
. "$PSScriptRoot/baton-home.ps1"

$script:BrokerStaleSeconds = 60

function Get-BrokerRoot {
    param([string]$BatonHome = (Get-BatonHome))
    return (Join-Path $BatonHome 'broker')
}

function Initialize-BrokerDirs {
    <# Idempotent skeleton. Returns the broker root. #>
    param([string]$BatonHome = (Get-BatonHome))
    $root = Get-BrokerRoot -BatonHome $BatonHome
    foreach ($d in @($root,
        (Join-Path $root 'queue'), (Join-Path $root 'active'),
        (Join-Path $root 'done'), (Join-Path $root 'orphaned'),
        (Join-Path $root 'interrupts'), (Join-Path $root 'answers'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    return $root
}

function Read-BrokerJson {
    <# Parse one protocol file; malformed or absent -> $null. ConvertFrom-Json
       auto-parses ISO timestamps into DateTime (house trap) — re-stringify the
       known stamp fields so round-trips stay string-typed. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $o = $null
    try { $o = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable } catch { return $null }
    if ($o -isnot [hashtable]) { return $null }
    foreach ($k in @('submitted_at', 'asked_at', 'at', 'locked_at', 'finished_at')) {
        if ($o.ContainsKey($k) -and ($o[$k] -is [datetime])) {
            $o[$k] = ([datetime]$o[$k]).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    return $o
}

function New-QueueEntry {
    <# Submit a goal for the broker. Returns the queue id. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        $BudgetCap = $null,
        [string]$GateArtifact = '',
        [string]$GateDiff = '',
        [ValidateSet('local','free','paid')][string]$MaxCostTier = 'paid',
        [string]$BatonHome = (Get-BatonHome),
        [datetime]$Now = (Get-Date)
    )
    $root = Initialize-BrokerDirs -BatonHome $BatonHome
    $rand = -join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    $id = 'q-' + $Now.ToString('yyyyMMddTHHmmss') + '-' + $rand
    $entry = [ordered]@{
        id            = $id
        goal          = $Goal
        budget_cap    = if ($null -eq $BudgetCap) { $null } else { [double]$BudgetCap }
        gate_artifact = $GateArtifact
        gate_diff     = $GateDiff
        max_cost_tier = $MaxCostTier
        submitted_at  = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    ($entry | ConvertTo-Json -Depth 4) |
        Set-Content -LiteralPath (Join-Path (Join-Path $root 'queue') "$id.json") -Encoding utf8NoBOM
    return $id
}

function Get-QueueEntries {
    <# Pending queue entries, oldest first (ids embed a sortable timestamp).
       Malformed files are skipped. @() return — callers may pipe. #>
    param([string]$BatonHome = (Get-BatonHome))
    $qdir = Join-Path (Get-BrokerRoot -BatonHome $BatonHome) 'queue'
    if (-not (Test-Path $qdir)) { return @() }
    $found = [System.Collections.ArrayList]@()
    foreach ($f in (Get-ChildItem -Path $qdir -Filter '*.json' | Sort-Object Name)) {
        $e = Read-BrokerJson -Path $f.FullName
        if ($null -ne $e) { [void]$found.Add($e) }
    }
    return @($found)
}

function Invoke-QueueClaim {
    <# Atomic claim: rename queue/<id>.json -> active/<id>.json. Move-Item on one
       volume is a rename — two racers produce exactly one winner; the loser's
       Move-Item throws and we return $null (never propagate). #>
    param([Parameter(Mandatory)][string]$Id, [string]$BatonHome = (Get-BatonHome))
    $root = Get-BrokerRoot -BatonHome $BatonHome
    $src = Join-Path (Join-Path $root 'queue') "$Id.json"
    $dst = Join-Path (Join-Path $root 'active') "$Id.json"
    try { Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop } catch { return $null }
    return (Read-BrokerJson -Path $dst)
}

function Write-BrokerHeartbeat {
    param([int]$BrokerPid = $PID, [string]$BatonHome = (Get-BatonHome), [datetime]$Now = (Get-Date))
    $root = Initialize-BrokerDirs -BatonHome $BatonHome
    ([ordered]@{ pid = $BrokerPid; at = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
        ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $root 'heartbeat.json') -Encoding utf8NoBOM
}

function Test-BrokerAlive {
    <# True when heartbeat.json exists and is fresher than the stale window. #>
    param([string]$BatonHome = (Get-BatonHome), [datetime]$Now = (Get-Date))
    $hb = Read-BrokerJson -Path (Join-Path (Get-BrokerRoot -BatonHome $BatonHome) 'heartbeat.json')
    if ($null -eq $hb -or [string]::IsNullOrEmpty([string]$hb.at)) { return $false }
    $ts = $null
    try {
        $ts = [datetime]::Parse([string]$hb.at, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $false }
    return (($Now.ToUniversalTime() - $ts).TotalSeconds -lt $script:BrokerStaleSeconds)
}

function Lock-Broker {
    <# Single-instance guard. $true when this process now owns the lock. An
       existing lock is reclaimable when the heartbeat has gone stale. #>
    param([int]$BrokerPid = $PID, [string]$BatonHome = (Get-BatonHome))
    $root = Initialize-BrokerDirs -BatonHome $BatonHome
    $lockPath = Join-Path $root 'broker.lock'
    if ((Test-Path $lockPath) -and (Test-BrokerAlive -BatonHome $BatonHome)) { return $false }
    ([ordered]@{ pid = $BrokerPid; locked_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } |
        ConvertTo-Json) | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM
    Write-BrokerHeartbeat -BrokerPid $BrokerPid -BatonHome $BatonHome
    return $true
}

function Unlock-Broker {
    param([string]$BatonHome = (Get-BatonHome))
    $lockPath = Join-Path (Get-BrokerRoot -BatonHome $BatonHome) 'broker.lock'
    if (Test-Path $lockPath) { Remove-Item -Force -LiteralPath $lockPath }
}

function Write-RunInterrupt {
    <# Park one structural question as a file. Returns the file path. #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Seq,
        [Parameter(Mandatory)][ValidateSet('budget','destructive')][string]$Kind,
        [string]$TaskId = '',
        [string]$Message = '',
        [string]$BatonHome = (Get-BatonHome),
        [datetime]$Now = (Get-Date)
    )
    $root = Initialize-BrokerDirs -BatonHome $BatonHome
    $path = Join-Path (Join-Path $root 'interrupts') ('{0}-{1}.json' -f $RunId, $Seq)
    ([ordered]@{
        run_id = $RunId; seq = $Seq; kind = $Kind; task_id = $TaskId; message = $Message
        asked_at = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Read-InterruptAnswer {
    <# Validated answer or $null. A malformed/invalid answer file is renamed to
       .rejected so polling never spins on garbage, and reads as $null. #>
    param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][int]$Seq,
          [string]$BatonHome = (Get-BatonHome))
    $path = Join-Path (Join-Path (Get-BrokerRoot -BatonHome $BatonHome) 'answers') ('{0}-{1}.json' -f $RunId, $Seq)
    if (-not (Test-Path $path)) { return $null }
    $a = Read-BrokerJson -Path $path
    if (($null -ne $a) -and ([string]$a.decision -in @('proceed', 'abort'))) { return $a }
    try { Move-Item -LiteralPath $path -Destination ($path + '.rejected') -Force } catch { }
    return $null
}

function Wait-InterruptAnswer {
    <# Blocking poll for an answer, refreshing the heartbeat each cycle so a
       parked broker still reads as alive. TimeoutSeconds 0 = wait forever;
       timeout -> $null (caller treats as abort). #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][int]$Seq,
        [int]$PollSeconds = 5,
        [int]$TimeoutSeconds = 0,
        [string]$BatonHome = (Get-BatonHome)
    )
    $deadline = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { $null }
    while ($true) {
        $a = Read-InterruptAnswer -RunId $RunId -Seq $Seq -BatonHome $BatonHome
        if ($null -ne $a) { return $a }
        if (($null -ne $deadline) -and ((Get-Date) -gt $deadline)) { return $null }
        Write-BrokerHeartbeat -BatonHome $BatonHome
        Start-Sleep -Seconds $PollSeconds
    }
}

function Move-ClaimTo {
    <# Finish a claim: active/<id>.json -> done|orphaned/<id>.json with result
       fields merged in. Missing active file still produces a terminal record. #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('done','orphaned')][string]$State,
        [hashtable]$Result = @{},
        [string]$BatonHome = (Get-BatonHome)
    )
    $root = Initialize-BrokerDirs -BatonHome $BatonHome
    $src = Join-Path (Join-Path $root 'active') "$Id.json"
    $entry = Read-BrokerJson -Path $src
    if ($null -eq $entry) { $entry = @{ id = $Id } }
    foreach ($k in $Result.Keys) { $entry[$k] = $Result[$k] }
    $entry['finished_at'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ($entry | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath (Join-Path (Join-Path $root $State) "$Id.json") -Encoding utf8NoBOM
    if (Test-Path $src) { Remove-Item -Force -LiteralPath $src }
}

function Invoke-OrphanSweep {
    <# Broker startup: EVERY leftover active claim is orphaned — a prior broker
       died mid-run, and a half-executed DAG is never auto-resumed (invariant).
       Returns the orphaned ids. @() return — callers may pipe. #>
    param([string]$BatonHome = (Get-BatonHome))
    $adir = Join-Path (Get-BrokerRoot -BatonHome $BatonHome) 'active'
    if (-not (Test-Path $adir)) { return @() }
    $swept = [System.Collections.ArrayList]@()
    foreach ($f in (Get-ChildItem -Path $adir -Filter '*.json')) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        Move-ClaimTo -Id $id -State 'orphaned' `
            -Result @{ status = 'orphaned'; why = 'broker restarted while run was active' } -BatonHome $BatonHome
        [void]$swept.Add($id)
    }
    return @($swept)
}
```

- [ ] **Step 2: Write `scripts/test-broker-lib.ps1`** with exactly this content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/broker-lib.ps1"

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$prevHome = $env:BATON_HOME
$tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) "broker-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
$env:BATON_HOME = $tmpHome

try {
    # ---- dirs + queue ----
    $root = Initialize-BrokerDirs
    Check 'BL1 broker root created under BATON_HOME' ($root -eq (Join-Path $tmpHome 'broker'))
    foreach ($sub in @('queue', 'active', 'done', 'orphaned', 'interrupts', 'answers')) {
        Check "BL2 subdir $sub exists" (Test-Path (Join-Path $root $sub))
    }

    $id1 = New-QueueEntry -Goal 'first goal' -BudgetCap 0.5 -Now ([datetime]'2026-07-04T10:00:00')
    Start-Sleep -Milliseconds 20
    $id2 = New-QueueEntry -Goal 'second goal' -Now ([datetime]'2026-07-04T10:00:01')
    Check 'BL3 queue ids have q- prefix' (($id1 -like 'q-*') -and ($id2 -like 'q-*'))
    $entries = Get-QueueEntries
    Check 'BL4 two entries, oldest first' ((@($entries).Count -eq 2) -and ($entries[0].goal -eq 'first goal'))
    Check 'BL5 budget_cap round-trips as double' ([double]$entries[0].budget_cap -eq 0.5)
    Check 'BL6 null budget_cap round-trips as null' ($null -eq $entries[1].budget_cap)
    Check 'BL7 submitted_at stays a string (DateTime re-stringified)' ($entries[0].submitted_at -is [string])

    # ---- claim ----
    $claimed = Invoke-QueueClaim -Id $id1
    Check 'BL8 claim returns the entry' ($claimed.goal -eq 'first goal')
    Check 'BL9 claim moved queue -> active' ((-not (Test-Path (Join-Path $root "queue/$id1.json"))) -and (Test-Path (Join-Path $root "active/$id1.json")))
    Check 'BL10 double-claim loses quietly -> $null' ($null -eq (Invoke-QueueClaim -Id $id1))
    Check 'BL11 claim of unknown id -> $null' ($null -eq (Invoke-QueueClaim -Id 'q-nope'))

    # ---- heartbeat + lock ----
    Check 'BL12 no heartbeat -> not alive' (-not (Test-BrokerAlive))
    Write-BrokerHeartbeat -BrokerPid 1234
    Check 'BL13 fresh heartbeat -> alive' (Test-BrokerAlive)
    Check 'BL14 stale heartbeat -> not alive' (-not (Test-BrokerAlive -Now ((Get-Date).AddSeconds(120))))
    Remove-Item -Force (Join-Path $root 'heartbeat.json')
    Check 'BL15 lock acquired when free' (Lock-Broker -BrokerPid 1111)
    Check 'BL16 second lock refused while heartbeat fresh' (-not (Lock-Broker -BrokerPid 2222))
    # stale reclaim: age the heartbeat by rewriting it in the past
    ([ordered]@{ pid = 1111; at = (Get-Date).ToUniversalTime().AddSeconds(-120).ToString('yyyy-MM-ddTHH:mm:ssZ') } |
        ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $root 'heartbeat.json') -Encoding utf8NoBOM
    Check 'BL17 stale lock is reclaimable' (Lock-Broker -BrokerPid 2222)
    Unlock-Broker
    Check 'BL18 unlock removes the lock file' (-not (Test-Path (Join-Path $root 'broker.lock')))

    # ---- interrupts + answers ----
    $ipath = Write-RunInterrupt -RunId 'go-x' -Seq 1 -Kind 'budget' -TaskId 't3' -Message 'would cross cap'
    $iobj = Read-BrokerJson -Path $ipath
    Check 'BL19 interrupt file has kind/task/seq' (($iobj.kind -eq 'budget') -and ($iobj.task_id -eq 't3') -and ([int]$iobj.seq -eq 1))
    Check 'BL20 no answer yet -> $null' ($null -eq (Read-InterruptAnswer -RunId 'go-x' -Seq 1))
    ([ordered]@{ decision = 'proceed'; by = 'kevin' } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $root 'answers/go-x-1.json') -Encoding utf8NoBOM
    $ans = Read-InterruptAnswer -RunId 'go-x' -Seq 1
    Check 'BL21 valid answer parsed' ($ans.decision -eq 'proceed')
    Set-Content -LiteralPath (Join-Path $root 'answers/go-x-2.json') -Value 'not json' -Encoding utf8NoBOM
    Check 'BL22 malformed answer -> $null' ($null -eq (Read-InterruptAnswer -RunId 'go-x' -Seq 2))
    Check 'BL23 malformed answer renamed .rejected' (Test-Path (Join-Path $root 'answers/go-x-2.json.rejected'))
    ([ordered]@{ decision = 'maybe' } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $root 'answers/go-x-3.json') -Encoding utf8NoBOM
    Check 'BL24 invalid decision -> $null + rejected' (($null -eq (Read-InterruptAnswer -RunId 'go-x' -Seq 3)) -and (Test-Path (Join-Path $root 'answers/go-x-3.json.rejected')))
    Check 'BL25 wait times out -> $null' ($null -eq (Wait-InterruptAnswer -RunId 'go-x' -Seq 9 -PollSeconds 1 -TimeoutSeconds 1))

    # ---- terminal moves + orphan sweep ----
    Move-ClaimTo -Id $id1 -State 'done' -Result @{ status = 'completed'; run_dir = 'runs/go-x' }
    $doneObj = Read-BrokerJson -Path (Join-Path $root "done/$id1.json")
    Check 'BL26 done record merges result + finished_at' (($doneObj.status -eq 'completed') -and ($doneObj.finished_at -is [string]))
    Check 'BL27 active file removed after move' (-not (Test-Path (Join-Path $root "active/$id1.json")))
    ([ordered]@{ id = 'q-dead'; goal = 'left behind' } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $root 'active/q-dead.json') -Encoding utf8NoBOM
    $swept = Invoke-OrphanSweep
    Check 'BL28 orphan sweep moves leftover active claims' ((@($swept) -contains 'q-dead') -and (Test-Path (Join-Path $root 'orphaned/q-dead.json')))
    Check 'BL29 orphaned record says why' ((Read-BrokerJson -Path (Join-Path $root 'orphaned/q-dead.json')).status -eq 'orphaned')
} finally {
    $env:BATON_HOME = $prevHome
    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
```

- [ ] **Step 3: Run the suite**

Run: `pwsh -NoProfile -File scripts/test-broker-lib.ps1`
Expected: every line `PASS: BL…`, final `ALL CHECKS PASS`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/broker-lib.ps1 scripts/test-broker-lib.ps1
git commit -m "feat(broker): slice 1 file protocol — queue/claim/heartbeat/lock/interrupt/answer/orphan"
```

---

### Task 2: conductor-lib `-InterruptHandler` seam

**Files:**
- Modify: `scripts/conductor-lib.ps1` (Invoke-Conductor only — param list + the two guard blocks at lines ~524–533)
- Create: `scripts/test-conductor-interrupts.ps1`

**Interfaces:**
- Consumes: existing `Invoke-Conductor` internals (`$spend`, `$decisions`, `Complete-Run`, `New-RunEvent`/`Add-RunEvent`, `New-RunDecision`/`Add-RunDecision`).
- Produces: `Invoke-Conductor -InterruptHandler [scriptblock]`. The handler receives ONE hashtable argument `@{ kind = 'budget'|'destructive'; run_id; task_id; message }` and returns `'proceed'` to continue past that one task's guard; any other return, `$null`, or a throw → today's terminal `interrupted-*` return. Task 3's broker handler plugs in here.

**Semantics (binding):** the pre-existing `interrupt` event is still written BEFORE the handler is consulted (unchanged position); on `proceed`, an `interrupt-approved` event plus a decision-ledger row are appended and the walk continues; the budget guard re-fires per task (approval is one-task-scoped). With no handler the new code adds NOTHING to any ledger — behavior and artifacts byte-for-byte identical.

- [ ] **Step 1: Add the parameter.** In `Invoke-Conductor`'s `param(...)` block, after `[scriptblock]$Gater`, add:

```powershell
        [scriptblock]$Gater,
        [scriptblock]$InterruptHandler
```

- [ ] **Step 2: Replace the budget guard block.** Replace exactly this (conductor-lib.ps1, inside the `foreach ($task in $order)` walk):

```powershell
        if (Test-BudgetExceeded -CumulativeSpend $spend -TaskEstimate $est -BudgetCap $BudgetCap) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "budget: would cross cap at $($task.id)")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-budget' -PendingTaskId $task.id)
        }
```

with:

```powershell
        if (Test-BudgetExceeded -CumulativeSpend $spend -TaskEstimate $est -BudgetCap $BudgetCap) {
            $imsg = "budget: would cross cap at $($task.id)"
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message $imsg)
            # Style-B seam: an injected handler may approve THIS task's spend.
            # No handler / non-'proceed' / handler error -> today's terminal return.
            $answer = $null
            if ($InterruptHandler) {
                try { $answer = & $InterruptHandler @{ kind = 'budget'; run_id = $runId; task_id = $task.id; message = $imsg } } catch { $answer = $null }
            }
            if ([string]$answer -ne 'proceed') {
                return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-budget' -PendingTaskId $task.id)
            }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt-approved' -Message "budget guard approved for $($task.id) via interrupt answer")
            $iDec = New-RunDecision -TaskId $task.id -Chose 'proceed' -Alternatives @('abort') -Why 'budget guard approved via interrupt answer' -CostTier $task.est_cost_tier
            Add-RunDecision -RunDir $RunDir -Decision $iDec
            [void]$decisions.Add($iDec)
        }
```

- [ ] **Step 3: Replace the destructive guard block.** Replace exactly this:

```powershell
        if (Test-TaskDestructive -Task $task) {
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message "destructive: $($task.id) is reversible:false")
            return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-destructive' -PendingTaskId $task.id)
        }
```

with:

```powershell
        if (Test-TaskDestructive -Task $task) {
            $imsg = "destructive: $($task.id) is reversible:false"
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt' -Level 'warn' -Message $imsg)
            $answer = $null
            if ($InterruptHandler) {
                try { $answer = & $InterruptHandler @{ kind = 'destructive'; run_id = $runId; task_id = $task.id; message = $imsg } } catch { $answer = $null }
            }
            if ([string]$answer -ne 'proceed') {
                return (Complete-Run -RunDir $RunDir -Plan $plan -Decisions $decisions -Spend $spend -Status 'interrupted-destructive' -PendingTaskId $task.id)
            }
            Add-RunEvent -RunDir $RunDir -EventObj (New-RunEvent -TaskId $task.id -Kind 'interrupt-approved' -Message "destructive guard approved for $($task.id) via interrupt answer")
            $iDec = New-RunDecision -TaskId $task.id -Chose 'proceed' -Alternatives @('abort') -Why 'destructive guard approved via interrupt answer' -CostTier $task.est_cost_tier
            Add-RunDecision -RunDir $RunDir -Decision $iDec
            [void]$decisions.Add($iDec)
        }
```

- [ ] **Step 4: Write `scripts/test-conductor-interrupts.ps1`** with exactly this content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/conductor-lib.ps1"

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$prevHome = $env:BATON_HOME
$tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-ih-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
$env:BATON_HOME = $tmpHome

try {
    $destructivePlan = '{"tasks":[{"id":"t1","desc":"safe","depends_on":[],"est_cost_tier":"free","reversible":true},{"id":"t2","desc":"dangerous","depends_on":["t1"],"est_cost_tier":"free","reversible":false}]}'
    $paidPlan = '{"tasks":[{"id":"p1","desc":"paid one","depends_on":[],"est_cost_tier":"paid","reversible":true},{"id":"p2","desc":"paid two","depends_on":["p1"],"est_cost_tier":"paid","reversible":true}]}'
    $mkPlanner = { param($json) { param($g) $p = ConvertTo-PlanObject -RawStdout $json; if ($p) { $p.goal = $g }; $p }.GetNewClosure() }
    $okSpawner = { param($task) @{ ok = $true; spend = 0.0; chose = 'stub'; why = "ran $($task.id)"; alternatives = @() } }
    $newRun = { param($tag) $d = Join-Path $tmpHome "runs/go-ih-$tag"; New-Item -ItemType Directory -Force -Path $d | Out-Null; $d }

    # IH1: no handler -> destructive interrupt terminal (regression of today's behavior)
    $r1 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 1) -Planner (& $mkPlanner $destructivePlan) -Spawner $okSpawner
    Check 'IH1 no handler -> interrupted-destructive' (($r1.status -eq 'interrupted-destructive') -and ($r1.pending_task_id -eq 't2'))
    $ev1 = Get-Content (Join-Path $r1.run_dir 'events.jsonl') -Raw
    Check 'IH1b no handler -> no interrupt-approved event' ($ev1 -notmatch 'interrupt-approved')

    # IH2: handler 'proceed' -> destructive task executes, run completes
    $seen = [System.Collections.ArrayList]@()
    $proceedHandler = { param($i) [void]$seen.Add($i); 'proceed' }.GetNewClosure()
    $r2 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 2) -Planner (& $mkPlanner $destructivePlan) -Spawner $okSpawner -InterruptHandler $proceedHandler
    Check 'IH2 proceed -> completed' ($r2.status -eq 'completed')
    $ev2 = Get-Content (Join-Path $r2.run_dir 'events.jsonl') -Raw
    Check 'IH2b interrupt event still written first' ($ev2 -match '"kind":"interrupt"')
    Check 'IH2c interrupt-approved event written' ($ev2 -match 'interrupt-approved')
    $dec2 = Get-Content (Join-Path $r2.run_dir 'decisions.jsonl') -Raw
    Check 'IH2d approval logged as decision' ($dec2 -match '"chose":"proceed"')
    Check 'IH2e handler got kind + task_id' (($seen[0].kind -eq 'destructive') -and ($seen[0].task_id -eq 't2'))

    # IH3: handler 'abort' -> terminal, same as no handler
    $r3 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 3) -Planner (& $mkPlanner $destructivePlan) -Spawner $okSpawner -InterruptHandler { param($i) 'abort' }
    Check 'IH3 abort -> interrupted-destructive' ($r3.status -eq 'interrupted-destructive')

    # IH4: handler throws -> fail-safe terminal
    $r4 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 4) -Planner (& $mkPlanner $destructivePlan) -Spawner $okSpawner -InterruptHandler { param($i) throw 'boom' }
    Check 'IH4 handler error -> interrupted-destructive' ($r4.status -eq 'interrupted-destructive')

    # IH5: budget approval is one-task-scoped — two over-cap paid tasks -> two handler calls
    $calls = [System.Collections.ArrayList]@()
    $countingHandler = { param($i) [void]$calls.Add($i.task_id); 'proceed' }.GetNewClosure()
    $r5 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 5) -Planner (& $mkPlanner $paidPlan) -Spawner $okSpawner -BudgetCap 0.01 -InterruptHandler $countingHandler
    Check 'IH5 both budget guards consulted' ((@($calls).Count -eq 2) -and ($r5.status -eq 'completed'))
    Check 'IH5b handler saw budget kind per task' (($calls[0] -eq 'p1') -and ($calls[1] -eq 'p2'))

    # IH6: budget abort at first guard -> terminal at p1, handler called once
    $calls2 = [System.Collections.ArrayList]@()
    $abortHandler = { param($i) [void]$calls2.Add($i.task_id); 'abort' }.GetNewClosure()
    $r6 = Invoke-Conductor -Goal 'g' -RunDir (& $newRun 6) -Planner (& $mkPlanner $paidPlan) -Spawner $okSpawner -BudgetCap 0.01 -InterruptHandler $abortHandler
    Check 'IH6 budget abort -> interrupted-budget at p1' (($r6.status -eq 'interrupted-budget') -and ($r6.pending_task_id -eq 'p1') -and (@($calls2).Count -eq 1))
} finally {
    $env:BATON_HOME = $prevHome
    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
```

- [ ] **Step 5: Run new suite + full conductor regression**

Run: `pwsh -NoProfile -File scripts/test-conductor-interrupts.ps1`
Expected: all `PASS: IH…`, `ALL CHECKS PASS`, exit 0.

Run: `pwsh -NoProfile -File scripts/test-conductor-lib.ps1`
Expected: unchanged — `ALL CHECKS PASS` (T1–T88, SB1–SB12), exit 0. If ANY existing check fails, the seam broke the no-handler invariant: fix before committing.

- [ ] **Step 6: Commit**

```bash
git add scripts/conductor-lib.ps1 scripts/test-conductor-interrupts.ps1
git commit -m "feat(conductor): -InterruptHandler seam — injected approval at the two guard sites, absent = unchanged"
```

---

### Task 3: baton-broker.ps1 — the watcher CLI

**Files:**
- Create: `scripts/baton-broker.ps1`
- Create: `scripts/test-baton-broker.ps1`

**Interfaces:**
- Consumes: everything Task 1 produces; `Invoke-Conductor -InterruptHandler` from Task 2; `Initialize-RunDir`/`New-RunId`/`ConvertTo-PlanObject` from conductor-lib; test seams `BATON_GO_TEST_PLAN`/`BATON_GO_TEST_SPAWN`/`BATON_GO_TEST_GATE` (same contract as fleet-go.ps1:34–49).
- Produces: `baton-broker.ps1 start [-Once] [-PollSeconds n] [-AnswerPollSeconds n] | status [-Json] | stop`. Env seam `BATON_BROKER_ANSWER_TIMEOUT` (seconds; unset/0 = wait forever) bounds the parked wait for tests.

- [ ] **Step 1: Write `scripts/baton-broker.ps1`** with exactly this content:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Style-B broker daemon (slice 1). Watches $BATON_HOME/broker/queue, executes
  runs in-process via Invoke-Conductor, parks the two structural interrupts as
  files, and never auto-resumes a crashed run.
.NOTES
  start: foreground loop (Ctrl+C or `stop` to end). -Once drains at most one
  entry then exits (test seam). status: counts + pending interrupts. stop:
  writes stop.signal; the loop exits at its next poll.
#>
param(
    [Parameter(Position = 0)][ValidateSet('start', 'status', 'stop')][string]$Command = 'status',
    [int]$PollSeconds = 5,
    [int]$AnswerPollSeconds = 5,
    [switch]$Once,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'conductor-lib.ps1')
. (Join-Path $PSScriptRoot 'broker-lib.ps1')

$brokerRoot = Initialize-BrokerDirs
$logPath = Join-Path (Get-BatonHome) 'logs/baton-broker.log'

function Write-BrokerLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding utf8NoBOM } catch { }
    Write-Host $line
}

function Invoke-BrokerRun {
    <# Execute one claimed entry in-process. The interrupt handler writes the
       question file and blocking-waits for the answer (heartbeat kept fresh);
       timeout/no answer reads as abort — the safe direction. #>
    param([Parameter(Mandatory)][hashtable]$Entry)
    $runDir = Initialize-RunDir -RunId (New-RunId)
    $seqRef = @{ n = 0 }
    $answerPoll = $AnswerPollSeconds
    $answerTimeout = 0
    if ($env:BATON_BROKER_ANSWER_TIMEOUT) { $answerTimeout = [int]$env:BATON_BROKER_ANSWER_TIMEOUT }
    $handler = {
        param($interrupt)
        $seqRef.n++
        [void](Write-RunInterrupt -RunId ([string]$interrupt.run_id) -Seq $seqRef.n `
            -Kind ([string]$interrupt.kind) -TaskId ([string]$interrupt.task_id) -Message ([string]$interrupt.message))
        Write-BrokerLog "parked: $($interrupt.run_id) seq $($seqRef.n) ($($interrupt.kind) at $($interrupt.task_id)) — waiting for answer"
        $ans = Wait-InterruptAnswer -RunId ([string]$interrupt.run_id) -Seq $seqRef.n `
            -PollSeconds $answerPoll -TimeoutSeconds $answerTimeout
        if ($null -eq $ans) { Write-BrokerLog "no answer for $($interrupt.run_id) seq $($seqRef.n) — treating as abort"; return 'abort' }
        Write-BrokerLog "answer for $($interrupt.run_id) seq $($seqRef.n): $($ans.decision)"
        return [string]$ans.decision
    }.GetNewClosure()

    $go = @{ Goal = [string]$Entry.goal; RunDir = $runDir; InterruptHandler = $handler }
    if ($null -ne $Entry.budget_cap) { $go.BudgetCap = [double]$Entry.budget_cap }
    if (-not [string]::IsNullOrEmpty([string]$Entry.max_cost_tier)) { $go.MaxCostTier = [string]$Entry.max_cost_tier }
    if (-not [string]::IsNullOrEmpty([string]$Entry.gate_artifact)) { $go.GateArtifact = [string]$Entry.gate_artifact }
    if (-not [string]::IsNullOrEmpty([string]$Entry.gate_diff)) { $go.GateDiff = [string]$Entry.gate_diff }

    # Same hermetic seams as fleet-go.ps1 — broker tests never call a model.
    if ($env:BATON_GO_TEST_PLAN) {
        $canned = $env:BATON_GO_TEST_PLAN
        $go['Planner'] = { param($g) $p = ConvertTo-PlanObject -RawStdout $canned; if ($p) { $p.goal = $g }; $p }.GetNewClosure()
    }
    if ($env:BATON_GO_TEST_SPAWN -eq '1') {
        $go['Spawner'] = { param($task) @{ ok = $true; spend = 0.0; chose = 'test-stub'; why = "ran $($task.id)"; alternatives = @() } }
    }
    if ($env:BATON_GO_TEST_GATE) {
        $cannedVerdict = $env:BATON_GO_TEST_GATE
        $go['Gater'] = { param($art, $goal) @{ verdict = $cannedVerdict; reason = 'test-stub verdict'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = 'test brief'; findings = @(); reviews = @(); unparsed = @() } }.GetNewClosure()
        if (-not $go.ContainsKey('GateArtifact')) { $go['GateArtifact'] = 'test artifact' }
    }
    return (Invoke-Conductor @go)
}

switch ($Command) {
    'start' {
        if (-not (Lock-Broker)) {
            [Console]::Error.WriteLine('broker already running (fresh heartbeat). Use `baton-broker.ps1 stop`, or wait for the stale window.')
            exit 2
        }
        $stopSignal = Join-Path $brokerRoot 'stop.signal'
        if (Test-Path $stopSignal) { Remove-Item -Force $stopSignal }
        $orphans = Invoke-OrphanSweep
        if (@($orphans).Count -gt 0) { Write-BrokerLog "orphan sweep: $(@($orphans) -join ', ') (never auto-resumed)" }
        Write-BrokerLog "broker started (pid $PID, poll ${PollSeconds}s)"
        try {
            while ($true) {
                if (Test-Path $stopSignal) { Write-BrokerLog 'stop signal — exiting'; Remove-Item -Force $stopSignal; break }
                Write-BrokerHeartbeat
                $pending = Get-QueueEntries
                if (@($pending).Count -eq 0) {
                    if ($Once) { break }
                    Start-Sleep -Seconds $PollSeconds
                    continue
                }
                $claimed = Invoke-QueueClaim -Id ([string]$pending[0].id)
                if ($null -eq $claimed) { continue }   # lost a race; re-poll
                Write-BrokerLog "claimed $($claimed.id): $($claimed.goal)"
                try {
                    $result = Invoke-BrokerRun -Entry $claimed
                    Move-ClaimTo -Id ([string]$claimed.id) -State 'done' -Result @{
                        status = [string]$result.status; run_id = [string]$result.run_id
                        run_dir = [string]$result.run_dir; spend = [double]$result.spend
                    }
                    Write-BrokerLog "finished $($claimed.id): $($result.status) ($($result.run_dir))"
                } catch {
                    # The loop never throws: a failed run is recorded, the broker lives on.
                    Move-ClaimTo -Id ([string]$claimed.id) -State 'done' -Result @{
                        status = 'failed'; error = $_.Exception.Message
                    }
                    Write-BrokerLog "FAILED $($claimed.id): $($_.Exception.Message)"
                }
                if ($Once) { break }
            }
        } finally { Unlock-Broker }
        exit 0
    }
    'status' {
        $counts = [ordered]@{}
        foreach ($state in @('queue', 'active', 'done', 'orphaned')) {
            $d = Join-Path $brokerRoot $state
            $counts[$state] = if (Test-Path $d) { @(Get-ChildItem -Path $d -Filter '*.json').Count } else { 0 }
        }
        $idir = Join-Path $brokerRoot 'interrupts'
        $adir = Join-Path $brokerRoot 'answers'
        $waiting = [System.Collections.ArrayList]@()
        foreach ($f in @(Get-ChildItem -Path $idir -Filter '*.json' -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path (Join-Path $adir $f.Name))) { [void]$waiting.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name)) }
        }
        $status = [ordered]@{
            alive = (Test-BrokerAlive)
            locked = (Test-Path (Join-Path $brokerRoot 'broker.lock'))
            counts = $counts
            waiting_interrupts = @($waiting)
        }
        if ($Json) { $status | ConvertTo-Json -Depth 4 }
        else {
            Write-Host ("broker: {0}" -f $(if ($status.alive) { 'RUNNING' } else { 'not running' }))
            Write-Host ("queue {0} · active {1} · done {2} · orphaned {3}" -f $counts.queue, $counts.active, $counts.done, $counts.orphaned)
            if (@($waiting).Count -gt 0) {
                Write-Host "waiting on answers: $(@($waiting) -join ', ')"
                Write-Host "answer with: a JSON file {\"decision\":\"proceed\"|\"abort\"} at broker/answers/<name>.json"
            }
        }
        exit 0
    }
    'stop' {
        Set-Content -LiteralPath (Join-Path $brokerRoot 'stop.signal') -Value 'stop' -Encoding utf8NoBOM
        Write-Host 'stop signal written — the broker exits at its next poll (a parked run exits after its answer/timeout).'
        exit 0
    }
}
```

- [ ] **Step 2: Write `scripts/test-baton-broker.ps1`** with exactly this content:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$cli = Join-Path $PSScriptRoot 'baton-broker.ps1'
Check 'BB0 baton-broker.ps1 exists' (Test-Path $cli)
. "$PSScriptRoot/broker-lib.ps1"

$prevHome = $env:BATON_HOME
$prevPlan = $env:BATON_GO_TEST_PLAN
$prevSpawn = $env:BATON_GO_TEST_SPAWN
$prevTimeout = $env:BATON_BROKER_ANSWER_TIMEOUT
$tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) "broker-cli-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
$env:BATON_HOME = $tmpHome

$safePlan = '{"tasks":[{"id":"t1","desc":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
$destructivePlan = '{"tasks":[{"id":"t1","desc":"dangerous","depends_on":[],"est_cost_tier":"free","reversible":false}]}'

try {
    $root = Initialize-BrokerDirs
    $env:BATON_GO_TEST_PLAN = $safePlan
    $env:BATON_GO_TEST_SPAWN = '1'
    $env:BATON_BROKER_ANSWER_TIMEOUT = '2'

    # BB1: -Once with an empty queue exits promptly and cleanly
    & pwsh -NoProfile -File $cli start -Once | Out-Null
    Check 'BB1 empty-queue -Once exits 0' ($LASTEXITCODE -eq 0)
    Check 'BB1b lock released after exit' (-not (Test-Path (Join-Path $root 'broker.lock')))

    # BB2: one safe entry -> executed to completion, claim lands in done/
    $qid = New-QueueEntry -Goal 'do a safe thing'
    & pwsh -NoProfile -File $cli start -Once | Out-Null
    Check 'BB2 exits 0' ($LASTEXITCODE -eq 0)
    $doneRec = Read-BrokerJson -Path (Join-Path $root "done/$qid.json")
    Check 'BB2b claim moved to done with completed status' ($doneRec.status -eq 'completed')
    Check 'BB2c run dir recorded and artifacts exist' ((-not [string]::IsNullOrEmpty([string]$doneRec.run_dir)) -and (Test-Path (Join-Path ([string]$doneRec.run_dir) 'report.md')))
    Check 'BB2d run plan.json written (Style-A-compatible artifacts)' (Test-Path (Join-Path ([string]$doneRec.run_dir) 'plan.json'))

    # BB3: destructive plan, no answer -> timeout reads as abort -> interrupted-destructive
    $env:BATON_GO_TEST_PLAN = $destructivePlan
    $qid3 = New-QueueEntry -Goal 'do a dangerous thing'
    & pwsh -NoProfile -File $cli start -Once -AnswerPollSeconds 1 | Out-Null
    $doneRec3 = Read-BrokerJson -Path (Join-Path $root "done/$qid3.json")
    Check 'BB3 unanswered interrupt -> interrupted-destructive' ($doneRec3.status -eq 'interrupted-destructive')
    $ifiles = @(Get-ChildItem -Path (Join-Path $root 'interrupts') -Filter '*.json')
    Check 'BB3b interrupt file was written' (@($ifiles).Count -ge 1)

    # BB4: destructive plan, answered 'proceed' mid-park -> run completes
    $qid4 = New-QueueEntry -Goal 'approved dangerous thing'
    $env:BATON_BROKER_ANSWER_TIMEOUT = '30'
    $proc = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $cli, 'start', '-Once', '-AnswerPollSeconds', '1') -PassThru -WindowStyle Hidden
    $answered = $false
    $before = @($ifiles | ForEach-Object { $_.Name })
    for ($i = 0; $i -lt 60; $i++) {
        $fresh = @(Get-ChildItem -Path (Join-Path $root 'interrupts') -Filter '*.json' |
            Where-Object { $before -notcontains $_.Name })
        if (@($fresh).Count -ge 1) {
            ([ordered]@{ decision = 'proceed'; by = 'test' } | ConvertTo-Json) |
                Set-Content -LiteralPath (Join-Path $root ('answers/' + $fresh[0].Name)) -Encoding utf8NoBOM
            $answered = $true; break
        }
        Start-Sleep -Milliseconds 500
    }
    $proc.WaitForExit(60000) | Out-Null
    $doneRec4 = Read-BrokerJson -Path (Join-Path $root "done/$qid4.json")
    Check 'BB4 answer file was written by the test' $answered
    Check 'BB4b proceed answer -> run completed' ($doneRec4.status -eq 'completed')
    $ev4 = Get-Content -Raw -LiteralPath (Join-Path ([string]$doneRec4.run_dir) 'events.jsonl')
    Check 'BB4c interrupt-approved event in the run ledger' ($ev4 -match 'interrupt-approved')

    # BB5: status reports counts and exits 0
    $statusOut = & pwsh -NoProfile -File $cli status 2>&1 | Out-String
    Check 'BB5 status exits 0 and shows done count' (($LASTEXITCODE -eq 0) -and ($statusOut -match 'done 3'))

    # BB6: lock contention -> exit 2
    [void](Lock-Broker -BrokerPid 9999)   # fresh heartbeat now owned by "another" broker
    & pwsh -NoProfile -File $cli start -Once 2>$null | Out-Null
    Check 'BB6 second broker refused (exit 2)' ($LASTEXITCODE -eq 2)
    Unlock-Broker
    Remove-Item -Force (Join-Path $root 'heartbeat.json') -ErrorAction SilentlyContinue

    # BB7: leftover active claim orphaned at startup, never auto-resumed
    ([ordered]@{ id = 'q-dead'; goal = 'was mid-run' } | ConvertTo-Json) |
        Set-Content -LiteralPath (Join-Path $root 'active/q-dead.json') -Encoding utf8NoBOM
    & pwsh -NoProfile -File $cli start -Once | Out-Null
    Check 'BB7 startup orphan sweep' (Test-Path (Join-Path $root 'orphaned/q-dead.json'))
} finally {
    $env:BATON_HOME = $prevHome
    $env:BATON_GO_TEST_PLAN = $prevPlan
    $env:BATON_GO_TEST_SPAWN = $prevSpawn
    $env:BATON_BROKER_ANSWER_TIMEOUT = $prevTimeout
    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
```

- [ ] **Step 3: Run the suite**

Run: `pwsh -NoProfile -File scripts/test-baton-broker.ps1`
Expected: all `PASS: BB…`, `ALL CHECKS PASS`, exit 0. (BB4 runs a real child broker parked on a real interrupt — allow ~10–30 s.)

- [ ] **Step 4: Commit**

```bash
git add scripts/baton-broker.ps1 scripts/test-baton-broker.ps1
git commit -m "feat(broker): baton-broker daemon — claim/execute/park loop, status, stop, orphan sweep"
```

---

### Task 4: fleet-go `-Queue`, bootstrap deploy, docs

**Files:**
- Modify: `scripts/fleet-go.ps1` (add `-Queue` before the run is initialized)
- Modify: `scripts/bootstrap.ps1` (deploy manifest array, line ~259)
- Modify: `scripts/test-bootstrap.ps1` (two asserts, pattern of existing lines 61–64)
- Create: `commands/broker.md`
- Modify: `commands/go.md`, `docs/COMMANDS.md`

**Interfaces:**
- Consumes: `New-QueueEntry` (Task 1).
- Produces: `/baton:go … --queue` → queue entry + guidance line; `/baton:broker` command doc.

- [ ] **Step 1: Add `-Queue` to fleet-go.ps1.** In the `param(...)` block add after `[switch]$Json`:

```powershell
    [switch]$Queue,
```

Then insert this block immediately AFTER the goal-validation line (`if ([string]::IsNullOrWhiteSpace($theGoal)) { … exit 2 }`) and BEFORE `$runDir = Initialize-RunDir -RunId (New-RunId)`:

```powershell
# Style-B: -Queue submits to the broker instead of running in-session.
if ($Queue) {
    . (Join-Path $PSScriptRoot 'broker-lib.ps1')
    $qp = @{ Goal = $theGoal; MaxCostTier = $MaxCostTier }
    if ($PSBoundParameters.ContainsKey('Budget')) { $qp.BudgetCap = $Budget }
    if ($PSBoundParameters.ContainsKey('GateArtifact')) { $qp.GateArtifact = $GateArtifact }
    if ($PSBoundParameters.ContainsKey('GateDiff')) { $qp.GateDiff = $GateDiff }
    $qid = New-QueueEntry @qp
    if ($Json) { @{ queued = $qid } | ConvertTo-Json }
    else {
        Write-Host "Queued $qid for the broker."
        Write-Host "Watch: scripts/baton-broker.ps1 status · answers go in `$BATON_HOME/broker/answers/ as {""decision"":""proceed""|""abort""}"
    }
    exit 0
}
```

- [ ] **Step 2: Test the flag by hand (hermetic)**

Run (PowerShell):
```powershell
$env:BATON_HOME = Join-Path ([System.IO.Path]::GetTempPath()) 'q-smoke'
pwsh -NoProfile -File scripts/fleet-go.ps1 -Goal 'queued goal' -Queue -Json
Get-ChildItem (Join-Path $env:BATON_HOME 'broker/queue')
Remove-Item -Recurse -Force $env:BATON_HOME; Remove-Item Env:BATON_HOME
```
Expected: JSON `{"queued":"q-…"}`; one `q-*.json` in the queue dir; NO `runs/` dir created.

- [ ] **Step 3: Bootstrap manifest.** In `scripts/bootstrap.ps1` line ~259, extend the `foreach ($script in @(…))` array: after `'start-lib.ps1'` (the current last element), append:

```powershell
, 'broker-lib.ps1', 'baton-broker.ps1'
```

(the resulting array ends `…, 'idea-lib.ps1', 'start-lib.ps1', 'broker-lib.ps1', 'baton-broker.ps1')`).

- [ ] **Step 4: test-bootstrap asserts.** In `scripts/test-bootstrap.ps1`, directly after the line `Assert "would deploy prompt-pool-lib.ps1" …` add:

```powershell
Assert "would deploy broker-lib.ps1"    ($out -match 'broker-lib\.ps1')
Assert "would deploy baton-broker.ps1"  ($out -match 'baton-broker\.ps1')
```

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all asserts pass (the suite runs bootstrap in dry-run mode), exit 0.

- [ ] **Step 5: Create `commands/broker.md`** with exactly this content:

```markdown
---
description: Operate the Style-B broker — queue runs headlessly, watch status, answer parked interrupts
---

# /baton:broker — the headless run broker

The broker executes queued `/baton:go` runs OUTSIDE this session. Artifacts are
identical to an in-session run (`$BATON_HOME/runs/go-*/`).

When the user invokes `/baton:broker <subcommand>`, run the matching CLI with
the Bash tool and relay the output:

- `status` (default): `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/baton-broker.ps1" status`
- `start`: tell the user to run it in their OWN terminal (it is a foreground
  daemon): `pwsh -NoProfile -File <scripts>/baton-broker.ps1 start`. Do NOT
  start it from this session — it would block the shell.
- `stop`: `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/baton-broker.ps1" stop`

Queueing a run: `/baton:go "<goal>" --queue` (see go.md).

Parked interrupts: `status` lists names waiting under `broker/interrupts/`.
To answer one, write `$BATON_HOME/broker/answers/<same-name>.json` containing
`{"decision":"proceed"}` or `{"decision":"abort"}` — relay the interrupt's
question to the user and write the file they choose. No answer = the run
aborts at the guard (or waits forever if no timeout is set): the safe direction.
```

- [ ] **Step 6: Docs touch-ups.**
  - `commands/go.md`: in the flags/usage section add one line: `` `--queue` — do not run now; submit to the Style-B broker (start it with `baton-broker.ps1 start`; watch with `/baton:broker status`). Budget/gate flags ride along. ``
  - `docs/COMMANDS.md`: add a `/baton:broker` row/section mirroring broker.md's summary (status/start/stop + the answers-file protocol, one short paragraph).

- [ ] **Step 7: Full regression sweep**

Run each; all must exit 0:
```
pwsh -NoProfile -File scripts/test-broker-lib.ps1
pwsh -NoProfile -File scripts/test-conductor-interrupts.ps1
pwsh -NoProfile -File scripts/test-baton-broker.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

- [ ] **Step 8: Commit**

```bash
git add scripts/fleet-go.ps1 scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/broker.md commands/go.md docs/COMMANDS.md
git commit -m "feat(broker): fleet-go --queue, bootstrap deploy, /baton:broker docs"
```

---

## Execution Handoff

Subagent-driven (standing default), streamlined ceremony (no per-task reviewers; one opus whole-branch final review). Branch `feature/style-b-broker-slice1` off master.

| Task | Model | Why |
|------|-------|-----|
| 1 broker-lib + suite | haiku | complete code in plan — transcription + test run |
| 2 conductor seam | **opus** | invariant-critical edit inside the engine's guarded walk; must prove the no-handler byte-for-byte property against the full existing suite |
| 3 baton-broker + process tests | sonnet | integration: closures over broker state, child-process test choreography (BB4's park-and-answer race) |
| 4 flag + manifest + docs | haiku | mechanical edits with exact anchors |

Final review focus for opus: the no-handler invariant (existing suites untouched and green), the claim-rename race, the BB4 answer round-trip, and that no path lets the broker auto-resume an orphan.
