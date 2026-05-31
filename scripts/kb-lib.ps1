#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Thin PowerShell wrappers around the kb/ Python package — used by the
  /kb-index, /kb-search, and /research slash commands.

.DESCRIPTION
  All real work lives in Python (kb.index, kb.search). These wrappers locate
  the repo root, invoke `python -m kb.*` with the right CWD, and pass args
  through. Slash commands stay short and shell-quoteable.

  Locating the repo: searches upward from PSScriptRoot for a folder
  containing a `kb/` directory. Falls back to ~/coding-agent-orchestrator
  and the env var $env:CAO_REPO_ROOT.
#>

function Get-CaoRepoRoot {
    if ($env:CAO_REPO_ROOT -and (Test-Path (Join-Path $env:CAO_REPO_ROOT 'kb'))) {
        return (Resolve-Path $env:CAO_REPO_ROOT).Path
    }
    # Walk up from script location
    $dir = $PSScriptRoot
    for ($i = 0; $i -lt 8 -and $dir; $i++) {
        if (Test-Path (Join-Path $dir 'kb')) {
            return $dir
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    # Common dev path
    $candidate = 'D:\Dev\coding-agent-orchestrator'
    if (Test-Path (Join-Path $candidate 'kb')) { return $candidate }
    throw "Could not locate the coding-agent-orchestrator repo (no kb/ found). Set `$env:CAO_REPO_ROOT to the repo root."
}

function Invoke-KbIndex {
    <# Wrap `python -m kb.index`. Pass through args. #>
    param([string[]]$Args = @())
    $repo = Get-CaoRepoRoot
    Push-Location $repo
    try {
        & python -m kb.index @Args
        return $LASTEXITCODE
    } finally { Pop-Location }
}

function Invoke-KbSearch {
    <#
    .SYNOPSIS
      Wrap `python -m kb.search`. Always emits JSON; caller may pretty-print.

    .OUTPUTS
      Array of hashtables: @{ score; source; span_start; span_end; section; text }
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$K = 5,
        [string]$Scope,
        [int]$SnippetChars = 200
    )
    $repo = Get-CaoRepoRoot
    $argList = @('-m', 'kb.search', $Query, '--k', "$K", '--json', '--snippet-chars', "$SnippetChars")
    if ($Scope) { $argList += @('--scope', $Scope) }
    Push-Location $repo
    try {
        $out = & python @argList 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "kb.search exited $LASTEXITCODE -- $out"
            return @()
        }
        try {
            return ($out | ConvertFrom-Json)
        } catch {
            Write-Warning "kb.search returned non-JSON: $out"
            return @()
        }
    } finally { Pop-Location }
}

function Format-KbHits {
    <# Render kb.search hits as a compact readable block. #>
    param(
        [Parameter(Mandatory)]$Hits,
        [int]$SnippetChars = 200
    )
    if (-not $Hits -or $Hits.Count -eq 0) {
        return '(no hits)'
    }
    $lines = @()
    foreach ($h in $Hits) {
        $head = "[{0:F3}]  {1}  ({2}-{3})" -f $h.score, $h.source, $h.span_start, $h.span_end
        if ($h.section) { $head += "  § $($h.section)" }
        $lines += $head
        $snippet = ($h.text -replace "`r?`n", ' ').Trim()
        if ($snippet.Length -gt $SnippetChars) {
            $snippet = $snippet.Substring(0, $SnippetChars) + '…'
        }
        $lines += "   $snippet"
        $lines += ''
    }
    return ($lines -join "`n")
}
