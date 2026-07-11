# Direct Model Commands + Per-Model Token Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/baton:codex|grok|gemini` direct-model slash commands over a shared, journaled, Governor-metered runner, plus per-model token capture on the fleet dispatch path and named model-tier selection.

**Architecture:** One shared runner (`fleet-ask.ps1`) delegates to the already-hardened `Invoke-Fleet`. Token capture is an additive, observe-only field derived in the CLI dispatch path (exact via a per-row regex, else an honest `len/4` estimate) and appended to the journal line as a trailing `tok:N(basis)` field. Named tiers are flat `tier_<name>` fleet.yaml keys whose arg fragments substitute a `{{tier_args}}` template token — no parser changes.

**Tech Stack:** PowerShell 7 (pwsh), existing `scripts/fleet-lib.ps1` dispatch layer, plugin command docs (`commands/*.md`), `references/fleet.yaml` seed.

## Global Constraints

Copied verbatim from the spec (`docs/superpowers/specs/2026-07-11-direct-model-commands-token-telemetry-design.md` §8) and the project house rules. Every task's requirements implicitly include this section.

- **965-byte shell-arg ceiling:** long prompts ride a temp file (`-PromptFile`), never an inline arg.
- CLI errors: `[Console]::Error.WriteLine("<msg>")` then `exit 2`. Hooks exit 0.
- All file writes: `-Encoding utf8NoBOM`.
- Arrays serialized with `ConvertTo-Json -InputObject @(...)`.
- Never name a variable `$args`, `$input`, `$event`, `$matches`, `$host`, `$pid`.
- Guard any `N/0` division (here: the `len/4` estimate — `[math]::Ceiling(0/4)` is 0, safe; no variable divisor).
- **Box-private:** real rosters/model-IDs/budgets/regexes live ONLY in the operator's live `~/.baton/fleet.yaml`. The in-repo `references/fleet.yaml` seed carries placeholder/effort-only examples — NEVER real box-private model IDs.
- **Namespace = A3:** canonical plugin-namespaced `commands/{codex,grok,gemini,agy}.md` → `/baton:codex` etc. (ship + version + bootstrap-deploy with Baton), PLUS documented (not force-deployed) bare `/codex` user aliases.
- **Token field is observe-only this slice** — no Governor/cost wiring; same discipline as d078 / Verified Labor.
- **Journal `tok:` field is appended at the very END of the line** (after `host:`/`job:`/`phase:`) so every current consumer that splits on ` | ` and prefix-matches ignores it.
- Estimates are NEVER presented as metered (the d059 honesty rule): `tokens_basis` is `exact` only when a regex matched.
- Tests are hermetic: temp fleet.yaml + temp state + `try/finally`; NEVER touch real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or `D:\dev`.

## Deviations from spec (flagged for Kevin — proceed unless vetoed)

