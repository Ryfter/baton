# Verified Labor V1 — verification contract library — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `scripts/verification-lib.ps1` — the pure verification-contract layer of d082 (Slice V1): trusted profile resolution frozen from a base commit, preset sugar, argv-only lint, containment, protected-path hashing, a Windows-native argv runner, expected-file evaluation with the A5 content bar, deterministic evidence grading, and a single façade result object. **No conductor changes** — new files only, plus bootstrap wiring.

**Architecture:** One dot-sourceable library (pattern: `fleet-executor-lib.ps1` — small pure functions, git plumbing via `& git -C`, fail-behavior explicit per function) + one seeded JSON presets file + one hermetic suite. The spine is `codex-ringer.md` §5–§7/§12–§13 with d082 adjudications A5 (content bar) and A7 (platform-variant presets).

**Tech stack:** PowerShell 7 (pwsh), `System.Diagnostics.Process` with `ArgumentList` (never a shell string), `git show`/`hash-object`-free SHA256 via .NET, JSON everywhere (`ConvertFrom-Json -AsHashtable`).

## Global Constraints (binding — d082 §4 + house rules)

- argv-only execution: reject `sh|bash|zsh|dash -c`, `cmd /c|/k`, `pwsh|powershell -Command/-EncodedCommand` (and abbreviations), `python|python3|py -c`, `node -e|--eval`, `perl -e`, `ruby -e` — case-insensitive, on the resolved leaf of argv[0].
- All contract paths (cwd, expect_files, protected_paths) must resolve INSIDE the worktree root; reject rooted paths, `..` escape, and links whose final target escapes.
- The frozen contract comes from the BASE COMMIT (`git show <sha>:.baton/verification.json`), never the mutable worktree copy.
- Fail-CLOSED posture (contrast the advisory gates): a contract that cannot be resolved, linted, or executed is a failure, never a silent pass.
- Verification success requires exit 0 AND expected files present/non-empty AND (A5) any pre-existing expected file's content hash CHANGED AND protected paths intact AND diff scope clean when enforced.
- Every shell arg < 965 bytes; `utf8NoBOM` writes; `[Console]::Error.WriteLine` + `exit 2` for CLI user errors (no CLI in V1); never name variables `$args/$input/$event/$matches/$host/$pid`; unary-comma returns only for direct-assignment consumers; `ConvertTo-Json -InputObject @(...)` for arrays; guard 0/0.
- Tests are hermetic: temp git repos + temp dirs + `try/finally`; NEVER touch real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or real `D:\dev`; zero network, zero model calls.
- New runtime files MUST land in `bootstrap.ps1`'s deploy list AND `test-bootstrap.ps1` asserts (v1.8.0 coach-lib lesson).

## Controller preamble (before Task 1)

The main working tree sits on `feature/plan-gate` (ship-gated). Build V1 in a **separate git worktree off master**:

```powershell
git -C D:\Dev\Baton worktree add ..\baton-verified-labor -b feature/verified-labor master
```

All tasks run in `D:\Dev\baton-verified-labor`. Implementers: verify with `git -C D:\Dev\baton-verified-labor branch --show-current` → `feature/verified-labor` before any edit; commit ONLY files this plan names, via explicit `git add <paths>`.

**Design call recorded here (deviation from d082 §3 wording):** the presets file is **JSON, not YAML** — `references/verify-presets.json`. Contracts are already JSON (`.baton/verification.json`); one `ConvertFrom-Json -AsHashtable` parse path, zero new YAML parsing code. The d082 spec's intent (named presets, per-platform argv) is unchanged.

---

## Task 1 — presets file + normalize/lint layer + tests [implementer: haiku]

**Files:**
- Create: `references/verify-presets.json`
- Create: `scripts/verify-noop.ps1`
- Create: `scripts/verification-lib.ps1` (part 1: constants + presets + lint + containment + normalize)
- Create: `scripts/test-verification-lib.ps1` (sections P/S/C/N)

**Interfaces (produced — Task 2 consumes these exactly):**
- `Get-VerifyPresets [-PresetsPath <string>] -> hashtable` (the parsed `presets` map; `@{}` when file absent/unparseable)
- `Test-VerifyArgvSafe -Argv <string[]> -> @{ ok = <bool>; reason = <string> }`
- `Test-VerifyPathContained -Root <string> -Relative <string> -> <string full path | $null>`
- `Get-VerificationContract -Raw <hashtable> -WorktreeRoot <string> [-PresetsPath] [-MaxTimeoutS 1800] -> @{ ok; contract; reason }` where `contract` is `[ordered]@{ argv; cwd; timeout_s; expect_files; protected_paths; proves; grade_ceiling }` (paths kept worktree-RELATIVE in the contract; containment validated against `-WorktreeRoot`).

- [ ] **Step 1: Write `references/verify-presets.json`** (exact content):

```json
{
  "schema": 1,
  "presets": {
    "pytest": {
      "windows": ["python", "-m", "pytest", "-q"],
      "posix": ["python3", "-m", "pytest", "-q"],
      "args_append": true,
      "timeout_s": 600,
      "proves": "the named pytest target passes",
      "grade_ceiling": "strong"
    },
    "pwsh-suite": {
      "windows": ["pwsh", "-NoProfile", "-File"],
      "posix": ["pwsh", "-NoProfile", "-File"],
      "args_append": true,
      "timeout_s": 600,
      "proves": "the named PowerShell test suite exits 0",
      "grade_ceiling": "strong"
    },
    "node-test": {
      "windows": ["node", "--test"],
      "posix": ["node", "--test"],
      "args_append": true,
      "timeout_s": 600,
      "proves": "node --test passes for the named target",
      "grade_ceiling": "strong"
    },
    "file-exists-nonempty": {
      "windows": ["pwsh", "-NoProfile", "-File", "{{lib_dir}}/verify-noop.ps1"],
      "posix": ["pwsh", "-NoProfile", "-File", "{{lib_dir}}/verify-noop.ps1"],
      "args_append": false,
      "timeout_s": 60,
      "proves": "the expected files exist with non-empty, changed content",
      "grade_ceiling": "weak"
    }
  }
}
```

`{{lib_dir}}` is the ONLY substitution token presets may carry; it resolves to the lib's own directory (trusted file, trusted token). `file-exists-nonempty` delegates all real checking to `expect_files` + the A5 content bar; its argv is a shipped no-op so the argv-only rule holds with no shell escape.

