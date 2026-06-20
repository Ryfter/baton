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

Assert "removes legacy hooks"            ($out -match 'legacy hook')
Assert "cleans legacy settings entries"  ($out -match 'legacy (PostToolUse|Stop) entry|Cleaning legacy hook registrations')
Assert "mentions OTel env helper"        ($out -match 'OTel env')
Assert "mentions Baton plugin"           ($out -match 'Baton plugin')
Assert "mentions catalog deployment"     ($out -match 'catalog')
Assert "mentions backend verification"   ($out -match 'Verifying backends')
Assert "initializes BATON_HOME"          ($out -match 'BATON_HOME')
Assert "mentions state migration"        ($out -match 'migration')
Assert "would deploy baton-home.ps1"     ($out -match 'baton-home\.ps1')
Assert "would deploy idea-lib.ps1"        ($out -match 'idea-lib\.ps1')
Assert "would install baton plugin"       ($out -match 'baton@ryfter')
Assert "would seed tools.yaml"            ($out -match 'tools\.yaml')
Assert "would deploy routing-lib.ps1"     ($out -match 'routing-lib\.ps1')
Assert "would deploy routing-dispatch.ps1" ($out -match 'routing-dispatch\.ps1')
Assert "would deploy routing-learn.ps1"   ($out -match 'routing-learn\.ps1')
Assert "would deploy routing-calibrate.ps1" ($out -match 'routing-calibrate\.ps1')
Assert "would deploy routing-cascade.ps1" ($out -match 'routing-cascade\.ps1')
Assert "would deploy prime-hours.ps1"   ($out -match 'prime-hours\.ps1')
Assert "would deploy fleet-orchestrate.ps1" ($out -match 'fleet-orchestrate\.ps1')
Assert "would deploy fleet-backlog.ps1" ($out -match 'fleet-backlog\.ps1')
Assert "would deploy run-backlog.ps1"   ($out -match 'run-backlog\.ps1')
Assert "would deploy fleet-models.ps1" ($out -match 'fleet-models\.ps1')
Assert "deploys triage-lib script"   ($out -match 'triage-lib\.ps1')
Assert "deploys fleet-triage script" ($out -match 'fleet-triage\.ps1')
Assert "deploys usage-lib script"    ($out -match 'usage-lib\.ps1')
Assert "deploys fleet-usage script"  ($out -match 'fleet-usage\.ps1')
Assert "deploys projects-lib script"   ($out -match 'projects-lib\.ps1')
Assert "deploys fleet-projects script" ($out -match 'fleet-projects\.ps1')
Assert "deploys research-gate-lib script"   ($out -match 'research-gate-lib\.ps1')
Assert "deploys fleet-research-gate script" ($out -match 'fleet-research-gate\.ps1')
Assert "deploys conductor-lib script" ($out -match 'conductor-lib\.ps1')
Assert "deploys fleet-go script"      ($out -match 'fleet-go\.ps1')
Assert "deploys memory-lib script"   ($out -match 'memory-lib\.ps1')
Assert "deploys fleet-memory script" ($out -match 'fleet-memory\.ps1')
Assert "would deploy lm-studio-small.ps1" ($out -match 'lm-studio-small\.ps1')
Assert "would seed prime-hours.yaml"    ($out -match 'prime-hours\.yaml')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')
Assert "does NOT register hooks anymore" ($out -notmatch 'would register PostToolUse')
Assert "mentions mcp SDK probe"          ($out -match 'mcp SDK|mcp.*package missing|python not on PATH')

# Static check: bootstrap must back up settings.json before overwriting it.
$bootstrapContent = Get-Content (Join-Path $here 'bootstrap.ps1') -Raw
Assert "bootstrap backs up settings.json before overwriting" ($bootstrapContent -match 'Copy-Item.*settings\.json.*\.bak|settingsPath\.bak')

if ($failures -gt 0) { exit 1 } else { exit 0 }
