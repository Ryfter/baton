#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("proj-create-" + [guid]::NewGuid().ToString('N'))
$devRoot = Join-Path $tmp 'Dev'
$batonHome = Join-Path $tmp 'baton'
$grimdex = Join-Path $tmp 'Grimdex'
$grimlore = Join-Path $tmp 'Grimlore'
New-Item -ItemType Directory -Force -Path $devRoot, $batonHome, $grimdex, $grimlore | Out-Null

$prevHome = $env:BATON_HOME
$prevRoot = $env:BATON_PROJECTS_ROOT
$prevGx = $env:GRIMDEX_ROOT
$prevGl = $env:GRIMLORE_ROOT
$env:BATON_HOME = $batonHome
$env:BATON_PROJECTS_ROOT = $devRoot
$env:GRIMDEX_ROOT = $grimdex
$env:GRIMLORE_ROOT = $grimlore

try {
    . (Join-Path $PSScriptRoot 'project-create-lib.ps1')

    Check 'PC1 slug' ((ConvertTo-ProjectSlug -Text 'My Cool App') -eq 'my-cool-app')
    Check 'PC2 home root uses BATON_PROJECTS_ROOT' ((Get-ProjectHomeRoot) -eq $devRoot)

    $created = New-BatonProject -Name 'Widget Lab' -Description 'A widget experiment' `
        -SkipGitHub -BatonHome $batonHome -ProjectsRoot $devRoot
    Check 'PC3 folder created' (Test-Path -LiteralPath $created.folder)
    Check 'PC4 charter exists' (Test-Path -LiteralPath (Join-Path $created.folder 'CHARTER.md'))
    Check 'PC4b PLAN.md skeleton' (Test-Path -LiteralPath (Join-Path $created.folder 'PLAN.md'))
    $planText = Get-Content -LiteralPath (Join-Path $created.folder 'PLAN.md') -Raw
    Check 'PC4c PLAN.md has component id' ($planText -match '\{#[a-z0-9-]+\}')
    Check 'PC5 registry record' (Test-Path -LiteralPath (Join-Path $batonHome 'projects/widget-lab/project.json'))
    Check 'PC6 grimdex tier' (Test-Path -LiteralPath (Join-Path $grimdex 'projects/widget-lab/decision-guidance.md'))
    Check 'PC7 grimlore bundle' (Test-Path -LiteralPath (Join-Path $grimlore 'projects/widget-lab/index.md'))

    $parsed = Invoke-MaestroNewProjectLine -Line 'new project Gadget — handy tools' -BatonHome $batonHome
    Check 'PC8 room line parses id' ([string]$parsed.id -eq 'gadget')
    Check 'PC9 room line sets blurb' ([string]$parsed.blurb -match 'handy tools')
} finally {
    $env:BATON_HOME = $prevHome
    $env:BATON_PROJECTS_ROOT = $prevRoot
    $env:GRIMDEX_ROOT = $prevGx
    $env:GRIMLORE_ROOT = $prevGl
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
Write-Host 'project-create-lib: all checks passed'
exit 0
