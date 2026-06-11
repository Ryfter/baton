#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Single PowerShell entry for the baton_mcp MCP server (Phase 3). Thin adapter:
  dot-sources the existing libs and prints ONE JSON envelope to stdout.
.DESCRIPTION
  Args arrive via a JSON file (-ArgsPath) — never inline — per the 965-byte
  shell-argument rule. Errors are returned as {ok:false, error} with exit 0 so
  the MCP layer gets structured failures; exit 1 only if even that fails.
#>
param(
    [Parameter(Mandatory)][string]$Op,
    [string]$ArgsPath
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
function Out-Json($obj) { $obj | ConvertTo-Json -Depth 8 -Compress }

try {
    $a = @{}
    if ($ArgsPath -and (Test-Path $ArgsPath)) {
        $raw = Get-Content -LiteralPath $ArgsPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            ($raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $a[$_.Name] = $_.Value }
        }
    }
    switch ($Op) {
        'capabilities' {
            . "$here/routing-lib.ps1"
            Out-Json @{ ok = $true; capabilities = @(Get-KnownCapabilities) }
        }
        'route-select' {
            . "$here/routing-lib.ps1"
            $sel = @{ Capability = [string]$a.capability }
            if ($a.max_tier)   { $sel['MaxCostTier']  = [string]$a.max_tier }
            if ($a.local_only) { $sel['RequireLocal'] = $true }
            # Select-Capability uses ,(array) return to preserve array identity;
            # pipe through ForEach-Object to unwrap before Select-Object.
            $cands = @(Select-Capability @sel | ForEach-Object { $_ } | Select-Object name, kind, source, cost_tier, quality, why)
            Out-Json @{ ok = $true; capability = [string]$a.capability; candidates = $cands }
        }
        'route-dispatch' {
            . "$here/routing-dispatch.ps1"
            $p = @{ Capability = [string]$a.capability; Prompt = [string]$a.prompt }
            if ($a.max_tier)   { $p['MaxCostTier']  = [string]$a.max_tier }
            if ($a.local_only) { $p['RequireLocal'] = $true }
            if ($a.judge)      { $p['Judge']        = $true }
            if ($a.rank)       { $p['Rank']         = [int]$a.rank }
            if ($a.timeout_s)  { $p['TimeoutS']     = [int]$a.timeout_s }
            $r = Invoke-RoutedCapability @p
            Out-Json @{
                ok = $true; status = $r.status; winner = $r.winner; result = $r.result
                attempts = @($r.attempts | ForEach-Object { $_ } | Select-Object candidate, cost_tier, passed, score, reason, duration_s, gate)
            }
        }
        'fleet-list' {
            . "$here/fleet-lib.ps1"
            $rows = @(Read-Fleet | ForEach-Object {
                @{ name = $_.name; kind = $_.kind; enabled = ($_.enabled -eq $true); cost_tier = $_.cost_tier }
            })
            Out-Json @{ ok = $true; providers = $rows }
        }
        'fleet-doctor' {
            # Call fleet-doctor.ps1 with -Json; capture stdout only (stderr is host-only in PS)
            $out = (& "$here/fleet-doctor.ps1" -Json | Out-String).Trim()
            $healthy = ($LASTEXITCODE -eq 0)
            # ConvertFrom-Json of '[]' can return $null in some PS versions — guard with @()
            $rows = if ($out) { @(ConvertFrom-Json -InputObject $out -NoEnumerate) } else { @() }
            if ($null -eq $rows) { $rows = @() }
            Out-Json @{ ok = $true; healthy = $healthy; rows = @($rows) }
        }
        'fleet-test' {
            . "$here/fleet-lib.ps1"
            $p = @{ Name = [string]$a.name; Prompt = [string]$a.prompt }
            if ($a.model) { $p['Model'] = [string]$a.model }
            $r = Invoke-Fleet @p
            Out-Json @{ ok = $true; name = [string]$a.name; stdout = $r.stdout; stderr = $r.stderr; exit_code = $r.exit_code; duration_s = $r.duration_s }
        }
        'job-status' {
            . "$here/job-lib.ps1"
            $cur = Read-CurrentJob
            if (-not $cur.job_id) {
                Out-Json @{ ok = $true; active = $false; job_id = $null; phase = $null; manifest = $null }
                break
            }
            $jobDir = Join-Path (Join-Path (Get-BatonHome) 'jobs') $cur.job_id
            $m = if (Test-Path $jobDir) { Read-Manifest -JobDir $jobDir } else { $null }
            Out-Json @{ ok = $true; active = $true; job_id = $cur.job_id; phase = $cur.phase; manifest = $m }
        }
        'job-list' {
            . "$here/job-lib.ps1"
            $filter = if ($a.filter) { [string]$a.filter } else { 'active' }
            $jobsRoot = Join-Path (Get-BatonHome) 'jobs'
            $jobs = @()
            if (Test-Path $jobsRoot) {
                foreach ($d in (Get-ChildItem $jobsRoot -Directory)) {
                    try { $m = Read-Manifest -JobDir $d.FullName } catch { continue }
                    if (-not $m -or -not $m.id) { continue }
                    if ($filter -ne 'all' -and [string]$m.status -ne $filter) { continue }
                    $jobs += @{ id = $m.id; title = $m.title; phase = $m.current_phase; project = $m.project; status = $m.status; created_at = $m.created_at }
                }
            }
            Out-Json @{ ok = $true; jobs = $jobs }
        }
        default {
            Out-Json @{ ok = $false; error = "unknown op: $Op" }
        }
    }
} catch {
    try { Out-Json @{ ok = $false; error = $_.Exception.Message } } catch { exit 1 }
}
