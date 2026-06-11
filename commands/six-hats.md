---
description: Six Thinking Hats preset on the ensemble primitive. Runs six role-prefixed prompts (White/Red/Black/Yellow/Green/Blue) concurrently across the fleet, then synthesizes the result as a Blue-Hat conclusion.
argument-hint: "<question>" [--providers a,b,c] [--tier free,local]
---

# /baton:six-hats

Run Edward de Bono's Six Thinking Hats across the fleet.

## Steps

1. **Parse `$ARGUMENTS`:** the quoted string is the question; optional
   `--providers a,b,c` and `--tier free,local`.

2. **Resolve the roster** (same precedence as `/baton:ensemble`):
   - if `--providers` given → that list (drop unknown/disabled with a warning)
   - else if `--tier` given → all enabled providers whose `cost_tier` is in the list
   - else → `Get-FleetResearchDefault`
   Empty → stop with the same message as `/baton:ensemble`.

   ```powershell
   . "$HOME/.claude/scripts/fleet-lib.ps1"
   $explicit = @( <comma-split of --providers, or empty> )
   $tiers    = @( <comma-split of --tier, or empty> )
   if ($explicit.Count) {
       $all = Read-Fleet
       $roster = @($explicit | Where-Object { $n = $_; ($all | Where-Object { $_.name -eq $n -and $_.enabled -eq $true }) })
   } elseif ($tiers.Count) {
       $roster = @((Read-Fleet | Where-Object { $_.enabled -eq $true -and $tiers -contains $_.cost_tier }).name)
   } else {
       $roster = @(Get-FleetResearchDefault)
   }
   if (-not $roster.Count) { Write-Host "No providers resolved." -ForegroundColor Red; return }
   ```

3. **Pick the output dir.** Job-bound → `<job>/phases/research/six-hats-<ts>/`;
   standalone → `~/.claude/ensembles/six-hats-<ts>/`. Timestamp `yyyy-MM-ddTHH-mm-ss`.

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $ts = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'
   $state = Read-CurrentJob
   if ($state.job_id) {
       $outDir = Join-Path $HOME ".claude/jobs/$($state.job_id)/phases/research/six-hats-$ts"
   } else {
       $outDir = Join-Path $HOME ".claude/ensembles/six-hats-$ts"
   }
   ```

4. **KB pre-fanout retrieval (Plan 8).** Before dispatching to the fleet,
   query the embedded KB for top-3 relevant chunks and prepend them as a
   "Relevant prior knowledge" section on each provider's prompt. Graceful
   no-op if the index is empty or kb-search errors.

   ```powershell
   . "$HOME/.claude/scripts/kb-lib.ps1"
   $kbHits = Invoke-KbSearch -Query '<question>' -K 3 -SnippetChars 600 2>$null
   if ($kbHits -and $kbHits.Count -gt 0) {
       $kbBlock = "Relevant prior knowledge (from this project's KB):`n`n"
       foreach ($h in $kbHits) {
           $snippet = ($h.text -replace "`r?`n", ' ').Trim()
           if ($snippet.Length -gt 600) { $snippet = $snippet.Substring(0, 600) + '…' }
           $kbBlock += "- $($h.source) [score $('{0:F2}' -f $h.score)]: $snippet`n"
       }
       $augmented = "$kbBlock`n---`n`n<question>"
   } else {
       $augmented = '<question>'
   }
   ```

5. **Build the six hat tasks + dispatch concurrently:**

   ```powershell
   . "$HOME/.claude/scripts/six-hats-lib.ps1"
   . "$HOME/.claude/scripts/fleet-ensemble.ps1"
   $tasks = Build-SixHatsTasks -Question $augmented -Providers @(<roster>)
   $manifest = Invoke-FleetEnsembleTasks -Tasks $tasks -OutputDir '<outDir>'
   $manifest | Format-Table label, provider, status, duration_s -AutoSize
   ```

6. **Blue-Hat synthesis.** Read each `<outDir>/<hat>.md`. Write a synthesis to
   `<outDir>/synthesis.md` structured as:
   - One short paragraph per hat (summarising the contribution)
   - **Tensions** — where Black and Yellow disagree, where Red diverges from White
   - **Creative directions** — most promising Green Hat ideas
   - **Recommended next move** — your Blue Hat conclusion
   Skip any hat whose file starts with `[ENSEMBLE ERROR]` or `[ENSEMBLE TIMEOUT]`,
   but note the gap. If ALL hats failed, skip synthesis and suggest `/baton:fleet doctor`.
   When KB hits were prepended, mention which sources were used in the synthesis
   preamble.

7. **Present** the synthesis. Report which hats succeeded/failed.

## Arguments

$ARGUMENTS
