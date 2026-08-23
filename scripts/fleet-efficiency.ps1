#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:efficiency — Efficiency Officer CLI (token-saver spine).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('select','delta-packet','profile','brief')][string]$Subcommand = 'select',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest,
    [string]$Request,
    [string]$Root,
    [string[]]$Source,
    [string]$Change,
    [string]$State,
    [ValidateSet('python','pwsh','typescript','javascript','nodejs','react','html-css')][string]$Language = 'python',
    [int]$MaxPacketBytes = 12000,
    [string]$Output,
    [string]$Report,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'efficiency-lib.ps1')

function Err([string]$m) { [Console]::Error.WriteLine($m); exit 2 }

switch ($Subcommand) {
    'select' {
        if (-not $Request -and $Rest.Count -gt 0) { $Request = ($Rest -join ' ') }
        if (-not $Request) { Err 'usage: fleet-efficiency select -Request "..." [-Root path]' }
        $r = Invoke-EfficiencyContextSelect -Request $Request -Root $Root -Source $Source -MaxPacketBytes $MaxPacketBytes
        if (-not $r.ok) { Err $r.reason }
        if ($Output -and $r.output) { Copy-Item -LiteralPath $r.output -Destination $Output -Force }
        if ($Report -and $r.report) { Copy-Item -LiteralPath $r.report -Destination $Report -Force }
        if ($Json) { $r | ConvertTo-Json -Depth 4 } else { Write-Output $r.packet }
        exit 0
    }
    'delta-packet' {
        if (-not $Change) { Err 'delta-packet requires -Change' }
        $r = Invoke-EfficiencyStateDeltaPacket -Change $Change -RepoPath $Root
        if (-not $r.ok) { Err $r.reason }
        if ($Json) { $r | ConvertTo-Json -Depth 3 } else { Write-Output $r.packet }
        exit 0
    }
    'profile' {
        $text = Get-CodingProfile -Language $Language
        if ($Json) { @{ language = $Language; body = $text } | ConvertTo-Json } else { Write-Output $text }
        exit 0
    }
    'brief' {
        $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'prompts/efficiency-officer.txt'
        if (-not (Test-Path -LiteralPath $p)) { Err "missing $p" }
        Get-Content -LiteralPath $p -Raw
        exit 0
    }
    default { Err "unknown subcommand: $Subcommand" }
}
