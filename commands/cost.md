---
description: Per-project cost ledger. Bare /cost prints the current ledger. `/cost <new-total>` appends an entry with auto-computed delta and updates the Current-total header.
argument-hint: [<new-total> [--source "<s>"] [--note "<text>"]]
---

# /cost

Per-project cost tracking. Stores at `~/.claude/knowledge/projects/<id>/cost.md`.
Cross-project rollup is deferred to the Plan 7 multi-project command center.

## Steps

1. **If `$ARGUMENTS` is empty**, print the current ledger and stop:

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/cost-lib.ps1"
   $path = Get-CostPath
   if (Test-Path $path) {
       Get-Content $path -Raw | Write-Host
   } else {
       Write-Host "No cost ledger yet for this project. Run: /cost <total> --note ""<text>""" -ForegroundColor Yellow
   }
   ```

2. **If `$ARGUMENTS` has a number**, parse: first token is the new total (strip
   any leading `$`); optional `--source "<s>"` (default `Claude Code billing`);
   optional `--note "<text>"`. Then:

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/cost-lib.ps1"
   $total  = [decimal]'<TOTAL>'
   $source = '<SOURCE_OR_DEFAULT>'
   $note   = '<NOTE_OR_EMPTY>'
   $r = Add-CostEntry -Total $total -Source $source -Note $note
   $deltaStr = if ($r.delta -ge 0) { ('+$' + ('{0:F2}' -f $r.delta)) } else { ('-$' + ('{0:F2}' -f [Math]::Abs($r.delta))) }
   Write-Host "Logged: total=`$$total ($deltaStr from previous)." -ForegroundColor Green
   Get-Content $r.path -Raw | Write-Host
   ```

3. **On error** (bad number parse), surface the message and show the usage from
   `argument-hint`.

## Arguments

$ARGUMENTS
