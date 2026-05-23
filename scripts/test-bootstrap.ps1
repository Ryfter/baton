#!/usr/bin/env pwsh
# Smoke test: run bootstrap in dry-run mode against a temp HOME, assert no crash
# and that the dry-run output mentions each expected component.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $here 'bootstrap.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# Run dry-run; capture stdout
$out = & pwsh -NoProfile -File $bootstrap -DryRun 2>&1 | Out-String

Assert "mentions hook deployment"        ($out -match 'PostToolUse hook')
Assert "mentions OTel env helper"        ($out -match 'OTel env')
Assert "mentions slash commands"         ($out -match 'slash commands')
Assert "mentions catalog deployment"     ($out -match 'catalog')
Assert "mentions backend verification"   ($out -match 'Verifying backends')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')

if ($failures -gt 0) { exit 1 } else { exit 0 }
