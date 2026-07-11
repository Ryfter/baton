# Copilot Credit Budget (d079) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Kevin's real GitHub Copilot AI-credit spend (used / allowance / % / run-rate / days-to-exhaustion, per-model split, 80% warning) as a fail-open panel in `/baton:usage`, fed by GitHub's user-level billing API.

**Architecture:** One new focused library `scripts/copilot-credit-lib.ps1` (fetch via injectable `-Fetcher` seam → fold → cycle-anchored forecast → panel render), one surgical render call inside `scripts/fleet-usage.ps1`'s `status` branch, deploy/docs wiring. No new subsystem; allowance rides the existing per-worker `budget` field (`Get-WorkerBudget`); only `credit_reset_day` / `credit_warn_pct` are new optional fleet fields. **The panel is advisory and fail-open — it can never break `/baton:usage`, change its exit code, or run when no budget is configured (byte-for-byte unchanged output in that case).**

**Tech Stack:** PowerShell 7; `gh api` (default fetch) / `BATON_GH_BILLING_TOKEN` PAT fallback / `BATON_COPILOT_TEST_USAGE` hermetic file seam; house Assert-style test suites.

**Spec:** `docs/superpowers/specs/2026-07-06-copilot-credit-budget-design.md` (d079). The spec commit `deb551c` lives on branch `feature/copilot-credit-budget-spec`.

**Branch setup (controller does this before Task 1):**
```powershell
cd D:\Dev\Baton
git checkout master; git pull
git checkout -b feature/copilot-credit-budget
git cherry-pick deb551c   # brings the spec doc onto the work branch
```

**Execution ladder (spec §11):** Task 1 = Haiku (complete code below — transcription + run), Task 2 = Sonnet (integration edit), Task 3 = Haiku. Streamlined ceremony: no per-task reviewers; ONE final opus whole-branch review. Do **not** merge without Kevin's word.

## Global Constraints (spec §10 — binding, every task)

- 965-byte arg ceiling (files for anything large).
- `[Console]::Error.WriteLine` + `exit 2` for CLI user errors (never `Write-Error` under `ErrorActionPreference=Stop`).
- `utf8NoBOM` writes.
- `ConvertFrom-Json` auto-parses ISO dates → re-stringify on round-trip.
- `ConvertTo-Json -InputObject @(...)` for guaranteed arrays.
- Never name vars `$args/$input/$event/$matches/$host/$pid`.
- Unary-comma flatten only on direct-assignment returns; `@()` when callers pipe.
- Guard 0/0 → NaN (every division below has an explicit guard).
- Box-private: real numbers ONLY in live `~/.baton/fleet.yaml`; the shared seed carries commented placeholders.
- Tests hermetic: temp `BATON_HOME` + temp fleet.yaml + `try/finally`; never real `gh`, `~/.baton`, `~/.claude`, or the network.
- No credential value is ever emitted to stdout, journal, or logs.
- Pass untyped ordered-dict results into untyped params (house lesson: a typed param breaks `[ordered]@{}` binding).

---

### Task 1: `copilot-credit-lib.ps1` + hermetic suite  [HAIKU — transcription]

**Files:**
- Create: `D:\Dev\Baton\scripts\copilot-credit-lib.ps1`
- Create: `D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1`

**Interfaces:**
- Consumes: `Get-BatonHome` (baton-home.ps1), `Read-Fleet` (fleet-lib.ps1).
- Produces (Task 2 relies on these exact names/shapes):
  - `Get-CopilotCreditConfig [-Worker 'gh-copilot'] [-FleetPath]` → `@{ budget=[int]|$null; reset_day=[int 1-28]|$null; warn_pct=[int, default 80] }`
  - `Get-CopilotCreditUsage [-User] [-Fetcher]` → ordered `@{ ok; used; amount; currency='USD'; by_model=@(@{model;credits;amount}...); fetched_at; reason }`
  - `Get-CopilotCreditForecast [-User] [-FleetPath] [-Now] [-Fetcher]` → ordered `@{ status; used; budget; remaining; pct; amount; by_model; reset_date; days_elapsed; days_left_in_cycle; run_rate; days_to_exhaustion; warn; warn_pct; reason }` with `status ∈ unavailable|no_budget|no_reset_anchor|ok`
  - `Write-CopilotCreditPanel -Forecast <result>` → Write-Host panel, never throws
  - Test seam: env `BATON_COPILOT_TEST_USAGE` = path to a canned JSON response file (checked by the default fetch path before token/gh).

- [ ] **Step 1: Write the library**

Create `D:\Dev\Baton\scripts\copilot-credit-lib.ps1` with exactly:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Copilot Credit Budget (d079). Pulls current-cycle Copilot AI-credit usage from
  GitHub's user-level billing API and computes a cycle-anchored forecast for the
  /baton:usage panel. Informational + warning only — never governs dispatch.
