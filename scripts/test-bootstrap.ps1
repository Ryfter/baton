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
Assert "would deploy saturation-lib.ps1" ($out -match 'saturation-lib\.ps1')
Assert "would deploy effective-cost-lib.ps1" ($out -match 'effective-cost-lib\.ps1')
Assert "would deploy fleet-effective-cost.ps1" ($out -match 'fleet-effective-cost\.ps1')
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
Assert "deploys usage-classify-lib script" ($out -match 'usage-classify-lib\.ps1')
Assert "deploys usage-probe-lib script" ($out -match 'usage-probe-lib\.ps1')
Assert "deploys fleet-usage script"  ($out -match 'fleet-usage\.ps1')
Assert "deploys copilot-credit-lib script (d079 panel needs it on deployed boxes)" ($out -match 'copilot-credit-lib\.ps1')
Assert "deploys fleet-ask script (direct-model commands need it on-box)" ($out -match 'fleet-ask\.ps1')
Assert "deploys projects-lib script"   ($out -match 'projects-lib\.ps1')
Assert "deploys fleet-projects script" ($out -match 'fleet-projects\.ps1')
Assert "deploys research-gate-lib script"   ($out -match 'research-gate-lib\.ps1')
Assert "deploys fleet-research-gate script" ($out -match 'fleet-research-gate\.ps1')
Assert "deploys conductor-lib script" ($out -match 'conductor-lib\.ps1')
Assert "deploys fleet-go script"      ($out -match 'fleet-go\.ps1')
Assert "deploys memory-lib script"   ($out -match 'memory-lib\.ps1')
Assert "deploys fleet-memory script" ($out -match 'fleet-memory\.ps1')
Assert "deploys worker-lib script"   ($out -match 'worker-lib\.ps1')
Assert "deploys fleet-worker script" ($out -match 'fleet-worker\.ps1')
Assert "deploys gate-lib script"   ($out -match 'gate-lib\.ps1')
Assert "deploys fleet-gate script" ($out -match 'fleet-gate\.ps1')
Assert "deploys plan-gate-lib script (Plan Gate d080 needs it on deployed boxes)" ($out -match 'plan-gate-lib\.ps1')
Assert "deploys fleet-plan-gate script (/baton:plan-gate CLI)" ($out -match 'fleet-plan-gate\.ps1')
Assert "would deploy start-lib.ps1" ($out -match 'start-lib\.ps1')
Assert "deploys coach-lib script (v1.8.0 footers need it on deployed boxes)" ($out -match 'coach-lib\.ps1')
Assert "deploys registry-lib script (roster/resolution needed on deployed boxes)" ($out -match 'registry-lib\.ps1')
Assert "deploys fleet-probe-lib script (canary round-trip needed on deployed boxes)" ($out -match 'fleet-probe-lib\.ps1')
Assert "deploys fleet-executor-lib script (agentic -Execute labor needs it on-box)" ($out -match 'fleet-executor-lib\.ps1')
Assert "deploys verification-lib script (Verified Labor d082 V1)" ($out -match 'verification-lib\.ps1')
Assert "deploys verify-noop helper (file-exists-nonempty preset argv target)" ($out -match 'verify-noop\.ps1')
Assert "seeds verify-presets.json into BATON_HOME (preset sugar on deployed boxes)" ($out -match 'verify-presets\.json')
Assert "deploys session-markers-lib script (active detection needs it on-box)" ($out -match 'session-markers-lib\.ps1')
Assert "deploys fleet-project script (/baton:project CLI)" ($out -match 'fleet-project\.ps1')
Assert "would deploy cost-resolver-lib.ps1"    ($out -match 'cost-resolver-lib\.ps1')
Assert "would deploy optimize-prompt-lib.ps1"  ($out -match 'optimize-prompt-lib\.ps1')
Assert "would deploy prompt-pool-lib.ps1"       ($out -match 'prompt-pool-lib\.ps1')
Assert "would deploy fleet-optimize-prompt.ps1" ($out -match 'fleet-optimize-prompt\.ps1')
Assert "would deploy lm-studio-small.ps1" ($out -match 'lm-studio-small\.ps1')
Assert "would seed prime-hours.yaml"    ($out -match 'prime-hours\.yaml')
Assert "would seed the planner prompt (seed-if-absent)" ($out -match 'planner prompt \(seed-if-absent\)')
Assert "does not exit non-zero"          ($LASTEXITCODE -eq 0 -or $out -match 'Bootstrap complete')
Assert "does NOT register hooks anymore" ($out -notmatch 'would register PostToolUse')
Assert "mentions mcp SDK probe"          ($out -match 'mcp SDK|mcp.*package missing|python not on PATH')

# Static check: bootstrap must back up settings.json before overwriting it.
$bootstrapContent = Get-Content (Join-Path $here 'bootstrap.ps1') -Raw
Assert "bootstrap backs up settings.json before overwriting" ($bootstrapContent -match 'Copy-Item.*settings\.json.*\.bak|settingsPath\.bak')

# Static check: the planner prompt must be seeded via the never-overwrite path
# (Copy-IfMissing), not Copy-WithPrompt/-Force — the optimizer mutates the live
# copy and a redeploy must never clobber it.
Assert "planner prompt seeded via Copy-IfMissing (never clobbers a tuned live prompt)" `
    ($bootstrapContent -match 'Copy-IfMissing\s+\$promptSrc\s+\$promptDst')

if ($failures -gt 0) { exit 1 } else { exit 0 }
