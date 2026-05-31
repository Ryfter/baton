#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Live smoke test for /six-hats — dispatches 6 role-prefixed prompts to a
  real fleet provider, prints manifest + per-hat file sizes + previews.

.EXAMPLE
  pwsh -NoProfile -File scripts\smoke-six-hats.ps1 `
       -Question "Should we adopt X?" `
       -Providers ollama-local
#>
param(
    [string]$Question = 'Should a small team adopt Rust for a greenfield internal CLI?',
    [string[]]$Providers = @('ollama-local'),
    [int]$TimeoutS = 240,
    [int]$PreviewChars = 400
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'six-hats-lib.ps1')
. (Join-Path $PSScriptRoot 'fleet-ensemble.ps1')

$ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
$outDir = Join-Path $HOME ".claude/ensembles/six-hats-smoke-$ts"
Write-Host "=== Dispatching 6 hats to: $($Providers -join ', ') ===" -ForegroundColor Cyan
Write-Host "Question: $Question"
Write-Host "OutputDir: $outDir"
Write-Host ""

$tasks = Build-SixHatsTasks -Question $Question -Providers $Providers
$m = Invoke-FleetEnsembleTasks -Tasks $tasks -OutputDir $outDir -TimeoutS $TimeoutS

Write-Host "=== Manifest ==="
$m | Format-Table label, provider, status, duration_s -AutoSize

Write-Host "=== File sizes ==="
Get-ChildItem $outDir -Filter *.md | Select-Object Name, Length | Format-Table -AutoSize

foreach ($hat in @('black', 'yellow')) {
    $f = Join-Path $outDir "$hat.md"
    if (Test-Path $f) {
        $text = Get-Content $f -Raw
        $preview = if ($text.Length -gt $PreviewChars) { $text.Substring(0, $PreviewChars) + '...' } else { $text }
        Write-Host "=== Preview: $hat.md (first $PreviewChars chars) ===" -ForegroundColor Cyan
        Write-Host $preview
        Write-Host '---'
    }
}

Write-Host "Output dir: $outDir"
