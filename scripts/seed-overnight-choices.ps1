#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'choices-lib.ps1')

$cards = @(
    @{
        project = 'canvas-toolchain'
        priority = 'P0'
        title = 'npm publish + #151 A/B/C'
        question = 'How should the npm publish and issue #151 work proceed?'
        options = @(
            @{ id = 'a'; label = 'A'; summary = 'Publish first, then handle #151' }
            @{ id = 'b'; label = 'B'; summary = 'Handle #151 before publishing' }
            @{ id = 'c'; label = 'C'; summary = 'Defer both for now' }
        )
        recommendation = 'a'
        why = 'Unblock package consumers, then address the follow-up choice.'
    }
    @{
        project = 'bookprofile'
        priority = 'P1'
        title = 'Book DNA surface A/B/C'
        question = 'Which surface should expose Book DNA?'
        options = @(
            @{ id = 'a'; label = 'A'; summary = 'Public surface' }
            @{ id = 'b'; label = 'B'; summary = 'Private surface' }
            @{ id = 'c'; label = 'C'; summary = 'Hybrid surface' }
        )
        recommendation = 'c'
        why = 'A hybrid keeps personal detail private while allowing selected publishing.'
    }
    @{
        project = 'atomicforge'
        priority = 'P1'
        title = 'Push local main?'
        question = 'Should the local main branch be pushed?'
        options = @(
            @{ id = 'yes'; label = 'Push'; summary = 'Push local main to its remote' }
            @{ id = 'no'; label = 'Hold'; summary = 'Leave local main unpushed' }
        )
        recommendation = 'no'
        why = 'Hold until the operator confirms the external write.'
    }
    @{
        project = 'bench-gauntlet'
        priority = 'P1'
        title = 'Stamp v2 scoring contract?'
        question = 'Should the v2 scoring contract be stamped now?'
        options = @(
            @{ id = 'yes'; label = 'Stamp'; summary = 'Adopt the v2 scoring contract' }
            @{ id = 'no'; label = 'Hold'; summary = 'Keep the contract unstamped' }
        )
        recommendation = 'no'
        why = 'Hold the contract boundary until the operator confirms it.'
    }
    @{
        project = 'baton'
        priority = 'P2'
        title = 'Kill hung fleet-dispatch?'
        question = 'Should the hung fleet-dispatch process be killed?'
        options = @(
            @{ id = 'yes'; label = 'Kill'; summary = 'Terminate the hung process' }
            @{ id = 'no'; label = 'Leave running'; summary = 'Do not terminate it' }
        )
        recommendation = 'yes'
        why = 'A confirmed hung dispatcher cannot make further progress.'
    }
)

$batonHome = Get-BatonHome
$existing = @(Get-Choices -BatonHome $batonHome)
foreach ($card in $cards) {
    $duplicate = @($existing | Where-Object {
        $_.project -eq $card.project -and
        $_.title -eq $card.title -and
        $_.status -in @('draft', 'admitted')
    })
    if ($duplicate.Count -gt 0) { continue }

    $draft = New-ChoiceDraft `
        -Project $card.project `
        -Title $card.title `
        -Question $card.question `
        -Options $card.options `
        -RecommendationOptionId $card.recommendation `
        -RecommendationWhy $card.why `
        -Evidence @("~/.baton/overnight/report-$($card.project).md") `
        -BatonHome $batonHome
    $admitted = Set-ChoiceAdmitted -Id $draft.id -Priority $card.priority -BatonHome $batonHome
    Write-Output $admitted.id
    $existing += $admitted
}
