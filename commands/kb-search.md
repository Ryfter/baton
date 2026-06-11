---
description: Semantic top-k search over the embedded KB. Scope = universal | <project-id> | all (default all). Use --k to change result count.
argument-hint: "<query>" [--k N] [--scope universal|<project-id>|all] [--decisions-only]
---

# /baton:kb-search

Query the embedded KB. Returns top-k chunks with scores + source paths + snippets.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted string is the query; optional
   `--k N` (default 5), `--scope <value>` (default `all`), and
   `--decisions-only` (default false).

2. **Run search.**

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $hits = Invoke-KbSearch -Query '<query>' -K <k> -Scope '<scope-or-empty>' -DecisionsOnly:<$decisionsOnly>
   Format-KbHits -Hits $hits
   ```

3. **Empty index?** If `Invoke-KbSearch` returns `@()` *and* the index is
   empty, suggest `/baton:kb-index --full` (and `ollama pull nomic-embed-text`
   if that's not pulled yet).

4. **Empty query?** Ask the user for a non-empty query string.

## Arguments

$ARGUMENTS
