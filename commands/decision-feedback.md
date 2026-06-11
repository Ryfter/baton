---
description: Attach human feedback to a decision record. Outcome worked|didnt|mixed; --urgent writes a dashboard journal line for immediate visibility.
argument-hint: <id> "<text>" [--outcome worked|didnt|mixed] [--urgent]
---

# /baton:decision-feedback

Append feedback to a decision record at
`~/.claude/knowledge/projects/<project>/decisions/<id>-*.md`.

## Steps

1. **Parse `$ARGUMENTS`:** first token is the decision id (e.g. `d014`); next a
   quoted string is the feedback text; optional `--outcome worked|didnt|mixed`
   (default `worked`); optional `--urgent`.

2. **Resolve project** via Plan 3's `Resolve-ProjectId` (auto-detect from git
   remote / cwd).

3. **Run:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/decisions-lib.ps1"
   $id      = '<ID>'
   $text    = '<TEXT>'             # single-quote-escaped
   $outcome = '<OUTCOME>'           # 'worked' | 'didnt' | 'mixed'
   $proj    = Resolve-ProjectId
   Append-DecisionFeedback -Id $id -Project $proj -Text $text -Outcome $outcome -Author 'kevin'
   Write-Host "Feedback recorded on $id ($outcome)." -ForegroundColor Green
   ```

4. **If `--urgent`**, additionally write a journal line so the dashboard sees it:

   ```powershell
   $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
   $line = "$ts | dashboard | decision-flag | $id | urgent feedback: $text"
   Add-Content -Path (Join-Path $HOME '.claude/model-routing-log.md') -Value $line
   ```

5. **On error** (unknown id, no project), surface the thrown message and suggest
   the user check `~/.claude/knowledge/projects/<id>/decisions/` for valid ids.

## Arguments

$ARGUMENTS
