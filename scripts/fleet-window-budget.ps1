#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:budget runner. Window-aware token consumption (5h grid + 7d rolling)
  folded from model-routing-log.md, with optional headroom against window-budgets.json.
.DESCRIPTION
  status  — per-model tokens / dispatches / time (+ headroom when budgets exist)
  doctor  — what cannot be computed and why (silence is never "all good")
  Exit: 0 ok, 1 runtime error, 2 bad usage.
#>
param(
    [Parameter(Position = 0)][string]$Subcommand = 'status',
    [ValidateSet('5h', '7d', 'both')][string]$Window = 'both',
    [string]$Project,
    [switch]$Json,
    [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { $null })
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'window-budget-lib.ps1')

function Write-BudgetErr([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Format-HeadroomCell($HeadroomPct, [string]$Key) {
    if ($null -eq $HeadroomPct) { return '-' }
    $v = $HeadroomPct[$Key]
    if ($null -eq $v) { return '-' }
    return ('{0}%' -f $v)
}

try {
    if (-not $BatonHome) { $BatonHome = Get-BatonHome }

    switch ($Subcommand) {
        'status' {
            $status = Get-WindowBudgetStatus -Window $Window -Project $Project -BatonHome $BatonHome
            if ($Json) {
                ConvertTo-Json -InputObject ([pscustomobject]$status) -Depth 10
                exit 0
            }

            Write-Host ("window-budget status  now={0}  pressure={1}" -f $status.now, $(if ($status.pressure_enabled) { 'on' } else { 'off' }))
            $w5 = $status.windows['5h']
            $w7 = $status.windows['7d']
            Write-Host ("  5h: {0} → {1}  ({2}{3})" -f $w5.start_offset, $w5.end_offset, $w5.kind, $(if ($w5.fallback) { '; FALLBACK' } else { '' }))
            Write-Host ("  7d: {0} → {1}  ({2})" -f $w7.start_offset, $w7.end_offset, $w7.kind)
            if ($Project) { Write-Host ("  project filter: {0}" -f $Project) }
            Write-Host ''

            $show5 = ($Window -eq '5h' -or $Window -eq 'both')
            $show7 = ($Window -eq '7d' -or $Window -eq 'both')

            if ($show5) {
                Write-Host '--- 5h window ---'
                Write-Host ("{0,-20} {1,10} {2,8} {3,8} {4,10} {5,10} {6,10} {7,8}" -f `
                    'MODEL', 'TOKENS', 'DISP', 'SEC', 'EXACT', 'EST', 'HEADROOM', 'PRESSURE')
                foreach ($m in @($status.models)) {
                    $hr = Format-HeadroomCell $m.headroom_pct '5h'
                    Write-Host ("{0,-20} {1,10} {2,8} {3,8} {4,10} {5,10} {6,10} {7,8}" -f `
                        $m.model, $m.tokens_5h, $m.dispatches_5h, $m.seconds_5h, `
                        $m.exact_tokens_5h, $m.estimated_tokens_5h, $hr, $m.pressure)
                }
                if (@($status.models).Count -eq 0) { Write-Host '  (no dispatches with tok: in this window)' }
                Write-Host ''
            }
            if ($show7) {
                Write-Host '--- 7d window ---'
                Write-Host ("{0,-20} {1,10} {2,8} {3,8} {4,10} {5,10} {6,10} {7,8}" -f `
                    'MODEL', 'TOKENS', 'DISP', 'SEC', 'EXACT', 'EST', 'HEADROOM', 'PRESSURE')
                foreach ($m in @($status.models)) {
                    $hr = Format-HeadroomCell $m.headroom_pct '7d'
                    Write-Host ("{0,-20} {1,10} {2,8} {3,8} {4,10} {5,10} {6,10} {7,8}" -f `
                        $m.model, $m.tokens_7d, $m.dispatches_7d, $m.seconds_7d, `
                        $m.exact_tokens_7d, $m.estimated_tokens_7d, $hr, $m.pressure)
                }
                if (@($status.models).Count -eq 0) { Write-Host '  (no dispatches with tok: in this window)' }
                Write-Host ''
            }
            if (-not $status.budgets_configured) {
                Write-Host 'note: no window-budgets.json — headroom is blank (no invented caps).'
            }
            exit 0
        }
        'doctor' {
            $doc = Get-WindowBudgetDoctor -BatonHome $BatonHome
            if ($Json) {
                ConvertTo-Json -InputObject ([pscustomobject]$doc) -Depth 10
                exit 0
            }
            Write-Host ("window-budget doctor  ok={0}  now={1}" -f $doc.ok, $doc.now)
            Write-Host ("  5h kind={0} fallback={1}" -f $doc.windows['5h'].kind, [bool]$doc.windows['5h'].fallback)
            Write-Host ("  7d kind={0}" -f $doc.windows['7d'].kind)
            if ($doc.journal) {
                Write-Host ("  journal: exists={0} parsed={1} unparsable={2} notes={3} no_tok={4}" -f `
                    $doc.journal.exists, $doc.journal.lines_parsed, $doc.journal.lines_unparsable, `
                    $doc.journal.lines_note, $doc.journal.lines_no_tok)
            }
            if (@($doc.issues).Count -eq 0) {
                Write-Host '  issues: (none)'
            } else {
                Write-Host '  issues:'
                foreach ($iss in @($doc.issues)) {
                    Write-Host ("    [{0}] {1}: {2}" -f $iss.severity, $iss.code, $iss.message)
                }
            }
            exit 0
        }
        default {
            Write-BudgetErr "unknown subcommand: $Subcommand (use status|doctor)"
            exit 2
        }
    }
} catch {
    Write-BudgetErr ("budget: {0}" -f $_.Exception.Message)
    exit 1
}
