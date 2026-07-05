# Fleet Does the Labor — Slice 1: Round-Trip Proof + Prompt Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Baton a `fleet doctor --live` probe that proves each enabled instrument actually answers a real prompt, and harden the CLI dispatch path so real (large/quoted) prompts survive.

**Architecture:** A new pure-plus-seamed `fleet-probe-lib.ps1` sends a fixed canary prompt through `Invoke-Fleet` to every enabled provider and classifies the result (canary-token match, judge-free). `fleet-doctor.ps1` gains a `--live` pass over the same roster. Separately, `Invoke-Fleet-Cli` switches to the existing stdin dispatch path for providers whose template ends in a standalone quoted `"{{prompt}}"`, immunizing real prompts against the 965-byte / quote-mangling wall.

**Tech Stack:** PowerShell 7 (pwsh), the existing `fleet-lib.ps1` dispatch, `Start-ThreadJob` (bundled ThreadJob module) for the probe timeout guard.

## Global Constraints

Every task's requirements implicitly include these (spec §11):

- Every shell command arg < 965 bytes; large prompts go via file/stdin.
- CLI/script errors: `[Console]::Error.WriteLine(...)` + `exit 2` (never `Write-Error` under `Stop`). `fleet-doctor.ps1` keeps its existing exit-code contract (0 = all enabled ok, 1 = any enabled bad).
- All file writes use `-Encoding utf8NoBOM`.
- `ConvertFrom-Json` auto-parses ISO dates to `[datetime]` — re-stringify on round-trip. `ConvertTo-Json` guaranteed-array output uses `-InputObject @(...)`.
- Never name PowerShell vars `$args` / `$input` / `$event` / `$matches` / `$host` / `$pid`.
- Unary-comma flatten `,([object[]]$x)` ONLY on direct-assignment returns; use `@($x)` when callers pipe.
- Guard `0/0` NaN in any division (this slice has none — assert none is introduced).
- Box-private: never write real roster/endpoint values into the shared seed `fleet.yaml`; placeholder hosts only. The live probe reads the box-private live roster at run time.
- Tests are hermetic: temp `fleet.yaml` fixtures, temp `BATON_HOME`, `try/finally` restore. NEVER touch real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or `D:\dev`.
- The canary prompt constant is exactly `Reply with exactly the word PONG and nothing else.` and the token constant is exactly `PONG`.

## File Structure

- **Create** `scripts/fleet-probe-lib.ps1` — canary constants, `Test-FleetCanary` (pure classifier), `Test-ProviderReachable` (reachability, injectable URL probe), `Invoke-FleetProbe` (per-provider live round-trip with timeout guard + injectable dispatcher).
- **Create** `scripts/test-fleet-probe-lib.ps1` — unit tests for the three functions (fake dispatcher / injected URL probe; every branch).
- **Modify** `scripts/fleet-lib.ps1` — `Invoke-Fleet-Cli` gains `Test-StdinSafe` predicate + stdin-default routing.
- **Modify** `scripts/test-fleet-dispatch.ps1` — add predicate + stdin-default regression asserts.
- **Modify** `scripts/fleet-doctor.ps1` — `-Live`, `-TimeoutS`, `-Json` live rendering + exit contract.
- **Modify** `scripts/test-fleet-doctor.ps1` — end-to-end `--live` asserts.
- **Modify** `scripts/bootstrap.ps1` — add `fleet-probe-lib.ps1` to the deploy manifest.
- **Modify** `scripts/test-bootstrap.ps1` — add a deploy assert for `fleet-probe-lib.ps1`.
- **Modify** `commands/fleet.md` — document `doctor --live [--timeout <s>] [--json]`.
- **Modify** `AGENTS.md` — one line: `fleet doctor --live` as the model-agnostic roster verification.
- **Modify** `.claude-plugin/plugin.json` — version bump `1.9.0` → `1.10.0-rc.1`.

---

### Task 1: Canary classifier + reachability (`fleet-probe-lib.ps1` part 1)

**Files:**
- Create: `scripts/fleet-probe-lib.ps1`
- Test: `scripts/test-fleet-probe-lib.ps1`