.DESCRIPTION
  Fail-open everywhere: any failure collapses to ok=$false / status='unavailable'
  with a human reason; the panel can never break /baton:usage or its exit code.
  See docs/superpowers/specs/2026-07-06-copilot-credit-budget-design.md (d079).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet

function Get-CopilotFetchReason {
    <# Classify a fetch error into the spec's reason vocabulary. Pure. #>
    param([string]$ErrorText)
    $t = [string]$ErrorText
    if ($t -match '404' -or $t -match "user['’]?\s+scope" -or $t -match 'Not Found') {
        return 'insufficient-scope'
    }
    return 'fetch-failed'
}

function Get-CopilotCreditConfig {
    <# Box-private knobs off the gh-copilot fleet row. budget = allowance (credits);
       credit_reset_day = billing-cycle day-of-month (1-28, else ignored);
       credit_warn_pct = warn threshold (default 80). Absent file/fields -> nulls. #>
    param(
        [string]$Worker = 'gh-copilot',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    $cfg = @{ budget = $null; reset_day = $null; warn_pct = 80 }
    if (-not (Test-Path $FleetPath)) { return $cfg }
    if (-not (Get-Command Read-Fleet -ErrorAction SilentlyContinue)) { return $cfg }
    foreach ($p in (Read-Fleet -Path $FleetPath)) {
        if ([string]$p.name -ne $Worker) { continue }
        if ($null -ne $p.budget) { $cfg.budget = [int]$p.budget }
        if ($null -ne $p.credit_reset_day) {
            $rd = 0
            if ([int]::TryParse([string]$p.credit_reset_day, [ref]$rd) -and $rd -ge 1 -and $rd -le 28) {
                $cfg.reset_day = $rd
            }
        }
        if ($null -ne $p.credit_warn_pct) {
            $wp = 0
            if ([int]::TryParse([string]$p.credit_warn_pct, [ref]$wp) -and $wp -ge 1 -and $wp -le 100) {
                $cfg.warn_pct = $wp
            }
        }
        break
    }
    return $cfg
}

function Resolve-CopilotLogin {
    <# GitHub login: -User, else BATON_GH_USER, else ambient `gh api user`. $null on failure. #>
    param([string]$User)
    if ($User) { return $User }
    if ($env:BATON_GH_USER) { return $env:BATON_GH_USER }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    try {
        $login = (& gh api user --jq .login 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $login) { return $login }
    } catch { }
    return $null
}

function Get-CopilotCreditUsage {
    <# Current-cycle Copilot AI-credit usage. Fail-open, never throws: ok=$false + reason
       (gh-cli-missing | insufficient-scope | org-managed | fetch-failed) on any failure.
       -Fetcher seam receives the login and returns the raw JSON response text.
       No leading slash on the gh api path (MSYS path-rewrite hygiene). #>
    param([string]$User, [scriptblock]$Fetcher)
    $result = [ordered]@{
        ok = $false; used = $null; amount = $null; currency = 'USD'
        by_model = @(); fetched_at = (Get-Date).ToUniversalTime().ToString('o'); reason = $null
    }
    $raw = $null
    try {
        if ($Fetcher) {
            $raw = & $Fetcher (Resolve-CopilotLogin -User $User)
        } elseif ($env:BATON_COPILOT_TEST_USAGE) {
            # hermetic test seam (BATON_GO_TEST_* pattern): canned response file
            $raw = Get-Content -LiteralPath $env:BATON_COPILOT_TEST_USAGE -Raw -ErrorAction Stop
        } elseif ($env:BATON_GH_BILLING_TOKEN) {
            $login = Resolve-CopilotLogin -User $User
            if (-not $login) { $result.reason = 'fetch-failed'; return $result }
            $headers = @{ Authorization = ('Bearer ' + $env:BATON_GH_BILLING_TOKEN); Accept = 'application/vnd.github+json' }
            $resp = Invoke-RestMethod -Uri ("https://api.github.com/users/$login/settings/billing/ai_credit/usage") -Headers $headers -ErrorAction Stop
            $raw = $resp | ConvertTo-Json -Depth 10
        } else {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $result.reason = 'gh-cli-missing'; return $result }
            $login = Resolve-CopilotLogin -User $User
            if (-not $login) { $result.reason = 'fetch-failed'; return $result }
            $raw = & gh api ("users/$login/settings/billing/ai_credit/usage") 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { $result.reason = Get-CopilotFetchReason -ErrorText $raw; return $result }
        }
    } catch {
        $result.reason = Get-CopilotFetchReason -ErrorText $_.Exception.Message
        return $result
    }
    $data = $null
    try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $result.reason = 'fetch-failed'; return $result }
    $items = $data.usageItems
    if ($null -eq $items) { $result.reason = 'org-managed'; return $result }   # applicable shape absent
    $used = 0.0; $amount = 0.0
    $models = [ordered]@{}
    foreach ($it in @($items)) {
        if ([string]$it.product -ne 'Copilot AI Credits') { continue }
        $q = [double]$it.grossQuantity
        $a = [double]$it.grossAmount
        $used += $q; $amount += $a
        $m = [string]$it.model
        if (-not $m) { $m = '(unknown)' }
        if (-not $models.Contains($m)) { $models[$m] = @{ model = $m; credits = 0.0; amount = 0.0 } }
        $models[$m].credits += $q
        $models[$m].amount += $a
    }
    $result.ok = $true
    $result.used = $used
    $result.amount = [math]::Round($amount, 2)
    $result.by_model = @($models.Values | Sort-Object { -[double]$_.credits })
    return $result
}

