#!/usr/bin/env pwsh
<# Diff-apply worker path — edit-block parser.
   Spec: docs/superpowers/specs/2026-08-03-diff-apply-worker-path-design.md (d103, Task 1).

   Parses model-emitted text into SEARCH/REPLACE edit blocks:

       FILE: <repo-relative path>
       <<<<<<< SEARCH
       <exact existing text>
       =======
       <replacement text>
       >>>>>>> REPLACE

   Pure parsing only — no filesystem access, no application. Later tasks add the
   applier, context assembler, and dispatch wiring. #>

function ConvertFrom-EditBlocks {
    <# .SYNOPSIS
       Parse model output text into edit blocks.
       Returns [ordered]@{ result = 'ok'|'malformed'|'empty'; error = <string>; blocks = @(...) }
       where each block is [ordered]@{ path; search; replace; is_create }. #>
    param(
        [string]$Text = ''
    )

    if ($null -eq $Text) { $Text = '' }

    # Normalize line endings to LF so CRLF model output parses identically.
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $normalized -split "`n"

    $state = 'outside'   # outside | awaiting_search | in_search | in_replace
    $pendingPath = $null
    $curPath = $null
    $searchLines = @()
    $replaceLines = @()
    $blocks = @()
    $malformed = $false
    $errorMsg = ''

    $i = 0
    while ($i -lt $lines.Count -and -not $malformed) {
        $line = $lines[$i]

        switch ($state) {
            'outside' {
                if ($line -match '^FILE:\s*(.+?)\s*$') {
                    $pendingPath = $Matches[1]
                    $state = 'awaiting_search'
                } elseif ($line -match '^<<<<<<< SEARCH\s*$') {
                    $malformed = $true
                    $errorMsg = 'SEARCH block with no preceding FILE: line'
                }
                # else: prose outside blocks, ignored.
                $i++
            }
            'awaiting_search' {
                if ($line -match '^<<<<<<< SEARCH\s*$') {
                    $curPath = $pendingPath
                    $pendingPath = $null
                    $searchLines = @()
                    $replaceLines = @()
                    $state = 'in_search'
                    $i++
                } elseif ($line.Trim() -eq '') {
                    # Blank line — keep waiting, pending path survives.
                    $i++
                } else {
                    # A non-blank, non-marker line intervened: the FILE: line was prose.
                    # Discard the pending path and reprocess this same line as 'outside'.
                    $pendingPath = $null
                    $state = 'outside'
                }
            }
            'in_search' {
                if ($line -match '^=======\s*$') {
                    $state = 'in_replace'
                } else {
                    $searchLines += $line
                }
                $i++
            }
            'in_replace' {
                if ($line -match '^>>>>>>> REPLACE\s*$') {
                    $searchText = ($searchLines -join "`n")
                    $blocks += [ordered]@{
                        path      = $curPath
                        search    = $searchText
                        replace   = ($replaceLines -join "`n")
                        is_create = ($searchText -eq '')
                    }
                    $state = 'outside'
                    $curPath = $null
                } else {
                    $replaceLines += $line
                }
                $i++
            }
        }
    }

    if (-not $malformed) {
        if ($state -eq 'in_search' -or $state -eq 'in_replace') {
            $malformed = $true
            $errorMsg = "unterminated block for $curPath"
        }
        # 'awaiting_search' at end-of-text is a dangling FILE: mention, not an error.
    }

    if ($malformed) {
        return [ordered]@{ result = 'malformed'; error = $errorMsg; blocks = @() }
    }

    if ($blocks.Count -eq 0) {
        return [ordered]@{ result = 'empty'; error = ''; blocks = @() }
    }

    return [ordered]@{ result = 'ok'; error = ''; blocks = $blocks }
}
