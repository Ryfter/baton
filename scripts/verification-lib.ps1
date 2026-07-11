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
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Argv)
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