function Get-CopilotCreditForecast {
    <# Cycle-anchored forecast: run_rate = used / days-since-reset (first-call friendly,
       no journal history needed). status: unavailable | no_budget | no_reset_anchor | ok. #>
    param(
        [string]$User,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$Fetcher
    )
    $cfg = Get-CopilotCreditConfig -FleetPath $FleetPath
    $u = Get-CopilotCreditUsage -User $User -Fetcher $Fetcher
    $result = [ordered]@{
        status = 'unavailable'; used = $null; budget = $cfg.budget; remaining = $null; pct = $null
        amount = $null; by_model = @(); reset_date = $null; days_elapsed = $null
        days_left_in_cycle = $null; run_rate = $null; days_to_exhaustion = $null
        warn = $false; warn_pct = $cfg.warn_pct; reason = $null
    }
    if (-not $u.ok) { $result.reason = $u.reason; return $result }
    $result.used = $u.used
    $result.amount = $u.amount
    $result.by_model = $u.by_model
    if ($null -eq $cfg.budget -or $cfg.budget -le 0) { $result.status = 'no_budget'; return $result }
    $result.remaining = [math]::Max(0, $cfg.budget - $u.used)
    $result.pct = [math]::Round(($u.used / $cfg.budget) * 100)   # budget > 0 guarded above
    $result.warn = ($result.pct -ge $cfg.warn_pct)
    if ($null -eq $cfg.reset_day) { $result.status = 'no_reset_anchor'; return $result }
    $nowUtc = $Now.ToUniversalTime()
    $anchor = [datetime]::new($nowUtc.Year, $nowUtc.Month, $cfg.reset_day, 0, 0, 0, [System.DateTimeKind]::Utc)
    if ($nowUtc -ge $anchor) { $lastReset = $anchor; $nextReset = $anchor.AddMonths(1) }
    else                     { $lastReset = $anchor.AddMonths(-1); $nextReset = $anchor }
    $result.reset_date = $nextReset.ToString('yyyy-MM-dd')
    $result.days_elapsed = [int][math]::Max(1, [math]::Floor(($nowUtc - $lastReset).TotalDays))  # never 0
    $result.days_left_in_cycle = [int][math]::Ceiling(($nextReset - $nowUtc).TotalDays)
    $result.run_rate = [math]::Round($u.used / $result.days_elapsed, 2)
    $result.days_to_exhaustion = if ($result.run_rate -gt 0) { [math]::Round($result.remaining / $result.run_rate, 2) } else { $null }
    $result.status = 'ok'
    return $result
}

function Write-CopilotCreditPanel {
    <# Render one /baton:usage panel. Untyped param (ordered-dict binding lesson).
       ASCII-only output (console-encoding safety). Never throws. #>
    param([Parameter(Mandatory)]$Forecast)
    Write-Host ''
    if ($Forecast.status -eq 'unavailable') {
        Write-Host ('Copilot Credits    unavailable (' + $Forecast.reason + ')')
        if ($Forecast.reason -eq 'insufficient-scope') {
            Write-Host '  fix: gh auth refresh -h github.com -s user'
        }
        return
    }
    if ($Forecast.status -eq 'no_budget') {
        Write-Host ('Copilot Credits    ' + $Forecast.used + ' used (no budget configured in fleet.yaml)')
        return
    }
    $head = 'Copilot Credits    ' + $Forecast.used + ' / ' + $Forecast.budget + '  (' + $Forecast.pct + '%)'
    if ($null -ne $Forecast.amount) {
        $head += '   ~$' + ('{0:N2}' -f [double]$Forecast.amount) + ' of $' + ('{0:N2}' -f ($Forecast.budget * 0.01))
    }
    Write-Host $head
    if ($Forecast.status -eq 'ok') {
        $line = '  run-rate ' + $Forecast.run_rate + '/day'
        if ($null -ne $Forecast.days_to_exhaustion) { $line += ' · ~' + $Forecast.days_to_exhaustion + ' days to exhaustion' }
        $line += ' · resets ' + $Forecast.reset_date + ' (' + $Forecast.days_left_in_cycle + 'd)'
        Write-Host $line
    }
    if (@($Forecast.by_model).Count -gt 0) {
        $mparts = @()
        foreach ($m in @($Forecast.by_model)) { $mparts += ($m.model + ' ' + $m.credits) }
        Write-Host ('  by model: ' + ($mparts -join ' · '))
    }
    if ($Forecast.warn) {
        Write-Host ('  WARNING: over ' + $Forecast.warn_pct + '% - check the Copilot code-review ruleset (biggest metered driver)')
    }
}
```

- [ ] **Step 2: Write the failing suite**

Create `D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1` with exactly:

```powershell
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/copilot-credit-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$savedHome = $env:BATON_HOME
$savedSeam = $env:BATON_COPILOT_TEST_USAGE
$env:BATON_HOME = $tmp