1. Tiers = flat `tier_<name>` keys, not a nested `tiers:` map (§3.3). Zero parser changes; same capability. `{{tier_args}}` template token is preserved exactly as spec'd.
2. HTTP exact token counts (§4.1 native `prompt_eval_count`/`usage.total_tokens`) are a named follow-up; this slice ships CLI-exact + universal estimate fallback. HTTP rows report `estimate`.
3. Footer separators are ASCII `|` (not the spec's `·`/`—` glyphs), carrying forward the d079 ASCII-only console-safety fix.

---

## File Structure

- **Create** `scripts/fleet-ask.ps1` — the one shared runner behind all three commands. Resolves a provider, reads the prompt (inline or file), dispatches via `Invoke-Fleet`, prints stdout + an ASCII footer; `--tier all` boundary loop.
- **Modify** `scripts/fleet-lib.ps1` — add `Get-FleetTokenUsage`, `Get-FleetProviderTier`, `Get-FleetProviderTierNames`; thread `tokens`/`tokens_basis` through `Invoke-Fleet-Cli` + `Invoke-Fleet`; add `-Tier` + `{{tier_args}}` resolution; extend `Write-FleetJournalLine` with `-Tokens`/`-TokensBasis`.
- **Modify** `scripts/test-fleet-lib.ps1` — token + tier unit/integration checks.
- **Create** `scripts/test-fleet-ask.ps1` — child-process smoke of the runner against the stub fixture.
- **Modify** `scripts/test-hook.ps1` — FIX the pre-existing red hermeticity bug (isolate `StatePath` in the top test block).
- **Create** `commands/{codex,grok,gemini,agy}.md` — thin delegators to `fleet-ask.ps1`.
- **Modify** `references/fleet.yaml` — seed the codex row with `token_usage` + `{{tier_args}}` + effort-tier examples.
- **Modify** `scripts/bootstrap.ps1` — add `fleet-ask.ps1` to the Step-5b deploy manifest.
- **Modify** `scripts/test-bootstrap.ps1` — assert `fleet-ask.ps1` deploys.
- **Modify** `docs/agent-handoffs.md` + `.claude-plugin/plugin.json` — one handoff line + minor bump 1.14.0→1.15.0.

---

### Task 1: Get-FleetTokenUsage (pure token derivation)

**Files:**
- Modify: `scripts/fleet-lib.ps1` (add function after `Test-StdinSafe`, before `Write-FleetJournalLine` — around line 203)
- Test: `scripts/test-fleet-lib.ps1` (append a new section before the final `if ($failures ...)`)

**Interfaces:**
- Produces: `Get-FleetTokenUsage -Provider <hashtable> [-Prompt <string>] [-Stdout <string>]` → `@{ tokens = <int>; tokens_basis = 'exact'|'estimate' }`. `exact` only when the row's `token_usage` regex matches `$Stdout` with a numeric first capture group (commas/whitespace stripped); else `estimate = [math]::Ceiling((len(Prompt)+len(Stdout))/4)`.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-fleet-lib.ps1` (before the final `if ($failures -gt 0)` block):

```powershell
# ===== Get-FleetTokenUsage (token telemetry) =====
# exact: row has a token_usage regex with a numeric first capture group over stdout
$tokProvider = @{ name = 'tok'; token_usage = 'tokens used[:\s]+([\d,]+)' }
$r1 = Get-FleetTokenUsage -Provider $tokProvider -Prompt 'hi' -Stdout "did work`ntokens used: 14,350`ndone"
Assert "token exact: parses captured count" ($r1.tokens -eq 14350)
Assert "token exact: basis is exact"        ($r1.tokens_basis -eq 'exact')

# no regex on the row -> estimate over (prompt+stdout) length / 4
$estProvider = @{ name = 'est' }
$r2 = Get-FleetTokenUsage -Provider $estProvider -Prompt 'abcd' -Stdout 'efgh'   # 8 chars -> ceil(8/4)=2
Assert "token estimate: len/4"        ($r2.tokens -eq 2)
Assert "token estimate: basis is estimate" ($r2.tokens_basis -eq 'estimate')

# regex present but no match in stdout -> estimate (honest fallback, d059)
$r3 = Get-FleetTokenUsage -Provider $tokProvider -Prompt '' -Stdout 'no counter here'
Assert "token regex-no-match: falls back to estimate" ($r3.tokens_basis -eq 'estimate')

# empty prompt + empty stdout -> 0 tokens, no divide error
$r4 = Get-FleetTokenUsage -Provider $estProvider -Prompt '' -Stdout ''
Assert "token empty: zero tokens, no crash" ($r4.tokens -eq 0 -and $r4.tokens_basis -eq 'estimate')
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: FAIL — `Get-FleetTokenUsage` is not defined (the four new asserts fail / the script errors on the unknown command).

- [ ] **Step 3: Implement Get-FleetTokenUsage**

Insert into `scripts/fleet-lib.ps1` immediately after the `Test-StdinSafe` function closes (after line 202):

```powershell
function Get-FleetTokenUsage {
    <# Derive a token count + basis from a CLI provider's stdout.
       Returns @{ tokens = <int>; tokens_basis = 'exact'|'estimate' }.
       exact  : the row has a `token_usage` regex whose FIRST capture group is a
                number (commas/whitespace stripped) present in stdout.
       estimate: no field / no match -> ceil((len(prompt)+len(stdout))/4). The d059
                honesty rule: an estimate is never labelled exact. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [string]$Prompt = '',
        [string]$Stdout = ''
    )
    $regex = [string]$Provider.token_usage
    if ($regex) {
        $m = [regex]::Match($Stdout, $regex)
        if ($m.Success -and $m.Groups.Count -ge 2) {
            $digits = $m.Groups[1].Value -replace '[,\s]', ''
            $n = 0
            if ([int]::TryParse($digits, [ref]$n)) {
                return @{ tokens = $n; tokens_basis = 'exact' }
            }
        }
    }
    $len = $Prompt.Length + $Stdout.Length
    return @{ tokens = [int][math]::Ceiling($len / 4); tokens_basis = 'estimate' }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: PASS — all four new asserts pass, existing asserts unaffected, final line "All tests passed" / exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1
git commit -m "feat(fleet): Get-FleetTokenUsage — exact-regex + honest estimate token basis"
```

---

### Task 2: Thread tokens through dispatch + journal

**Files:**
- Modify: `scripts/fleet-lib.ps1` — `Invoke-Fleet-Cli` (both return sites), `Invoke-Fleet` (normalize + journal call), `Write-FleetJournalLine` (new params + trailing field)
- Test: `scripts/test-fleet-lib.ps1`

**Interfaces:**
- Consumes: `Get-FleetTokenUsage` (Task 1).
- Produces:
  - `Invoke-Fleet-Cli` return hashtable gains `tokens` (int) + `tokens_basis` (string).
  - `Invoke-Fleet` return hashtable carries `tokens` + `tokens_basis` for BOTH cli and http paths (http normalized to `estimate` when the hatch omits them).
  - `Write-FleetJournalLine -Tokens <int> -TokensBasis <string>` appends ` | tok:<n>(<basis>)` as the LAST field.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-fleet-lib.ps1` (after the Task-1 section):

```powershell
# ===== token threading: journal tok: field + Invoke-Fleet return =====
$tokJournal = Join-Path $env:TEMP "fleet-tok-$(Get-Random).md"
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "notok-$(Get-Random).json")
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 1 -ExitCode 0 -Prompt 'p' `
        -JournalPath $tokJournal -Tokens 4242 -TokensBasis 'exact'
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$tline = @(Get-Content $tokJournal)[-1]
Assert "journal tok field present"     ($tline -match '\| tok:4242\(exact\)\s*$')
Assert "journal tok is the LAST field" ($tline.TrimEnd() -match 'tok:4242\(exact\)$')
Remove-Item $tokJournal -ErrorAction SilentlyContinue

# Invoke-Fleet threads tokens/basis into its return (stub-cli has no regex -> estimate)
$tokState = Join-Path $env:TEMP "fleet-tokret-$(Get-Random).json"
$env:CAO_STATE_PATH = $tokState
try {
    $tr = Invoke-Fleet -Name 'stub-cli' -Prompt 'hello' -Path $fixture -NoJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "Invoke-Fleet return has tokens key"     ($tr.ContainsKey('tokens'))
Assert "Invoke-Fleet return has tokens_basis"   ($tr.tokens_basis -eq 'estimate')
Assert "Invoke-Fleet estimate tokens > 0"       ($tr.tokens -gt 0)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: FAIL — `Write-FleetJournalLine` has no `-Tokens` param (parameter-binding error) and `$tr` has no `tokens` key.

- [ ] **Step 3a: Extend Write-FleetJournalLine**

In `scripts/fleet-lib.ps1`, add two params to `Write-FleetJournalLine`'s `param(...)` block (after the `$OriginHost` param, before the closing `)` at line ~217):

```powershell
        ,
        [int]$Tokens = 0,
        [string]$TokensBasis = 'estimate'
```

Then, after the job/phase `try { ... } catch { }` block (after line 238) and BEFORE the `$dir = Split-Path ...` line (line 240), insert the trailing-field append:

```powershell
    # Trailing token field (observe-only). Appended AFTER host:/job:/phase: so every
    # consumer that splits on ' | ' and prefix-matches ignores it (spec §4.2).
    $line += " | tok:$Tokens($TokensBasis)"
```

- [ ] **Step 3b: Thread tokens through Invoke-Fleet-Cli**

In `scripts/fleet-lib.ps1`, replace the success return (line 351):

```powershell
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration }
```

with:

```powershell
        $tok = Get-FleetTokenUsage -Provider $Provider -Prompt $Prompt -Stdout ([string]$out)
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration; tokens = $tok.tokens; tokens_basis = $tok.tokens_basis }
```

and replace the catch return (line 354):

```powershell
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration }
```

with:

```powershell
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration; tokens = 0; tokens_basis = 'estimate' }
```

- [ ] **Step 3c: Normalize + journal in Invoke-Fleet**

In `scripts/fleet-lib.ps1`, inside `Invoke-Fleet`, AFTER the kind-dispatch `if/elseif/else` assigns `$result` (after line 394) and BEFORE the `if (-not $NoJournal)` block (line 396), insert normalization:

```powershell
    # Normalize token fields so both cli and http paths carry them. HTTP hatches
    # that do not emit native counts fall back to an honest estimate (exact native
    # counts are a named follow-up, spec §4.1).
    if (-not $result.ContainsKey('tokens')) {
        $tok = Get-FleetTokenUsage -Provider $provider -Prompt $Prompt -Stdout ([string]$result.stdout)
        $result.tokens = $tok.tokens
        $result.tokens_basis = $tok.tokens_basis
    }
```

Then replace the journal call (lines 397-398):

```powershell
        Write-FleetJournalLine -Provider $Name -DurationS $result.duration_s `
            -ExitCode $result.exit_code -Prompt $Prompt -JournalPath $JournalPath
```

with:

```powershell
        Write-FleetJournalLine -Provider $Name -DurationS $result.duration_s `
            -ExitCode $result.exit_code -Prompt $Prompt -JournalPath $JournalPath `
            -Tokens $result.tokens -TokensBasis $result.tokens_basis
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: PASS — new token-threading asserts pass; existing fleet-line asserts (lines 64-100) still pass (the `tok:` field is trailing and does not disturb their prefix matches).

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1
git commit -m "feat(fleet): thread per-model tokens through dispatch + journal tok: field"
```

---

### Task 3: Named tier selection ({{tier_args}})

**Files:**
- Modify: `scripts/fleet-lib.ps1` — add `Get-FleetProviderTier` + `Get-FleetProviderTierNames`; add `-Tier` to `Resolve-FleetCommand`, `Invoke-Fleet-Cli`, `Invoke-Fleet`; resolve `{{tier_args}}` in all four substitution sites
- Test: `scripts/test-fleet-lib.ps1`

**Interfaces:**
- Consumes: `Read-Fleet` flat `tier_<name>` keys; optional `tier_default: <name>`.
- Produces:
  - `Get-FleetProviderTierNames -Provider <hashtable>` → `string[]` of tier names (the `tier_*` keys minus `tier_default`), sorted.
  - `Get-FleetProviderTier -Provider <hashtable> [-Tier <name>]` → the arg fragment `string` for the named tier (or `tier_default`'s, or `''`).
  - `-Tier <name>` on `Resolve-FleetCommand`, `Invoke-Fleet-Cli`, `Invoke-Fleet`. `{{tier_args}}` in a `command_template` is replaced by the resolved fragment (default `''`) in every dispatch branch.

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test-fleet-lib.ps1`:

```powershell
# ===== named tiers ({{tier_args}}) =====
$tierP = @{ name = 't'; command_template = 'run {{tier_args}} "{{prompt}}"';
            tier_low = '-e low'; tier_high = '-e high'; tier_default = 'low' }
Assert "tier names exclude tier_default" (@(Get-FleetProviderTierNames -Provider $tierP) -join ',' -eq 'high,low')
Assert "tier fragment by name"           ((Get-FleetProviderTier -Provider $tierP -Tier 'high') -eq '-e high')
Assert "tier fragment falls to default"  ((Get-FleetProviderTier -Provider $tierP) -eq '-e low')
Assert "unknown tier -> empty fragment"  ((Get-FleetProviderTier -Provider $tierP -Tier 'nope') -eq '')

# {{tier_args}} resolves through Resolve-FleetCommand
$rc = Resolve-FleetCommand -Provider $tierP -Prompt 'hi' -Tier 'high'
Assert "Resolve substitutes {{tier_args}}" ($rc -eq 'run -e high "hi"')
$rcDefault = Resolve-FleetCommand -Provider $tierP -Prompt 'hi'
Assert "Resolve uses tier_default"         ($rcDefault -eq 'run -e low "hi"')

# a row with no tiers: {{tier_args}} -> '' (byte-for-byte no-op besides spacing)
$noTierP = @{ name = 'n'; command_template = 'run {{tier_args}} "{{prompt}}"' }
$rcNone = Resolve-FleetCommand -Provider $noTierP -Prompt 'x'
Assert "no tiers -> {{tier_args}} empty" ($rcNone -eq 'run  "x"')

# dispatch through a temp fleet.yaml with a tier provider (stdin-promoted stub)
$tierDir = Join-Path $env:TEMP "baton-tier-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tierDir | Out-Null
$tierYaml = Join-Path $tierDir 'fleet.yaml'
Set-Content -Path $tierYaml -Encoding utf8NoBOM -Value @'
providers:
  - name: tierstub
    kind: cli
    enabled: true
    cost_tier: free
    tier_hi: '-Command "Write-Output tier-hi"'
    command_template: 'pwsh -NoProfile {{tier_args}} "{{prompt}}"'
'@
$env:CAO_STATE_PATH = (Join-Path $tierDir 'nostate.json')
try {
    $td = Invoke-Fleet -Name 'tierstub' -Prompt 'ignored' -Path $tierYaml -Tier 'hi' -NoJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "tier fragment reaches dispatch" (($td.stdout | Out-String) -match 'tier-hi')
Remove-Item $tierDir -Recurse -Force -ErrorAction SilentlyContinue
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: FAIL — `Get-FleetProviderTierNames`/`Get-FleetProviderTier` undefined; `{{tier_args}}` left literal in resolved commands.

- [ ] **Step 3a: Add the tier helpers**

Insert into `scripts/fleet-lib.ps1` after `Get-FleetTokenUsage` (Task 1):

```powershell
function Get-FleetProviderTierNames {
    <# Named tiers on a provider = its flat `tier_<name>` keys, excluding the
       `tier_default` selector. Returns a sorted string[] (empty if none). #>
    param([Parameter(Mandatory)][hashtable]$Provider)
    return @($Provider.Keys |
        Where-Object { $_ -like 'tier_*' -and $_ -ne 'tier_default' } |
        ForEach-Object { $_.Substring(5) } | Sort-Object)
}

function Get-FleetProviderTier {
    <# The arg fragment for a named tier. -Tier missing -> the `tier_default`
       tier's fragment; unknown/absent -> '' (an empty {{tier_args}} slot). #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [string]$Tier
    )
    $name = if ($Tier) { $Tier } else { [string]$Provider.tier_default }
    if (-not $name) { return '' }
    $val = $Provider["tier_$name"]
    if ($null -eq $val) { return '' }
    return [string]$val
}
```

- [ ] **Step 3b: Resolve {{tier_args}} in Resolve-FleetCommand**

In `scripts/fleet-lib.ps1`, add a `-Tier` param to `Resolve-FleetCommand` (after the `[string]$Model` param, line ~166):

```powershell
        [string]$Model,
        [string]$Tier
```

Then, in `Resolve-FleetCommand`, after the `$cmd = $template.Replace('{{prompt}}', $Prompt)` line (line 181) and the `{{model}}` replace (line 182), add the tier replace:

```powershell
    $cmd = $cmd.Replace('{{tier_args}}', (Get-FleetProviderTier -Provider $Provider -Tier $Tier))
```

- [ ] **Step 3c: Resolve {{tier_args}} in the three Invoke-Fleet-Cli branches**

In `Invoke-Fleet-Cli`, add a `-Tier` param (after `[string]$Model`, line 253):

```powershell
        [string]$Model,
        [string]$Tier,
```

In the `$usePromptFile` branch, after its `{{model}}` replace (line 271), add:

```powershell
        $cmd = $cmd.Replace('{{tier_args}}', (Get-FleetProviderTier -Provider $Provider -Tier $Tier))
```

In the `$useStdin` branch, after its `{{model}}` replace (line 278), add:

```powershell
        $cmd = $cmd.Replace('{{tier_args}}', (Get-FleetProviderTier -Provider $Provider -Tier $Tier))
```

In the `else` (legacy) branch, replace the single line (line 280):

```powershell
        $cmd = Resolve-FleetCommand -Provider $Provider -Prompt $Prompt -Model $Model
```

with:

```powershell
        $cmd = Resolve-FleetCommand -Provider $Provider -Prompt $Prompt -Model $Model -Tier $Tier
```

- [ ] **Step 3d: Thread -Tier through Invoke-Fleet**

In `Invoke-Fleet`, add a `-Tier` param (after `[string]$Model`, line 368):

```powershell
        [string]$Model,
        [string]$Tier,
```

Then pass it to the cli dispatch (line 378):

```powershell
        $result = Invoke-Fleet-Cli -Provider $provider -Prompt $Prompt -Model $Model -Tier $Tier
```

(The http path takes no tier — http hatches have no `{{tier_args}}` template; leave line 391 unchanged.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-lib.ps1`
Expected: PASS — tier asserts pass; all prior asserts still pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-lib.ps1 scripts/test-fleet-lib.ps1
git commit -m "feat(fleet): named tier selection via {{tier_args}} (--tier)"
```

---

### Task 4: fleet-ask.ps1 shared runner + smoke tests

**Files:**
- Create: `scripts/fleet-ask.ps1`
- Test: `scripts/test-fleet-ask.ps1`

**Interfaces:**
- Consumes: `Invoke-Fleet` (with `-Tier`), `Get-FleetProvider`, `Get-FleetProviderTierNames`.
- Produces: `fleet-ask.ps1 -Provider <name> [-Prompt <inline>] [-PromptFile <path>] [-Tier <name|all>] [-FleetPath <path>]`. Prints provider stdout then an ASCII footer `-- <provider> | <Ns> | exit:<code> | tok:<n>(<basis>)`. Unknown/disabled provider or missing prompt → stderr + `exit 2`. Exit code = provider exit code (or worst across tiers for `--tier all`).

- [ ] **Step 1: Write the failing smoke tests**

Create `scripts/test-fleet-ask.ps1`:

```powershell
#!/usr/bin/env pwsh
# Child-process smoke of scripts/fleet-ask.ps1 against the stub fixture.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner  = Join-Path $here 'fleet-ask.ps1'
$fixture = Join-Path $here 'fixtures\fleet-sample.yaml'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# stub-cli echoes 'hello-<prompt>'; isolate state so no job/phase tags leak.
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "ask-nostate-$(Get-Random).json")
$env:CAO_FLEET_HOST = 'testbox'
try {
    $out = & pwsh -NoProfile -File $runner -Provider 'stub-cli' -Prompt 'world' -FleetPath $fixture 2>&1 | Out-String
    Assert "prints provider stdout"     ($out -match 'hello-world')
    Assert "prints ASCII footer w/ tok" ($out -match '-- stub-cli \| \d+s \| exit:0 \| tok:\d+\((exact|estimate)\)')

    # unknown provider -> stderr + exit 2
    & pwsh -NoProfile -File $runner -Provider 'does-not-exist' -Prompt 'x' -FleetPath $fixture 2>$null | Out-Null
    Assert "unknown provider exits 2" ($LASTEXITCODE -eq 2)

    # missing prompt -> exit 2
    & pwsh -NoProfile -File $runner -Provider 'stub-cli' -FleetPath $fixture 2>$null | Out-Null
    Assert "missing prompt exits 2" ($LASTEXITCODE -eq 2)

    # -PromptFile is read (965-byte escape hatch)
    $pf = Join-Path $env:TEMP "ask-prompt-$(Get-Random).txt"
    Set-Content -Path $pf -Value 'fromfile' -Encoding utf8NoBOM
    $out2 = & pwsh -NoProfile -File $runner -Provider 'stub-cli' -PromptFile $pf -FleetPath $fixture 2>&1 | Out-String
    Assert "-PromptFile is honored" ($out2 -match 'hello-fromfile')
    Remove-Item $pf -ErrorAction SilentlyContinue
} finally {
    Remove-Item env:CAO_STATE_PATH, env:CAO_FLEET_HOST -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "`n$failures failed" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll tests passed" -ForegroundColor Green; exit 0 }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pwsh -NoProfile -File scripts/test-fleet-ask.ps1`
Expected: FAIL — `fleet-ask.ps1` does not exist (child pwsh errors; asserts fail).

- [ ] **Step 3: Implement fleet-ask.ps1**

Create `scripts/fleet-ask.ps1`:

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared runner behind /baton:codex|grok|gemini|agy — dispatch one fleet model,
  journaled + Governor-metered, and print its answer + a token footer.
.DESCRIPTION
  Delegates to Invoke-Fleet (the hardened dispatch path). Reads the prompt inline
  or from a file (the 965-byte escape hatch). `--tier all` runs every named tier
  (boundary tester). Errors politely: unknown/disabled provider or missing prompt
  -> stderr + exit 2.
#>
param(
    [Parameter(Mandatory)][string]$Provider,
    [string]$Prompt,
    [string]$PromptFile,
    [string]$Tier,
    [string]$FleetPath
)

. "$PSScriptRoot/fleet-lib.ps1"

function Write-AskError($msg) { [Console]::Error.WriteLine($msg) }

# Resolve the fleet.yaml path (test override -> BATON_HOME default).
$path = if ($FleetPath) { $FleetPath } else { Join-Path (Get-BatonHome) 'fleet.yaml' }

$prov = Get-FleetProvider -Name $Provider -Path $path
if (-not $prov) { Write-AskError "provider '$Provider' not found in $path"; exit 2 }
if ($prov.enabled -ne $true) { Write-AskError "provider '$Provider' is disabled in fleet.yaml"; exit 2 }

# Prompt: file wins (long/quote-heavy), else inline.
$promptText = if ($PromptFile) {
    if (-not (Test-Path $PromptFile)) { Write-AskError "prompt file not found: $PromptFile"; exit 2 }
    Get-Content -LiteralPath $PromptFile -Raw
} else { $Prompt }
if ([string]::IsNullOrWhiteSpace($promptText)) { Write-AskError "no prompt given (-Prompt or -PromptFile)"; exit 2 }

function Invoke-One($tierName) {
    $r = Invoke-Fleet -Name $Provider -Prompt $promptText -Path $path -Tier $tierName
    Write-Host ([string]$r.stdout)
    $label = if ($tierName) { "$Provider/$tierName" } else { $Provider }
    Write-Host "-- $label | $($r.duration_s)s | exit:$($r.exit_code) | tok:$($r.tokens)($($r.tokens_basis))"
    return [int]$r.exit_code
}

if ($Tier -eq 'all') {
    $names = @(Get-FleetProviderTierNames -Provider $prov)
    if ($names.Count -eq 0) { Write-AskError "provider '$Provider' defines no tiers"; exit 2 }
    $worst = 0
    foreach ($n in $names) {
        Write-Host "=== tier: $n ==="
        $code = Invoke-One $n
        if ($code -ne 0) { $worst = $code }
    }
    exit $worst
} else {
    exit (Invoke-One $Tier)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pwsh -NoProfile -File scripts/test-fleet-ask.ps1`
Expected: PASS — stdout printed, footer matches, unknown/missing → exit 2, `-PromptFile` honored.

- [ ] **Step 5: Commit**

```bash
git add scripts/fleet-ask.ps1 scripts/test-fleet-ask.ps1
git commit -m "feat(fleet): fleet-ask.ps1 shared runner for direct-model commands"
```

---

### Task 5: Command docs + seed + deploy wiring + version bump

**Files:**
- Create: `commands/codex.md`, `commands/grok.md`, `commands/gemini.md`, `commands/agy.md`
- Modify: `references/fleet.yaml` (codex row: `token_usage` + `{{tier_args}}` + effort-tier examples)
- Modify: `scripts/bootstrap.ps1` (Step-5b manifest: add `fleet-ask.ps1`)
- Modify: `scripts/test-bootstrap.ps1` (assert `fleet-ask.ps1` deploys)
- Modify: `docs/agent-handoffs.md` (one line), `.claude-plugin/plugin.json` (1.14.0→1.15.0)

**Interfaces:**
- Consumes: `fleet-ask.ps1` (Task 4).
- Produces: `/baton:codex`, `/baton:grok`, `/baton:gemini`, `/baton:agy` slash commands.

- [ ] **Step 1: Write the failing deploy assert**

In `scripts/test-bootstrap.ps1`, after the `copilot-credit-lib` assert (line 49), add:

```powershell
Assert "deploys fleet-ask script (direct-model commands need it on-box)" ($out -match 'fleet-ask\.ps1')
```

- [ ] **Step 2: Run to verify it fails**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: FAIL — `fleet-ask.ps1` not yet in the deploy manifest.

- [ ] **Step 3a: Add fleet-ask.ps1 to the bootstrap manifest**

In `scripts/bootstrap.ps1` Step-5b (line 259), add `'fleet-ask.ps1'` to the deployed-scripts array — insert right after `'fleet-lib.ps1'`:

```powershell
'fleet-lib.ps1', 'fleet-ask.ps1', 'fleet-doctor.ps1',
```

- [ ] **Step 3b: Seed the codex row in references/fleet.yaml**

In `references/fleet.yaml`, replace the codex `command_template` line (line 119):

```yaml
    command_template: 'codex exec --sandbox workspace-write "{{prompt}}"'
```

with the tier-enabled template + token regex + effort-tier examples (effort flags are generic codex options — NOT box-private):

```yaml
    command_template: 'codex exec --sandbox workspace-write {{tier_args}} "{{prompt}}"'
    # Per-model token capture (observe-only). ONE capture group over stdout; commas
    # stripped. No match -> honest len/4 estimate (never labelled exact).
    token_usage: 'tokens used[:\s]+([\d,]+)'
    # Named tiers: --tier <name> substitutes the fragment at {{tier_args}}; --tier all
    # runs every tier (boundary tester). Real model IDs (5.6 | Sol/Tera/Luna) are
    # BOX-PRIVATE — add `tier_sol/tera/luna: '-m <model-id> ...'` in your live
    # ~/.baton/fleet.yaml. These effort-only examples are generic codex flags:
    tier_low:  '-c model_reasoning_effort=low'
    tier_med:  '-c model_reasoning_effort=medium'
    tier_high: '-c model_reasoning_effort=high'
```

- [ ] **Step 3c: Write the four command docs**

Create `commands/codex.md`:

```markdown
---
description: Ask Codex directly — one journaled, Governor-metered dispatch through Baton's hardened fleet path. `--tier <name>` selects a model/effort tier; `--tier all` boundary-tests every tier.
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:codex

Send a one-shot prompt to the **codex** fleet provider and print its answer.
Unlike a raw `codex exec`, this call is journaled to the model-routing log and
metered by the Usage Governor, and it reuses Baton's hardened prompt transport
(stdin / temp-file), so quotes and long prompts are safe.

## Steps

1. **Parse `$ARGUMENTS`.** Split off an optional trailing `--tier <name>` (or
   `--tier all`); everything else is the prompt. Empty prompt → print usage, stop.

2. **Write the prompt to a temp file** when it exceeds ~900 bytes or contains
   quotes (the 965-byte rule), then dispatch with `-PromptFile`; otherwise pass
   `-Prompt` inline:

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider codex -PromptFile "<tmp>" [-Tier <name>]
   ```

3. **Relay** the model's stdout verbatim to the user, then the footer line
   (`-- codex | <N>s | exit:<code> | tok:<n>(<basis>)`). `tok:` is observe-only;
   `exact` means a real token count was captured, `estimate` means len/4.

Bare `/codex` alias: to type `/codex` instead of `/baton:codex`, copy this file
to `~/.claude/commands/codex.md` (documented, not force-deployed — namespace A3).
```

Create `commands/grok.md` (identical structure, provider `grok-cli`, title `/baton:grok`, footer `-- grok-cli ...`, alias note for `~/.claude/commands/grok.md`; grok tokens fall back to estimate — note that):

```markdown
---
description: Ask Grok (xAI CLI) directly — one journaled, Governor-metered dispatch through Baton's hardened fleet path (quote-safe temp-file transport).
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:grok

Send a one-shot prompt to the **grok-cli** fleet provider and print its answer,
journaled + Governor-metered. Grok's prompt rides a temp file (quote-safe).

## Steps

1. **Parse `$ARGUMENTS`.** Split off optional `--tier <name>`/`--tier all`; the
   rest is the prompt. Empty → usage, stop.

2. **Dispatch** (long/quote-heavy prompts via `-PromptFile`, the 965-byte rule):

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider grok-cli -PromptFile "<tmp>" [-Tier <name>]
   ```

3. **Relay** stdout + the footer. grok has no token regex yet → `tok:` shows an
   honest `estimate`.

Bare `/grok` alias: copy this file to `~/.claude/commands/grok.md` (namespace A3).
```

Create `commands/gemini.md` (provider `gemini-antigravity`, title `/baton:gemini`; note the box-private caveat that agy inline transport breaks on embedded double quotes → route quote-free prompts):

```markdown
---
description: Ask Gemini Antigravity (agy) directly — one journaled, Governor-metered dispatch through Baton's fleet path.
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:gemini

Send a one-shot prompt to the **gemini-antigravity** (agy) provider and print its
answer, journaled + Governor-metered.

## Steps

1. **Parse `$ARGUMENTS`.** Split off optional `--tier <name>`/`--tier all`; the
   rest is the prompt. Empty → usage, stop.

2. **Dispatch** — agy interpolates the prompt inline (it does not read stdin), so
   embedded double quotes break it; route quote-free prompts, and use `-PromptFile`
   only for length, not quoting:

   ```powershell
   & pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-ask.ps1" -Provider gemini-antigravity -Prompt "<prompt>" [-Tier <name>]
   ```

3. **Relay** stdout + the footer (`tok:` = estimate; agy has no token regex).

Bare `/gemini` alias: copy this file to `~/.claude/commands/gemini.md` (A3).
```

Create `commands/agy.md` (a thin alias pointing at the same runner + provider — one paragraph):

```markdown
---
description: Alias of /baton:gemini — ask Gemini Antigravity (agy) directly through Baton's journaled fleet path.
argument-hint: "<prompt>  [--tier <name>|all]"
---

# /baton:agy

Alias for [/baton:gemini](gemini.md). Parses `$ARGUMENTS` identically and
dispatches to the **gemini-antigravity** provider via
`$HOME/.claude/scripts/fleet-ask.ps1 -Provider gemini-antigravity`. See
`/baton:gemini` for the quote-free-prompt caveat.
```

- [ ] **Step 3d: Handoff line + version bump**

Append one line under the appropriate section of `docs/agent-handoffs.md`:

```markdown
- **Direct-model commands (#2, v1.15.0):** `/baton:codex|grok|gemini|agy "<prompt>" [--tier <name>|all]` → `scripts/fleet-ask.ps1` → `Invoke-Fleet` (journaled + metered). Per-model tokens land as a trailing `tok:N(exact|estimate)` field on the fleet journal line (observe-only). Tiers = flat `tier_<name>` fleet.yaml keys → `{{tier_args}}`.
```

Bump `.claude-plugin/plugin.json`:

```json
  "version": "1.15.0",
```

- [ ] **Step 4: Run the deploy assert to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-bootstrap.ps1`
Expected: PASS — including the new `deploys fleet-ask script` assert.

- [ ] **Step 5: Commit**

```bash
git add commands/codex.md commands/grok.md commands/gemini.md commands/agy.md references/fleet.yaml scripts/bootstrap.ps1 scripts/test-bootstrap.ps1 docs/agent-handoffs.md .claude-plugin/plugin.json
git commit -m "feat(commands): /baton:codex|grok|gemini|agy + seed + deploy wiring (v1.15.0)"
```

---

### Task 6: Fix the red test-hook hermeticity + consumer-safety sweep

**Files:**
- Modify: `scripts/test-hook.ps1` (isolate `StatePath` in the top block)
- Verify: full suite sweep + fleet-line consumer grep

**Interfaces:**
- Consumes: nothing new. Produces: `test-hook.ps1` deterministically green regardless of any active job on the box; confirmation that no fleet-journal consumer breaks on the new `tok:` field.

- [ ] **Step 1: Reproduce the red test**

Run: `pwsh -NoProfile -File scripts/test-hook.ps1`
Expected (when a job is active on the box): FAIL `pipe-in-command produces 5 pipe-separated fields` — actual 7 (the hook read the real `~/.baton/current-job.json` and appended `| job:X | phase:Y`). This is a hermeticity leak, not a format regression.

- [ ] **Step 2: Isolate the state path in the top block**

In `scripts/test-hook.ps1`, wrap the first test block so every hook invocation reads a non-existent state file. Change the `try {` at line 23 to first point `CAO_STATE_PATH` at a temp path that does not exist, and clear it in the `finally`:

Replace line 23 (`try {`) with:

```powershell
$env:CAO_STATE_PATH = Join-Path $env:TEMP "test-hook-nostate-$(Get-Random).json"
try {
```

And in the `finally` block at line 117-119, add the env cleanup alongside the file removal:

```powershell
} finally {
    Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
    Remove-Item $tmpLog, $tmpErr -ErrorAction SilentlyContinue
}
```

(The hook's `StatePath` default honors `$env:CAO_STATE_PATH` first — line 28 of `log-tool-call.ps1` — so pointing it at a non-existent file guarantees no job/phase tags, making Test 6's field count deterministically 5. The Plan-3 sub-block below already sets/clears `CAO_STATE_PATH` per case and is unaffected.)

- [ ] **Step 3: Run test-hook to verify it passes**

Run: `pwsh -NoProfile -File scripts/test-hook.ps1`
Expected: PASS — `pipe-in-command produces 5 pipe-separated fields` now actual 5; all other asserts pass; exit 0.

- [ ] **Step 4: Consumer-safety grep + full sweep**

Confirm no fleet-journal-line consumer is broken by the trailing `tok:` field (it is appended last; consumers prefix-match on ` | `). Grep for parsers, then run the whole suite:

Run: `git grep -nE "fleet \\\\\\|| -split ' \\\\\\| '|split.*\\| fleet" scripts/`
Expected: the matches are `test-fleet-lib.ps1` (updated here) and `test-hook.ps1` (which parses `| hook |`, a different source). Confirm none count fleet-line fields by position past the fixed prefix; if any does, it is a real break — STOP and report.

Run the full sweep: `pwsh -NoProfile -File scripts/run-all-tests.ps1` (or the repo's sweep entry point; if none, run each `scripts/test-*.ps1`).
Expected: all suites green EXCEPT the known pre-existing `test-otel-parser.ps1` failure (`claude_code.` prefix stripped) which is unrelated to this branch. `test-hook.ps1` is now green (this task fixed it).

- [ ] **Step 5: Commit**

```bash
git add scripts/test-hook.ps1
git commit -m "fix(test): isolate test-hook state path — deterministic 5-field journal assert"
```

---

## Self-Review

**1. Spec coverage** (against `2026-07-11-direct-model-commands-token-telemetry-design.md`):
- §3.1 shared runner `fleet-ask.ps1` — Task 4. ✅
- §3.2 three command docs, A3 namespace + agy alias — Task 5. ✅
- §3.3 tier selection (`{{tier_args}}` + `--tier` + `--tier all`) — Task 3 (mechanism) + Task 4 (`all` loop) + Task 5 (seed). Represented as flat `tier_<name>` keys (Deviation 1). ✅
- §4.1 token field (exact regex / estimate) — Task 1; HTTP native counts deferred (Deviation 2). ✅
- §4.2 return shape + journal `tok:` appended at end — Task 2. ✅
- §4.3 seed codex regex; claude json deferred; grok/agy estimate — Task 5 + noted in docs. ✅
- §5 bootstrap deploy-assert + AGENTS/handoff line + plugin bump — Task 5. ✅
- §6 hermetic tests + consumer-safety grep — Tasks 1-4 + 6. ✅
- The "must FIX test-hook 5-field" requirement — Task 6. ✅

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/uncoded steps — every code step carries complete code. ✅

**3. Type consistency:** `tokens` (int) + `tokens_basis` (string) used identically in `Get-FleetTokenUsage` return, `Invoke-Fleet-Cli` return, `Invoke-Fleet` return, and `Write-FleetJournalLine` params. `Get-FleetProviderTier`/`Get-FleetProviderTierNames` signatures match their call sites in Task 3 tests and Task 4 runner. `-Tier` param name consistent across `Resolve-FleetCommand`, `Invoke-Fleet-Cli`, `Invoke-Fleet`, `fleet-ask.ps1`. ✅

## Execution Handoff

Model ladder (streamlined ceremony — no per-task reviewers; ONE final Opus whole-branch review):
- Task 1 — **Haiku** (pure function, complete code)
- Task 2 — **Sonnet** (dispatch + journal integration edit)
- Task 3 — **Sonnet** (dispatch-core multi-site integration)
- Task 4 — **Haiku** (new file, complete code)
- Task 5 — **Haiku** (docs + seed + wiring, complete code)
- Task 6 — **Haiku** (mechanical test fix + specified sweep)
- Final whole-branch review — **Opus**
