#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/efficiency-lib.ps1"

function Assert($name, $cond) {
    if (-not $cond) { Write-Host "FAIL: $name" -ForegroundColor Red; exit 1 }
    Write-Host "ok: $name" -ForegroundColor Green
}

Assert 'Get-CodingProfile python' { (Get-CodingProfile -Language python) -match 'pytest' }
Assert 'Build-EfficiencyTaskPrompt no root' {
    $p = Build-EfficiencyTaskPrompt -TaskDesc 'fix tests' -RepoPath '' -RunDir ''
    $p -eq 'Task: fix tests'
}

$repo = Split-Path -Parent $PSScriptRoot
Assert 'Build-EfficiencyTaskPrompt with repo' {
    $p = Build-EfficiencyTaskPrompt -TaskDesc 'bootstrap octopus' -RepoPath $repo
    $p -match 'Task:' -and $p.Length -gt 20
}

Write-Host 'efficiency-lib tests passed' -ForegroundColor Cyan
