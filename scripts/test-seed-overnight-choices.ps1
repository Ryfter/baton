#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'choices-lib.ps1')

$script:failures = 0
function Assert([string]$Label, [bool]$Condition) {
    if ($Condition) { Write-Host "PASS  $Label" -ForegroundColor Green }
    else { Write-Host "FAIL  $Label" -ForegroundColor Red; $script:failures++ }
}

$seed = Join-Path $PSScriptRoot 'seed-overnight-choices.ps1'
$previousHome = $env:BATON_HOME
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("baton-seed-overnight-" + [guid]::NewGuid().ToString('N'))
$env:BATON_HOME = Join-Path $tempRoot 'baton-home'

try {
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null

    $firstOutput = @(& pwsh -NoProfile -File $seed 2>&1)
    Assert 'S1 first run succeeds' ($LASTEXITCODE -eq 0)

    $first = @(Get-Choices -BatonHome $env:BATON_HOME)
    Assert 'S2 first run seeds five choices' ($first.Count -eq 5)
    Assert 'S3 every seeded choice is admitted' (@($first | Where-Object status -ne 'admitted').Count -eq 0)
    Assert 'S4 first run prints five ids' (@($firstOutput | Where-Object { "$_" -match '^ch-[0-9a-f]{12}$' }).Count -eq 5)

    $expected = @(
        @{ project = 'canvas-toolchain'; priority = 'P0'; title = 'npm publish + #151 A/B/C' }
        @{ project = 'bookprofile'; priority = 'P1'; title = 'Book DNA surface A/B/C' }
        @{ project = 'atomicforge'; priority = 'P1'; title = 'Push local main?' }
        @{ project = 'bench-gauntlet'; priority = 'P1'; title = 'Stamp v2 scoring contract?' }
        @{ project = 'baton'; priority = 'P2'; title = 'Kill hung fleet-dispatch?' }
    )
    foreach ($want in $expected) {
        $actual = @($first | Where-Object {
            $_.project -eq $want.project -and $_.title -eq $want.title
        })
        Assert "S5 card $($want.project) exists once" ($actual.Count -eq 1)
        if ($actual.Count -eq 1) {
            Assert "S6 card $($want.project) priority" ($actual[0].priority -eq $want.priority)
            Assert "S7 card $($want.project) evidence is report path string" (
                @($actual[0].evidence).Count -eq 1 -and
                $actual[0].evidence[0] -is [string] -and
                $actual[0].evidence[0] -eq "~/.baton/overnight/report-$($want.project).md"
            )
        }
    }

    $secondOutput = @(& pwsh -NoProfile -File $seed 2>&1)
    Assert 'S8 second run succeeds' ($LASTEXITCODE -eq 0)
    $second = @(Get-Choices -BatonHome $env:BATON_HOME)
    Assert 'S9 second run adds zero choices' ($second.Count -eq 5)
    Assert 'S10 second run prints no ids' (@($secondOutput | Where-Object { "$_" -match '^ch-[0-9a-f]{12}$' }).Count -eq 0)

    $draftHome = Join-Path $tempRoot 'draft-home'
    $existing = New-ChoiceDraft -Project 'canvas-toolchain' -Title 'npm publish + #151 A/B/C' `
        -Question 'Existing draft?' `
        -Options @(@{ id = 'a'; label = 'A' }, @{ id = 'b'; label = 'B' }) `
        -RecommendationOptionId 'a' -RecommendationWhy 'Fixture' -BatonHome $draftHome
    $env:BATON_HOME = $draftHome
    [void]@(& pwsh -NoProfile -File $seed 2>&1)
    $afterDraft = @(Get-Choices -BatonHome $draftHome)
    Assert 'S11 matching draft is not duplicated' (
        @($afterDraft | Where-Object {
            $_.project -eq 'canvas-toolchain' -and $_.title -eq 'npm publish + #151 A/B/C'
        }).Count -eq 1
    )
    Assert 'S12 matching draft remains the existing card' (
        @($afterDraft | Where-Object id -eq $existing.id).Count -eq 1
    )
}
finally {
    if ($null -eq $previousHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $previousHome }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { exit 1 }
Write-Host 'ALL PASS'
exit 0
