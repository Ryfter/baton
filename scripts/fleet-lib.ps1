#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared library for the fleet dispatch layer. Dot-source from the slash
  command, doctor, and tests.

.DESCRIPTION
  Parses fleet.yaml (hand-rolled minimal parser — shallow schema only),
  resolves command templates, dispatches to cli/http providers, and journals
  each invocation. See docs/superpowers/specs/2026-05-26-plan4-fleet-design.md.
#>

$script:DefaultFleetPath = (Join-Path $HOME '.claude/fleet.yaml')

function ConvertFrom-FleetValue {
    # Strip surrounding quotes; coerce true/false to bool.
    param([string]$Raw)
    $v = $Raw.Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    return $v
}

function Read-Fleet {
    <# Parse fleet.yaml into an array of provider hashtables. #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) {
        throw "fleet.yaml not found at $Path. Run scripts/bootstrap.ps1 to deploy the seed."
    }
    $providers = [System.Collections.ArrayList]@()
    $current = $null
    $inEnv = $false
    $envIndent = 0

    foreach ($rawLine in (Get-Content $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^providers:\s*$') { continue }

        # New provider: "  - name: <value>"
        if ($rawLine -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$providers.Add($current) }
            $current = @{ name = (ConvertFrom-FleetValue $matches[2]); env = $null }
            $inEnv = $false
            continue
        }
        if (-not $current) { continue }

        $indent = ($rawLine -replace '\S.*$', '').Length

        # env: block opener (no value on the line)
        if ($rawLine -match '^(\s+)env:\s*$') {
            $current.env = @{}
            $inEnv = $true
            $envIndent = $matches[1].Length
            continue
        }

        # env entry (deeper indentation than the env: key)
        if ($inEnv -and $indent -gt $envIndent -and $rawLine -match '^\s+([\w.-]+):\s*(.+?)\s*$') {
            $current.env[$matches[1]] = (ConvertFrom-FleetValue $matches[2])
            continue
        }

        # indentation returned to field level — exit env block and fall through
        if ($inEnv) {
            $inEnv = $false
        }

        # ordinary field (including lines that just exited the env block)
        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $key = $matches[1]
            $val = $matches[2]
            # Skip env key when it has no value (already handled above); value would be empty
            if ($key -eq 'env' -and $val -eq '') { continue }
            $current[$key] = (ConvertFrom-FleetValue $val)
        }
    }
    if ($current) { [void]$providers.Add($current) }
    return $providers.ToArray()
}

function Get-FleetProvider {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = $script:DefaultFleetPath
    )
    return (Read-Fleet -Path $Path | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}
