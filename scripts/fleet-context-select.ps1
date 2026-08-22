#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Select bounded context passages (token-saver) without a model call.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Request,
    [string]$Root,
    [string[]]$Source,
    [string]$Output,
    [string]$Report,
    [int]$MaxPacketBytes = 12000,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script = Join-Path $repoRoot 'tools/token_saver/select_context.py'
if (-not (Test-Path -LiteralPath $script)) {
    [Console]::Error.WriteLine("token-saver script not found: $script")
    exit 2
}

$args = @(
    $script,
    '--request', $Request,
    '--max-packet-bytes', [string]$MaxPacketBytes
)
if ($Root) { $args += @('--root', $Root) }
foreach ($s in @($Source)) { if ($s) { $args += @('--source', $s) } }
if ($Output) { $args += @('--output', $Output) }
if ($Report) { $args += @('--report', $Report) }

& python3 @args
$code = $LASTEXITCODE
if ($Json) {
    $obj = [ordered]@{ exit = $code; output = $Output; report = $Report }
    if ($Report -and (Test-Path -LiteralPath $Report)) {
        $obj.report_json = (Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json)
    }
    $obj | ConvertTo-Json -Depth 6
}
exit $code
