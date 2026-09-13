#!/usr/bin/env pwsh
<#
.SYNOPSIS
  baton hud -- thin passthrough to `python -m hud`. All logic lives in Python
  (hud/__main__.py, hud/servicectl.py); this file only picks an interpreter
  and forwards argv, exit code included.
#>
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

# Prefer the repo's own venv -- a bare python3/python resolved from PATH may
# lack FastAPI/uvicorn (or any of hud's deps), which crashes even the
# subcommands that don't need them (C2). Try POSIX layout first, then
# Windows (venv's own layout differs by platform), before falling back to
# PATH.
$venvPythonPosix = Join-Path $repoRoot ".venv/bin/python"
$venvPythonWindows = Join-Path $repoRoot ".venv/Scripts/python.exe"
if (Test-Path $venvPythonPosix) {
    $pythonPath = $venvPythonPosix
} elseif (Test-Path $venvPythonWindows) {
    $pythonPath = $venvPythonWindows
} else {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) {
        Write-Error "baton hud: no .venv/bin/python, no .venv/Scripts/python.exe, and no python3/python on PATH"
        exit 1
    }
    $pythonPath = $python.Path
}

Push-Location $repoRoot
try {
    & $pythonPath -m hud @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