**Interfaces:**
- Produces:
  - `$script:FleetCanaryPrompt` = `'Reply with exactly the word PONG and nothing else.'`
  - `$script:FleetCanaryToken` = `'PONG'`
  - `Test-FleetCanary -Output <string> -ExitCode <int> -TimedOut <bool>` → `@{ live = 'live_ok'|'live_fail'; reason = <string|$null> }`. Reason values: `timeout`, `nonzero-exit`, `no-canary`, or `$null` when `live_ok`.
  - `Test-ProviderReachable -Provider <hashtable> [-UrlProbe <scriptblock>]` → `@{ reachable = <bool>; reason = $null|'not-on-PATH'|'unreachable' }`. `-UrlProbe` takes a URL string, returns `$true` reachable / `$false` not; default does `Invoke-WebRequest -Method Head -TimeoutSec 5 -UseBasicParsing`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-fleet-probe-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
# Tests for scripts/fleet-probe-lib.ps1 — canary classifier, reachability, live probe.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-probe-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- Test-FleetCanary (pure) ---
$c1 = Test-FleetCanary -Output 'PONG' -ExitCode 0 -TimedOut $false
Assert "canary: exact token -> live_ok"        ($c1.live -eq 'live_ok' -and $null -eq $c1.reason)
$c2 = Test-FleetCanary -Output 'the answer is pong.' -ExitCode 0 -TimedOut $false
Assert "canary: case-insensitive substring -> live_ok" ($c2.live -eq 'live_ok')
$c3 = Test-FleetCanary -Output 'usage: codex [options]' -ExitCode 0 -TimedOut $false
Assert "canary: exit 0 but no token -> no-canary" ($c3.live -eq 'live_fail' -and $c3.reason -eq 'no-canary')
$c4 = Test-FleetCanary -Output 'PONG' -ExitCode 3 -TimedOut $false
Assert "canary: nonzero exit beats token -> nonzero-exit" ($c4.live -eq 'live_fail' -and $c4.reason -eq 'nonzero-exit')
$c5 = Test-FleetCanary -Output '' -ExitCode 0 -TimedOut $true
Assert "canary: timeout beats all -> timeout" ($c5.live -eq 'live_fail' -and $c5.reason -eq 'timeout')

# --- Test-ProviderReachable ---
$cliOk = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='pwsh -NoProfile -Command "x"' }
Assert "reachable: pwsh on PATH -> reachable" ($cliOk.reachable -eq $true -and $null -eq $cliOk.reason)
$cliNo = Test-ProviderReachable -Provider @{ name='p'; kind='cli'; command_template='definitely-not-a-real-binary-xyz foo' }
Assert "reachable: missing binary -> not-on-PATH" ($cliNo.reachable -eq $false -and $cliNo.reason -eq 'not-on-PATH')
$httpOk = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $true }
Assert "reachable: http probe true -> reachable" ($httpOk.reachable -eq $true)
$httpNo = Test-ProviderReachable -Provider @{ name='h'; kind='http'; base_url='http://x' } -UrlProbe { param($u) $false }
Assert "reachable: http probe false -> unreachable" ($httpNo.reachable -eq $false -and $httpNo.reason -eq 'unreachable')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-probe-lib.ps1`
Expected: FAIL — `fleet-probe-lib.ps1` does not exist / functions not defined.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/fleet-probe-lib.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet round-trip probe (Slice 1). Sends a canary prompt to an enabled provider
  and classifies whether it actually answered. Judge-free: a deterministic token.
.NOTES
  Pure classifier (Test-FleetCanary) + reachability (Test-ProviderReachable) +
  live round-trip (Invoke-FleetProbe, added in Task 2). Diagnostic only — never
  mutates state, never throws on a provider failure.
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet, Invoke-Fleet, Get-FleetProvider

$script:FleetCanaryPrompt = 'Reply with exactly the word PONG and nothing else.'
$script:FleetCanaryToken  = 'PONG'

function Test-FleetCanary {
    <# Pure. Classify a dispatch result into a live verdict + reason.
       Precedence: timeout > nonzero-exit > token-match. #>
    param(
        [string]$Output,
        [int]$ExitCode = 0,
        [bool]$TimedOut = $false
    )
    if ($TimedOut)        { return @{ live = 'live_fail'; reason = 'timeout' } }
    if ($ExitCode -ne 0)  { return @{ live = 'live_fail'; reason = 'nonzero-exit' } }
    if (([string]$Output).ToUpperInvariant().Contains($script:FleetCanaryToken)) {
        return @{ live = 'live_ok'; reason = $null }
    }
    return @{ live = 'live_fail'; reason = 'no-canary' }
}

function Test-ProviderReachable {
    <# Is the provider's transport up? cli -> binary on PATH; http -> base_url HEAD.
       -UrlProbe injects the reachability check for tests. Returns @{reachable;reason}. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [scriptblock]$UrlProbe
    )
    if (-not $UrlProbe) {
        $UrlProbe = {
            param($url)
            try { Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null; return $true }
            catch { return $false }
        }
    }
    if ($Provider.kind -eq 'cli') {
        $bin = ([string]$Provider.command_template -split '\s+')[0]
        if (Get-Command $bin -ErrorAction SilentlyContinue) { return @{ reachable = $true; reason = $null } }
        return @{ reachable = $false; reason = 'not-on-PATH' }
    }
    if ($Provider.kind -eq 'http') {
        if (& $UrlProbe ([string]$Provider.base_url)) { return @{ reachable = $true; reason = $null } }
        return @{ reachable = $false; reason = 'unreachable' }
    }
    # Unknown kind: treat as unreachable rather than throwing.
    return @{ reachable = $false; reason = 'unreachable' }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-fleet-probe-lib.ps1`
