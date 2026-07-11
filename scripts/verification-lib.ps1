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
