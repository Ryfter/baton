#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Claude Code PostToolUse hook: auto-indexes touched KB files.

.DESCRIPTION
  Reads the PostToolUse JSON payload from stdin. When Write/Edit touches a file
  under ~/.claude/knowledge/, starts `python -m kb.index --scope <derived>` in
  the background. Incremental indexing is the default, so unchanged files in the
  same scope are skipped by the Python indexer.
#>

$ErrorActionPreference = 'Continue'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $evt = $raw | ConvertFrom-Json -ErrorAction Stop
    $filePath = $evt.tool_input.file_path
    if (-not $filePath) { exit 0 }

    $knowledgeRoot = [IO.Path]::GetFullPath((Join-Path $HOME '.claude\knowledge')).TrimEnd('\', '/')
    $touchedPath = [IO.Path]::GetFullPath(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($filePath)
    )

    $rootPrefix = "$knowledgeRoot\"
    if (($touchedPath -ne $knowledgeRoot) -and -not $touchedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        exit 0
    }

    $relative = $touchedPath.Substring($knowledgeRoot.Length).TrimStart('\', '/') -replace '/', '\'
    $parts = $relative -split '\\'
    $scope = 'all'
    if ($parts.Count -ge 1 -and $parts[0] -ieq 'universal') {
        $scope = 'universal'
    } elseif ($parts.Count -ge 2 -and $parts[0] -ieq 'projects') {
        $scope = $parts[1]
    }

    $repoRoot = $null
    if ($env:CAO_REPO_ROOT -and (Test-Path (Join-Path $env:CAO_REPO_ROOT 'kb'))) {
        $repoRoot = (Resolve-Path $env:CAO_REPO_ROOT).Path
    } else {
        $candidate = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if (Test-Path (Join-Path $candidate 'kb')) { $repoRoot = $candidate }
    }

    $startArgs = @{
        FilePath     = 'python'
        ArgumentList = @('-m', 'kb.index', '--scope', $scope)
        WindowStyle  = 'Hidden'
    }
    if ($repoRoot) { $startArgs.WorkingDirectory = $repoRoot }

    Start-Process @startArgs | Out-Null
    exit 0
} catch {
    exit 0
}