Expected: PASS — all 9 asserts green.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-probe-lib.ps1 scripts/test-fleet-probe-lib.ps1
git commit -m "feat(fleet): canary classifier + reachability probe (Slice 1 part 1)"
```

---

### Task 2: Live round-trip with timeout guard (`fleet-probe-lib.ps1` part 2)

**Files:**
- Modify: `scripts/fleet-probe-lib.ps1` (append `Invoke-FleetProbe`)
- Test: `scripts/test-fleet-probe-lib.ps1` (append live-probe asserts)

**Interfaces:**
- Consumes: `Test-FleetCanary`, `Test-ProviderReachable`, `$script:FleetCanaryPrompt` (Task 1); `Invoke-Fleet` (fleet-lib).
- Produces:
  - `Invoke-FleetProbe -Provider <hashtable> [-TimeoutS <int>=60] [-FleetPath <string>] [-Dispatcher <scriptblock>] [-UrlProbe <scriptblock>]` → per-provider result hashtable:
    `@{ name; kind; enabled; reachable; live; reason; elapsed_s }`.
    - `live` ∈ `live_ok | live_fail | skip`.
    - `reason` ∈ `$null | disabled | not-on-PATH | unreachable | timeout | nonzero-exit | no-canary | dispatch-error`.
    - Disabled provider → `@{ live='skip'; reason='disabled'; reachable=$null; elapsed_s=$null }`.
  - `-Dispatcher` contract (for tests): a scriptblock invoked as `& $Dispatcher $Provider $FleetPath $CanaryPrompt $ScriptRoot`, returning `@{ stdout=<string>; exit_code=<int> }` (matching `Invoke-Fleet`'s shape). It runs inside a `Start-ThreadJob`, so a fake may `Start-Sleep` to exercise the timeout path.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-fleet-probe-lib.ps1` BEFORE the final tally block:

