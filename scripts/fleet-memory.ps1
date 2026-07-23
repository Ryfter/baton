#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Memory Bridge runner. Subcommands: remember (capture a problem->attempt->outcome),
  recall (pre-action warning if a task matches a past attempt), promote (watch list /
  flag one into Grimdex), ingest (fold a conductor run ledger into the journal).
  Advisory only — never blocks work.
.NOTES
  See docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md.
#>
param(
    [Parameter(Position=0)][string]$Subcommand = 'recall',
    [Parameter(Position=1)][string]$Target,                 # id|signature for promote (flag path)
    [string]$Problem,
    [string]$Approach,
    [ValidateSet('pass','fail','partial','unknown')][string]$Outcome = 'unknown',
    [string]$Tags,
    [ValidateSet('project','universal')][string]$Scope = 'project',
    [string]$RefJob,
    [string]$Text,
    [string]$File,
    [double]$MinOverlap = 0.5,
    [switch]$Deep,
    [switch]$Json,
    [string]$Run,                                           # ingest: run-dir or run-id under $BATON_HOME/runs/
    [switch]$DryRun,                                        # ingest: preview only
    [string]$MemoryPath = $(if ($env:BATON_HOME) { Join-Path $env:BATON_HOME 'memory-journal.jsonl' } else { Join-Path $HOME '.baton/memory-journal.jsonl' })
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'memory-lib.ps1')

function Write-MemoryErr([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

switch ($Subcommand) {
    'remember' {
        if (-not $Problem) { Write-Error "remember requires -Problem"; exit 2 }
        $tagArr = if ($Tags) { @($Tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() }
        $refs = @{}; if ($RefJob) { $refs['job'] = $RefJob }
        $res = Add-MemoryEvent -Problem $Problem -Approach $Approach -Outcome $Outcome -Tags $tagArr -Scope $Scope -Source 'manual' -Refs $refs -Path $MemoryPath
        if ($Json) { $res | ConvertTo-Json } else { Write-Host "remembered $($res.id) (signature: $($res.signature))" }
        return
    }
    'recall' {
        $task = if ($Text) { $Text }
                elseif ($File) { if (-not (Test-Path $File)) { Write-Error "file not found: $File"; exit 2 }; (Get-Content -LiteralPath $File -Raw).Trim() }
                else { '' }
        if (-not $task) { Write-Error "recall requires -Text or -File"; exit 2 }
        $r = Invoke-MemoryRecall -Task $task -MinOverlap $MinOverlap -Deep:$Deep -Path $MemoryPath
        if ($Json) { $r | ConvertTo-Json -Depth 6 }
        else { Write-Host (Format-RecallReport -Query $task -Matches $r.matches -Candidates $r.candidates -SemanticCandidates $r.semantic) }
        return
    }
    'promote' {
        if ($Target) {
            $pArgs = @{ Path = $MemoryPath }
            if ($Target -like 'mem-*') { $pArgs['Id'] = $Target } else { $pArgs['Signature'] = $Target }
            $res = Invoke-MemoryPromote @pArgs
            if ($Json) { $res | ConvertTo-Json }
            elseif ($res.promoted) { Write-Host "promoted signature '$($res.signature)' -> $($res.written)" }
            else { Write-Host "promotion write failed for '$($res.signature)' — left un-stamped." }
        } else {
            $cands = Get-PromotionCandidates -Path $MemoryPath
            if ($Json) { @($cands) | ConvertTo-Json -Depth 6 }
            elseif (@($cands).Count -eq 0) { Write-Host "No promotion candidates." }
            else {
                Write-Host "Promotion candidates:"
                foreach ($c in $cands) { Write-Host "  • $($c.signature) — $($c.reason) [$($c.kind)]  (flag: /baton:memory-promote $($c.signature))" }
            }
        }
        return
    }
    'ingest' {
        . (Join-Path $PSScriptRoot 'memory-ingest-lib.ps1')
        $runSpec = if ($Run) { $Run } elseif ($Target) { $Target } else { '' }
        if (-not $runSpec) {
            Write-MemoryErr 'ingest requires -Run <run-dir|run-id>'
            exit 2
        }
        $batonHome = if ($env:BATON_HOME) { $env:BATON_HOME } else { Get-BatonHome }
        $res = Invoke-MemoryIngest -Run $runSpec -BatonHome $batonHome -MemoryPath $MemoryPath -DryRun:$DryRun
        if ($Json) {
            $res | ConvertTo-Json -Depth 8
        } else {
            $mode = if ($res.dry_run) { 'dry-run' } else { 'ingest' }
            Write-Host ("memory-ingest [{0}] run={1}" -f $mode, $res.run_id)
            Write-Host ("  written:            {0}" -f $res.written)
            Write-Host ("  skipped-duplicate:  {0}" -f $res.skipped_duplicate)
            if (@($res.rows).Count -gt 0) {
                Write-Host '  rows:'
                foreach ($row in @($res.rows)) {
                    $mark = if ($row.duplicate) { 'DUP' } elseif ($row.written) { 'WROTE' } elseif ($res.dry_run) { 'PREVIEW' } else { 'SKIP' }
                    Write-Host ("    [{0}] outcome={1} sig={2} — {3}" -f $mark, $row.outcome, $row.signature, $row.problem)
                }
            } elseif (@($res.warnings).Count -eq 0) {
                Write-Host '  (no rows produced)'
            }
            foreach ($w in @($res.warnings)) { Write-Host ("  warning: {0}" -f $w) }
        }
        # Non-zero only when the run could not be resolved and no dry-run preview path.
        if (@($res.warnings).Count -gt 0 -and $res.written -eq 0 -and $res.skipped_duplicate -eq 0 -and @($res.rows).Count -eq 0 -and -not $res.run_dir) {
            exit 2
        }
        return
    }
    default { Write-Error "unknown subcommand: $Subcommand (use remember|recall|promote|ingest)"; exit 2 }
}
