#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Memory Bridge (Sprint 5). Projectmem-style problem->attempt->outcome dev memory:
  an append-only memory-journal.jsonl, deterministic signature matching (warn before
  repeating a known-bad fix), and a discover->crystallize promotion path into Grimdex.
.DESCRIPTION
  Dot-source for the function library (tests do); fleet-memory.ps1 wraps it for
  /baton:remember, /baton:recall, /baton:memory-promote. Advisory only — never blocks.
  House pattern mirrors usage-lib.ps1 (Read/Add/Fold) and research-gate-lib.ps1 (-Searcher seam).
.NOTES
  See docs/superpowers/specs/2026-06-19-memory-bridge-sprint5-design.md (d-mb-1..6).
#>
. "$PSScriptRoot/baton-home.ps1"

$script:DefaultMemoryPath  = (Join-Path (Get-BatonHome) 'memory-journal.jsonl')
$script:DefaultLessonsPath = $(if ($env:BATON_MEM_LESSONS) { $env:BATON_MEM_LESSONS } else { Join-Path $HOME '.claude/knowledge/projects/baton/memory-lessons.md' })

function Get-MemorySignature {
    <# Normalize free text into a deterministic token-set key: lowercase, strip
       paths / line-number refs / hex+uuid hashes / digit-unit tokens, drop stopwords,
       return the sorted distinct tokens joined by spaces. Same input -> same key. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.ToLowerInvariant()
    $t = $t -replace '[a-z]:\\[^\s]+', ' '          # windows paths
    $t = $t -replace '(?:[\w.-]+/)+[\w.-]+', ' '    # unix-style paths
    $t = $t -replace ':\d+', ' '                    # :line-number refs
    $t = $t -replace '\b[0-9a-f]{8,}\b', ' '         # hex / uuid hashes
    $t = $t -replace '\b\d+[a-z]*\b', ' '            # numbers + digit-unit (30s, 200ms)
    $t = $t -replace '[^a-z0-9]+', ' '               # punctuation -> space
    $stop = @('the','a','an','to','of','in','on','is','it','and','or','for','with',
              'this','that','my','we','i','be','by','at','as','was','are','from','its')
    $tokens = $t -split '\s+' | Where-Object { $_ -and ($_.Length -gt 1) -and ($stop -notcontains $_) }
    return (($tokens | Sort-Object -Unique) -join ' ')
}

function Read-MemoryJournal {
    <# Robust JSONL reader: missing path -> empty; malformed lines skipped. object[]. #>
    param([string]$Path = $script:DefaultMemoryPath)
    if (-not $Path -or -not (Test-Path $Path)) { return ([object[]]@()) }
    $out = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
    }
    return ([object[]]$out.ToArray())
}

function Add-MemoryEvent {
    <# Append one memory row. Computes id + signature. Never throws on write fault
       (warns). Creates the parent dir. Returns @{ id; signature }. #>
    param(
        [Parameter(Mandatory)][string]$Problem,
        [string]$Approach = '',
        [ValidateSet('pass','fail','partial','unknown')][string]$Outcome = 'unknown',
        [ValidateSet('attempt','outcome','note')][string]$Kind = 'attempt',
        [string[]]$Tags = @(),
        [ValidateSet('project','universal')][string]$Scope = 'project',
        [string]$Source = 'manual',
        [hashtable]$Refs = @{},
        [string]$Path = $script:DefaultMemoryPath,
        [string]$Timestamp,
        [string]$Id
    )
    if (-not $Timestamp) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
    if (-not $Id) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $rand  = [System.IO.Path]::GetRandomFileName().Substring(0,4)
        $Id = "mem-$stamp-$rand"
    }
    $sig = Get-MemorySignature -Text $Problem
    $row = [ordered]@{
        ts = $Timestamp; id = $Id; kind = $Kind; signature = $sig; problem = $Problem
        approach = $Approach; outcome = $Outcome; tags = @($Tags); source = $Source
        refs = @{ job = $Refs['job']; run = $Refs['run']; decision = $Refs['decision'] }
        scope = $Scope; promoted = $false
    }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $Path -Value ($row | ConvertTo-Json -Depth 6 -Compress) -Encoding utf8
    } catch {
        Write-Warning "memory: failed to append event to $Path : $($_.Exception.Message)"
    }
    return [pscustomobject]@{ id = $Id; signature = $sig }
}
