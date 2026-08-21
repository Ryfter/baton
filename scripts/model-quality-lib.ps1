#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Append qualitative model-quality rows to ~/.baton/overnight/model-quality.jsonl.
.DESCRIPTION
  Fold fleet-go exits and review artifacts into box-private evidence for nightly
  rundowns. No Grimdex promotion — human review first.
.NOTES
  Smoke (one-liner):
    pwsh -NoProfile -Command ". '$PSScriptRoot/model-quality-lib.ps1'; Add-ModelQualityEvent -Provider smoke -Model test -TaskClass verify.code -Outcome partial -EvidenceRef /tmp/smoke.md -Notes 'smoke' -Reviewer agent; (Get-Content (Join-Path $HOME '.baton/overnight/model-quality.jsonl') | Select-Object -Last 1)"
#>
Set-StrictMode -Version Latest

function Add-ModelQualityEvent {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$TaskClass,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'partial', 'unknown')][string]$Outcome,
        [Parameter(Mandatory)][string]$EvidenceRef,
        [string]$Notes = '',
        [string]$Reviewer = $(if ($env:USERNAME) { $env:USERNAME } else { 'unknown' })
    )
    $dir = Join-Path $HOME '.baton/overnight'
    $file = Join-Path $dir 'model-quality.jsonl'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $event = [ordered]@{
        date         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        provider     = $Provider
        model        = $Model
        task_class   = $TaskClass
        outcome      = $Outcome
        evidence_ref = $EvidenceRef
        notes        = $Notes
        reviewer     = $Reviewer
    }
    Add-Content -LiteralPath $file -Value ($event | ConvertTo-Json -Compress) -Encoding utf8NoBOM
    return $event
}
