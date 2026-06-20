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

function Find-MemoryMatches {
    <# Rows whose stored signature token-overlaps the query signature at/above
       -MinOverlap (shared / query-token count). Ranked overlap desc then recency
       desc. Reads the journal when -Rows is not supplied. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [double]$MinOverlap = 0.5,
        [string]$Path = $script:DefaultMemoryPath,
        [object[]]$Rows
    )
    $qtokens = @((Get-MemorySignature -Text $Query) -split '\s+' | Where-Object { $_ })
    if ($qtokens.Count -eq 0) { return ([object[]]@()) }
    if ($null -eq $Rows) { $Rows = Read-MemoryJournal -Path $Path }
    $scored = foreach ($r in $Rows) {
        $rtokens = @([string]$r.signature -split '\s+' | Where-Object { $_ })
        if ($rtokens.Count -eq 0) { continue }
        $shared  = @($qtokens | Where-Object { $rtokens -contains $_ }).Count
        $overlap = [double]$shared / $qtokens.Count
        if ($overlap -ge $MinOverlap) {
            [pscustomobject]@{ row = $r; overlap = $overlap; ts = [string]$r.ts }
        }
    }
    $ranked = @($scored) | Sort-Object -Property @{ e = { $_.overlap }; Descending = $true }, @{ e = { $_.ts }; Descending = $true }
    $out = [object[]]@($ranked | ForEach-Object { $_.row })
    if ($out.Count -eq 0) { return ([object[]]@()) }
    return ,([object[]]$out)
}

function Get-PromotionCandidates {
    <# Group non-promoted rows by signature; flag one whose fail-count >= FailThreshold
       (governance: stop repeating a bad fix) or pass-count >= WinThreshold (crystallize
       a winner). Returns one candidate per flagged signature. #>
    param(
        [int]$FailThreshold = 2,
        [int]$WinThreshold = 2,
        [string]$Path = $script:DefaultMemoryPath,
        [object[]]$Rows
    )
    if ($null -eq $Rows) { $Rows = Read-MemoryJournal -Path $Path }
    $active = @($Rows | Where-Object { $_.promoted -ne $true -and [string]$_.signature })
    $out = [System.Collections.ArrayList]@()
    foreach ($grp in ($active | Group-Object -Property signature)) {
        $fails = @($grp.Group | Where-Object { [string]$_.outcome -eq 'fail' }).Count
        $wins  = @($grp.Group | Where-Object { [string]$_.outcome -eq 'pass' }).Count
        $reason = $null; $kind = $null
        if ($fails -ge $FailThreshold)     { $reason = "failed ${fails}x";    $kind = 'avoid' }
        elseif ($wins -ge $WinThreshold)   { $reason = "succeeded ${wins}x";  $kind = 'prefer' }
        if ($reason) {
            [void]$out.Add([pscustomobject]@{
                signature = $grp.Name; reason = $reason; fail_count = $fails; win_count = $wins
                kind = $kind; rows = @($grp.Group); problem = [string]($grp.Group[0].problem)
            })
        }
    }
    if ($out.Count -eq 0) { return ([object[]]@()) }
    return ,([object[]]$out.ToArray())
}

function Format-RecallReport {
    <# Human-readable recall warning: signature, prior matches (failed count first),
       promotion candidates, and any semantic neighbors. Pure string builder. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [object[]]$Matches = @(),
        [object[]]$Candidates = @(),
        [object[]]$SemanticCandidates = @()
    )
    $sig = Get-MemorySignature -Text $Query
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("RECALL — signature: $sig")
    $fails = @($Matches | Where-Object { [string]$_.outcome -eq 'fail' })
    if (@($Matches).Count -eq 0) {
        [void]$sb.AppendLine("No prior memory matches this task.")
    } else {
        [void]$sb.AppendLine("$(@($Matches).Count) prior attempt(s) on this signature — $(@($fails).Count) FAILED:")
        foreach ($m in $Matches) {
            $oc = ([string]$m.outcome).ToUpperInvariant()
            $job = if ($m.refs -and $m.refs.job) { "  [$($m.refs.job)]" } else { '' }
            [void]$sb.AppendLine("  • $($m.approach) — $oc ($($m.problem))$job")
        }
    }
    foreach ($c in $Candidates) {
        [void]$sb.AppendLine("PROMOTION CANDIDATE: signature '$($c.signature)' $($c.reason) — consider /baton:memory-promote")
    }
    if (@($SemanticCandidates).Count) {
        [void]$sb.AppendLine("Related (semantic):")
        foreach ($s in $SemanticCandidates) {
            $txt = ("$($s.text)" -replace '\s+',' ').Trim()
            [void]$sb.AppendLine("  ~ $($s.source): $txt")
        }
    }
    return $sb.ToString().TrimEnd()
}

function Format-PromotionMemo {
    <# A promotion candidate -> a Grimdex lesson/decision draft (AVOID or PREFER). #>
    param([Parameter(Mandatory)][pscustomobject]$Candidate)
    $verb = if ($Candidate.kind -eq 'avoid') { 'AVOID' } else { 'PREFER' }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("## Memory-promoted rule ($verb)")
    [void]$sb.AppendLine("Signature: $($Candidate.signature)")
    [void]$sb.AppendLine("Problem: $($Candidate.problem)")
    [void]$sb.AppendLine("Basis: $($Candidate.reason)")
    [void]$sb.AppendLine("Attempts:")
    foreach ($r in @($Candidate.rows)) {
        [void]$sb.AppendLine("  - $($r.approach) -> $($r.outcome)")
    }
    return $sb.ToString().TrimEnd()
}
