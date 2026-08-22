#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Hold-out validation — builder-blind scenarios frozen from base commit.
#>
$ErrorActionPreference = 'Stop'

function Get-HoldoutManifestRelPath {
    return '.baton/holdout/manifest.json'
}

function Get-FrozenHoldoutManifest {
    <# Read holdout manifest from BASE commit (never mutable worktree copy). #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$BaseSha
    )
    $rel = Get-HoldoutManifestRelPath
    $raw = & git -C $RepoPath show "${BaseSha}:$rel" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace((@($raw) -join ''))) {
        return @{ ok = $false; manifest = $null; reason = 'no-holdout-manifest' }
    }
    try {
        $doc = (@($raw) -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @{ ok = $false; manifest = $null; reason = 'holdout-manifest-unparseable' }
    }
    if ([int]$doc.schema_version -ne 1) {
        return @{ ok = $false; manifest = $null; reason = "unsupported holdout schema $($doc.schema_version)" }
    }
    return @{ ok = $true; manifest = $doc; reason = '' }
}

function Get-HoldoutScenarioPaths {
    param([Parameter(Mandatory)]$Manifest)
    $out = @()
    foreach ($s in @($Manifest.scenarios)) {
        if ($s.path) { $out += [string]$s.path }
    }
    return $out
}

function Invoke-HoldoutScenario {
    <# Run one hold-out check (argv only) in WorktreeRoot. Scenario: { id, title, argv[] }. #>
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][string]$WorktreeRoot
    )
    $argv = @($Scenario.argv)
    if ($argv.Count -lt 1) {
        return @{ ok = $false; id = [string]$Scenario.id; reason = 'empty argv'; exit = 1 }
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [string]$argv[0]
    $psi.Arguments = (($argv | Select-Object -Skip 1) | ForEach-Object {
        if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.WorkingDirectory = $WorktreeRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $ok = ($proc.ExitCode -eq 0)
    return @{
        ok     = $ok
        id     = [string]$Scenario.id
        title  = [string]$Scenario.title
        exit   = [int]$proc.ExitCode
        stdout = $stdout
        stderr = $stderr
        reason = if ($ok) { 'pass' } else { "exit $($proc.ExitCode)" }
    }
}

function Invoke-HoldoutSuite {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$WorktreeRoot
    )
    $frozen = Get-FrozenHoldoutManifest -RepoPath $RepoPath -BaseSha $BaseSha
    if (-not $frozen.ok) {
        return @{
            ok = $true
            skipped = $true
            reason = $frozen.reason
            results = @()
        }
    }
    $results = @()
    $fail = 0
    foreach ($s in @($frozen.manifest.scenarios)) {
        $r = Invoke-HoldoutScenario -Scenario $s -WorktreeRoot $WorktreeRoot
        $results += $r
        if (-not $r.ok) { $fail++ }
    }
    return @{
        ok       = ($fail -eq 0)
        skipped  = $false
        reason   = if ($fail -eq 0) { 'all pass' } else { "$fail scenario(s) failed" }
        results  = $results
        scenario_count = $results.Count
    }
}

function Format-HoldoutReport {
    param([Parameter(Mandatory)]$SuiteResult)
    if ($SuiteResult.skipped) {
        return "Hold-out: skipped ($($SuiteResult.reason))"
    }
    $lines = @("Hold-out: $($SuiteResult.scenario_count) scenario(s) — $($SuiteResult.reason)")
    foreach ($r in @($SuiteResult.results)) {
        $mark = if ($r.ok) { 'PASS' } else { 'FAIL' }
        $lines += "  [$mark] $($r.id): $($r.title)"
        if (-not $r.ok -and $r.stderr) { $lines += "        $($r.stderr.Trim())" }
    }
    return ($lines -join "`n")
}

function Test-PathIsHoldoutExcluded {
    param([Parameter(Mandatory)][string]$Path)
    $norm = ([string]$Path).Replace('\', '/').TrimStart('./')
    return ($norm -match '(^|/)\.baton/holdout(/|$)')
}
