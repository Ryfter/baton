---
description: Calibrate universal decision guidance for the current project — surface universal rules, capture per-project overrides into projects/<id>/decision-guidance.md.
argument-hint: [--re-calibrate]
---

# /project-init

Initialize (or re-calibrate) per-project decision guidance from the universal layer.

## Steps

1. **Resolve project** via Plan 3 `Resolve-ProjectId` (auto-detect from git remote / cwd).

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   $proj = Resolve-ProjectId
   $projGuide = Join-Path $HOME ".claude/knowledge/projects/$proj/decision-guidance.md"
   $uniGuide  = Join-Path $HOME ".claude/knowledge/universal/decision-guidance.md"
   ```

2. **Check state:**
   - If `$projGuide` exists AND `--re-calibrate` is NOT in `$ARGUMENTS`:
     stop with *"Project '<proj>' already initialised. Use --re-calibrate to redo."*
   - Else continue.

3. **Read the universal guidance** and present it to the user verbatim:

   ```powershell
   if (-not (Test-Path $uniGuide)) {
       Write-Host "(no universal decision guidance yet — nothing to calibrate from)" -ForegroundColor Yellow
   } else {
       Write-Host "Universal decision guidance:" -ForegroundColor Cyan
       Get-Content $uniGuide -Raw | Write-Host
   }
   ```

4. **Ask the user:**
   *"For project '<proj>': anything to override or add? Reply with overrides as
   `- universal says: X; here: Y; because: Z` lines, one per override. Or say 'use as-is'."*

   Wait for their answer.

5. **Write `$projGuide`** with the calibration header + their overrides (or a
   "use as-is" note). Ensure the parent directory exists. Format:

   ```markdown
   # Decision guidance — <proj>

   <!-- calibrated <YYYY-MM-DD> from universal -->

   ## Established patterns
   _Populated by /consolidate-decisions._

   ## Known mistakes
   _Populated by /consolidate-decisions._

   ## Open / under-feedback
   _Populated by /consolidate-decisions._

   ## Deviations from universal

   <one bullet per override the user supplied>
   ```

6. **Confirm to the user** the file path written.

## Arguments

$ARGUMENTS
