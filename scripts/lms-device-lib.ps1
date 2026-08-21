#!/usr/bin/env pwsh
<# LM Link device identity + activity.

   Box identity is invisible to the REST API: both /v1/models and the native
   /api/v1/models omit the device. Only the `lms` CLI carries deviceIdentifier,
   so placement and busy-checks must go through it (baton-d120).

   Split on purpose: Convert-* / Resolve-* are pure and unit-tested offline;
   Get-Lms* shell out and are smoke-tested only when `lms` is on PATH. #>

function Convert-LmsLinkStatus {
    <# `lms link status` is human-formatted, not JSON. Parse identifier -> name.
       Returns @{ devices = @(@{name; identifier; status}); local = <name> } #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $devices = @()
    $local = ''
    $current = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*This device:\s*(.+?)\s*$') { $local = $Matches[1]; continue }
        # Device bullets sit at the top indent level; `Loaded Models Instances:`
        # nests its own bullets deeper, and those are NOT devices.
        if ($line -match '^(\s*)-\s+(.+?)\s*$') {
            if ($Matches[1].Length -le 3) {
                if ($null -ne $current) { $devices += $current }
                $current = @{ name = $Matches[2]; identifier = ''; status = '' }
            }
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*Identifier:\s*([0-9a-fA-F]+)\s*$') { $current.identifier = $Matches[1] }
        elseif ($line -match '^\s*Status:\s*(.+?)\s*$') { $current.status = $Matches[1] }
    }
    if ($null -ne $current) { $devices += $current }
    return @{ devices = $devices; local = $local }
}

function Test-LmsStatusBusy {
    <# Which `lms ps` status strings mean the box is actively working.
       Idle-but-resident models still hold VRAM; they do not block dispatch. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Status)
    return ([string]$Status).ToLowerInvariant() -in @('generating', 'processingprompt', 'processing')
}

function Resolve-LmsBoxActivity {
    <# Fold `lms ps --json` rows into one record per known device.
       DeviceMap comes from Convert-LmsLinkStatus. Devices with nothing loaded
       are reported explicitly as idle rather than omitted. #>
    param(
        [Parameter(Mandatory)][AllowNull()]$LoadedRows,
        [Parameter(Mandatory)][hashtable]$DeviceMap
    )
    $byId = @{}
    foreach ($d in @($DeviceMap.devices)) {
        $byId[[string]$d.identifier] = @{
            name = [string]$d.name; identifier = [string]$d.identifier
            reachable = ([string]$d.status -eq 'connected'); busy = $false
            models = @(); vram_bytes = [long]0
        }
    }
    $localName = [string]$DeviceMap.local
    if ($localName -and -not ($byId.Values | Where-Object { $_.name -eq $localName })) {
        $byId[''] = @{ name = $localName; identifier = ''; reachable = $true
                       busy = $false; models = @(); vram_bytes = [long]0 }
    }
    foreach ($row in @($LoadedRows)) {
        if ($null -eq $row) { continue }
        $id = if ($null -ne $row.PSObject.Properties['deviceIdentifier'] -and $row.deviceIdentifier) {
            [string]$row.deviceIdentifier } else { '' }
        if (-not $byId.ContainsKey($id)) {
            $byId[$id] = @{ name = if ($id) { $id } else { $localName }; identifier = $id
                            reachable = $true; busy = $false; models = @(); vram_bytes = [long]0 }
        }
        $status = [string]$row.status
        $busy = Test-LmsStatusBusy -Status $status
        $byId[$id].models += @{
            identifier = [string]$row.identifier; status = $status; busy = $busy
            size_bytes = [long]$row.sizeBytes
        }
        $byId[$id].vram_bytes += [long]$row.sizeBytes
        if ($busy) { $byId[$id].busy = $true }
    }
    return @($byId.Values | Sort-Object { $_.name })
}

function Get-LmsDeviceMap {
    param([string]$LmsPath = 'lms')
    $text = & $LmsPath link status 2>&1 | Out-String
    return Convert-LmsLinkStatus -Text $text
}

function Get-LmsLoadedRows {
    param([string]$LmsPath = 'lms')
    $raw = & $LmsPath ps --json 2>&1 | Out-String
    if (-not $raw.Trim()) { return @() }
    try { return @($raw | ConvertFrom-Json) } catch { return @() }
}

function Get-LmsBoxActivity {
    <# One call: what is loaded and what is busy, per box, fleet-wide. #>
    param([string]$LmsPath = 'lms')
    return Resolve-LmsBoxActivity -LoadedRows (Get-LmsLoadedRows -LmsPath $LmsPath) `
                                  -DeviceMap  (Get-LmsDeviceMap  -LmsPath $LmsPath)
}
