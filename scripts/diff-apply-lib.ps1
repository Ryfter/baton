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

   Task 1 is the pure parser (ConvertFrom-EditBlocks). Task 2 adds the safe,
   all-or-nothing applier (Test-DiffApplyPathSafe, Invoke-EditBlockApply): every
   path is validated and every block applied to in-memory copies first; the disk
   is touched only once every block has succeeded. Later tasks add the context
   assembler and dispatch wiring. #>

. "$PSScriptRoot/verification-lib.ps1"   # Test-DiffFilesInAllowedPaths for the scope pre-check

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

function Get-EditSearchSnippet {
    <# First ~80 chars of a search text, newlines escaped, for error messages. #>
    param([string]$Text = '')
    if ($null -eq $Text) { $Text = '' }
    $flat = $Text.Replace("`r", '').Replace("`n", '\n')
    if ($flat.Length -gt 80) { return $flat.Substring(0, 80) + '...' }
    return $flat
}

function Test-DiffApplyPathSafe {
    <# .SYNOPSIS
       Decide whether a model-supplied relative path may be written inside a
       worktree. Fail-CLOSED: anything not provably inside the worktree, and any
       .git / parent-escape / symlink route out of it, is rejected.
       Returns [ordered]@{ ok = <bool>; reason = <string>; full = <string> }. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [string]$RelPath = ''
    )

    $out = [ordered]@{ ok = $false; reason = ''; full = '' }
    if ($null -eq $RelPath) { $RelPath = '' }

    if ([string]::IsNullOrWhiteSpace($RelPath)) { $out.reason = 'empty-path'; return $out }

    if ([System.IO.Path]::IsPathRooted($RelPath) -or
        $RelPath -match '^[A-Za-z]:' -or
        $RelPath.StartsWith('\\') -or
        $RelPath.StartsWith('//')) {
        $out.reason = 'absolute-path'; return $out
    }

    # Split on both separators — a model may emit either on any platform.
    $segments = @($RelPath -split '[\\/]')

    foreach ($seg in $segments) {
        if ($seg -eq '..') { $out.reason = 'parent-escape'; return $out }
    }
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($i -gt 0 -and $segments[$i] -eq '') { $out.reason = 'git-path'; return $out }
        if ($segments[$i].ToLowerInvariant() -eq '.git') { $out.reason = 'git-path'; return $out }
    }

    foreach ($ch in $RelPath.ToCharArray()) {
        if ([int]$ch -lt 32) { $out.reason = 'control-char'; return $out }
    }

    $rootFull = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\', '/')
    try {
        $full = [System.IO.Path]::GetFullPath((Join-Path $Worktree $RelPath))
    } catch {
        $out.reason = 'outside-worktree'; return $out
    }

    $sep = [System.IO.Path]::DirectorySeparatorChar
    $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase }
           else { [System.StringComparison]::Ordinal }
    if ($full.Length -le ($rootFull.Length + 1) -or -not $full.StartsWith(($rootFull + $sep), $cmp)) {
        $out.reason = 'outside-worktree'; return $out
    }

    # A symlink (or junction) at the target, or at ANY existing ancestor directory
    # under the root, is the same escape as '..' — reject it.
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band $reparse)) {
            $out.reason = 'symlink-target'; return $out
        }
    }
    $ancestor = Split-Path -Parent $full
    while ($ancestor -and $ancestor.Length -gt $rootFull.Length) {
        if (Test-Path -LiteralPath $ancestor) {
            $anc = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
            if ($null -ne $anc -and ($anc.Attributes -band $reparse)) {
                $out.reason = 'symlink-target'; return $out
            }
        }
        $next = Split-Path -Parent $ancestor
        if ($next -eq $ancestor) { break }
        $ancestor = $next
    }

    $out.ok = $true
    $out.full = $full
    return $out
}

