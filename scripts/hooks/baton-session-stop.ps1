#!/usr/bin/env pwsh
<# SessionEnd adapter: clear the session marker and write the resume pointer
   into the project's record (d076). Non-blocking: always exits 0. #>
$ErrorActionPreference = 'Continue'
try {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    function Resolve-Lib([string]$name) {
        @((Join-Path $scriptDir "../$name"), (Join-Path $scriptDir "../scripts/$name")) |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    $mk = Resolve-Lib 'session-markers-lib.ps1'
    $reg = Resolve-Lib 'registry-lib.ps1'
    if (-not $mk -or -not $reg) { exit 0 }
    . $mk
    . $reg   # also dot-sources start-lib (Read-/Write-ProjectRecord) + baton-home

    $sid = $null; $cwd = (Get-Location).Path
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if ($raw) {
                $payload = $raw | ConvertFrom-Json
                if ($payload.session_id) { $sid = [string]$payload.session_id }
                if ($payload.cwd) { $cwd = [string]$payload.cwd }
            }
        }
    } catch { }
    if (-not $sid) { exit 0 }

    # Guard: only write resume pointer for actual project folders
    if (-not (Test-IsProjectFolder -Folder $cwd)) { exit 0 }

    $cleared = Clear-SessionMarker -SessionId $sid
    $agent = if ($cleared -and $cleared.agent) { [string]$cleared.agent } else { 'claude' }

    # Write the resume pointer into the project record (merge, don't clobber).
    $batonHome = Get-BatonHome
    $projectsRoot = Join-Path $batonHome 'projects'
    $projId = Get-ProjectId -Folder $cwd
    $existing = Read-ProjectRecord -ProjectId $projId -ProjectsRoot $projectsRoot
    $rec = @{}
    if ($existing) { foreach ($p in $existing.PSObject.Properties) { $rec[$p.Name] = $p.Value } }
    $rec['id'] = $projId
    if (-not $rec.ContainsKey('name')) { $rec['name'] = (Split-Path -Leaf $cwd) }
    if (-not $rec.ContainsKey('folder')) { $rec['folder'] = $cwd }
    $rec['agent'] = $agent
    $rec['last_session_id'] = $sid
    $rec['last_ended_at'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-ProjectRecord -Record $rec -ProjectsRoot $projectsRoot
    exit 0
} catch { exit 0 }
