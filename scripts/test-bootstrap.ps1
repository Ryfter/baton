#!/usr/bin/env pwsh
# Smoke test: run bootstrap in dry-run mode against the real $HOME -- the dry-run
# gate prevents writes, so this is safe. Asserts no crash and that dry-run output
# mentions each expected component.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $here 'bootstrap.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# Run dry-run; capture stdout. -NonInteractive so a differing deployed file can
# never block the smoke test on a Read-Host prompt.
$out = & pwsh -NoProfile -File $bootstrap -DryRun -NonInteractive 2>&1 | Out-String

Assert "mentions hook deployment"        ($out -match 'PostToolUse hook')
Assert "mentions OTel env helper"        ($out -match 'OTel env')
Assert "mentions slash commands"         ($out -match 'slash commands')
Assert "mentions catalog deployment"     ($out -match 'catalog')
Assert "mentions backend verification"   ($out -match 'Verifying backends')
Assert "would deploy idea-lib.ps1"        ($out -match 'idea-lib\.ps1')
Assert "would deploy idea.md"             ($out -match 'idea\.md')
Assert "would deploy tools.yaml"          ($out -match 'tools\.yaml')
Assert "would deploy tools.md"            ($out -match 'tools\.md')
Assert "would deploy routing-lib.ps1"     ($out -match 'routing-lib\.ps1')
Assert "would deploy route.md"            ($out -match 'route\.md')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')

# Static check: bootstrap must back up settings.json before overwriting it.
$bootstrapContent = Get-Content (Join-Path $here 'bootstrap.ps1') -Raw
Assert "bootstrap backs up settings.json before overwriting" ($bootstrapContent -match 'Copy-Item.*settings\.json.*\.bak|settingsPath\.bak')

if ($failures -gt 0) { exit 1 } else { exit 0 }
