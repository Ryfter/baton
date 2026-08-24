#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Agent observability sidecars — AgentTrail live map + optional AgentPulse snapshot.

.DESCRIPTION
  Invoke, don't absorb: starts agenttrail per worktree, records port under
  $BATON_HOME/observability/, and optionally refreshes agentpulse.json for the
  dashboard attention rail.

  Set BATON_AGENTTRAIL=0 to skip sidecar probes from Python readers.
#>
param(
    [ValidateSet('start', 'stop', 'status', 'snapshot')]
    [string]$Action = 'status',
    [string]$Project = '',
    [string]$Folder = '',
    [int]$Port = 0,
    [switch]$Open,
    [switch]$Json
)

. "$PSScriptRoot/baton-home.ps1"

$obsRoot = Join-Path $BatonHome 'observability'
$trailRoot = Join-Path $obsRoot 'agenttrail'
$pulsePath = Join-Path $obsRoot 'agentpulse.json'

function Write-Json($obj) {
    if ($Json) { $obj | ConvertTo-Json -Depth 8 -Compress:$false }
}

function Resolve-ProjectFolder {
    param([string]$ProjectId, [string]$ExplicitFolder)
    if ($ExplicitFolder -and (Test-Path -LiteralPath $ExplicitFolder)) {
        return (Resolve-Path -LiteralPath $ExplicitFolder).Path
    }
    if (-not $ProjectId) { return $null }
    $rec = Join-Path $BatonHome "projects/$ProjectId/project.json"
    if (-not (Test-Path -LiteralPath $rec)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $rec -Raw | ConvertFrom-Json
        $folder = [string]$doc.folder
        if ($folder -and (Test-Path -LiteralPath $folder)) { return (Resolve-Path -LiteralPath $folder).Path }
    } catch { }
    return $null
}

function Get-TrailMetaPath {
    param([string]$ProjectId)
    return Join-Path $trailRoot "$ProjectId.json"
}

function Read-TrailMeta {
    param([string]$ProjectId)
    $p = Get-TrailMetaPath -ProjectId $ProjectId
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { return $null }
}

function Test-TrailAlive {
    param([int]$PortNum)
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PortNum/" -TimeoutSec 1 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Start-AgentTrailSidecar {
    param([string]$FolderPath, [string]$ProjectId, [int]$PreferredPort)

    $null = New-Item -ItemType Directory -Force -Path $trailRoot | Out-Null
    $meta = Read-TrailMeta -ProjectId $ProjectId
    if ($meta -and $meta.port -and (Test-TrailAlive -PortNum ([int]$meta.port))) {
        return @{ ok = $true; port = [int]$meta.port; pid = $meta.pid; already = $true; folder = $FolderPath }
    }

    $portArg = if ($PreferredPort -gt 0) { $PreferredPort } else { 5330 }
    $logDir = Join-Path $obsRoot 'logs'
    $null = New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir "agenttrail-$ProjectId.log"

    $openFlag = if ($Open) { '--open' } else { @() }
    $args = @('agenttrail', '--port', "$portArg") + @($openFlag)
    $psi = @{
        FilePath               = 'npx'
        ArgumentList           = $args
        WorkingDirectory       = $FolderPath
        RedirectStandardOutput = $log
        RedirectStandardError  = $log
        PassThru               = $true
        WindowStyle            = 'Hidden'
    }
    $proc = Start-Process @psi
    Start-Sleep -Seconds 2

    $bound = $null
    foreach ($p in ($portArg..($portArg + 14))) {
        if (Test-TrailAlive -PortNum $p) { $bound = $p; break }
    }
    if (-not $bound) {
        return @{ ok = $false; error = 'agenttrail did not bind a port'; log = $log }
    }

    $record = @{
        project_id = $ProjectId
        folder     = $FolderPath
        port       = $bound
        pid        = $proc.Id
        started_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-TrailMetaPath -ProjectId $ProjectId) -Encoding utf8
    return @{ ok = $true; port = $bound; pid = $proc.Id; already = $false; folder = $FolderPath; log = $log }
}

function Stop-AgentTrailSidecar {
    param([string]$ProjectId)
    $meta = Read-TrailMeta -ProjectId $ProjectId
    if (-not $meta) { return @{ ok = $true; stopped = $false } }
    if ($meta.pid) {
        try { Stop-Process -Id ([int]$meta.pid) -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item -LiteralPath (Get-TrailMetaPath -ProjectId $ProjectId) -Force -ErrorAction SilentlyContinue
    return @{ ok = $true; stopped = $true; project_id = $ProjectId }
}

function Invoke-AgentPulseSnapshot {
    $null = New-Item -ItemType Directory -Force -Path $obsRoot | Out-Null
    $tmp = Join-Path $env:TEMP "agentpulse-$(Get-Random).json"
    try {
        & npx --yes @conalh/agentpulse@latest live --once --format json --output $tmp 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
            return @{ ok = $false; error = 'agentpulse snapshot failed' }
        }
        Copy-Item -LiteralPath $tmp -Destination $pulsePath -Force
        $doc = Get-Content -LiteralPath $pulsePath -Raw | ConvertFrom-Json
        return @{ ok = $true; path = $pulsePath; sessions = @($doc.sessions).Count }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

$folderPath = Resolve-ProjectFolder -ProjectId $Project -ExplicitFolder $Folder
$result = switch ($Action) {
    'start' {
        if (-not $folderPath -or -not $Project) {
            @{ ok = $false; error = 'Need -Project and resolvable folder (or -Folder)' }
        } else {
            Start-AgentTrailSidecar -FolderPath $folderPath -ProjectId $Project -PreferredPort $Port
        }
    }
    'stop' {
        if (-not $Project) { @{ ok = $false; error = 'Need -Project' } }
        else { Stop-AgentTrailSidecar -ProjectId $Project }
    }
    'status' {
        $rows = @()
        if (Test-Path -LiteralPath $trailRoot) {
            Get-ChildItem -LiteralPath $trailRoot -Filter '*.json' | ForEach-Object {
                try {
                    $m = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                    $alive = $false
                    if ($m.port) { $alive = Test-TrailAlive -PortNum ([int]$m.port) }
                    $rows += @{
                        project_id = $m.project_id
                        folder     = $m.folder
                        port       = $m.port
                        alive      = $alive
                        map_url    = if ($m.port) { "http://127.0.0.1:$($m.port)" } else { '' }
                    }
                } catch { }
            }
        }
        @{
            ok           = $true
            sidecars     = $rows
            pulse_path   = $(if (Test-Path -LiteralPath $pulsePath) { $pulsePath } else { $null })
            pulse_exists = (Test-Path -LiteralPath $pulsePath)
        }
    }
    'snapshot' { Invoke-AgentPulseSnapshot }
}

Write-Json $result
if (-not $result.ok) { exit 1 }