# Canned billing response: 1018 credits across 3 models + one non-Copilot row (excluded).
$fixture = @'
{
  "usageItems": [
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "GPT-5",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 612, "grossAmount": 6.12, "netQuantity": 612, "netAmount": 6.12 },
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "Claude-Sonnet",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 300, "grossAmount": 3.00, "netQuantity": 300, "netAmount": 3.00 },
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "Gemini",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 106, "grossAmount": 1.06, "netQuantity": 106, "netAmount": 1.06 },
    { "product": "Actions Minutes", "sku": "Other", "model": "n/a",
      "unitType": "minutes", "pricePerUnit": 0.008,
      "grossQuantity": 999, "grossAmount": 7.99, "netQuantity": 999, "netAmount": 7.99 }
  ]
}
'@
$fixturePath = Join-Path $tmp 'usage-fixture.json'
Set-Content -Path $fixturePath -Value $fixture -Encoding utf8NoBOM

function New-TestFleet {
    param([string]$Name, [string[]]$ExtraLines)
    $p = Join-Path $tmp $Name
    $lines = @('providers:', '  - name: gh-copilot', '    kind: cli', '    enabled: true', '    cost_tier: paid', "    command_template: 'gh models run {{model}}'")
    if ($ExtraLines) { $lines += $ExtraLines }
    Set-Content -Path $p -Value ($lines -join "`n") -Encoding utf8NoBOM
    return $p
}
$fleetFull  = New-TestFleet -Name 'fleet-full.yaml'  -ExtraLines @('    budget: 1500', '    credit_reset_day: 10')
$fleetWarn  = New-TestFleet -Name 'fleet-warn.yaml'  -ExtraLines @('    budget: 1200', '    credit_reset_day: 10')
$fleetNoRst = New-TestFleet -Name 'fleet-norst.yaml' -ExtraLines @('    budget: 1500')
$fleetBare  = New-TestFleet -Name 'fleet-bare.yaml'  -ExtraLines @()
$fleetBadRd = New-TestFleet -Name 'fleet-badrd.yaml' -ExtraLines @('    budget: 1500', '    credit_reset_day: 31')
$T0 = [datetime]::Parse('2026-07-20T12:00:00Z').ToUniversalTime()