- [ ] **Step 2: Write `scripts/verify-noop.ps1`** (exact content):

```powershell
#!/usr/bin/env pwsh
# Verification no-op (file-exists-nonempty preset): the contract's expect_files
# evaluation does the real work; this argv target only supplies exit 0.
exit 0
```

- [ ] **Step 3: Start `scripts/verification-lib.ps1`** with header + constants + the four Task-1 functions (exact content):

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Verified Labor V1 (d082): the pure verification-contract layer. A labor task
  passes only when an independent, executable contract produces evidence — argv-only
  execution frozen from the base revision, protected-oracle hashing, deterministic
  evidence grading. Fail-CLOSED: an unresolvable or violated contract is a failure.
.NOTES
  Spine: codex-ringer.md §5–§7/§12–§13 + d082 adjudications (A5 content bar,
  A7 platform-variant presets). No conductor coupling — V2 wires the Conductor.
#>
. "$PSScriptRoot/baton-home.ps1"

# Captured at dot-source: presets' {{lib_dir}} token resolves here, so a frozen
# contract's no-op helper path is valid wherever the lib is deployed.
$script:VerifyLibDir = $PSScriptRoot

function Get-VerifyPresetsPath {
    <# Resolution order: explicit env for tests -> BATON_HOME seeded copy ->
       repo references (running from a checkout). Absent everywhere -> '' —
       preset-sugar profiles then fail lint with 'unknown-preset'. #>
    if ($env:BATON_VERIFY_PRESETS) { return $env:BATON_VERIFY_PRESETS }
    $seeded = Join-Path (Get-BatonHome) 'verify-presets.json'
    if (Test-Path -LiteralPath $seeded) { return $seeded }
    $repo = Join-Path (Split-Path $PSScriptRoot -Parent) 'references/verify-presets.json'
    if (Test-Path -LiteralPath $repo) { return $repo }
    return ''
}

function Get-VerifyPresets {
    <# Parsed presets map. Fail-soft to @{} — a missing/corrupt presets file only
       disables preset SUGAR; raw contracts are unaffected. #>
    param([string]$PresetsPath = (Get-VerifyPresetsPath))
    if (-not $PresetsPath -or -not (Test-Path -LiteralPath $PresetsPath)) { return @{} }
    try {
        $doc = Get-Content -LiteralPath $PresetsPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($doc.presets -is [hashtable]) { return $doc.presets }
    } catch { }
    return @{}
}

