#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Efficiency Officer — token-saver spine (context select + state delta).
.DESCRIPTION
  Deterministic helpers used by Conductor before instrument prompts and by
  /baton:efficiency. Never blocks labor; fail-open on errors.
#>

function Get-EfficiencyRepoRoot {
    param([string]$RepoPath, [string]$RunDir)
    if (-not [string]::IsNullOrWhiteSpace($RepoPath) -and (Test-Path -LiteralPath $RepoPath)) {
        return (Resolve-Path -LiteralPath $RepoPath).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($RunDir)) {
        $marker = Join-Path $RunDir 'repo-path.txt'
        if (Test-Path -LiteralPath $marker) {
            $p = (Get-Content -LiteralPath $marker -Raw).Trim()
            if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path }
        }
    }
    return $null
}

function Get-EfficiencyTokenSaverDir {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'tools/token_saver')
}

function Get-EfficiencyStatePath {
    param([string]$RepoPath, [string]$RunDir)
    $root = Get-EfficiencyRepoRoot -RepoPath $RepoPath -RunDir $RunDir
    if ($root) { return (Join-Path $root '.token-saver/state.json') }
    if ($RunDir) { return (Join-Path $RunDir '.token-saver/state.json') }
    return $null
}

function Invoke-EfficiencyContextSelect {
    param(
        [Parameter(Mandatory)][string]$Request,
        [string]$Root,
        [string[]]$Source,
        [int]$MaxPacketBytes = 12000,
        [string]$OutputDir
    )
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'fleet-context-select.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @{ ok = $false; reason = 'fleet-context-select.ps1 missing' }
    }
    if (-not $OutputDir) {
        $OutputDir = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-eff-" + [guid]::NewGuid().ToString('n'))
    }
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $outFile = Join-Path $OutputDir 'context-packet.txt'
    $reportFile = Join-Path $OutputDir 'context-packet-report.json'
    $args = @(
        '-NoProfile', '-File', $scriptPath,
        '-Request', $Request,
        '-MaxPacketBytes', $MaxPacketBytes,
        '-Output', $outFile,
        '-Report', $reportFile
    )
    if ($Root) { $args += @('-Root', $Root) }
    foreach ($s in @($Source)) { if ($s) { $args += @('-Source', $s) } }
    try {
        & pwsh @args 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } catch {
        return @{ ok = $false; reason = $_.Exception.Message }
    }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
        return @{ ok = $false; reason = "select_context exit $code"; output_dir = $OutputDir }
    }
    $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    return @{
        ok = $true
        packet = $text
        output = $outFile
        report = $reportFile
        bytes = if ($text) { [Text.Encoding]::UTF8.GetByteCount($text) } else { 0 }
    }
}

function Invoke-EfficiencyStateDeltaPacket {
    param(
        [Parameter(Mandatory)][string]$Change,
        [string]$RepoPath,
        [string]$RunDir
    )
    $state = Get-EfficiencyStatePath -RepoPath $RepoPath -RunDir $RunDir
    if (-not $state) { return @{ ok = $false; reason = 'no state path' } }
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'fleet-state-delta.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @{ ok = $false; reason = 'fleet-state-delta.ps1 missing' }
    }
    $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-delta-" + [guid]::NewGuid().ToString('n') + '.txt')
    $args = @('-NoProfile', '-File', $scriptPath, 'packet', '-State', $state, '-Change', $Change, '-Output', $outFile)
    try {
        & pwsh @args 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } catch {
        return @{ ok = $false; reason = $_.Exception.Message }
    }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
        return @{ ok = $false; reason = "state_delta exit $code" }
    }
    return @{ ok = $true; packet = (Get-Content -LiteralPath $outFile -Raw); output = $outFile }
}

function Build-EfficiencyTaskPrompt {
    <# Shrink a task description using local passage select when a repo root is known. #>
    param(
        [Parameter(Mandatory)][string]$TaskDesc,
        [string]$RepoPath,
        [string]$RunDir,
        [int]$MaxPacketBytes = 12000
    )
    $root = Get-EfficiencyRepoRoot -RepoPath $RepoPath -RunDir $RunDir
    $base = "Task: $TaskDesc"
    if (-not $root) { return $base }

    $delta = Invoke-EfficiencyStateDeltaPacket -Change $TaskDesc -RepoPath $RepoPath -RunDir $RunDir
    if ($delta.ok -and $delta.packet) {
        return @"
Task (delta from accepted state):
$($delta.packet)
"@
    }

    $sel = Invoke-EfficiencyContextSelect -Request $TaskDesc -Root $root -MaxPacketBytes $MaxPacketBytes
    if ($sel.ok -and $sel.packet -and $sel.bytes -gt 0) {
        return @"
Task: $TaskDesc

Relevant context (Efficiency Officer — bounded local select, $($sel.bytes) bytes):
$($sel.packet)
"@
    }
    return $base
}

function Get-CodingProfile {
    param([ValidateSet('python','pwsh','typescript','javascript','nodejs','react','html-css')][string]$Language = 'python')
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $path = Join-Path $repoRoot "references/coding-profiles/$Language.md"
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw) }
    return ''
}