try {
    # ---- reason classifier (pure) ----
    Check 'C1 404 -> insufficient-scope' ((Get-CopilotFetchReason -ErrorText 'HTTP 404: Not Found') -eq 'insufficient-scope')
    Check 'C2 user-scope text -> insufficient-scope' ((Get-CopilotFetchReason -ErrorText "needs the 'user' scope") -eq 'insufficient-scope')
    Check 'C3 network error -> fetch-failed' ((Get-CopilotFetchReason -ErrorText 'connection refused') -eq 'fetch-failed')

    # ---- config reader ----
    $cfg = Get-CopilotCreditConfig -FleetPath $fleetFull
    Check 'C4 config reads budget + reset day' ($cfg.budget -eq 1500 -and $cfg.reset_day -eq 10 -and $cfg.warn_pct -eq 80)
    Check 'C5 config: no fields -> nulls + default warn' ((Get-CopilotCreditConfig -FleetPath $fleetBare).budget -eq $null -and (Get-CopilotCreditConfig -FleetPath $fleetBare).warn_pct -eq 80)
    Check 'C6 config: reset day 31 out of range -> ignored' ((Get-CopilotCreditConfig -FleetPath $fleetBadRd).reset_day -eq $null)
    Check 'C7 config: missing fleet file -> nulls, no throw' ((Get-CopilotCreditConfig -FleetPath (Join-Path $tmp 'nope.yaml')).budget -eq $null)

    # ---- usage fold (injected fetcher) ----
    $u = Get-CopilotCreditUsage -Fetcher { param($login) $fixture }.GetNewClosure()
    Check 'U1 folds used across Copilot rows only' ($u.ok -and [double]$u.used -eq 1018)
    Check 'U2 folds dollar amount' ([math]::Round([double]$u.amount, 2) -eq 10.18)
    Check 'U3 by_model has 3 rows, top is GPT-5 612' (@($u.by_model).Count -eq 3 -and $u.by_model[0].model -eq 'GPT-5' -and [double]$u.by_model[0].credits -eq 612)
    Check 'U4 non-Copilot product excluded' (-not (@($u.by_model) | Where-Object { $_.model -eq 'n/a' }))

    $uThrow = Get-CopilotCreditUsage -Fetcher { param($login) throw 'HTTP 404: Not Found' }
    Check 'U5 fetcher throw 404 -> ok=false insufficient-scope' ((-not $uThrow.ok) -and $uThrow.reason -eq 'insufficient-scope')
    $uJunk = Get-CopilotCreditUsage -Fetcher { param($login) 'this is not json' }
    Check 'U6 non-JSON -> fetch-failed' ((-not $uJunk.ok) -and $uJunk.reason -eq 'fetch-failed')
    $uOrg = Get-CopilotCreditUsage -Fetcher { param($login) '{"message":"no billing here"}' }
    Check 'U7 no usageItems shape -> org-managed' ((-not $uOrg.ok) -and $uOrg.reason -eq 'org-managed')
    $uEmpty = Get-CopilotCreditUsage -Fetcher { param($login) '{"usageItems":[]}' }
    Check 'U8 empty usageItems -> ok, used 0' ($uEmpty.ok -and [double]$uEmpty.used -eq 0)

    # ---- test seam (env file) ----
    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $uSeam = Get-CopilotCreditUsage
    Check 'U9 BATON_COPILOT_TEST_USAGE seam serves the fixture' ($uSeam.ok -and [double]$uSeam.used -eq 1018)
    $env:BATON_COPILOT_TEST_USAGE = $null

    # ---- forecast branches ----
    $fx = { param($login) $fixture }.GetNewClosure()
    $f = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher $fx
    Check 'F1 status ok' ($f.status -eq 'ok')
    Check 'F2 remaining 482, pct 68' ([double]$f.remaining -eq 482 -and [int]$f.pct -eq 68)
    Check 'F3 cycle window: elapsed 10, left 21, resets 2026-08-10' ($f.days_elapsed -eq 10 -and $f.days_left_in_cycle -eq 21 -and $f.reset_date -eq '2026-08-10')
    Check 'F4 run-rate 101.8, exhaustion 4.73d' ([double]$f.run_rate -eq 101.8 -and [double]$f.days_to_exhaustion -eq 4.73)
    Check 'F5 warn false at 68% vs 80' ($f.warn -eq $false)

    $fw = Get-CopilotCreditForecast -FleetPath $fleetWarn -Now $T0 -Fetcher $fx
    Check 'F6 warn true at 85% vs 80' ($fw.warn -eq $true -and [int]$fw.pct -eq 85)

    $fBefore = Get-CopilotCreditForecast -FleetPath $fleetFull -Now ([datetime]::Parse('2026-07-05T00:00:00Z').ToUniversalTime()) -Fetcher $fx
    Check 'F7 before reset day: prior-month anchor (elapsed 25, left 5, resets 2026-07-10)' ($fBefore.days_elapsed -eq 25 -and $fBefore.days_left_in_cycle -eq 5 -and $fBefore.reset_date -eq '2026-07-10')

    $fEdge = Get-CopilotCreditForecast -FleetPath $fleetFull -Now ([datetime]::Parse('2026-07-10T00:00:00Z').ToUniversalTime()) -Fetcher $fx
    Check 'F8 at reset instant: days_elapsed clamped to 1' ($fEdge.days_elapsed -eq 1)

    $fZero = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher { param($login) '{"usageItems":[]}' }
    Check 'F9 zero usage: run_rate 0 -> exhaustion null' ([double]$fZero.run_rate -eq 0 -and $null -eq $fZero.days_to_exhaustion)

    $fNoB = Get-CopilotCreditForecast -FleetPath $fleetBare -Now $T0 -Fetcher $fx
    Check 'F10 no budget -> status no_budget, used still reported' ($fNoB.status -eq 'no_budget' -and [double]$fNoB.used -eq 1018)

    $fNoR = Get-CopilotCreditForecast -FleetPath $fleetNoRst -Now $T0 -Fetcher $fx
    Check 'F11 no reset anchor -> used/budget/pct only' ($fNoR.status -eq 'no_reset_anchor' -and [int]$fNoR.pct -eq 68 -and $null -eq $fNoR.run_rate)

    $fUn = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher { param($login) throw 'connection refused' }
    Check 'F12 fetch failure -> unavailable + reason' ($fUn.status -eq 'unavailable' -and $fUn.reason -eq 'fetch-failed')

    # ---- panel render (capture via Out-String on a child scope) ----
    $pOk = (Write-CopilotCreditPanel -Forecast $f) *>&1 | Out-String
    Check 'P1 ok panel shows used/budget/pct + run-rate + models' ($pOk -match '1018 / 1500' -and $pOk -match '68%' -and $pOk -match 'run-rate 101.8/day' -and $pOk -match 'GPT-5 612')
    $pWarn = (Write-CopilotCreditPanel -Forecast $fw) *>&1 | Out-String
    Check 'P2 warn line at threshold' ($pWarn -match 'WARNING: over 80%')
    $scope = [ordered]@{ status='unavailable'; reason='insufficient-scope' }
    $pScope = (Write-CopilotCreditPanel -Forecast $scope) *>&1 | Out-String
    Check 'P3 insufficient-scope shows the exact fix hint' ($pScope -match 'gh auth refresh -h github.com -s user')
    $pUn = (Write-CopilotCreditPanel -Forecast $fUn) *>&1 | Out-String
    Check 'P4 unavailable is one honest line' ($pUn -match 'unavailable \(fetch-failed\)')
} finally {
    $env:BATON_HOME = $savedHome
    $env:BATON_COPILOT_TEST_USAGE = $savedSeam
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) failure(s)"; exit 1 }
Write-Host "`nALL PASS"; exit 0
```

Note for the implementer: `Write-Host` output is captured by `*>&1 | Out-String` in PowerShell 7 — if P1–P4 come back empty, wrap the call as `$pOk = & { Write-CopilotCreditPanel -Forecast $f } *>&1 | Out-String` (information-stream capture through a scriptblock); do not weaken the asserts.

- [ ] **Step 3: Run the suite**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1`
Expected: `ALL PASS`, exit 0 (fix the library, not the expected values, if not).

