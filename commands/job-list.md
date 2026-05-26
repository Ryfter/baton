---
description: List jobs under ~/.claude/jobs/, filtered by status.
argument-hint: [--all | --active | --done]
---

# /job-list

Show jobs in `~/.claude/jobs/`. Default filter: `--active`.

Parse `$ARGUMENTS` for one of `--all`, `--active`, `--done`. If empty, treat as `--active`.

Run:

```powershell
. "$HOME/.claude/scripts/job-lib.ps1"

$filter = '<FILTER>'   # 'all', 'active', or 'done'
$jobsRoot = Join-Path $HOME '.claude/jobs'
if (-not (Test-Path $jobsRoot)) {
    Write-Host "No jobs yet."
    return
}

$rows = @()
foreach ($d in Get-ChildItem -Path $jobsRoot -Directory) {
    $mani = Read-Manifest -JobDir $d.FullName
    if (-not $mani) { continue }
    if ($filter -ne 'all' -and $mani.status -ne $filter) { continue }
    $rows += [pscustomobject]@{
        ID      = $mani.id
        Phase   = $mani.current_phase
        Project = $mani.project
        Status  = $mani.status
        Started = $mani.created_at
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No jobs match filter '$filter'."
    return
}

$rows | Sort-Object Started -Descending | Format-Table -AutoSize
```

Replace `<FILTER>` with `all`, `active`, or `done` based on the parsed flag before running.

## Arguments

$ARGUMENTS