function Test-VerifyArgvSafe {
    <# argv-only gate (codex-ringer §5): shell/eval escapes turn an argument vector
       back into command construction, which full-auto must never execute. The leaf
       of argv[0] (basename, .exe stripped, case-folded) picks the rule set. #>
    param([Parameter(Mandatory)][string[]]$Argv)
    foreach ($tok in $Argv) {
        if ($null -eq $tok -or ($tok -isnot [string]) -or [string]::IsNullOrWhiteSpace([string]$tok)) {
            return @{ ok = $false; reason = 'argv contains a null/empty/non-string element' }
        }
    }
    $leaf = [System.IO.Path]::GetFileName([string]$Argv[0]).ToLowerInvariant()
    if ($leaf.EndsWith('.exe')) { $leaf = $leaf.Substring(0, $leaf.Length - 4) }
    $rest = @($Argv | Select-Object -Skip 1 | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $hit = switch ($leaf) {
        { $_ -in @('sh', 'bash', 'zsh', 'dash', 'ksh') } { @($rest | Where-Object { $_ -eq '-c' }) }
        'cmd'                                            { @($rest | Where-Object { $_ -in @('/c', '/k') }) }
        { $_ -in @('pwsh', 'powershell') }               { @($rest | Where-Object { $_ -match '^-{1,2}(c|command|e|ec|enc\w*)$' }) }
        { $_ -in @('python', 'python3', 'py') }          { @($rest | Where-Object { $_ -eq '-c' }) }
        'node'                                           { @($rest | Where-Object { $_ -in @('-e', '--eval', '-p', '--print') }) }
        { $_ -in @('perl', 'ruby') }                     { @($rest | Where-Object { $_ -eq '-e' }) }
        default                                          { @() }
    }
    if (@($hit).Count -gt 0) {
        return @{ ok = $false; reason = "argv uses a shell/eval escape ('$leaf $(@($hit)[0])') — checked-in script files only (codex-ringer §5)" }
    }
    return @{ ok = $true; reason = '' }
}

function Test-VerifyPathContained {
    <# Containment: a contract-relative path must resolve inside -Root. Rejects
       rooted input, `..` escape, and (for existing items) links whose final
       target escapes. Returns the resolved full path, or $null on violation. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Relative
    )
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Relative)) { return $null }
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $combined = [System.IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    $rootPrefix = $rootFull.TrimEnd('\', '/') + $sep
    if (-not ($combined + $sep).StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (Test-Path -LiteralPath $combined) {
        $item = Get-Item -LiteralPath $combined -Force
        if ($item.LinkType) {
            $target = $null
            try { $target = $item.ResolveLinkTarget($true) } catch { }
            if ($null -ne $target) {
                $tFull = [System.IO.Path]::GetFullPath($target.FullName)
                if (-not ($tFull + $sep).StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            }
        }
    }
    return $combined
}

function Get-VerificationContract {
    <# Normalize + lint one profile (raw or preset-sugar) into the immutable
       contract shape. Paths stay worktree-RELATIVE in the contract (the runner
       resolves them per call); containment is validated here against -WorktreeRoot.
       Returns @{ ok; contract; reason } — never throws. #>
    param(
        [Parameter(Mandatory)][hashtable]$Raw,
        [Parameter(Mandatory)][string]$WorktreeRoot,
        [string]$PresetsPath = (Get-VerifyPresetsPath),
        [int]$MaxTimeoutS = 1800
    )
    $bad = { param($why) return @{ ok = $false; contract = $null; reason = [string]$why } }

    $argv = $null; $timeout = 300; $proves = ''; $ceiling = 'strong'
    if ($Raw.preset) {
        $presets = Get-VerifyPresets -PresetsPath $PresetsPath
        $p = $presets[[string]$Raw.preset]
        if ($null -eq $p) { return (& $bad "unknown-preset '$($Raw.preset)'") }
        $platKey = if ($IsWindows) { 'windows' } else { 'posix' }
        $argv = @(@($p[$platKey]) | ForEach-Object { ([string]$_).Replace('{{lib_dir}}', $script:VerifyLibDir) })
        if (@($argv).Count -lt 1) { return (& $bad "preset '$($Raw.preset)' has no argv for platform '$platKey'") }
        if ($p.args_append -eq $true -and $Raw.args) { $argv = @($argv) + @(@($Raw.args) | ForEach-Object { [string]$_ }) }
        if ($p.timeout_s) { $timeout = [int]$p.timeout_s }
        if ($p.proves) { $proves = [string]$p.proves }
        if ($p.grade_ceiling) { $ceiling = [string]$p.grade_ceiling }
    } elseif ($Raw.argv) {
        $argv = @(@($Raw.argv) | ForEach-Object { [string]$_ })
    } else {
        return (& $bad 'profile has neither argv nor preset')
    }
    if (@($argv).Count -lt 1) { return (& $bad 'argv is empty') }
    $safe = Test-VerifyArgvSafe -Argv $argv
    if (-not $safe.ok) { return (& $bad $safe.reason) }

    if ($Raw.timeout_s) { $timeout = [int]$Raw.timeout_s }
    if ($timeout -lt 1) { return (& $bad "timeout_s must be positive (got $timeout)") }
    if ($timeout -gt $MaxTimeoutS) { return (& $bad "timeout_s $timeout exceeds the policy cap $MaxTimeoutS") }
    if ($Raw.proves) { $proves = [string]$Raw.proves }
    if ([string]::IsNullOrWhiteSpace($proves)) { return (& $bad "contract requires a plain-language 'proves' statement") }
    if ($Raw.grade_ceiling) { $ceiling = [string]$Raw.grade_ceiling }
    if ($ceiling -notin @('strong', 'bounded', 'weak')) { return (& $bad "grade_ceiling '$ceiling' is not strong|bounded|weak") }

    $cwd = if ($Raw.cwd) { [string]$Raw.cwd } else { '.' }
    if ($null -eq (Test-VerifyPathContained -Root $WorktreeRoot -Relative $cwd)) {
        return (& $bad "cwd '$cwd' escapes the worktree root")
    }
    $expect = @(); $protected = @()
    foreach ($f in @($Raw.expect_files)) {
        if ($null -eq $f) { continue }
        if ($null -eq (Test-VerifyPathContained -Root $WorktreeRoot -Relative ([string]$f))) {
            return (& $bad "expect_files entry '$f' escapes the worktree root")
        }
        $expect += [string]$f
    }
    foreach ($f in @($Raw.protected_paths)) {
        if ($null -eq $f) { continue }
        if ($null -eq (Test-VerifyPathContained -Root $WorktreeRoot -Relative ([string]$f))) {
            return (& $bad "protected_paths entry '$f' escapes the worktree root")
        }
        $protected += [string]$f
    }

    $contract = [ordered]@{
        argv            = @($argv)
        cwd             = $cwd
        timeout_s       = $timeout
        expect_files    = @($expect)
        protected_paths = @($protected)
        proves          = $proves
        grade_ceiling   = $ceiling
    }
    return @{ ok = $true; contract = $contract; reason = '' }
}
```

- [ ] **Step 4: Start `scripts/test-verification-lib.ps1`** with the harness + sections P (presets), S (argv safety), C (containment), N (normalize) — exact content:

```powershell
#!/usr/bin/env pwsh
# Hermetic suite for verification-lib (d082 V1). Zero network, zero model calls,
# temp dirs only — never real ~/.baton, ~/.claude, or any real project tree.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'verification-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpRoot = Join-Path $env:TEMP "verify-lib-test-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedPresetsEnv = $env:BATON_VERIFY_PRESETS
try {
    # Pin presets to the repo copy so the suite never reads a live BATON_HOME seed.
    $env:BATON_VERIFY_PRESETS = Join-Path (Split-Path $PSScriptRoot -Parent) 'references/verify-presets.json'
    $wt = Join-Path $tmpRoot 'wt'
    New-Item -ItemType Directory -Force -Path $wt | Out-Null

    # --- P: presets ---
    $presets = Get-VerifyPresets
    Assert "P1 presets file parses and exposes pytest" ($null -ne $presets['pytest'])
    Assert "P2 file-exists-nonempty carries weak ceiling" ($presets['file-exists-nonempty'].grade_ceiling -eq 'weak')
    $noneP = Get-VerifyPresets -PresetsPath (Join-Path $tmpRoot 'absent.json')
    Assert "P3 absent presets file -> empty map (fail-soft)" ($noneP.Count -eq 0)

    # --- S: argv safety ---
    Assert "S1 plain argv ok" ((Test-VerifyArgvSafe -Argv @('python', '-m', 'pytest')).ok)
    Assert "S2 sh -c rejected" (-not (Test-VerifyArgvSafe -Argv @('sh', '-c', 'echo hi')).ok)
    Assert "S3 cmd /c rejected (case-insensitive)" (-not (Test-VerifyArgvSafe -Argv @('CMD', '/C', 'dir')).ok)
    Assert "S4 pwsh -Command rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-Command', '1')).ok)
    Assert "S5 pwsh -EncodedCommand abbreviation rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-enc', 'AAA')).ok)
    Assert "S6 python -c rejected" (-not (Test-VerifyArgvSafe -Argv @('python', '-c', 'print(1)')).ok)
    Assert "S7 node --eval rejected" (-not (Test-VerifyArgvSafe -Argv @('node', '--eval', '1')).ok)
    Assert "S8 powershell.exe path form rejected" (-not (Test-VerifyArgvSafe -Argv @('C:\wp\powershell.exe', '-command', '1')).ok)
    Assert "S9 pwsh -File allowed" ((Test-VerifyArgvSafe -Argv @('pwsh', '-NoProfile', '-File', 'x.ps1')).ok)
    Assert "S10 empty element rejected" (-not (Test-VerifyArgvSafe -Argv @('git', '')).ok)

    # --- C: containment ---
    Set-Content -LiteralPath (Join-Path $wt 'inside.txt') -Value 'x' -Encoding utf8NoBOM
    Assert "C1 relative inside resolves" ($null -ne (Test-VerifyPathContained -Root $wt -Relative 'inside.txt'))
    Assert "C2 '.' resolves to the root itself" ($null -ne (Test-VerifyPathContained -Root $wt -Relative '.'))
    Assert "C3 .. escape rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative '..\outside.txt'))
    Assert "C4 rooted path rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative $tmpRoot))
    Assert "C5 nested .. that stays inside is fine" ($null -ne (Test-VerifyPathContained -Root $wt -Relative 'a\..\inside.txt'))
    # Junction escape (no admin needed, unlike symlinks): link inside -> dir outside
    $outDir = Join-Path $tmpRoot 'outside-dir'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $junc = Join-Path $wt 'jlink'
    $null = New-Item -ItemType Junction -Path $junc -Target $outDir -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $junc) {
        Assert "C6 junction whose target escapes is rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative 'jlink'))
    } else {
        Assert "C6 junction whose target escapes is rejected (skipped: junction unavailable)" $true
    }

    # --- N: normalize + lint ---
    $rawOk = @{ argv = @('git', 'status'); proves = 'demo'; expect_files = @('inside.txt') }
    $n1 = Get-VerificationContract -Raw $rawOk -WorktreeRoot $wt
    Assert "N1 raw profile normalizes" ($n1.ok -and $n1.contract.timeout_s -eq 300 -and $n1.contract.grade_ceiling -eq 'strong')
    $n2 = Get-VerificationContract -Raw @{ argv = @('sh', '-c', 'x'); proves = 'p' } -WorktreeRoot $wt
    Assert "N2 shell escape fails lint" ((-not $n2.ok) -and $n2.reason -match 'escape')
    $n3 = Get-VerificationContract -Raw @{ argv = @('git', 'status') } -WorktreeRoot $wt
    Assert "N3 missing proves rejected" ((-not $n3.ok) -and $n3.reason -match 'proves')
    $n4 = Get-VerificationContract -Raw @{ argv = @('git', 'status'); proves = 'p'; timeout_s = 99999 } -WorktreeRoot $wt
    Assert "N4 timeout above cap rejected" ((-not $n4.ok) -and $n4.reason -match 'cap')
    $n5 = Get-VerificationContract -Raw @{ argv = @('git', 'status'); proves = 'p'; expect_files = @('..\x') } -WorktreeRoot $wt
    Assert "N5 escaping expect_files rejected" ((-not $n5.ok) -and $n5.reason -match 'escapes')
    $n6 = Get-VerificationContract -Raw @{ preset = 'pwsh-suite'; args = @('scripts/x.ps1'); proves = 'suite passes' } -WorktreeRoot $wt
    Assert "N6 preset expands with args appended" ($n6.ok -and $n6.contract.argv[-1] -eq 'scripts/x.ps1' -and $n6.contract.argv[0] -eq 'pwsh')
    $n7 = Get-VerificationContract -Raw @{ preset = 'no-such' } -WorktreeRoot $wt
    Assert "N7 unknown preset rejected" ((-not $n7.ok) -and $n7.reason -match 'unknown-preset')
    $n8 = Get-VerificationContract -Raw @{ preset = 'file-exists-nonempty'; expect_files = @('inside.txt') } -WorktreeRoot $wt
    Assert "N8 noop preset resolves {{lib_dir}} and keeps weak ceiling" ($n8.ok -and $n8.contract.grade_ceiling -eq 'weak' -and ($n8.contract.argv -join ' ') -match 'verify-noop')
} finally {
    if ($null -eq $savedPresetsEnv) { Remove-Item env:BATON_VERIFY_PRESETS -ErrorAction SilentlyContinue }
    else { $env:BATON_VERIFY_PRESETS = $savedPresetsEnv }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
```

- [ ] **Step 5: Run the suite** — `pwsh -NoProfile -File scripts/test-verification-lib.ps1` from `D:\Dev\baton-verified-labor`. Expected: all P/S/C/N checks PASS, exit 0.

- [ ] **Step 6: Commit**

```powershell
git add references/verify-presets.json scripts/verify-noop.ps1 scripts/verification-lib.ps1 scripts/test-verification-lib.ps1
git commit -m "feat(verify): V1 part 1 — presets, argv lint, containment, contract normalize (d082)"
```

---

## Task 2 — freeze, hashing, runner, evaluation, grading, façade + tests [implementer: sonnet]

**Files:**
- Modify: `scripts/verification-lib.ps1` (append part 2)
- Modify: `scripts/test-verification-lib.ps1` (append sections F/R/E/G/V; the `finally` block and exit-code footer stay LAST — insert new sections before `} finally`)

**Interfaces:**
- Consumes (Task 1, exact): `Get-VerificationContract -Raw -WorktreeRoot [-PresetsPath] [-MaxTimeoutS]` → `@{ok;contract;reason}`; `Test-VerifyPathContained -Root -Relative` → full-path-or-$null.
- Produces (V2 consumes — keys are FROZEN API):
  - `Get-FrozenVerificationContract -RepoPath -BaseSha -ProfileName -WorktreeRoot -RunTaskDir [-PresetsPath] -> @{ ok; contract; contract_path; reason }`
  - `Get-VerifyPathHashes -WorktreeRoot -Paths <string[]> -> hashtable rel-path -> sha256-or-'ABSENT'`
  - `Invoke-VerifyCommand -Argv -WorkingDir -TimeoutS -OutputPath [-MaxOutputBytes 262144] -> @{ started; exit_code; timed_out; duration_ms; output_truncated; spawn_error }`
  - `Invoke-VerificationContract -Contract -WorktreeRoot -RunTaskDir [-DiffFiles <string[]>] [-AllowedPaths <string[]>] [-ExpectPreHashes] [-ProtectedPreHashes] -> [ordered]@{ ok; grade; verdict; exit_code; timed_out; duration_ms; output_path; output_truncated; expected_files_ok; protected_ok; scope_ok; failure_category; proves }`
  - `verdict ∈ pass|fail|scope-violation|infrastructure-error`; `grade ∈ strong|bounded|weak|invalid`; `failure_category ∈ ''|check-failed|check-timeout|expected-file-missing|expected-file-empty|expected-file-unchanged|scope-violation|protected-path-mutated|spawn-failed`.

- [ ] **Step 1: Append part 2 to `scripts/verification-lib.ps1`** (exact content):

```powershell
function Get-FrozenVerificationContract {
    <# Resolve a named profile from the BASE COMMIT's .baton/verification.json —
       `git show <sha>:<path>`, never the mutable worktree copy (a worker edit to
       the config cannot change the current run's oracle). Writes the immutable
       contract copy to <RunTaskDir>/contract.json. Fail-closed via ok=$false. #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][string]$WorktreeRoot,
        [Parameter(Mandatory)][string]$RunTaskDir,
        [string]$PresetsPath = (Get-VerifyPresetsPath)
    )
    $raw = & git -C $RepoPath show "$($BaseSha):.baton/verification.json" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((@($raw) -join ''))) {
        return @{ ok = $false; contract = $null; contract_path = ''; reason = 'no-verification-config (base revision has no .baton/verification.json)' }
    }
    try { $doc = (@($raw) -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return @{ ok = $false; contract = $null; contract_path = ''; reason = 'verification-config-unparseable' } }
    if ($doc.schema -ne 1) { return @{ ok = $false; contract = $null; contract_path = ''; reason = "unsupported schema '$($doc.schema)'" } }
    $prof = $null
    if ($doc.profiles -is [hashtable]) { $prof = $doc.profiles[$ProfileName] }
    if ($null -eq $prof) { return @{ ok = $false; contract = $null; contract_path = ''; reason = "unknown-profile '$ProfileName'" } }
    $norm = Get-VerificationContract -Raw $prof -WorktreeRoot $WorktreeRoot -PresetsPath $PresetsPath
    if (-not $norm.ok) { return @{ ok = $false; contract = $null; contract_path = ''; reason = $norm.reason } }
    New-Item -ItemType Directory -Force -Path $RunTaskDir | Out-Null
    $cpath = Join-Path $RunTaskDir 'contract.json'
    ConvertTo-Json -InputObject $norm.contract -Depth 6 | Set-Content -LiteralPath $cpath -Encoding utf8NoBOM
    return @{ ok = $true; contract = $norm.contract; contract_path = $cpath; reason = '' }
}

function Get-VerifyPathHashes {
    <# SHA256 per worktree-relative path; 'ABSENT' when the file does not exist.
       Used pre-labor (freeze) and post-check (integrity + the A5 content bar). #>
    param(
        [Parameter(Mandatory)][string]$WorktreeRoot,
        [string[]]$Paths
    )
    $map = @{}
    foreach ($rel in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
        $full = Test-VerifyPathContained -Root $WorktreeRoot -Relative ([string]$rel)
        if ($null -eq $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { $map[[string]$rel] = 'ABSENT'; continue }
        $map[[string]$rel] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
    return $map
}

function Invoke-VerifyCommand {
    <# The argv runner: System.Diagnostics.Process + ArgumentList (never a shell
       string — nothing is reparsed), stdin closed (headless checks must not hang),
       stdout+stderr captured to a byte-capped file, timeout kills the whole
       process tree ($proc.Kill($true); taskkill /T /F fallback). #>
    param(
        [Parameter(Mandatory)][string[]]$Argv,
        [Parameter(Mandatory)][string]$WorkingDir,
        [int]$TimeoutS = 300,
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$MaxOutputBytes = 262144
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Argv[0]
    foreach ($a in @($Argv | Select-Object -Skip 1)) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.WorkingDirectory = $WorkingDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        return @{ started = $false; exit_code = -1; timed_out = $false; duration_ms = 0; output_truncated = $false; spawn_error = $_.Exception.Message }
    }
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($TimeoutS * 1000)
    if ($timedOut) {
        try { $proc.Kill($true) } catch { try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch { } }
    }
    $proc.WaitForExit()   # flush async stream reads after any WaitForExit(ms)
    $sw.Stop()
    $text = [string]$outTask.Result
    $errText = [string]$errTask.Result
    if ($errText) { $text = $text + "`n--- stderr ---`n" + $errText }
    $enc = [System.Text.Encoding]::UTF8
    $bytes = $enc.GetBytes($text)
    $truncated = $false
    if ($bytes.Length -gt $MaxOutputBytes) {
        $text = $enc.GetString($bytes, 0, $MaxOutputBytes) + "`n[output truncated at $MaxOutputBytes bytes]"
        $truncated = $true
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    Set-Content -LiteralPath $OutputPath -Value $text -Encoding utf8NoBOM
    $exit = if ($timedOut) { -1 } else { $proc.ExitCode }
    return @{ started = $true; exit_code = $exit; timed_out = $timedOut; duration_ms = [int]$sw.ElapsedMilliseconds; output_truncated = $truncated; spawn_error = $null }
}

function Get-VerificationGrade {
    <# Deterministic evidence grade (codex-ringer §6, V1 simplification recorded in
       the plan): any violation/failure -> invalid; STRONG requires a declared AND
       intact protected oracle plus full diff scoping; everything else that passed
       is BOUNDED; the contract's grade_ceiling (e.g. file-exists-nonempty -> weak)
       caps the result. The worker never selects its own grade. #>
    param(
        [Parameter(Mandatory)][hashtable]$Contract,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][bool]$ProtectedDeclared,
        [Parameter(Mandatory)][bool]$ProtectedIntact,
        [Parameter(Mandatory)][bool]$ScopeEnforced,
        [Parameter(Mandatory)][bool]$ScopeOk
    )
    if (-not $Passed) { return 'invalid' }
    $rank = @{ strong = 3; bounded = 2; weak = 1 }
    $computed = if ($ProtectedDeclared -and $ProtectedIntact -and $ScopeEnforced -and $ScopeOk) { 'strong' } else { 'bounded' }
    $ceiling = [string]$Contract.grade_ceiling
    if (-not $rank.ContainsKey($ceiling)) { $ceiling = 'strong' }
    if ($rank[$computed] -le $rank[$ceiling]) { return $computed }
    return $ceiling
}

function Invoke-VerificationContract {
    <# The façade V2 consumes. Orchestrates: run argv -> expected files (A5 content
       bar) -> protected-oracle integrity -> diff scope -> deterministic grade.
       Pre-hashes are captured PRE-LABOR by the caller (freeze time); when omitted,
       expected-file change detection degrades gracefully (absent pre-hash = new
       file, only existence+non-empty required). Never throws. #>
    param(
        [Parameter(Mandatory)][hashtable]$Contract,
        [Parameter(Mandatory)][string]$WorktreeRoot,
        [Parameter(Mandatory)][string]$RunTaskDir,
        [string[]]$DiffFiles = @(),
        [string[]]$AllowedPaths = @(),
        [hashtable]$ExpectPreHashes = @{},
        [hashtable]$ProtectedPreHashes = @{}
    )
    New-Item -ItemType Directory -Force -Path $RunTaskDir | Out-Null
    $outputPath = Join-Path $RunTaskDir 'check-output.txt'
    $result = [ordered]@{
        ok = $false; grade = 'invalid'; verdict = 'fail'
        exit_code = -1; timed_out = $false; duration_ms = 0
        output_path = $outputPath; output_truncated = $false
        expected_files_ok = $false; protected_ok = $false; scope_ok = $false
        failure_category = ''; proves = [string]$Contract.proves
    }

    # 1. Scope (checked first: a scope violation fails closed regardless of the check)
    $scopeEnforced = (@($AllowedPaths).Count -gt 0)
    $scopeOk = $true
    if ($scopeEnforced) {
        $allowedSet = @($AllowedPaths | ForEach-Object { ([string]$_).Replace('\', '/').ToLowerInvariant() })
        foreach ($df in @($DiffFiles)) {
            if ([string]::IsNullOrWhiteSpace([string]$df)) { continue }
            if ((([string]$df).Replace('\', '/').ToLowerInvariant()) -notin $allowedSet) { $scopeOk = $false; break }
        }
    }
    $result.scope_ok = $scopeOk
    if (-not $scopeOk) {
        $result.verdict = 'scope-violation'; $result.failure_category = 'scope-violation'
        return $result
    }

    # 2. Run the check
    $cwdFull = Test-VerifyPathContained -Root $WorktreeRoot -Relative ([string]$Contract.cwd)
    if ($null -eq $cwdFull) {
        $result.verdict = 'infrastructure-error'; $result.failure_category = 'spawn-failed'
        return $result
    }
    $run = Invoke-VerifyCommand -Argv @($Contract.argv) -WorkingDir $cwdFull -TimeoutS ([int]$Contract.timeout_s) -OutputPath $outputPath
    $result.exit_code = $run.exit_code
    $result.timed_out = [bool]$run.timed_out
    $result.duration_ms = [int]$run.duration_ms
    $result.output_truncated = [bool]$run.output_truncated
    if (-not $run.started) {
        $result.verdict = 'infrastructure-error'; $result.failure_category = 'spawn-failed'
        return $result
    }

    # 3. Protected-oracle integrity (evaluated even on check failure — a mutated
    #    oracle must fail closed and V2 must not retry it)
    $protDeclared = (@($Contract.protected_paths).Count -gt 0)
    $protPost = Get-VerifyPathHashes -WorktreeRoot $WorktreeRoot -Paths @($Contract.protected_paths)
    $protIntact = $true
    foreach ($k in @($protPost.Keys)) {
        $pre = if ($ProtectedPreHashes.ContainsKey($k)) { [string]$ProtectedPreHashes[$k] } else { $null }
        if ($null -ne $pre -and $pre -ne [string]$protPost[$k]) { $protIntact = $false; break }
    }
    $result.protected_ok = $protIntact
    if ($protDeclared -and -not $protIntact) {
        $result.verdict = 'scope-violation'; $result.failure_category = 'protected-path-mutated'
        return $result
    }

    # 4. Check outcome
    if ($run.timed_out) { $result.failure_category = 'check-timeout'; return $result }
    if ([int]$run.exit_code -ne 0) { $result.failure_category = 'check-failed'; return $result }

    # 5. Expected files: exist + non-empty + (A5) pre-existing content must have CHANGED
    foreach ($rel in @($Contract.expect_files)) {
        $full = Test-VerifyPathContained -Root $WorktreeRoot -Relative ([string]$rel)
        if ($null -eq $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $result.failure_category = 'expected-file-missing'; return $result
        }
        if ((Get-Item -LiteralPath $full).Length -lt 1) {
            $result.failure_category = 'expected-file-empty'; return $result
        }
        $pre = if ($ExpectPreHashes.ContainsKey([string]$rel)) { [string]$ExpectPreHashes[[string]$rel] } else { $null }
        if ($null -ne $pre -and $pre -ne 'ABSENT') {
            $post = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
            if ($post -eq $pre) { $result.failure_category = 'expected-file-unchanged'; return $result }
        }
    }
    $result.expected_files_ok = $true

    # 6. Pass + grade
    $result.verdict = 'pass'; $result.ok = $true
    $result.grade = Get-VerificationGrade -Contract $Contract -Passed $true `
        -ProtectedDeclared $protDeclared -ProtectedIntact $protIntact `
        -ScopeEnforced $scopeEnforced -ScopeOk $scopeOk
    return $result
}
```

- [ ] **Step 2: Append test sections F/R/E/G/V** to `scripts/test-verification-lib.ps1` (insert BEFORE the `} finally` line; exact content):

```powershell
    # --- helpers for part 2 ---
    function New-TestGitRepo([string]$Path) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        & git -C $Path init -q 2>$null | Out-Null
        & git -C $Path config user.email t@t 2>$null | Out-Null
        & git -C $Path config user.name t 2>$null | Out-Null
    }
    $repo = Join-Path $tmpRoot 'repo'
    New-TestGitRepo $repo
    $cfgDir = Join-Path $repo '.baton'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfg = @{ schema = 1; profiles = @{ demo = @{ argv = @('git', 'status'); proves = 'repo status readable'; protected_paths = @('oracle.txt') } } }
    ConvertTo-Json -InputObject $cfg -Depth 6 | Set-Content -LiteralPath (Join-Path $cfgDir 'verification.json') -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'oracle-v1' -Encoding utf8NoBOM
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m base 2>$null | Out-Null
    $baseSha = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $taskDir = Join-Path $tmpRoot 'run\tasks\t1'

    # --- F: frozen contract ---
    $f1 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F1 freeze resolves the profile from the base commit" ($f1.ok -and (Test-Path $f1.contract_path))
    $f2 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'nope' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F2 unknown profile fails closed" ((-not $f2.ok) -and $f2.reason -match 'unknown-profile')
    # Worker edits the WORKTREE copy after freeze -> frozen contract still governs
    $mut = @{ schema = 1; profiles = @{ demo = @{ argv = @('sh', '-c', 'evil'); proves = 'x' } } }
    ConvertTo-Json -InputObject $mut -Depth 6 | Set-Content -LiteralPath (Join-Path $cfgDir 'verification.json') -Encoding utf8NoBOM
    $f3 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\t1b')
    Assert "F3 frozen contract authority: worktree mutation is invisible" ($f3.ok -and ($f3.contract.argv[0] -eq 'git'))
    $f4 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha '0000000000000000000000000000000000000000' -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F4 bad base sha -> no-verification-config" ((-not $f4.ok) -and $f4.reason -match 'no-verification-config')

    # --- R: runner ---
    $rOut = Join-Path $tmpRoot 'r1.txt'
    $r1 = Invoke-VerifyCommand -Argv @('git', '--version') -WorkingDir $repo -TimeoutS 60 -OutputPath $rOut
    Assert "R1 plain command exits 0 with captured output" ($r1.exit_code -eq 0 -and (Get-Content $rOut -Raw) -match 'git version')
    $r2 = Invoke-VerifyCommand -Argv @('git', 'definitely-not-a-verb') -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r2.txt')
    Assert "R2 failing command reports nonzero exit" ($r2.started -and $r2.exit_code -ne 0)
    $r3 = Invoke-VerifyCommand -Argv @("no-such-exe-$(Get-Random)") -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r3.txt')
    Assert "R3 missing executable -> started=false (spawn error)" (-not $r3.started)
    # Timeout + tree kill: pwsh -File on a sleeper script (argv-safe form)
    $sleeper = Join-Path $tmpRoot 'sleeper.ps1'
    Set-Content -LiteralPath $sleeper -Value 'Start-Sleep -Seconds 120' -Encoding utf8NoBOM
    $t0 = Get-Date
    $r4 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $sleeper) -WorkingDir $repo -TimeoutS 2 -OutputPath (Join-Path $tmpRoot 'r4.txt')
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    Assert "R4 timeout kills the tree quickly" ($r4.timed_out -and $elapsed -lt 30)
    # argv literality: spaces, quotes, $() reach the child untouched
    $echoer = Join-Path $tmpRoot 'echoer.ps1'
    Set-Content -LiteralPath $echoer -Value 'param($P) [Console]::Out.Write($P)' -Encoding utf8NoBOM
    $lit = 'a b "q" $(Get-Date) `tick'
    $r5out = Join-Path $tmpRoot 'r5.txt'
    $r5 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $echoer, $lit) -WorkingDir $repo -TimeoutS 60 -OutputPath $r5out
    Assert "R5 argv passes spaces/quotes/dollar literally (no reparse)" ($r5.exit_code -eq 0 -and (Get-Content $r5out -Raw).Contains($lit))
    # Output cap
    $blaster = Join-Path $tmpRoot 'blaster.ps1'
    Set-Content -LiteralPath $blaster -Value "[Console]::Out.Write(('x' * 400000))" -Encoding utf8NoBOM
    $r6 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $blaster) -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r6.txt') -MaxOutputBytes 1000
    Assert "R6 output truncated at the byte cap" ($r6.output_truncated -and (Get-Item (Join-Path $tmpRoot 'r6.txt')).Length -lt 5000)

    # --- E/G/V: façade end-to-end ---
    $demo = $f1.contract
    $protPre = Get-VerifyPathHashes -WorktreeRoot $repo -Paths @($demo.protected_paths)
    $v1 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v1') -ProtectedPreHashes $protPre
    Assert "V1 clean pass; protected intact; grade bounded (no scope enforcement)" ($v1.ok -and $v1.verdict -eq 'pass' -and $v1.grade -eq 'bounded')
    $v2 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v2') -ProtectedPreHashes $protPre -DiffFiles @('src/a.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V2 scope enforced + protected intact -> STRONG" ($v2.ok -and $v2.grade -eq 'strong')
    $v3 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3') -ProtectedPreHashes $protPre -DiffFiles @('src/a.ps1', 'other/b.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V3 diff outside allowed paths -> scope-violation, fail closed" ($v3.verdict -eq 'scope-violation' -and $v3.failure_category -eq 'scope-violation' -and -not $v3.ok)
    # Protected-oracle mutation
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'TAMPERED' -Encoding utf8NoBOM
    $v4 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v4') -ProtectedPreHashes $protPre
    Assert "V4 mutated protected oracle -> scope-violation/protected-path-mutated" ($v4.verdict -eq 'scope-violation' -and $v4.failure_category -eq 'protected-path-mutated')
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'oracle-v1' -Encoding utf8NoBOM
    # Expected files: missing / empty / unchanged (A5) / changed
    $expC = [ordered]@{ argv = @('git', '--version'); cwd = '.'; timeout_s = 60; expect_files = @('out.txt'); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v5 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v5')
    Assert "V5 missing expected file fails" ($v5.failure_category -eq 'expected-file-missing')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value '' -NoNewline -Encoding utf8NoBOM
    $v6 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v6')
    Assert "V6 empty expected file fails" ($v6.failure_category -eq 'expected-file-empty')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value 'stale' -Encoding utf8NoBOM
    $prePre = Get-VerifyPathHashes -WorktreeRoot $repo -Paths @('out.txt')
    $v7 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v7') -ExpectPreHashes $prePre
    Assert "V7 pre-existing expected file UNCHANGED fails (A5 content bar)" ($v7.failure_category -eq 'expected-file-unchanged')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value 'fresh content' -Encoding utf8NoBOM
    $v8 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v8') -ExpectPreHashes $prePre
    Assert "V8 changed expected file passes" ($v8.ok -and $v8.expected_files_ok)
    # Check failure + weak ceiling + spawn failure verdicts
    $failC = [ordered]@{ argv = @('git', 'definitely-not-a-verb'); cwd = '.'; timeout_s = 60; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v9 = Invoke-VerificationContract -Contract $failC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v9')
    Assert "V9 failing check -> fail/check-failed, grade invalid" ($v9.verdict -eq 'fail' -and $v9.failure_category -eq 'check-failed' -and $v9.grade -eq 'invalid')
    $noopC = (Get-VerificationContract -Raw @{ preset = 'file-exists-nonempty'; expect_files = @('out.txt') } -WorktreeRoot $repo).contract
    $v10 = Invoke-VerificationContract -Contract $noopC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v10') -ExpectPreHashes $prePre
    Assert "V10 weak ceiling caps a passing existence check at WEAK" ($v10.ok -and $v10.grade -eq 'weak')
    $spawnC = [ordered]@{ argv = @("no-such-exe-$(Get-Random)"); cwd = '.'; timeout_s = 30; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v11 = Invoke-VerificationContract -Contract $spawnC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v11')
    Assert "V11 missing verifier exe -> infrastructure-error, not model-quality fail" ($v11.verdict -eq 'infrastructure-error' -and $v11.failure_category -eq 'spawn-failed')
    $v12 = Invoke-VerificationContract -Contract ([ordered]@{ argv = @('pwsh', '-NoProfile', '-File', $sleeper); cwd = '.'; timeout_s = 2; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }) -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v12')
    Assert "V12 check timeout -> fail/check-timeout (retry-eligible category)" ($v12.verdict -eq 'fail' -and $v12.failure_category -eq 'check-timeout' -and $v12.timed_out)
```

- [ ] **Step 3: Run the full suite** — `pwsh -NoProfile -File scripts/test-verification-lib.ps1`. Expected: ALL sections PASS (P/S/C/N + F/R/E/G/V ≈ 40 checks), exit 0. R4 must complete well under 30s (tree kill works).

- [ ] **Step 4: Commit**

```powershell
git add scripts/verification-lib.ps1 scripts/test-verification-lib.ps1
git commit -m "feat(verify): V1 part 2 — frozen contracts, argv runner, A5 evaluation, evidence grading (d082)"
```

---

## Task 3 — bootstrap wiring + deploy asserts [implementer: haiku]

**Files:**
- Modify: `scripts/bootstrap.ps1` (two one-line list edits)
- Modify: `scripts/baton-home.ps1` (one one-line list edit)
- Modify: `scripts/test-bootstrap.ps1` (three asserts)

**Interfaces:** consumes nothing new; produces a deployed box where `verification-lib.ps1` + `verify-noop.ps1` land in `~/.claude/scripts` and `verify-presets.json` is seeded into BATON_HOME.

- [ ] **Step 1:** In `scripts/bootstrap.ps1`, find the `foreach ($script in @('baton-home.ps1', ...))` deploy list (~line 259) and append `, 'verification-lib.ps1', 'verify-noop.ps1'` before the closing `))` — exact final segment: `..., 'plan-gate-lib.ps1', 'fleet-plan-gate.ps1', 'verification-lib.ps1', 'verify-noop.ps1')`.

- [ ] **Step 2:** In `scripts/baton-home.ps1` `Initialize-BatonHome`, change the seed list line to:

```powershell
    foreach ($cfg in @('fleet.yaml', 'tools.yaml', 'prime-hours.yaml', 'verify-presets.json')) {
```

(Seed-if-absent semantics are already generic — existing boxes gain the presets file on next bootstrap without clobbering anything.)

- [ ] **Step 3:** In `scripts/test-bootstrap.ps1`, next to the existing plan-gate asserts (~line 61), add:

```powershell
Assert "deploys verification-lib script (Verified Labor d082 V1)" ($out -match 'verification-lib\.ps1')
Assert "deploys verify-noop helper (file-exists-nonempty preset argv target)" ($out -match 'verify-noop\.ps1')
Assert "seeds verify-presets.json into BATON_HOME (preset sugar on deployed boxes)" ($out -match 'verify-presets\.json')
```

(If the third assert's `$out` source does not include seeding output, follow how the suite already asserts seeded configs — mirror the fleet.yaml seeding assert if one exists; if none exists, assert instead that `baton-home.ps1`'s deployed copy contains `verify-presets.json`: `((Get-Content $deployedBatonHome -Raw) -match 'verify-presets\.json')` — match the suite's existing variable names.)

- [ ] **Step 4: Run** `pwsh -NoProfile -File scripts/test-bootstrap.ps1` — all asserts green, exit 0. Also re-run `pwsh -NoProfile -File scripts/test-verification-lib.ps1` (unchanged, green).

- [ ] **Step 5: Commit**

```powershell
git add scripts/bootstrap.ps1 scripts/baton-home.ps1 scripts/test-bootstrap.ps1
git commit -m "feat(verify): deploy verification-lib + noop helper; seed verify-presets.json (d082 V1)"
```

---

## Final gate (controller)

1. Full sweep in the worktree: conductor, plan-gate, gate, fleet-dispatch, fleet-lib, executor, go-execute, routing, doctor, probe, bootstrap, verification — all exit 0 (V1 adds files only; nothing existing may move).
2. Single Opus whole-branch review (streamlined ceremony), fix wave if needed.
3. NO live smoke required for V1 (pure library; V2's scratch-repo smoke is the live gate).
4. Push `feature/verified-labor`; merge ONLY on Kevin's word. V2 planning starts after the plan-gate branch merges (V2 modifies conductor-lib).

## Self-review (done by the author)

- **Spec coverage:** d082 V1 scope ↔ tasks: presets/sugar (T1), lint incl. every named escape (T1/S-checks), containment incl. link escape (T1/C6 via junction — no admin needed), freeze-from-base + immutability (T2/F3), SHA256 hashing (T2), argv runner with closed stdin/tree-kill/cap (T2/R-checks), A5 content bar (T2/V7-V8), grading with ceiling (T2/V2/V10), façade key set exactly as the directive names (T2 interfaces), fail-closed postures (V3/V4/V11 distinctions), bootstrap+seed wiring (T3). codex-ringer §16 rows deferred to V2: worker-exit interplay, retry semantics, planner-unknown-profile plan rejection (freeze-level covered by F2).
- **Placeholder scan:** none — every step carries full code; Task 3 Step 3's conditional instruction names the exact fallback assert.
- **Type consistency:** `Get-VerificationContract` → `.contract` ordered dict consumed verbatim by `Get-FrozenVerificationContract` and the façade; hash maps are `rel-path -> string`; result keys match the frozen API list; `Test-VerifyPathContained` returns string-or-$null everywhere it's consumed.
- **House-rule check:** no `$args/$input/$event/$matches` names; no unary-comma returns (all collections returned as plain arrays/hashtables into direct assignments); `ConvertTo-Json -InputObject` at both write sites; utf8NoBOM throughout; all test paths under `$env:TEMP`; suite restores `BATON_VERIFY_PRESETS` in `finally`.
