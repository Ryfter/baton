#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Accepted-result + delta packet (token-saver state_delta).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('save', 'packet', 'inspect')][string]$Subcommand,
    [Parameter(Mandatory)][string]$State,
    [string]$Accepted,
    [string]$AcceptedFile,
    [string]$Change,
    [string]$ChangeFile,
    [string]$Output,
    [int]$MaxPacketBytes = 16000,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repoRoot 'tools/token_saver/state_delta.py'
if (-not (Test-Path -LiteralPath $script)) {
    [Console]::Error.WriteLine("state_delta not found: $script")
    exit 2
}

$args = @($script, $Subcommand, '--state', $State)
switch ($Subcommand) {
    'save' {
        if ($AcceptedFile) { $args += @('--accepted-file', $AcceptedFile) }
        elseif ($Accepted) { $args += @('--accepted', $Accepted) }
        else { [Console]::Error.WriteLine('save requires -Accepted or -AcceptedFile'); exit 2 }
    }
    'packet' {
        if ($ChangeFile) { $args += @('--change-file', $ChangeFile) }
        elseif ($Change) { $args += @('--change', $Change) }
        else { [Console]::Error.WriteLine('packet requires -Change or -ChangeFile'); exit 2 }
        $args += @('--max-packet-bytes', [string]$MaxPacketBytes)
        if ($Output) { $args += @('--output', $Output) }
    }
    'inspect' { }
}

& python3 @args
$code = $LASTEXITCODE
if ($Json -and $Subcommand -eq 'inspect') {
    # state_delta inspect prints json to stdout already
    exit $code
}
if ($Json) {
    @{ exit = $code; state = $State; output = $Output } | ConvertTo-Json
}
exit $code
