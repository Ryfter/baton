#!/usr/bin/env pwsh
# Tests for scripts/consolidate-decisions.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# Build a KB with 2 projects, each having one positive-feedback record for the same pattern.
$kb = Join-Path $env:TEMP "dec-cons-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $kb | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $kb 'universal') | Out-Null

# Project A — Start-Job decision, positive feedback
$rA = Add-DecisionRecord -Title "Use Start-Job for ensemble" `
    -Chosen "Start-Job per provider." -Alternatives @("subagents") `
    -Rationale "Env isolation." -Confidence 'high' -RevisitIf "scale beyond 5" `
    -Project 'projA' -KbRoot $kb
Append-DecisionFeedback -Id $rA.id -Project 'projA' -Text "worked great" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project B — same pattern, positive feedback
$rB = Add-DecisionRecord -Title "Use Start-Job for ensemble" `
    -Chosen "Start-Job per provider." -Alternatives @("subagents") `
    -Rationale "Env isolation." -Confidence 'med' -RevisitIf "scale beyond 5" `
    -Project 'projB' -KbRoot $kb
Append-DecisionFeedback -Id $rB.id -Project 'projB' -Text "smooth" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project A — solo decision (no cross-project signal), positive
$rA2 = Add-DecisionRecord -Title "Use Markdown for KB" `
    -Chosen "Markdown files." -Alternatives @("SQLite") `
    -Rationale "Inspectable." -Confidence 'high' -RevisitIf "performance issues" `
    -Project 'projA' -KbRoot $kb
Append-DecisionFeedback -Id $rA2.id -Project 'projA' -Text "fine" -Outcome 'worked' -Author 'kevin' -KbRoot $kb

# Project C — solo decision, negative
$rC = Add-DecisionRecord -Title "Use runspaces for parallel" `
    -Chosen "ForEach -Parallel." -Alternatives @("Start-Job") `
    -Rationale "Lightweight." -Confidence 'low' -RevisitIf "env collision" `
    -Project 'projC' -KbRoot $kb
Append-DecisionFeedback -Id $rC.id -Project 'projC' -Text "collisions broke it" -Outcome 'didnt' -Author 'kevin' -KbRoot $kb

# Run the consolidator
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-decisions.ps1') -KbRoot $kb | Out-Null

# --- Project guidance files exist for every project that had records ---
foreach ($p in @('projA','projB','projC')) {
    Assert "project $p guidance file exists" (Test-Path (Join-Path $kb "projects/$p/decision-guidance.md"))
}

# --- Project guidance: Project A's Markdown decision recorded ---
$gA = Get-Content (Join-Path $kb 'projects/projA/decision-guidance.md') -Raw
Assert "projA guidance mentions Markdown" ($gA -match 'Markdown')

# --- Project C's runspaces decision should appear under 'Known mistakes' (negative feedback) ---
$gC = Get-Content (Join-Path $kb 'projects/projC/decision-guidance.md') -Raw
Assert "projC guidance has Known mistakes" ($gC -match '## Known mistakes')
Assert "projC mistake mentions runspaces" ($gC -match 'runspaces')

# --- Universal guidance: Start-Job pattern promoted (>=2 projects with outcome:worked) ---
$uni = Get-Content (Join-Path $kb 'universal/decision-guidance.md') -Raw
Assert "universal mentions Start-Job pattern" ($uni -match 'Start-Job')

# --- Universal guidance: Markdown decision NOT promoted (only 1 project) ---
Assert "universal does NOT mention Markdown (only 1 project)" ($uni -notmatch 'Markdown')

# --- Records marked consolidated (idempotency footer) ---
$cA = Get-Content $rA.path -Raw
Assert "rA marked consolidated" ($cA -match '<!-- consolidated \d{4}-\d{2}-\d{2} -->')

# --- Second run is a no-op: counts of pattern mentions don't grow ---
$beforeCount = ([regex]::Matches($uni, 'Start-Job')).Count
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'consolidate-decisions.ps1') -KbRoot $kb | Out-Null
$uni2 = Get-Content (Join-Path $kb 'universal/decision-guidance.md') -Raw
$afterCount = ([regex]::Matches($uni2, 'Start-Job')).Count
Assert "second run is a no-op (universal mention count unchanged)" ($beforeCount -eq $afterCount)

Remove-Item $kb -Recurse -Force
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
