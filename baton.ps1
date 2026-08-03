#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Repo-root shim — forwards to scripts/baton.ps1 with full argument passthrough.
#>
$ErrorActionPreference = 'Stop'
$dispatcher = Join-Path $PSScriptRoot 'scripts' 'baton.ps1'
if (-not (Test-Path -LiteralPath $dispatcher)) {
    [Console]::Error.WriteLine("baton: dispatcher not found at $dispatcher")
    exit 1
}
# Do not bind automatic $args to a variable named $args.
$forward = @($args)
& pwsh -NoProfile -File $dispatcher @forward
exit $LASTEXITCODE