```powershell
# --- Invoke-FleetProbe (live round-trip) ---
# Fake dispatchers returning the Invoke-Fleet shape @{stdout;exit_code}.
$okDisp    = { param($prov,$fp,$canary,$root) @{ stdout = 'PONG'; exit_code = 0 } }
$noTokDisp = { param($prov,$fp,$canary,$root) @{ stdout = 'help text here'; exit_code = 0 } }
$failDisp  = { param($prov,$fp,$canary,$root) @{ stdout = ''; exit_code = 7 } }
$slowDisp  = { param($prov,$fp,$canary,$root) Start-Sleep -Seconds 5; @{ stdout = 'PONG'; exit_code = 0 } }
$throwDisp = { param($prov,$fp,$canary,$root) throw 'boom' }

$enabledCli = @{ name='w'; kind='cli'; enabled=$true; command_template='pwsh -NoProfile -Command "x"' }

$rSkip = Invoke-FleetProbe -Provider @{ name='d'; kind='cli'; enabled=$false; command_template='pwsh x' }
Assert "probe: disabled -> skip"        ($rSkip.live -eq 'skip' -and $rSkip.reason -eq 'disabled')

$rOk = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $okDisp
Assert "probe: token -> live_ok"        ($rOk.live -eq 'live_ok' -and $rOk.reachable -eq $true)
Assert "probe: live_ok records elapsed" ($rOk.elapsed_s -ge 0)

$rNo = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $noTokDisp
Assert "probe: no token -> no-canary"   ($rNo.live -eq 'live_fail' -and $rNo.reason -eq 'no-canary')

$rFail = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $failDisp
Assert "probe: nonzero exit -> nonzero-exit" ($rFail.reason -eq 'nonzero-exit')

$rSlow = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $slowDisp -TimeoutS 1
Assert "probe: slow dispatch -> timeout" ($rSlow.reason -eq 'timeout')

$rThrow = Invoke-FleetProbe -Provider $enabledCli -Dispatcher $throwDisp
Assert "probe: throwing dispatch -> dispatch-error" ($rThrow.reason -eq 'dispatch-error')

$rUnreach = Invoke-FleetProbe -Provider @{ name='h'; kind='http'; enabled=$true; base_url='http://x' } -UrlProbe { param($u) $false }
Assert "probe: http down -> unreachable (no dispatch)" ($rUnreach.live -eq 'live_fail' -and $rUnreach.reason -eq 'unreachable')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-probe-lib.ps1`
Expected: FAIL — `Invoke-FleetProbe` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/fleet-probe-lib.ps1`:

```powershell
function Invoke-FleetProbe {
    <# Per-provider live round-trip. Reachability precheck -> dispatch a canary
       under an enforced timeout -> classify. Diagnostic: never throws. The
       dispatch runs in a Start-ThreadJob so a hung/slow provider is bounded;
       a timed-out native child may linger (best-effort Stop-Job) — acceptable
       for a diagnostic. -Dispatcher injects for tests. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [int]$TimeoutS = 60,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [scriptblock]$Dispatcher,
        [scriptblock]$UrlProbe
    )
    $name = [string]$Provider.name
    $kind = [string]$Provider.kind
    if ($Provider.enabled -ne $true) {
        return @{ name = $name; kind = $kind; enabled = $false; reachable = $null; live = 'skip'; reason = 'disabled'; elapsed_s = $null }
    }
    $reach = Test-ProviderReachable -Provider $Provider -UrlProbe $UrlProbe
    if (-not $reach.reachable) {
        return @{ name = $name; kind = $kind; enabled = $true; reachable = $false; live = 'live_fail'; reason = $reach.reason; elapsed_s = $null }
    }
    if (-not $Dispatcher) {
        $Dispatcher = {
            param($prov, $fleetPath, $canary, $scriptRoot)
            . (Join-Path $scriptRoot 'fleet-lib.ps1')
            Invoke-Fleet -Name ([string]$prov.name) -Prompt $canary -Path $fleetPath -NoJournal
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false; $output = ''; $exit = 0; $errored = $false
    $threadJob = $null
    try {
        $threadJob = Start-ThreadJob -ScriptBlock $Dispatcher -ArgumentList $Provider, $FleetPath, $script:FleetCanaryPrompt, $PSScriptRoot
        $done = Wait-Job -Job $threadJob -Timeout $TimeoutS
        if (-not $done) {
            $timedOut = $true
            Stop-Job -Job $threadJob -ErrorAction SilentlyContinue
        } else {
            $disp = Receive-Job -Job $threadJob -ErrorAction Stop
            $output = [string]$disp.stdout
            $exit = [int]$disp.exit_code
        }
    } catch {
        $errored = $true
    } finally {
        if ($threadJob) { Remove-Job -Job $threadJob -Force -ErrorAction SilentlyContinue }
        $sw.Stop()
    }
    $elapsed = [int]$sw.Elapsed.TotalSeconds
    if ($errored) {
        return @{ name = $name; kind = $kind; enabled = $true; reachable = $true; live = 'live_fail'; reason = 'dispatch-error'; elapsed_s = $elapsed }
    }
    $verdict = Test-FleetCanary -Output $output -ExitCode $exit -TimedOut $timedOut
    return @{ name = $name; kind = $kind; enabled = $true; reachable = $true; live = $verdict.live; reason = $verdict.reason; elapsed_s = $elapsed }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-fleet-probe-lib.ps1`
Expected: PASS — all asserts green (the timeout case takes ~1s).

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-probe-lib.ps1 scripts/test-fleet-probe-lib.ps1
git commit -m "feat(fleet): live round-trip probe with timeout guard (Slice 1 part 2)"
```

---

### Task 3: stdin-default for clean-tail CLI templates (`Invoke-Fleet-Cli`)

**Files:**
- Modify: `scripts/fleet-lib.ps1` (add `Test-StdinSafe`; branch in `Invoke-Fleet-Cli`)
- Test: `scripts/test-fleet-dispatch.ps1` (append asserts)

**Interfaces:**
- Produces: `Test-StdinSafe -Provider <hashtable>` → `[bool]`. `$true` when the provider is not already `stdin:true` AND its `command_template` ends in a standalone quoted prompt token (regex `\s+(["'])\{\{prompt\}\}\1\s*$`) AND the template with that trailing token removed contains no shell operators (`|`, `>`, `<`, `&`, `;`, backtick, or `$(`).
- Behavior: when `Test-StdinSafe` is true, `Invoke-Fleet-Cli` strips the trailing quoted `{{prompt}}`, resolves `{{model}}` in the remainder, tokenizes it, and pipes the raw prompt via the existing temp-file→stdin mechanism. When false, the legacy interpolation path runs unchanged. Providers already `stdin:true` keep their current stdin behavior.

**Why this predicate:** it captures the real interpolating providers (`claude -p "{{prompt}}"`, `codex exec "{{prompt}}"`, `agy --print "{{prompt}}"`, `gh copilot suggest "{{prompt}}"`, `ollama run {{model}} "{{prompt}}"`) while leaving embedded-prompt templates — including the test stubs `pwsh -NoProfile -Command "Write-Output hello-{{prompt}}"` — on the legacy path, so `test-fleet-dispatch.ps1`'s `hello-world` / `m123:p` assertions do not regress.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-fleet-dispatch.ps1` BEFORE its final tally block. (It already dot-sources `fleet-lib.ps1` and defines `Assert` and `$fixture`.)

```powershell
# --- Test-StdinSafe predicate ---
Assert "stdin-safe: trailing quoted prompt (codex)" (Test-StdinSafe -Provider @{ name='c'; command_template='codex exec "{{prompt}}"' })
Assert "stdin-safe: trailing quoted prompt with model (ollama)" (Test-StdinSafe -Provider @{ name='o'; command_template='ollama run {{model}} "{{prompt}}"'; model_default='m' })
Assert "stdin-safe: embedded prompt -> legacy (test stub)" (-not (Test-StdinSafe -Provider @{ name='s'; command_template='pwsh -NoProfile -Command "Write-Output hello-{{prompt}}"' }))
Assert "stdin-safe: shell operator in tail -> legacy" (-not (Test-StdinSafe -Provider @{ name='p'; command_template='foo | bar "{{prompt}}"' }))
Assert "stdin-safe: already stdin:true -> not re-flagged" (-not (Test-StdinSafe -Provider @{ name='h'; stdin=$true; command_template='claude -p --model x' }))

# --- Regression: embedded-prompt stubs still interpolate ---
$tmpJ = New-TemporaryFile
$rReg = Invoke-Fleet -Name 'stub-cli' -Prompt 'world' -Path $fixture -JournalPath $tmpJ
Assert "regression: stub-cli still outputs hello-world (legacy path)" (($rReg.stdout | Out-String).Trim() -eq 'hello-world')
Remove-Item $tmpJ -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1`
Expected: FAIL — `Test-StdinSafe` not defined.

- [ ] **Step 3: Write minimal implementation**

In `scripts/fleet-lib.ps1`, add `Test-StdinSafe` immediately after `Resolve-FleetCommand` (after line 182):

```powershell
function Test-StdinSafe {
    <# True when a cli provider's template can safely pipe the prompt via stdin:
       not already stdin, template ends in a standalone quoted {{prompt}}, and the
       command minus that tail has no shell operators. Keeps embedded-prompt and
       shell-wrapped templates on the legacy interpolation path. #>
    param([Parameter(Mandatory)][hashtable]$Provider)
    if ($Provider.stdin -eq $true) { return $false }
    $template = [string]$Provider.command_template
    if (-not $template) { return $false }
    if ($template -notmatch '\s+(["''])\{\{prompt\}\}\1\s*$') { return $false }
    $head = $template -replace '\s+(["''])\{\{prompt\}\}\1\s*$', ''
    if ($head -match '[|><&;`]' -or $head -match '\$\(') { return $false }
    return $true
}
```

Then in `Invoke-Fleet-Cli`, replace the dispatch-path decision. The current body resolves the command then branches on `$Provider.stdin -eq $true`. Change it so the stdin path is taken when EITHER the provider is `stdin:true` OR `Test-StdinSafe` is true, and in the `Test-StdinSafe` case build the stdin command from the template with the trailing quoted prompt stripped. Concretely, replace the command-resolution + branch prologue:

```powershell
    # Decide dispatch path. stdin:true providers already omit {{prompt}};
    # clean-tail interpolating providers are promoted to stdin (prompt-size /
    # quote hardening) by stripping the trailing quoted {{prompt}} token.
    $useStdin = ($Provider.stdin -eq $true) -or (Test-StdinSafe -Provider $Provider)
    if ($Provider.stdin -eq $true) {
        $cmd = Resolve-FleetCommand -Provider $Provider -Prompt '' -Model $Model
    } elseif (Test-StdinSafe -Provider $Provider) {
        $stripped = ([string]$Provider.command_template) -replace '\s+(["''])\{\{prompt\}\}\1\s*$', ''
        $resolvedModel = if ($Model) { $Model } else { $Provider.model_default }
        if ($null -ne $resolvedModel) { $stripped = $stripped.Replace('{{model}}', [string]$resolvedModel) }
        $cmd = $stripped
    } else {
        $cmd = Resolve-FleetCommand -Provider $Provider -Prompt $Prompt -Model $Model
    }
```

…and change the existing `if ($Provider.stdin -eq $true) {` guard around the stdin/legacy blocks to `if ($useStdin) {`. Leave the stdin block body (temp-file write, tokenize `$cmd`, `& $exe @rest`) and the legacy `else` block (`Invoke-Expression $cmd`) otherwise unchanged.

> **Note for the implementer:** `Resolve-FleetCommand` with `-Prompt ''` for `stdin:true` providers reproduces today's behavior (their templates have no `{{prompt}}`; only `{{model}}` is substituted). Verify the existing stdin providers' tests still pass — do not alter `Resolve-FleetCommand`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1`
Expected: PASS — new predicate + regression asserts green, existing `hello-world` / `m123:p` / http asserts unchanged.

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: PASS — no regressions.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-lib.ps1 scripts/test-fleet-dispatch.ps1
git commit -m "feat(fleet): stdin-default for clean-tail CLI templates (Slice 1 prompt hardening)"
```

---

### Task 4: `fleet doctor --live` surface + end-to-end tests

**Files:**
- Modify: `scripts/fleet-doctor.ps1`
- Test: `scripts/test-fleet-doctor.ps1`

**Interfaces:**
- Consumes: `Invoke-FleetProbe` (Task 2), `Read-Fleet` (fleet-lib).
- Behavior: `fleet-doctor.ps1` gains `-Live` (switch), `-TimeoutS` (int, default 60), keeps `-Json`. Default (no `-Live`) path is byte-for-byte unchanged. With `-Live`: iterate enabled+disabled providers via `Invoke-FleetProbe`; render a live table (human) or the result-array (`-Json`); exit 0 iff every enabled provider is `live_ok`, else 1.

- [ ] **Step 1: Write the failing test**

Append to `scripts/test-fleet-doctor.ps1` BEFORE its final tally block:

```powershell
# --- fleet doctor --live (end-to-end, real Invoke-Fleet against fixture) ---
# Fixture roster: stub-cli/stub-with-model/stub-with-env (echo prompt -> contains
# PONG -> live_ok), stub-disabled (skip), stub-http (localhost:9999 -> unreachable),
# stub-fail (no {{prompt}} -> dispatch throws -> dispatch-error), stub-slow (sleep 10
# -> timeout at --timeout 3). Mixed roster -> exit 1.
$liveOut = & pwsh -NoProfile -File $doctor -Path $fixture -Live -TimeoutS 3 2>&1 | Out-String
$liveExit = $LASTEXITCODE
Assert "live: stub-cli reports live_ok"        ($liveOut -match 'stub-cli\s+.*live_ok')
Assert "live: stub-disabled reports skip"      ($liveOut -match 'stub-disabled\s+.*skip')
Assert "live: stub-http reports unreachable"   ($liveOut -match 'stub-http\s+.*(live_fail|unreachable)')
Assert "live: exit 1 on a mixed roster"        ($liveExit -eq 1)

# --json shape
$liveJson = & pwsh -NoProfile -File $doctor -Path $fixture -Live -TimeoutS 3 -Json 2>&1 | Out-String
$parsedLive = $liveJson | ConvertFrom-Json
$cliRow = @($parsedLive | Where-Object { $_.name -eq 'stub-cli' })
Assert "live --json: stub-cli row carries live=live_ok" ($cliRow.Count -eq 1 -and $cliRow[0].live -eq 'live_ok')

# All-live_ok roster -> exit 0 (hermetic single-provider temp yaml)
$tmpYaml = New-TemporaryFile
@'
providers:
  - name: only-ok
    kind: cli
    enabled: true
    cost_tier: free
    command_template: 'pwsh -NoProfile -Command "Write-Output PONG-{{prompt}}"'
'@ | Set-Content -LiteralPath $tmpYaml -Encoding utf8NoBOM
$okOut = & pwsh -NoProfile -File $doctor -Path $tmpYaml -Live -TimeoutS 10 2>&1 | Out-String
$okExit = $LASTEXITCODE
Assert "live: all-live_ok roster -> exit 0" ($okExit -eq 0)
Remove-Item $tmpYaml -ErrorAction SilentlyContinue

# Default (non-live) path unchanged: still reports PATH-based skip/err and exit 1
$plainOut = & pwsh -NoProfile -File $doctor -Path $fixture 2>&1 | Out-String
Assert "non-live path still reports stub-disabled skip" ($plainOut -match 'stub-disabled\s+skip')
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-fleet-doctor.ps1`
Expected: FAIL — `-Live` / `-TimeoutS` not recognized; no live output.

- [ ] **Step 3: Write minimal implementation**

In `scripts/fleet-doctor.ps1`:

1. Extend `param(...)`:

```powershell
param(
    [string]$Path = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'fleet.yaml' } else { Join-Path $HOME '.baton/fleet.yaml' }),
    [switch]$Json,
    [switch]$Live,
    [int]$TimeoutS = 60
)
```

2. After the existing `. (Join-Path $PSScriptRoot 'fleet-lib.ps1')`, add:

```powershell
if ($Live) { . (Join-Path $PSScriptRoot 'fleet-probe-lib.ps1') }
```

3. After the `try { $fleet = Read-Fleet ... }` block, add a `--live` branch that returns before the legacy loop:

```powershell
if ($Live) {
    $results = foreach ($p in $fleet) { Invoke-FleetProbe -Provider ([hashtable]$p) -TimeoutS $TimeoutS -FleetPath $Path }
    $rows = @($results)
    if ($Json) {
        ConvertTo-Json -InputObject @($rows) -Depth 4
    } else {
        $render = $rows | ForEach-Object {
            $reach = if ($null -eq $_.reachable) { '-' } elseif ($_.reachable) { 'yes' } else { 'no' }
            $detail = if ($_.reason) { $_.reason } elseif ($null -ne $_.elapsed_s) { "$($_.elapsed_s)s" } else { '' }
            [pscustomobject]@{ PROVIDER = $_.name; REACHABLE = $reach; LIVE = $_.live; DETAIL = $detail }
        }
        $render | Format-Table PROVIDER, REACHABLE, LIVE, DETAIL -AutoSize | Out-String | Write-Host
        $enabled = @($fleet | Where-Object { $_.enabled -eq $true }).Count
        Write-Host "$enabled enabled provider(s); live round-trip."
    }
    $anyLiveBad = @($rows | Where-Object { $_.enabled -eq $true -and $_.live -ne 'live_ok' }).Count -gt 0
    if ($anyLiveBad) { exit 1 } else { exit 0 }
}
```

(The existing non-live loop and its exit logic remain untouched below this branch.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-doctor.ps1`
Expected: PASS — live asserts + `--json` + exit-0/exit-1 + the unchanged non-live assert all green. (Runs ~3s for the timeout case.)

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-doctor.ps1 scripts/test-fleet-doctor.ps1
git commit -m "feat(fleet): fleet doctor --live round-trip surface (Slice 1)"
```

---

### Task 5: Deploy wiring, docs, version bump

**Files:**
- Modify: `scripts/bootstrap.ps1`
- Modify: `scripts/test-bootstrap.ps1`
- Modify: `commands/fleet.md`
- Modify: `AGENTS.md`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:** none (integration/config task).

- [ ] **Step 1: Add the new lib to the deploy manifest**

In `scripts/bootstrap.ps1`, find the Step 5b manifest array of script basenames (the same list that gained `session-markers-lib.ps1`, `registry-lib.ps1`, `fleet-project.ps1`). Add `'fleet-probe-lib.ps1'` to it. (Do NOT add test-*.ps1 files or hooks.)

- [ ] **Step 2: Add the deploy assert (v1.8.0 coach-lib omission lesson)**

In `scripts/test-bootstrap.ps1`, mirror the existing deploy asserts (e.g. the `registry-lib.ps1` one) with:

```powershell
Assert "deploys fleet-probe-lib.ps1" (Test-Path (Join-Path $deployDir 'fleet-probe-lib.ps1'))
```

- [ ] **Step 3: Run the bootstrap test to verify green**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — the new deploy assert green, prior count + 1, 0 FAIL.

- [ ] **Step 4: Document `--live` in the command doc**

In `commands/fleet.md`: update the front-matter `description`/`argument-hint` to mention `doctor [--live] [--timeout <s>]`, and in the `doctor` dispatch block add a note + invocation:

```powershell
& pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-doctor.ps1" -Live -TimeoutS 60
```

with one line explaining: `--live` sends a `PONG` canary to each enabled provider and reports `live_ok | live_fail(reason) | skip`; a `no-canary` reason means the provider ran but didn't answer (often a wrong command template for this box). Plain (no `--live`) stays the fast PATH/reachability check.

- [ ] **Step 5: Add the AGENTS.md line**

In `AGENTS.md`, near the fleet/model-agnostic material, add one line:

> `fleet doctor --live` — harness-neutral way to verify a box's roster actually answers (canary round-trip per enabled provider), not just that the binaries are installed.

- [ ] **Step 6: Bump the plugin version**

In `.claude-plugin/plugin.json`, change `"version": "1.9.0"` to `"version": "1.10.0-rc.1"`.

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 commands/fleet.md AGENTS.md .claude-plugin/plugin.json
git commit -m "chore(fleet): deploy wiring + docs + v1.10.0-rc.1 (Slice 1)"
```

---

## Global test sweep (run after Task 5, before final review)

```
pwsh -NoProfile -File scripts/test-fleet-probe-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-dispatch.ps1
pwsh -NoProfile -File scripts/test-fleet-lib.ps1
pwsh -NoProfile -File scripts/test-fleet-doctor.ps1
pwsh -NoProfile -File scripts/test-bootstrap.ps1
pwsh -NoProfile -File scripts/test-conductor-lib.ps1
```

All must be green (0 FAIL) — the last two guard against deploy-manifest and dispatch regressions.

## Notes for the executor

- Model ladder: Task 1, 2, 4, 5 are transcription-grade (complete code above) → **haiku**; Task 3 edits hot dispatch code with a regex predicate → **sonnet**. Streamlined ceremony: no per-task reviewers; one **opus** whole-branch review at the end.
- The `Start-ThreadJob` timeout guard may leave a hung native child running after a `timeout` verdict (best-effort `Stop-Job`). This is an accepted Slice-1 limitation for a diagnostic — note it, don't chase it.
- Out of scope (do not build): the `-Spawner` executor that applies repo changes (Slice 2), any routing/`Select-Capability` change, per-provider latency/quality benchmarking.

## Self-Review

**Spec coverage:** §Design.1 surface → Task 4. §Design.2 canary contract (prompt/token/pass/reasons/timeout/result-shape) → Tasks 1+2. §Design.3 stdin-default → Task 3. §Design.4 legibility (table + `--json`) → Task 4. §Design.5 hermetic tests (fake dispatcher, temp fixtures) → Tasks 1–4. §Design.6 deploy/docs/bump → Task 5. All covered. (Deviation from spec's 6 reasons: added `dispatch-error` for a thrown dispatch — necessary and documented in Task 2's interface.)

**Placeholder scan:** no TBD/TODO; every code step carries complete code; the one predicate is pinned to an exact regex with both-direction tests.

**Type consistency:** `Invoke-FleetProbe` result keys (`name/kind/enabled/reachable/live/reason/elapsed_s`) are consumed identically in Task 4's render/JSON and asserts; `Test-FleetCanary` return (`live/reason`) and `Test-ProviderReachable` return (`reachable/reason`) match their call sites; `Test-StdinSafe` returns `[bool]` used in `Invoke-Fleet-Cli` and tests.
