---
description: The idea front door. Turns a raw idea into board-ready GitHub Issues via research + a /council viability debate + a reviewable concept doc, with one human gate. Job-less.
argument-hint: "<raw idea>" [--no-research] [--providers a,b,c] [--tier free,local]
---

# /idea

Turn a raw idea into board-ready GitHub Issues. Job-less — this runs *before* you
commit to a job; its output (issues) becomes the backlog. Exactly one human gate:
you approve the concept doc before any issue is created.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted raw idea + optional `--no-research`,
   `--providers a,b,c`, `--tier free,local`. Empty idea → stop with:
   *"Usage: /idea \"<raw idea>\" [--no-research] [--providers …] [--tier …]"*.

2. **Create the idea workspace** (job-less; sibling of `~/.claude/ensembles/`):

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $ws = New-IdeaWorkspace -Idea '<raw idea>'
   $ws.path
   ```

3. **KB pre-fetch (prior art).** Query the embedded KB for related work and keep
   the hits to seed research + the concept doc. Graceful no-op if the index is
   empty or errors.

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $kbHits = Invoke-KbSearch -Query '<raw idea>' -K 3 -SnippetChars 600 2>$null
   ```

4. **Research (skip if `--no-research`).** Run a research ensemble on the idea,
   writing into the workspace's `research/` dir, then synthesize. Resolve the
   roster and run exactly as `/research` does (explicit `--providers` > `--tier` >
   `Get-FleetResearchDefault`), but the output dir is the idea workspace, not a
   job phase:

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $outDir = Join-Path $ws.path 'research'
   # roster resolution + Invoke-FleetEnsemble + synthesis.md exactly as /research steps 3-6,
   # prepending the KB hits from step 3 as a "Relevant prior knowledge" block.
   ```

   Write `research/synthesis.md`.

5. **Viability debate.** Run a two-round `/council` on the framed question
   *"Is this worth building, and what is the strongest version of it?"*, seeded
   with the research synthesis, writing into the workspace's `council/` dir:

   ```powershell
   . "$HOME/.claude/scripts/council-lib.ps1"
   $outDir = Join-Path $ws.path 'council'
   # roster + Build-CouncilR1Tasks/Build-CouncilR2Tasks + Invoke-FleetEnsembleTasks
   # exactly as /council steps 2-7, writing round1/, round2/, and synthesis.md.
   ```

   **Quorum abort is non-fatal here.** If the council can't reach quorum, do NOT
   stop — record that the debate was thin and continue to the concept doc with a
   *low-confidence viability* note.

6. **Draft the concept doc.** Scaffold it, then fill every section from the
   research + council syntheses (and the KB hits). Be honest in **Viability
   verdict** — flag low confidence when research/debate was thin.

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $concept = Join-Path $ws.path 'concept.md'
   New-IdeaConceptDoc -Path $concept -Title '<short idea title>' -Idea '<raw idea>'
   ```

   Fill the sections (Problem · Viability verdict · Proposed approach · Risks &
   open questions · **Decomposition** · Out of scope). In **Decomposition**, write
   the epic-level task list — each task gets a one-line title, 2-3 sentences of
   scope, acceptance criteria, and an optional Tier label. Then **present
   `concept.md` inline**.

7. **Human gate — approve / revise / drop.**
   - *revise* → edit the doc per feedback and re-present (loop).
   - *drop* → stop; the workspace + concept doc stay as a record.
   - *approve* → continue to step 8.

8. **Land on the board.** Build issue payloads from the Decomposition task list and
   create them. Build the `$tasks` array from the concept doc's Decomposition
   (one entry per task, fields `title`, `description`, `acceptance`, optional
   `tier`):

   ```powershell
   . "$HOME/.claude/scripts/idea-lib.ps1"
   $tasks = @(
       [pscustomobject]@{ title='<task 1 title>'; description='<scope>'; acceptance='<criteria>'; tier='Tier-2' }
       # ... one entry per Decomposition task
   )
   $issues = Build-IdeaIssues -Tasks $tasks -ConceptPath $concept
   $results = Publish-IdeaIssues -Issues $issues -Project 'coding-agent-orchestrator'
   $results | Format-Table title, number, ok, error -AutoSize
   ```

   If the first result is the `(preflight)` row with `ok = $false`, tell the user
   `gh` isn't authenticated (suggest `! gh auth login`) and that **no issues were
   created**. Otherwise report which issues landed (by number) and which failed.

9. **Write the issue numbers back into `concept.md`** under the Decomposition
   section (e.g. append `- #<number> — <title>` for each created issue) so the
   doc records where the tasks went.

10. **Decision capture (judgment).** If the viability debate produced a genuine
    go / no-go / architectural decision with real alternatives, capture it via the
    file-based decision intake (see `CLAUDE.md`). Skip for routine ideas.

## Arguments

$ARGUMENTS
