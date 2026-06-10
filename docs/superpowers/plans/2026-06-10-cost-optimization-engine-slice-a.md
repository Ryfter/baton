# Cost-Optimization Engine — Slice A (Time-Awareness) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A time-awareness layer that gates paid/frontier dispatch by item rank during prime-peak windows and scales concurrency up during off-peak/weekend surge windows.

**Architecture:** A new pure library `scripts/prime-hours.ps1` exposes `Test-PrimeHoursGate` (per-dispatch decision) and `Get-CapacityProfile` (per-session concurrency), both reading `~/.claude/prime-hours.yaml` with an injectable `-Now` for clock-independent tests. The gate guards ONLY the `paid` tier inside a `peak` window; `local`/`free` and off-peak always `allow` (invariant: rank ≠ tier; the routing optimizer still picks the model). Wiring into routing paid-tier, the backlog drivers, `/route`, and `/schedule` is additive and behavior-preserving — the routing gate is opt-in via a `-Rank` sentinel so the existing 31-check dispatch suite stays green.

**Tech Stack:** PowerShell 7 (pwsh); hand-rolled YAML parsing mirroring `fleet-lib.ps1`'s `Read-Fleet`/`ConvertFrom-FleetValue`; `Check($n,$c)` test harness with injected `-Now`/dispatchers (zero clock or model dependence).

**Spec:** `docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md` (Slice A).

## File Structure

- **Create `scripts/prime-hours.ps1`** — pure gate + capacity library. Dot-sources `fleet-lib.ps1` for `ConvertFrom-FleetValue`.
- **Create `scripts/test-prime-hours.ps1`** — gate, capacity, fail-open, boundary, tz, reserved-rank checks.
- **Create `references/prime-hours.yaml`** — the deployed seed config.
- **Modify `scripts/routing-dispatch.ps1`** — `Invoke-RoutedCandidate` + `Invoke-RoutedCapability` gain opt-in `-Rank` gating of paid candidates.
- **Modify `scripts/test-routing-dispatch.ps1`** — add gate cases; existing 31 stay green.
- **Modify `scripts/fleet-backlog.ps1`** — effective-rank ordering + per-item gate + capacity-driven parallelism.
- **Modify `scripts/test-fleet-backlog.ps1`** — effective-rank + gate cases.
- **Modify `scripts/bootstrap.ps1`** — deploy `prime-hours.ps1` (lib manifest) + `prime-hours.yaml` (seed).
- **Modify `scripts/test-bootstrap.ps1`** — assert both deploy.
- **Modify `commands/route.md`** — `--rank` flag + gated-candidate reporting + interactive ask instruction.

---

### Task 1: `prime-hours.ps1` — config + gate core

**Files:**
- Create: `scripts/prime-hours.ps1`
- Create: `scripts/test-prime-hours.ps1`

