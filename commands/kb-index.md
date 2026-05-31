---
description: Build (or update) the KB embedding index. Default is incremental by mtime; --full rebuilds from scratch. Scope = universal | <project-id> | all.
argument-hint: "[--full] [--scope universal|<project-id>|all]"
---

# /kb-index

Build or update the embedding index over `~/.claude/knowledge/` (+ job lessons).

## Steps

1. **Parse `$ARGUMENTS`** for `--full` and `--scope <value>`.

2. **Run the indexer.** Default is incremental (only re-indexes files whose
   mtime is newer than recorded). `--full` rebuilds from scratch.

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $argList = @()
   if ('--full' in $ARGUMENTS) { $argList += '--full' }
   # add --scope if present
   $code = Invoke-KbIndex -Args $argList
   ```

3. **Surface result.** The Python CLI prints a per-file `+` line and a
   summary `Indexed N/M files (...) chunks added. Store now has X rows.`.
   Pass that through to the user.

4. **First-run hint.** If `nomic-embed-text` is not pulled in Ollama, the
   indexer errors per-file. In that case suggest:

   ```
   ollama pull nomic-embed-text
   ```

   then `/kb-index --full` to retry.

## Arguments

$ARGUMENTS