- [ ] **Step 4: Commit**

```powershell
cd D:\Dev\Baton
git add scripts/copilot-credit-lib.ps1 scripts/test-copilot-credit-lib.ps1
git commit -m "feat(usage): copilot-credit-lib — billing fetch, cycle-anchored forecast, panel (d079)"
```

---

### Task 2: `/baton:usage` panel integration  [SONNET — integration]

**Files:**
- Modify: `D:\Dev\Baton\scripts\fleet-usage.ps1` (the `status` branch, currently lines 54–67, plus the dot-source block at line 24)
- Modify: `D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1` (append an R-series CLI section)

**Interfaces:**
- Consumes (exact, from Task 1): `Get-WorkerBudget -Worker 'gh-copilot' -FleetPath` (usage-lib, already sourced), `Get-CopilotCreditForecast -FleetPath`, `Write-CopilotCreditPanel -Forecast`, env seam `BATON_COPILOT_TEST_USAGE`.
- Produces: `status --json` gains a `copilot_credits` key ONLY when a budget is configured; non-JSON `status` gains the panel between the worker table and the coach footer. **No budget configured → output byte-for-byte unchanged (the gate check is a local file read; no fetch ever happens).**

- [ ] **Step 1: Dot-source the lib fail-open**

In `fleet-usage.ps1`, directly after the existing `try { . (Join-Path $PSScriptRoot 'coach-lib.ps1') } catch { }` line, add:

```powershell
try { . (Join-Path $PSScriptRoot 'copilot-credit-lib.ps1') } catch { }   # panel is optional (d079)
```

- [ ] **Step 2: Rework the `status` branch**

Replace the whole `'status' { ... }` case with:

```powershell
    'status' {
        $states = Get-AllWorkerStates -UsagePath $UsagePath -FleetPath $FleetPath
        $conserve = Get-ConserveMode -UsagePath $UsagePath
        # Copilot credit panel (d079): gate on a locally-configured budget BEFORE any
        # fetch, so an unconfigured box renders byte-for-byte as before. Fail-open.
        $ccForecast = $null
        if (Get-Command Get-CopilotCreditForecast -ErrorAction SilentlyContinue) {
            $ccBudget = Get-WorkerBudget -Worker 'gh-copilot' -FleetPath $FleetPath
            if ($null -ne $ccBudget) {
                try { $ccForecast = Get-CopilotCreditForecast -FleetPath $FleetPath } catch { $ccForecast = $null }
            }
        }
        if ($Json) {
            $obj = [ordered]@{ conserve_mode = $conserve; workers = @($states) }
            if ($null -ne $ccForecast) { $obj.copilot_credits = $ccForecast }
            [pscustomobject]$obj | ConvertTo-Json -Depth 6
        }
        else {
            Write-Host ("conserve_mode: {0}" -f $conserve)
            Write-Host ("{0,-18} {1,-18} {2}" -f 'WORKER','STATE','ETA/REASON')
            foreach ($s in $states) { Write-StateLine $s }
            if ($null -ne $ccForecast) { Write-CopilotCreditPanel -Forecast $ccForecast }
        }
        if (-not $Json) {
            if (Get-Command Write-CoachFooter -ErrorAction SilentlyContinue) { Write-CoachFooter -ExcludeIds @('budget') }
        }
        return
    }
```