function Invoke-EditBlockApply {
    <# .SYNOPSIS
       Apply parsed edit blocks to a worktree, all-or-nothing.

       Order: validate every path -> scope-check every path against allowed_paths
       (reusing the verification oracle, never a reimplementation) -> load every
       touched file into memory -> apply every block to the in-memory copies ->
       and only then flush to disk. Any failure returns before the flush, so a
       rejected batch leaves every file byte-identical.

       Matching is EXACT and ordinal — no fuzzy matching, and the substitution is
       an index-based Remove/Insert, never PowerShell's regex -replace.

       Returns [ordered]@{ ok; result; error; files_written; blocks_applied } where
       result is 'ok' | 'search-not-found' | 'search-ambiguous' | 'path-rejected' |
       'scope-rejected' | 'create-exists'. #>
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [object[]]$Blocks = @(),
        [string[]]$AllowedPaths = @()
    )

    $out = [ordered]@{
        ok             = $false
        result         = 'ok'
        error          = ''
        files_written  = @()
        blocks_applied = 0
    }

    $blockList = @($Blocks | Where-Object { $null -ne $_ })
    if ($blockList.Count -eq 0) { $out.ok = $true; return $out }

    # --- 1. Validate every path first; one bad path rejects the whole batch. ---
    $resolved = @{}     # normalized rel path -> absolute path
    $order = @()        # first-seen order of distinct rel paths
    foreach ($b in $blockList) {
        $rel = [string]$b.path
        $safe = Test-DiffApplyPathSafe -Worktree $Worktree -RelPath $rel
        if (-not $safe.ok) {
            $out.result = 'path-rejected'
            $out.error = "path rejected ($($safe.reason)): $rel"
            return $out
        }
        $norm = $rel.Replace('\', '/')
        if (-not $resolved.ContainsKey($norm)) {
            if (Test-Path -LiteralPath $safe.full -PathType Container) {
                $out.result = 'path-rejected'
                $out.error = "path rejected (directory-target): $rel"
                return $out
            }
            $resolved[$norm] = $safe.full
            $order += $norm
        }
    }

    # --- 2. Scope check via the shared oracle (fail closed if it is missing). ---
    if (-not (Get-Command -Name 'Test-DiffFilesInAllowedPaths' -ErrorAction SilentlyContinue)) {
        $out.result = 'scope-rejected'
        $out.error = 'scope oracle Test-DiffFilesInAllowedPaths unavailable — failing closed'
        return $out
    }
    $scope = Test-DiffFilesInAllowedPaths -DiffFiles $order -AllowedPaths $AllowedPaths
    if (-not $scope.ok) {
        $out.result = 'scope-rejected'
        $out.error = "path outside allowed_paths: $($scope.first_offender)"
        return $out
    }

    # --- 3. Load every existing target into memory (content + shape). ---
    $files = [ordered]@{}
    foreach ($norm in $order) {
        $full = $resolved[$norm]
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $offset = if ($bom) { 3 } else { 0 }
        $content = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)

        $crlfCount = 0
        $idx = $content.IndexOf("`r`n", [System.StringComparison]::Ordinal)
        while ($idx -ge 0) {
            $crlfCount++
            $idx = if (($idx + 2) -le $content.Length) { $content.IndexOf("`r`n", $idx + 2, [System.StringComparison]::Ordinal) } else { -1 }
        }
        $lfCount = 0
        $idx = $content.IndexOf("`n", [System.StringComparison]::Ordinal)
        while ($idx -ge 0) {
            $lfCount++
            $idx = if (($idx + 1) -le $content.Length) { $content.IndexOf("`n", $idx + 1, [System.StringComparison]::Ordinal) } else { -1 }
        }
        $eol = if ($crlfCount -gt ($lfCount - $crlfCount)) { "`r`n" } else { "`n" }

        $files[$norm] = [ordered]@{
            full             = $full
            content          = $content
            eol              = $eol
            bom              = $bom
            trailing_newline = $content.EndsWith("`n")
        }
    }

    # --- 4. Apply every block in order against the in-memory copies. ---
    $writeOrder = @()
    $applied = 0
    foreach ($b in $blockList) {
        $norm = ([string]$b.path).Replace('\', '/')
        $searchRaw = [string]$b.search
        $replaceRaw = [string]$b.replace
        $isCreate = ([bool]$b.is_create) -or ($searchRaw -eq '')

        if ($isCreate) {
            if ($files.Contains($norm)) {
                $out.result = 'create-exists'
                $out.error = "create block targets a file that already exists: $norm"
                return $out
            }
            $files[$norm] = [ordered]@{
                full             = $resolved[$norm]
                content          = $replaceRaw
                eol              = "`n"
                bom              = $false
                trailing_newline = $true
            }
        } else {
            if (-not $files.Contains($norm)) {
                $out.result = 'search-not-found'
                $out.error = "search text not found in ${norm} (file does not exist): $(Get-EditSearchSnippet $searchRaw)"
                return $out
            }
            $f = $files[$norm]
            $search = if ($f.eol -eq "`r`n") { $searchRaw.Replace("`n", "`r`n") } else { $searchRaw }
            $replace = if ($f.eol -eq "`r`n") { $replaceRaw.Replace("`n", "`r`n") } else { $replaceRaw }

            $count = 0
            $firstIdx = -1
            $scan = 0
            while ($scan -le $f.content.Length) {
                $hit = $f.content.IndexOf($search, $scan, [System.StringComparison]::Ordinal)
                if ($hit -lt 0) { break }
                $count++
                if ($firstIdx -lt 0) { $firstIdx = $hit }
                if ($count -ge 2) { break }
                $scan = $hit + $search.Length
            }

            if ($count -eq 0) {
                $out.result = 'search-not-found'
                $out.error = "search text not found in ${norm}: $(Get-EditSearchSnippet $searchRaw)"
                return $out
            }
            if ($count -ge 2) {
                $out.result = 'search-ambiguous'
                $out.error = "search text matches more than once in ${norm}: $(Get-EditSearchSnippet $searchRaw)"
                return $out
            }
            # Index-based splice — NOT -replace, which is regex and would corrupt
            # any text containing $ [ ( . etc.
            $f.content = $f.content.Remove($firstIdx, $search.Length).Insert($firstIdx, $replace)
        }

        if ($writeOrder -notcontains $norm) { $writeOrder += $norm }
        $applied++
    }

    # --- 5. Flush. Reached only when every block succeeded. ---
    $written = @()
    foreach ($norm in $writeOrder) {
        $f = $files[$norm]
        $text = $f.content
        if ($f.trailing_newline) {
            if (-not $text.EndsWith("`n")) { $text += $f.eol }
        } elseif ($text.EndsWith("`r`n")) {
            $text = $text.Substring(0, $text.Length - 2)
        } elseif ($text.EndsWith("`n")) {
            $text = $text.Substring(0, $text.Length - 1)
        }
        $dir = Split-Path -Parent $f.full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($f.full, $text, [System.Text.UTF8Encoding]::new([bool]$f.bom))
        $written += $norm
    }

    $out.ok = $true
    $out.result = 'ok'
    $out.files_written = @($written)
    $out.blocks_applied = $applied
    return $out
}
