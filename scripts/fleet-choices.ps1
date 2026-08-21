#!/usr/bin/env pwsh
param(
    [Parameter(Position=0)][string]$Subcommand,
    [Parameter(Position=1, ValueFromRemainingArguments)][string[]]$Ids,
    [switch]$Json,
    [string]$Project,
    [string]$Status,
    [string]$Priority = 'P1',
    [string]$Text,
    [string]$Title,
    [string]$Question,
    [string]$Blocks,
    [string[]]$Evidence = @(),
    [string]$OptionsJson,
    [string]$Rec,
    [string]$RecWhy
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'choices-lib.ps1')

function Write-ChoiceJson {
    param([Parameter(Mandatory)]$Value)
    ConvertTo-Json -InputObject $Value -Depth 8
}

function Get-RequiredId {
    if (@($Ids).Count -lt 1 -or [string]::IsNullOrWhiteSpace($Ids[0])) {
        throw "$Subcommand requires a choice id"
    }
    return $Ids[0]
}

try {
    switch ($Subcommand) {
        'brief' {
            $cursor = Reset-ChoicesBriefCursor
            if ($Json) {
                Write-ChoiceJson ([ordered]@{
                    choices = @(Get-Choices -Status 'admitted')
                    cursor  = $cursor
                })
            } else {
                Format-ChoicesBrief
            }
        }
        'next' {
            $choice = Get-NextAdmittedChoice
            if ($null -eq $choice) {
                Write-Output 'none admitted.'
            } elseif ($Json) {
                Write-ChoiceJson $choice
            } else {
                Format-ChoiceCard -Choice $choice
            }
        }
        'answer' {
            $id = Get-RequiredId
            $optionId = if (@($Ids).Count -gt 1) { $Ids[1] } else { $null }
            if ([string]::IsNullOrWhiteSpace($optionId) -and
                [string]::IsNullOrWhiteSpace($Text)) {
                throw 'answer requires an option id or -Text'
            }
            $choice = Set-ChoiceAnswered -Id $id -OptionId $optionId -FreeText $Text
            [void](Move-ChoiceCursorAfterAnswer)
            if ($Json) { Write-ChoiceJson $choice } else { Format-ChoiceCard -Choice $choice }
        }
        'list' {
            $choices = @(Get-Choices -Project $Project -Status $Status)
            if ($Json) {
                Write-ChoiceJson $choices
            } elseif ($choices.Count -eq 0) {
                Write-Output 'no choices.'
            } else {
                Write-Output (($choices | ForEach-Object { Format-ChoiceCard -Choice $_ }) -join "`n`n")
            }
        }
        'draft' {
            if ([string]::IsNullOrWhiteSpace($OptionsJson)) {
                throw 'draft requires -OptionsJson'
            }
            $optionsSource = if (Test-Path -LiteralPath $OptionsJson) {
                Get-Content -LiteralPath $OptionsJson -Raw
            } else {
                $OptionsJson
            }
            $options = @($optionsSource | ConvertFrom-Json)
            $choice = New-ChoiceDraft -Project $Project -Title $Title -Question $Question `
                -Options $options -RecommendationOptionId $Rec -RecommendationWhy $RecWhy `
                -Evidence $Evidence -Blocks $Blocks
            if ($Json) { Write-ChoiceJson $choice } else { Format-ChoiceCard -Choice $choice }
        }
        'admit' {
            $choice = Set-ChoiceAdmitted -Id (Get-RequiredId) -Priority $Priority
            if ($Json) { Write-ChoiceJson $choice } else { Format-ChoiceCard -Choice $choice }
        }
        'reject' {
            $choice = Set-ChoiceRejected -Id (Get-RequiredId)
            if ($Json) { Write-ChoiceJson $choice } else { Format-ChoiceCard -Choice $choice }
        }
        default {
            throw "unknown subcommand: $Subcommand (use brief, next, answer, list, draft, admit, reject)"
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