(Everything outside the two `$ccForecast` insertions and the `$obj` assembly is today's code verbatim — verify by diff that no other line of the branch changed.)

- [ ] **Step 3: Append the R-series to `test-copilot-credit-lib.ps1`**

Insert before the `} finally {` line (still inside the `try`):

```powershell
    # ---- R-series: /baton:usage runner integration (child process, hermetic) ----
    $runner = Join-Path $PSScriptRoot 'fleet-usage.ps1'

    $outBare = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetBare 2>&1 | Out-String
    Check 'R1 no budget -> no panel, no fetch' ($outBare -notmatch 'Copilot Credits')

    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $outFull = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    Check 'R2 budget configured -> panel renders numbers' ($outFull -match 'Copilot Credits' -and $outFull -match '1018 / 1500')

    $outJson = & pwsh -NoProfile -File $runner status -Json -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    $j = $null; try { $j = $outJson | ConvertFrom-Json } catch { }
    Check 'R3 --json carries copilot_credits' ($null -ne $j -and $null -ne $j.copilot_credits -and [double]$j.copilot_credits.used -eq 1018)

    $outJsonBare = & pwsh -NoProfile -File $runner status -Json -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetBare 2>&1 | Out-String
    $jb = $null; try { $jb = $outJsonBare | ConvertFrom-Json } catch { }
    Check 'R4 --json without budget has NO copilot_credits key' ($null -ne $jb -and -not ($jb.PSObject.Properties.Name -contains 'copilot_credits'))

    $badFix = Join-Path $tmp 'bad-fixture.json'
    Set-Content -Path $badFix -Value 'not json at all' -Encoding utf8NoBOM
    $env:BATON_COPILOT_TEST_USAGE = $badFix
    $outBad = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    Check 'R5 fetch failure -> honest one-liner, runner exit 0' ($outBad -match 'unavailable \(fetch-failed\)' -and $LASTEXITCODE -eq 0)

    $outNoR = $null
    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $outNoR = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetNoRst 2>&1 | Out-String
    Check 'R6 no reset anchor -> numbers without run-rate line' ($outNoR -match '1018 / 1500' -and $outNoR -notmatch 'run-rate')
    $env:BATON_COPILOT_TEST_USAGE = $null
```

(The child `pwsh` inherits `$env:BATON_COPILOT_TEST_USAGE` — that is the point of the file seam. `$env:BATON_HOME` is already the temp dir for the whole suite. Each command line here is far below the 965-byte ceiling.)

- [ ] **Step 4: Run both suites**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1` → `ALL PASS`, exit 0.
Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-usage.ps1` → all PASS, exit 0 (proves the untouched subcommands and the pre-existing status behavior survived).

- [ ] **Step 5: Commit**

```powershell
cd D:\Dev\Baton
git add scripts/fleet-usage.ps1 scripts/test-copilot-credit-lib.ps1
git commit -m "feat(usage): Copilot credit panel in /baton:usage status (+--json copilot_credits) (d079)"
```

---

### Task 3: Deploy wiring, docs, seed placeholders, version bump  [HAIKU]

**Files:**
- Modify: `D:\Dev\Baton\scripts\bootstrap.ps1` (deploy manifest array)
- Modify: `D:\Dev\Baton\scripts\test-bootstrap.ps1` (deploy asserts, near the existing usage asserts at ~lines 47–48)
- Modify: `D:\Dev\Baton\commands\usage.md`
- Modify: `D:\Dev\Baton\references\fleet.yaml` (gh-copilot row comments)
- Modify: `D:\Dev\Baton\docs\agent-handoffs.md` (one line)
- Modify: `D:\Dev\Baton\.claude-plugin\plugin.json` (minor bump)

- [ ] **Step 1: Bootstrap manifest**

In `bootstrap.ps1`, find the big `foreach ($script in @('baton-home.ps1', ...))` deploy array and add `'copilot-credit-lib.ps1'` immediately after `'usage-lib.ps1', 'fleet-usage.ps1',` (fleet-usage is already deployed; only the new lib is missing).

- [ ] **Step 2: Bootstrap asserts**

In `test-bootstrap.ps1`, directly after the line `Assert "deploys fleet-usage script"  ($out -match 'fleet-usage\.ps1')`, add:

```powershell
Assert "deploys copilot-credit-lib script (d079 panel needs it on deployed boxes)" ($out -match 'copilot-credit-lib\.ps1')
```

- [ ] **Step 3: Command doc**

In `commands/usage.md`, insert this section between the `## Steps` block and `## Coach footer`:

```markdown
## Copilot Credits panel (d079)

When the `gh-copilot` fleet entry carries a `budget` (your monthly AI-credit
allowance), `status` appends a Copilot Credits panel: used / allowance / % /
~dollar spend, a cycle-anchored run-rate with days-to-exhaustion, the per-model
split (the finest granularity GitHub exposes for a personal account), and a
warning once usage crosses `credit_warn_pct` (default 80). No `budget` → the
panel (and the fetch) never runs. `--json` adds the same data under
`copilot_credits`.

Box-private fields on the `gh-copilot` entry in `~/.baton/fleet.yaml`:

- `budget: 1500` — monthly allowance in credits (1 credit = $0.01)
- `credit_reset_day: 10` — billing-cycle reset day-of-month (1–28)
- `credit_warn_pct: 80` — optional warn threshold

Auth: rides the ambient `gh` login; the endpoint needs the token to carry the
`user` scope — if missing, the panel shows the exact fix
(`gh auth refresh -h github.com -s user`). `BATON_GH_BILLING_TOKEN` (a PAT) is
the headless fallback. All failures collapse to one honest
`Copilot Credits — unavailable (<reason>)` line; the panel never changes the
command's exit code.
```

- [ ] **Step 4: Seed placeholders**

In `references/fleet.yaml`, on the `gh-copilot` entry, add these commented lines after its `command_template` line:

```yaml
    # Copilot credit budget (d079) — BOX-PRIVATE: set real values ONLY in your live
    # ~/.baton/fleet.yaml. The allowance/reset-day are per-account.
    # budget: 1500            # monthly Copilot AI-credit allowance (credits; 1 = $0.01)
    # credit_reset_day: 10    # billing-cycle reset day-of-month (1-28)
    # credit_warn_pct: 80     # optional warn threshold (default 80)
```

- [ ] **Step 5: Agent handoff line**

In `docs/agent-handoffs.md`, find the section listing operator surfaces / recent capabilities (match the file's existing style — one-line entries) and add:

```markdown
- `/baton:usage` shows a Copilot Credits panel (d079) when the `gh-copilot` fleet row has a `budget`; needs `gh` token `user` scope (`gh auth refresh -h github.com -s user`).
```

- [ ] **Step 6: Plugin minor bump**

Read `D:\Dev\Baton\.claude-plugin\plugin.json`, take the current `version` (e.g. `1.12.0`), and set the MINOR-bumped value with patch reset (e.g. `1.13.0`). Exact procedure:

```powershell
cd D:\Dev\Baton
$pj = Get-Content .claude-plugin/plugin.json -Raw | ConvertFrom-Json
$v = [version]$pj.version
$pj.version = "{0}.{1}.0" -f $v.Major, ($v.Minor + 1)
$pj | ConvertTo-Json -Depth 10 | Set-Content .claude-plugin/plugin.json -Encoding utf8NoBOM
Get-Content .claude-plugin/plugin.json | Select-String 'version'
```

Expected: the version line shows the new minor. (Confirm no other keys were reordered destructively — if `ConvertTo-Json` mangles the file's shape, edit the version string in place with a targeted text replace instead.)

- [ ] **Step 7: Run gate suites**

Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-bootstrap.ps1` → all asserts PASS (incl. the new one), exit 0.
Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-copilot-credit-lib.ps1` → `ALL PASS` (seed edit must not break fleet parsing; R-series still green).
Run: `pwsh -NoProfile -File D:\Dev\Baton\scripts\test-fleet-lib.ps1` → PASS (the commented seed lines are inert to Read-Fleet).

- [ ] **Step 8: Commit**

```powershell
cd D:\Dev\Baton
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/usage.md references/fleet.yaml docs/agent-handoffs.md .claude-plugin/plugin.json
git commit -m "feat(usage): deploy wiring + docs + seed placeholders + minor bump for Copilot credit panel (d079)"
```

---

### Final gate (controller)

1. Full sweep: conductor, plan-gate, gate, fleet-dispatch, fleet-lib, executor, go-execute, routing, doctor, probe, usage, copilot-credit, bootstrap — all exit 0.
2. **Opus final whole-branch review** (spec §11; streamlined ceremony — this is the only review).
3. Live smoke on the real box (needs Kevin's gh auth): set `budget`/`credit_reset_day` in live `~/.baton/fleet.yaml`, run deployed `/baton:usage`; expect either the real panel or the honest `insufficient-scope` line with the `gh auth refresh -h github.com -s user` hint (that hint path was already validated live 2026-07-06).
4. PR; **merge only on Kevin's word**; then release + `bootstrap.ps1 -Force` redeploy.

## Self-review record

- **Spec coverage:** §4.1 (usage fetch + all four reasons: C1–C3/U5–U8 + gh-cli-missing branch in code), §4.2 (forecast + all four statuses: F1–F12), §4.3 (render + --json: Step 2 Task 2, R1–R6), §5 (seed placeholders: Task 3 Step 4), §6 (auth chain incl. token fallback + scope hint: lib code + P3), §7 (fail-open, exit-code-neutral: R5), §8 (all named cases mapped to checks), §9 (bootstrap + assert + doc + handoff + bump: Task 3). Out-of-scope items (§2) not built.
- **Placeholder scan:** no TBDs; every step carries full code or an exact textual edit; the one deliberate deviation from the spec mock is `WARNING:` instead of `⚠` (console-encoding safety, noted inline).
- **Type consistency:** `Get-CopilotCreditForecast` key names match between lib, panel, R-series, and the spec's §4.2 list (spec's `reset_date/days_elapsed/days_left_in_cycle/run_rate/days_to_exhaustion` all present; additive `amount/warn/warn_pct` documented in Interfaces). `Write-CopilotCreditPanel` takes the forecast result untyped (ordered-dict binding lesson). Fixture math verified by hand: 612+300+106=1018; 1018/1500→68%; elapsed 10 → 101.8/day → 482/101.8=4.73.