- [ ] **Step 1: Write the failing test** (`scripts/test-prime-hours.ps1`)

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/prime-hours.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("primehours-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $cfgYaml = @"
timezone: local
default_rank: 3
windows:
  - name: weekday-peak
    days: [Mon, Tue, Wed, Thu, Fri]
    start: "08:00"
    end: "18:00"
    kind: peak
  - name: weekend
    days: [Sat, Sun]
    kind: surge
    concurrency_factor: 2
"@
    $cfg = Join-Path $tmp 'prime-hours.yaml'
    Set-Content -Path $cfg -Value $cfgYaml -Encoding utf8

    # A Wednesday 10:00 (inside weekday-peak) and a Wednesday 20:00 (off-peak).
    $peakNow = [datetime]'2026-06-10T10:00:00'   # Wed
    $offNow  = [datetime]'2026-06-10T20:00:00'   # Wed
    $satNow  = [datetime]'2026-06-13T10:00:00'   # Sat

    # local/free always allow, even in a peak window.
    Check 'local allow in peak'  ((Test-PrimeHoursGate -Rank 5 -CostTier 'local' -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')
    Check 'free allow in peak'   ((Test-PrimeHoursGate -Rank 5 -CostTier 'free'  -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')

    # paid off-peak -> allow.
    Check 'paid allow off-peak'  ((Test-PrimeHoursGate -Rank 5 -CostTier 'paid' -Now $offNow -ConfigPath $cfg).decision -eq 'allow')
    # paid on a surge day (not a peak window) -> allow.
    Check 'paid allow on surge day' ((Test-PrimeHoursGate -Rank 5 -CostTier 'paid' -Now $satNow -ConfigPath $cfg).decision -eq 'allow')

    # paid in peak: rank policy.
    $r1 = Test-PrimeHoursGate -Rank 1 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg
    Check 'rank1 ask/run'  ($r1.decision -eq 'ask'   -and $r1.default -eq 'run')
    $r2 = Test-PrimeHoursGate -Rank 2 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg
    Check 'rank2 ask/defer'($r2.decision -eq 'ask'   -and $r2.default -eq 'defer')
    foreach ($rk in 3,4,5) {
        Check "rank$rk defer" ((Test-PrimeHoursGate -Rank $rk -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')
    }
    Check 'peak sets window name' ($r1.window -eq 'weekday-peak')

    # default_rank applies to unranked (no -Rank) -> rank 3 -> defer in peak.
    Check 'unranked uses default_rank' ((Test-PrimeHoursGate -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')

    # reserved ranks 0 and 6 resolve WITHOUT error (undocumented; table rows present).
    Check 'rank0 reserved allow' ((Test-PrimeHoursGate -Rank 0 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'allow')
    Check 'rank6 reserved defer' ((Test-PrimeHoursGate -Rank 6 -CostTier 'paid' -Now $peakNow -ConfigPath $cfg).decision -eq 'defer')

    # window boundaries: 08:00 inclusive start, 18:00 exclusive end.
    Check 'boundary start inclusive' ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now ([datetime]'2026-06-10T08:00:00') -ConfigPath $cfg).decision -eq 'defer')
    Check 'boundary end exclusive'   ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now ([datetime]'2026-06-10T18:00:00') -ConfigPath $cfg).decision -eq 'allow')

    # fail-open: missing config -> allow + (warning suppressed).
    $missing = Join-Path $tmp 'nope.yaml'
    Check 'fail-open missing config' ((Test-PrimeHoursGate -Rank 3 -CostTier 'paid' -Now $peakNow -ConfigPath $missing 3>$null).decision -eq 'allow')

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail check(s) FAILED"; exit 1 }
    Write-Host "All prime-hours gate checks passed."; exit 0
}
finally { Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue }
```

- [ ] **Step 2: Run it — verify it fails**

Run: `pwsh -NoProfile -File scripts/test-prime-hours.ps1`
Expected: FAIL — `prime-hours.ps1` doesn't exist (dot-source error).

- [ ] **Step 3: Implement `scripts/prime-hours.ps1`**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Time-awareness gate + capacity profile (Cost-Optimization Engine, Slice A). Gates
  paid/frontier dispatch by item rank during prime-peak windows; reports a concurrency
  surge during off-peak/weekend windows. PURE: returns decisions, never prompts.
.DESCRIPTION
  Reads ~/.claude/prime-hours.yaml. -Now is injectable so tests are clock-independent.
  Fail-open: a missing/garbage config never blocks work (returns allow). The gate guards
  ONLY the paid tier inside a peak window — local/free and off-peak always allow. Ranks
  0 and 6 are RESERVED rows in the policy table (one-line future activation), intentionally
  undocumented in v1. See docs/superpowers/specs/2026-06-10-cost-optimization-engine-design.md.
#>

. "$PSScriptRoot/fleet-lib.ps1"   # ConvertFrom-FleetValue

$script:DefaultPrimeHoursPath = (Join-Path $HOME '.claude/prime-hours.yaml')

function Read-PrimeHoursConfig {
    <# Parse prime-hours.yaml -> @{ timezone; default_rank; windows=@(@{name;days;start;end;kind;concurrency_factor}) }.
       Fail-open: missing/garbage -> permissive default (no windows). #>
    param([string]$Path = $script:DefaultPrimeHoursPath)
    $default = @{ timezone='local'; default_rank=3; windows=@() }
    if (-not $Path -or -not (Test-Path $Path)) { return $default }
    try {
        $cfg = @{ timezone='local'; default_rank=3; windows=[System.Collections.ArrayList]@() }
        $cur = $null; $inWindows = $false
        foreach ($raw in (Get-Content -LiteralPath $Path)) {
            if ($raw -match '^\s*#') { continue }
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            if ($raw -match '^timezone:\s*(.+?)\s*$')    { $cfg.timezone = [string](ConvertFrom-FleetValue $matches[1]); continue }
            if ($raw -match '^default_rank:\s*(.+?)\s*$') { $cfg.default_rank = [int](ConvertFrom-FleetValue $matches[1]); continue }
            if ($raw -match '^windows:\s*$') { $inWindows = $true; continue }
            if (-not $inWindows) { continue }
            if ($raw -match '^\s*-\s+name:\s*(.+?)\s*$') {
                if ($cur) { [void]$cfg.windows.Add($cur) }
                $cur = @{ name=[string](ConvertFrom-FleetValue $matches[1]); days=@(); start=$null; end=$null; kind='peak'; concurrency_factor=2.0 }
                continue
            }
            if (-not $cur) { continue }
            if ($raw -match '^\s+days:\s*\[(.*?)\]\s*$') {
                $cur.days = @($matches[1] -split ',' | ForEach-Object { ([string](ConvertFrom-FleetValue $_)).Trim() } | Where-Object { $_ })
                continue
            }
            if ($raw -match '^\s+([\w.-]+):\s*(.+?)\s*$') {
                $k = $matches[1]; $v = ConvertFrom-FleetValue $matches[2]
                if ($k -eq 'concurrency_factor') { $cur[$k] = [double]$v } else { $cur[$k] = [string]$v }
            }
        }
        if ($cur) { [void]$cfg.windows.Add($cur) }
        $cfg.windows = $cfg.windows.ToArray()
        return $cfg
    } catch {
        Write-Warning "prime-hours config parse failed ($($_.Exception.Message)); failing open."
        return $default
    }
}

function Get-PrimeHoursNow {
    <# Current wall-clock in the configured tz. 'local'/unknown -> machine-local. #>
    param([string]$Timezone)
    if (-not $Timezone -or $Timezone -eq 'local') { return (Get-Date) }
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($Timezone)
        return [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz)
    } catch {
        Write-Warning "prime-hours timezone '$Timezone' not found; using machine-local."
        return (Get-Date)
    }
}

function Test-InWindow {
    <# Is $Now inside $Window? Day-of-week match (3-letter, case-insensitive) AND, if the
       window has start/end, the time in [start, end). A window with no start/end = all day. #>
    param([Parameter(Mandatory)][hashtable]$Window, [Parameter(Mandatory)][datetime]$Now)
    $days = @($Window.days | ForEach-Object { "$_".Trim().ToLower() } | Where-Object { $_ } | ForEach-Object { $_.Substring(0,[Math]::Min(3,$_.Length)) })
    if ($days.Count -gt 0) {
        $dow3 = $Now.DayOfWeek.ToString().Substring(0,3).ToLower()
        if ($days -notcontains $dow3) { return $false }
    }
    if ($Window.start -and $Window.end) {
        $toMin = { param($s) $p = "$s" -split ':'; [int]$p[0]*60 + [int]$p[1] }
        $nowM = (& $toMin ($Now.ToString('HH:mm'))); $sM = (& $toMin $Window.start); $eM = (& $toMin $Window.end)
        if ($nowM -lt $sM -or $nowM -ge $eM) { return $false }
    }
    return $true
}

function Get-PrimeRankPolicy {
    <# Rank -> peak-window policy for a PAID dispatch. #1 highest .. #5 lowest. Ranks 0 and 6
       are RESERVED (rows present so future activation is one line) and undocumented in v1.
       Unknown rank -> DefaultRank's policy. #>
    param([int]$Rank, [int]$DefaultRank = 3)
    $table = @{
        0 = @{ decision='allow'; default='run'   }   # reserved: emergency / preempt (undocumented)
        1 = @{ decision='ask';   default='run'   }
        2 = @{ decision='ask';   default='defer' }
        3 = @{ decision='defer'; default='defer' }
        4 = @{ decision='defer'; default='defer' }
        5 = @{ decision='defer'; default='defer' }
        6 = @{ decision='defer'; default='defer' }   # reserved: frugal/local-only/surge-only (undocumented; full semantics deferred)
    }
    if ($table.ContainsKey($Rank)) { return $table[$Rank] }
    if ($table.ContainsKey($DefaultRank)) { return $table[$DefaultRank] }
    return @{ decision='defer'; default='defer' }
}

function Test-PrimeHoursGate {
    <# Decide whether a dispatch may proceed now. Returns
       @{ decision='allow'|'ask'|'defer'; default='run'|'defer'; reason; window }.
       local/free -> allow. paid off-peak -> allow. paid in a peak window -> rank policy. #>
    param(
        [int]$Rank = [int]::MinValue,
        [Parameter(Mandatory)][ValidateSet('local','free','paid')][string]$CostTier,
        [datetime]$Now,
        [string]$ConfigPath = $script:DefaultPrimeHoursPath
    )
    $cfg = Read-PrimeHoursConfig -Path $ConfigPath
    if ($Rank -eq [int]::MinValue) { $Rank = [int]$cfg.default_rank }
    if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-PrimeHoursNow -Timezone $cfg.timezone }

    if ($CostTier -ne 'paid') {
        return @{ decision='allow'; default='run'; reason="$CostTier tier is free"; window=$null }
    }
    $peak = $null
    foreach ($w in @($cfg.windows)) {
        if ([string]$w.kind -eq 'peak' -and (Test-InWindow -Window $w -Now $Now)) { $peak = $w; break }
    }
    if (-not $peak) {
        return @{ decision='allow'; default='run'; reason='paid, off-peak'; window=$null }
    }
    $p = Get-PrimeRankPolicy -Rank $Rank -DefaultRank ([int]$cfg.default_rank)
    return @{ decision=$p.decision; default=$p.default; reason="paid in peak window '$($peak.name)' (rank $Rank)"; window=[string]$peak.name }
}
```

- [ ] **Step 4: Run the test — verify it passes**

Run: `pwsh -NoProfile -File scripts/test-prime-hours.ps1`
Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/prime-hours.ps1 scripts/test-prime-hours.ps1
git commit -m "feat(engine): prime-hours gate — rank-gated paid dispatch in peak windows

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Get-CapacityProfile` — weekend/off-peak surge

**Files:**
- Modify: `scripts/prime-hours.ps1` (append `Get-CapacityProfile`)
- Modify: `scripts/test-prime-hours.ps1` (append capacity checks before the tally)

- [ ] **Step 1: Append the failing checks** (in `test-prime-hours.ps1`, immediately before the `Write-Host ""` tally)

```powershell
    # ===== Get-CapacityProfile: surge vs baseline =====
    $sat = [datetime]'2026-06-13T10:00:00'   # Sat -> weekend surge
    $wed = [datetime]'2026-06-10T10:00:00'   # Wed peak -> baseline (peak is not surge)
    $cap = Get-CapacityProfile -Now $sat -ConfigPath $cfg
    Check 'surge on weekend'        ($cap.surge -eq $true -and $cap.concurrency_factor -eq 2.0 -and $cap.window -eq 'weekend')
    $base = Get-CapacityProfile -Now $wed -ConfigPath $cfg
    Check 'baseline on weekday'     ($base.surge -eq $false -and $base.concurrency_factor -eq 1.0 -and $null -eq $base.window)
    Check 'capacity fail-open'      ((Get-CapacityProfile -Now $sat -ConfigPath (Join-Path $tmp 'nope.yaml') 3>$null).concurrency_factor -eq 1.0)
```

- [ ] **Step 2: Run — verify the new checks fail**

Run: `pwsh -NoProfile -File scripts/test-prime-hours.ps1`
Expected: FAIL — `Get-CapacityProfile` not recognized.

- [ ] **Step 3: Append `Get-CapacityProfile` to `prime-hours.ps1`**

```powershell
function Get-CapacityProfile {
    <# Per-session concurrency profile. In a 'surge' window -> that window's concurrency_factor
       (default 2) + surge=$true; otherwise baseline 1 / surge=$false. Drives max-parallel
       subagent count + deferred-queue drain in the backlog/run-loop. #>
    param([datetime]$Now, [string]$ConfigPath = $script:DefaultPrimeHoursPath)
    $cfg = Read-PrimeHoursConfig -Path $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-PrimeHoursNow -Timezone $cfg.timezone }
    foreach ($w in @($cfg.windows)) {
        if ([string]$w.kind -eq 'surge' -and (Test-InWindow -Window $w -Now $Now)) {
            $cf = if ($w.concurrency_factor) { [double]$w.concurrency_factor } else { 2.0 }
            return @{ concurrency_factor=$cf; surge=$true; window=[string]$w.name }
        }
    }
    return @{ concurrency_factor=1.0; surge=$false; window=$null }
}
```

- [ ] **Step 4: Run — verify pass**

Run: `pwsh -NoProfile -File scripts/test-prime-hours.ps1`
Expected: all PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/prime-hours.ps1 scripts/test-prime-hours.ps1
git commit -m "feat(engine): Get-CapacityProfile — weekend/off-peak surge concurrency

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Config seed + bootstrap deploy

**Files:**
- Create: `references/prime-hours.yaml`
- Modify: `scripts/bootstrap.ps1` (libs manifest ~line 250 + a seed-deploy step next to the fleet/tools seeds ~line 280)
- Modify: `scripts/test-bootstrap.ps1` (two asserts)

- [ ] **Step 1: Create `references/prime-hours.yaml`**

```yaml
# Prime-hours / capacity windows — Cost-Optimization Engine (Slice A).
# timezone: 'local' or an IANA id (e.g. America/Denver).
# default_rank: rank for un-ranked work (1 = highest priority/most spend-tolerant .. 5 = lowest).
# windows[]: name, days [Mon..Sun], optional start/end "HH:mm", kind: peak|surge.
#   peak  -> paid/frontier dispatch is rank-gated during this window.
#   surge -> cheap + high-throughput: raise concurrency, drain deferred work.
# A clock time in no window = ordinary off-peak (paid allowed, baseline concurrency).
timezone: local
default_rank: 3
windows:
  - name: weekday-peak
    days: [Mon, Tue, Wed, Thu, Fri]
    start: "08:00"
    end: "18:00"
    kind: peak
  - name: weekend
    days: [Sat, Sun]
    kind: surge
    concurrency_factor: 2
```

- [ ] **Step 2: Add the failing bootstrap asserts** (`scripts/test-bootstrap.ps1`, next to the `routing-calibrate.ps1` assert)

```powershell
Assert "would deploy prime-hours.ps1"   ($out -match 'prime-hours\.ps1')
Assert "would deploy prime-hours.yaml"  ($out -match 'prime-hours\.yaml')
```

- [ ] **Step 3: Run — verify fail**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL on the two new asserts.

- [ ] **Step 4: Wire bootstrap** — (a) add to the libs manifest array (~line 250), immediately after `'routing-calibrate.ps1',`:

```powershell
'routing-calibrate.ps1', 'prime-hours.ps1', 'six-hats-lib.ps1',
```

(b) Add a seed-deploy step after the tools.yaml seed (~line 280, after the `Copy-WithPrompt $toolsSrc …` block):

```powershell
# --- Step 5b5: Deploy prime-hours.yaml seed (don't clobber an existing one) ---
Write-Step "Deploying prime-hours.yaml seed"
$primeSrc = Join-Path $repoRoot 'references\prime-hours.yaml'
$primeDst = Join-Path $claudeDir 'prime-hours.yaml'
Copy-WithPrompt $primeSrc $primeDst 'prime-hours config'
```

- [ ] **Step 5: Run — verify pass**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: all PASS, exit 0.

- [ ] **Step 6: Commit**

```bash
git add references/prime-hours.yaml scripts/bootstrap.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(engine): bootstrap deploys prime-hours.ps1 + prime-hours.yaml seed

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Routing paid-tier gate (opt-in, regression-safe)

**Files:**
- Modify: `scripts/routing-dispatch.ps1` (`Invoke-RoutedCandidate`, `Invoke-RoutedCapability`)
- Modify: `scripts/test-routing-dispatch.ps1` (add gate cases; keep the 31 green)

**Design contract:** gating is OPT-IN via `-Rank` (default sentinel `[int]::MinValue` = "not set → never gate", so the existing 31 checks — which pass no `-Rank` — keep current behavior). When `-Rank` is set and a candidate is `paid`, consult `Test-PrimeHoursGate`. The library is deterministic/unattended: `defer` → skip the candidate (record a gated attempt; the loop falls through to the next cheaper-capable candidate or escalates); `ask` → resolve to the gate's `default` (`run`→dispatch, `defer`→skip) and tag the attempt; `allow` → dispatch. Every gated outcome is recorded on the attempt (`gate` field) so the command layer can report/override.

- [ ] **Step 1: Add failing gate cases** (`test-routing-dispatch.ps1`, before the final tally). Reuse the existing `$common4` fixtures (local-a/free-b/paid-c for code-gen); add a peak-window prime-hours config in `$tmp`:

```powershell
    # ===== Slice A: prime-hours gate on the paid tier (opt-in via -Rank) =====
    $phYaml = @"
timezone: local
default_rank: 3
windows:
  - name: peak
    days: [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
    start: "00:00"
    end: "23:59"
    kind: peak
"@
    $phCfg = Join-Path $tmp 'prime-hours.yaml'
    Set-Content -Path $phCfg -Value $phYaml -Encoding utf8
    $always = { param($c,$p) @{ stdout='WORKS'; stderr=''; exit_code=0; duration_s=1 } }   # every candidate passes

    # No -Rank -> NO gating -> cheapest (local-a) wins (regression-equivalent).
    $g0 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $always @common4
    Check 'no -Rank: no gating, local wins' ($g0.winner -eq 'local-a')

    # Rank 3 in an all-day peak window: paid candidates are deferred; local/free still allowed,
    # so local-a (free tier) still wins -> winner unchanged, but a paid candidate would be gated.
    # Force the local/free to FAIL so the loop reaches paid-c and we observe the gate:
    $onlyPaidWorks = { param($c,$p) if ($c.cost_tier -eq 'paid') { @{ stdout='WORKS'; exit_code=0; duration_s=1 } } else { @{ stdout=''; exit_code=0; duration_s=1 } } }
    $g3 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $onlyPaidWorks -Rank 3 -PrimeHoursConfig $phCfg @common4
    Check 'rank3 peak: paid deferred -> escalate' ($g3.status -eq 'escalate-to-conductor')
    Check 'paid attempt tagged gated' (@($g3.attempts | Where-Object { $_.candidate -eq 'paid-c' -and $_.gate -eq 'defer' }).Count -eq 1)

    # Rank 1 in peak: ask -> default run -> paid-c dispatched -> wins.
    $g1 = Invoke-RoutedCapability -Capability 'code-gen' -Prompt 'x' -Dispatcher $onlyPaidWorks -Rank 1 -PrimeHoursConfig $phCfg @common4
    Check 'rank1 peak: paid runs (ask->run)' ($g1.status -eq 'passed' -and $g1.winner -eq 'paid-c')
```

(Note: `$common4` must include the journal path; the gate adds `-PrimeHoursConfig` and optional `-GateNow`. If the existing fixtures already run during a real peak window, the no-`-Rank` regression case is unaffected because gating is off without `-Rank`.)

- [ ] **Step 2: Run — verify new cases fail**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: FAIL on the new gate cases (param `-Rank`/`-PrimeHoursConfig` not yet present); the original 31 still pass.

- [ ] **Step 3: Thread the gate through `Invoke-RoutedCandidate`**

Add params to `Invoke-RoutedCandidate` (after `$EffGrader`):

```powershell
        [int]$Rank = [int]::MinValue,
        [string]$PrimeHoursConfig,
        [datetime]$GateNow,
```

Immediately AFTER the unsupported-kind skip block and BEFORE the dispatch `try`, insert the gate (only when opt-in and paid):

```powershell
    # Slice A: prime-hours gate (opt-in via -Rank; guards only the paid tier).
    if ($Rank -ne [int]::MinValue -and $c.cost_tier -eq 'paid') {
        $gateArgs = @{ Rank = $Rank; CostTier = 'paid' }
        if ($PrimeHoursConfig) { $gateArgs['ConfigPath'] = $PrimeHoursConfig }
        if ($PSBoundParameters.ContainsKey('GateNow')) { $gateArgs['Now'] = $GateNow }
        $gate = Test-PrimeHoursGate @gateArgs
        $eff = if ($gate.decision -eq 'ask') { if ($gate.default -eq 'run') { 'allow' } else { 'defer' } } else { $gate.decision }
        if ($eff -eq 'defer') {
            $reason = "deferred: prime-hours $($gate.reason)"
            $attempt = [pscustomobject]@{ candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier; passed=$false; score=0.0; reason=$reason; duration_s=0; gate=$gate.decision }
            Write-RoutingJournalLine -Capability $Capability -Candidate $c.name -Source $c.source -Kind $c.kind -CostTier $c.cost_tier -ExitCode -1 -DurationS 0 -Passed $false -Score 0.0 -Reason $reason -JournalPath $JournalPath
            return @{ attempt = $attempt; result = @{ stdout=''; stderr=''; exit_code=-1; duration_s=0 } }
        }
        $script:__lastGateDecision = $gate.decision   # 'ask' or 'allow' that proceeded
    } else {
        $script:__lastGateDecision = $null
    }
```

Then, where the attempt object is built at the end of the dispatch path, add a `gate` field so a proceeded gate is visible:

```powershell
    $attempt = [pscustomobject]@{
        candidate=$c.name; source=$c.source; kind=$c.kind; cost_tier=$c.cost_tier
        passed=[bool]$verdict.passed; score=[double]$verdict.score; reason=[string]$verdict.reason
        duration_s=[int]$result.duration_s; gate=$script:__lastGateDecision
    }
```

(The non-cli-skip early-return attempt also gains `gate=$null` for shape consistency.)

- [ ] **Step 4: Thread params through `Invoke-RoutedCapability`**

Add the same three params (`-Rank`, `-PrimeHoursConfig`, `-GateNow`) to `Invoke-RoutedCapability`'s param block, and pass them into the `Invoke-RoutedCandidate` call inside the loop:

```powershell
        $rcArgs = @{ Capability=$Capability; Candidate=$c; Prompt=$Prompt; EffGrader=$effGrader;
                     Dispatcher=$Dispatcher; TimeoutS=$TimeoutS; ToolsPath=$ToolsPath;
                     FleetPath=$FleetPath; JournalPath=$JournalPath }
        if ($Rank -ne [int]::MinValue)               { $rcArgs['Rank'] = $Rank }
        if ($PrimeHoursConfig)                       { $rcArgs['PrimeHoursConfig'] = $PrimeHoursConfig }
        if ($PSBoundParameters.ContainsKey('GateNow')){ $rcArgs['GateNow'] = $GateNow }
        $rc = Invoke-RoutedCandidate @rcArgs
        [void]$attempts.Add($rc.attempt)
        if ($rc.attempt.passed) {
            return [pscustomobject]@{ status='passed'; capability=$Capability; winner=$c.name; result=$rc.result; attempts=$attempts.ToArray() }
        }
```

(`prime-hours.ps1` is in scope because `routing-dispatch.ps1` → `routing-lib.ps1` → `fleet-lib.ps1`; add `. "$PSScriptRoot/prime-hours.ps1"` near the top of `routing-dispatch.ps1` after the existing dot-source so `Test-PrimeHoursGate` resolves.)

- [ ] **Step 5: Run — new cases pass AND the original 31 stay green**

Run: `pwsh -NoProfile -File scripts/test-routing-dispatch.ps1`
Expected: all PASS, exit 0 (34 checks: 31 original + 3 gate). If any original check regressed, the `-Rank` default sentinel is wrong — confirm gating is fully skipped when `-Rank` is absent.

- [ ] **Step 6: Commit**

```bash
git add scripts/routing-dispatch.ps1 scripts/test-routing-dispatch.ps1
git commit -m "feat(engine): opt-in prime-hours gate on routing paid tier (regression-safe)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Backlog driver — effective rank + gate + capacity

**Files:**
- Modify: `scripts/fleet-backlog.ps1` (`Get-TopoOrder` neighbor map reuse; add `Get-EffectiveRanks`; gate + order in `Invoke-Backlog`)
- Modify: `scripts/test-fleet-backlog.ps1`

**Design:** tasks gain an optional `rank` (default 3). `Get-EffectiveRanks` computes, per task, `min(own rank, min effective rank of all transitive dependents)` so a rank-1 task's prerequisites inherit rank 1. Ready (unblocked) items dispatch in ascending effective rank. Each item consults `Test-PrimeHoursGate` with unattended semantics (`ask`→its default, `defer`→skip + record `deferred until off-peak`). `Get-CapacityProfile` sets max-parallel (surge raises it).

- [ ] **Step 1: Write the failing test** (`test-fleet-backlog.ps1`, new block)

```powershell
    # ===== Slice A: effective-rank prereq inheritance =====
    $tasks = @(
        @{ id='a'; depends_on=@();        rank=5 }
        @{ id='b'; depends_on=@('a');     rank=1 }   # b is urgent; a is its prereq
        @{ id='c'; depends_on=@();        rank=4 }
    )
    $eff = Get-EffectiveRanks -Tasks $tasks
    Check 'prereq inherits dependent rank' ($eff['a'] -eq 1)   # a pulled up to b's rank
    Check 'own rank kept when no urgent dependent' ($eff['c'] -eq 4)
    Check 'urgent task keeps its rank' ($eff['b'] -eq 1)
```

- [ ] **Step 2: Run — verify fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
Expected: FAIL — `Get-EffectiveRanks` not defined.

- [ ] **Step 3: Implement `Get-EffectiveRanks`** in `fleet-backlog.ps1` (near `Get-TopoOrder`)

```powershell
function Get-EffectiveRanks {
    <# Effective rank = min(own rank, min effective rank of all transitive dependents).
       A rank-1 task pulls its prerequisites up to rank 1 so they aren't starved. Returns
       @{ id = effRank }. Unranked tasks default to 3. #>
    param([Parameter(Mandatory)][object[]]$Tasks)
    $own = @{}; $dependents = @{}
    foreach ($t in $Tasks) {
        $r = if ($null -ne $t.rank) { [int]$t.rank } else { 3 }
        $own[$t.id] = $r; $dependents[$t.id] = @()
    }
    foreach ($t in $Tasks) {
        foreach ($d in @($t.depends_on)) {
            if ($dependents.ContainsKey($d)) { $dependents[$d] += $t.id }
        }
    }
    $eff = @{}
    function script:__effOf($id, $own, $dependents, $eff, $stack) {
        if ($eff.ContainsKey($id)) { return $eff[$id] }
        if ($stack -contains $id) { return $own[$id] }   # cycle guard (DAG already validated upstream)
        $best = $own[$id]
        foreach ($dep in $dependents[$id]) {
            $de = script:__effOf $dep $own $dependents $eff ($stack + $id)
            if ($de -lt $best) { $best = $de }
        }
        $eff[$id] = $best; return $best
    }
    foreach ($t in $Tasks) { [void](script:__effOf $t.id $own $dependents $eff @()) }
    return $eff
}
```

- [ ] **Step 4: Run — verify pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
Expected: all PASS, exit 0.

- [ ] **Step 5: Wire ordering + gate into `Invoke-Backlog`** — after `$order = Get-TopoOrder -Tasks $Tasks`, compute effective ranks and use them as the tiebreaker for ready items, and consult the gate per item (unattended). Add this helper call + per-item gate (using `$byId[$id].model`'s cost tier resolved via `Get-FleetProvider`):

```powershell
    $eff = Get-EffectiveRanks -Tasks $Tasks
    # Stable topo order, but among equally-ready items prefer lower effective rank:
    $order = @($order | Sort-Object @{ e = { $eff[$_] } }, @{ e = { [array]::IndexOf($order,$_) } })
    $cap = Get-CapacityProfile
    # (max-parallel = baseline * $cap.concurrency_factor; in the serial driver this only
    #  informs logging — the concurrent driver in Invoke-BacklogConcurrent consumes it.)
```

In the per-item dispatch loop, before dispatching item `$id` whose model is paid, gate it (unattended):

```powershell
        $prov = Get-FleetProvider -Name $model -Path $FleetPath
        if ($prov -and $prov.cost_tier -eq 'paid') {
            $gate = Test-PrimeHoursGate -Rank ([int]$eff[$id]) -CostTier 'paid'
            $eff2 = if ($gate.decision -eq 'ask') { $gate.default } else { $gate.decision }   # unattended: ask->default
            if ($eff2 -eq 'defer') {
                & $writeLive @{ label=$id; provider=$model; state='deferred'; reason="prime-hours: $($gate.reason)" }
                Write-Host "  deferred $id ($model) until off-peak — $($gate.reason)"
                continue   # skip this pass; a later (off-peak) run picks it up
            }
        }
```

(`prime-hours.ps1` resolves via the dot-source chain; `fleet-backlog.ps1` already loads `fleet-lib.ps1`. If not, add `. "$PSScriptRoot/prime-hours.ps1"` at the top.)

- [ ] **Step 6: Add the gate/defer test** (`test-fleet-backlog.ps1`) — with an injected paid provider + an all-day peak config, a rank-3 paid task is skipped with state `deferred`; a rank-1 paid task proceeds. Use the driver's existing injected-dispatch seam (no real model calls). Then run:

Run: `pwsh -NoProfile -File scripts/test-fleet-backlog.ps1`
Expected: all PASS, exit 0.

- [ ] **Step 7: Commit**

```bash
git add scripts/fleet-backlog.ps1 scripts/test-fleet-backlog.ps1
git commit -m "feat(engine): backlog driver — effective-rank ordering + prime-hours gate + capacity

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `/route` command — `--rank` + gated reporting

**Files:**
- Modify: `commands/route.md`

- [ ] **Step 1: Front-matter** — add `--rank <1-5>` to `argument-hint` and note in `description` that paid dispatch is gated by rank during prime hours.

- [ ] **Step 2: Dispatch-mode wiring** — in the `--run` block, parse `--rank` (default 3) and pass it + the deployed config:

```powershell
   $rank = if ($rankArg) { [int]$rankArg } else { 3 }
   $opt['Rank'] = $rank   # enables the prime-hours gate on paid candidates
   $outcome = Invoke-RoutedCapability @opt
```

After printing attempts, report any gated candidates and the override path:

```powershell
   $gated = @($outcome.attempts | Where-Object { $_.gate -eq 'defer' -or $_.gate -eq 'ask' })
   if ($gated.Count -gt 0) {
       Write-Host ""
       Write-Host "Prime-hours: $($gated.Count) paid candidate(s) gated this run (rank $rank). To pay premium now, re-run with --rank 1; to stay cheap, wait for off-peak or use --max-tier free."
   }
```

- [ ] **Step 3: Interactive ask instruction** — add prose telling Claude: when a rank-1 or rank-2 paid candidate would be the pick during a peak window (gate decision `ask`), Claude should ask the user *before* dispatching ("This will use the paid model <name> during peak hours — proceed? cheaper local/free options failed."), since "spend premium now?" is a real cost decision. Unattended callers (backlog/run-loop) skip the prompt — the library already resolves `ask` to its rank default.

- [ ] **Step 4: Verify the doc** — `pwsh -NoProfile -Command "(Get-Content commands/route.md -Raw | Select-String '--rank' -AllMatches).Matches.Count"` ≥ 2.

- [ ] **Step 5: Commit**

```bash
git add commands/route.md
git commit -m "feat(engine): /route --rank + prime-hours gated-candidate reporting

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full gate + final comprehensive review

**Files:** none (verification).

- [ ] **Step 1: Run the full suite set** — confirm exit 0 / all PASS each:

```
pwsh -NoProfile -File scripts/test-prime-hours.ps1
pwsh -NoProfile -File scripts/test-routing-dispatch.ps1   # 31 original + 3 gate
pwsh -NoProfile -File scripts/test-routing-lib.ps1
pwsh -NoProfile -File scripts/test-routing-learn.ps1
pwsh -NoProfile -File scripts/test-routing-calibrate.ps1
pwsh -NoProfile -File scripts/test-fleet-backlog.ps1
pwsh -NoProfile -File scripts/test-fleet-lib.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
```

- [ ] **Step 2: Live deploy smoke**

```
pwsh -NoProfile -File scripts/bootstrap.ps1 -Force
pwsh -NoProfile -Command ". \"$HOME/.claude/scripts/prime-hours.ps1\"; (Test-PrimeHoursGate -CostTier 'local').decision; (Get-CapacityProfile).surge"
```
Expected: `prime-hours.ps1` + `prime-hours.yaml` deployed; the gate returns `allow` for local; capacity returns a boolean.

- [ ] **Step 3: One comprehensive review** (per "crank this out") — dispatch a single adversarial reviewer over `git diff master...HEAD`: verify the invariants (rank ≠ tier; local/free never gated; gating opt-in so routing regression holds; fail-open; reserved 0/6 resolve), check the effective-rank inheritance + ascending order, and confirm zero real clock/model dependence in tests. Address blocking findings; nits at discretion.

- [ ] **Step 4: No commit** — proceed to gated merge.

---

## Self-Review

**Spec coverage:** gate (Task 1) ✓; capacity/surge (Task 2) ✓; config + bootstrap (Task 3) ✓; routing paid-tier wiring, regression-safe (Task 4) ✓; backlog effective-rank + gate + capacity (Task 5) ✓; `/route --rank` + reporting + interactive ask (Task 6) ✓; `/schedule` rank — *noted in spec as a consumer; deferred to a follow-up since `/schedule` is a skill not a script and carries no test harness here* (flagged, not silently dropped). Invariants (rank≠tier, optimizer-first, paid-during-peak only, fail-open, autonomy-preserving) enforced in Task 1 logic + Task 4 opt-in.

**Placeholder scan:** no TBD/TODO; every code step shows complete code. `/schedule` wiring is explicitly scoped out with a reason (not a placeholder).

**Type consistency:** `Test-PrimeHoursGate` → `@{decision;default;reason;window}` used identically in Tasks 4–6; `Get-CapacityProfile` → `@{concurrency_factor;surge;window}` used in Tasks 2,5; `Get-EffectiveRanks` → `@{id=int}` used in Task 5; the attempt object's new `gate` field is added in Task 4 and read in Task 6. `-Rank`/`-PrimeHoursConfig`/`-GateNow` param names match across `Invoke-RoutedCandidate` and `Invoke-RoutedCapability`.
