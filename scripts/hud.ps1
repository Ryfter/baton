#!/usr/bin/env pwsh
<#
.SYNOPSIS
  baton hud -- thin passthrough to `python -m hud`. All logic lives in Python
  (hud/__main__.py, hud/servicectl.py); this file only picks an interpreter
  and forwards argv, exit code included.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$python = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Error "baton hud: no python3/python on PATH"
    exit 1
}

Push-Location $repoRoot
try {
    & $python.Path -m hud @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
