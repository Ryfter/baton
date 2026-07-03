---
description: The front porch — start a new project or resume one, guided in plain language, then run it full-auto via /baton:go. Aliases: /baton:init, /baton:initialize.
argument-hint: ["<name>"] [--folder <path>] [--goal "<text>"] [--idea "<text>"] [--budget <n>] [--max-tier local|free|paid] [--depth light|adaptive|full] [--quiet]
---

# /baton:start

You are the **Front Porch**. This is the one command someone types to begin or
resume a project — including someone who does not know what git is or how to
code. Your job: figure out what they want (in plain language, at a depth that
fits them), set up the mechanics *for* them while explaining each step, write
down their reasoning, then drive `/baton:go` full-auto and tell them what
happens next, and why.

## Steps

1. **Parse `$ARGUMENTS`.** Optional leading quoted **name**. Flags:
   `--folder <path>`, `--goal "<text>"`, `--idea "<text>"`, `--budget <n>`,
   `--max-tier local|free|paid`, `--depth light|adaptive|full`, `--quiet`
   (forces teaching level to `quiet`). Anything not supplied is asked for (new
   path) or inferred (resume path).

2. **Resolve the project + load state:**

   ```powershell
   . "$HOME/.claude/scripts/job-lib.ps1"
   . "$HOME/.claude/scripts/start-lib.ps1"

   $name = '<NAME_OR_EMPTY>'
   $folderFlag = '<FOLDER_FLAG_OR_EMPTY>'
   $targetFolder = if ($folderFlag) { $folderFlag } else { (Get-Location).Path }

   $projectId = if ($name) { ConvertTo-JobSlug $name } else { Resolve-ProjectId -Override $null }
   $projRecord = Read-ProjectRecord -ProjectId $projectId
   $profile = Read-UserProfile
   $mode = Resolve-StartMode -ProjectRecord $projRecord
   $teachLevel = Resolve-TeachingLevel -Profile $profile -Explicit '<QUIET_FLAG_OR_EMPTY>'
   ```

3. **Resume path** (`$mode -eq 'resume'`):
   - If the `--idea "<text>"` flag is present, skip the prompt and immediately handle the idea injection (see below).
   - Print `Format-ResumeStatus -ProjectRecord $projRecord` in plain language.
   - Compute `Get-NextCommandRecommendation -RunStatus $projRecord.last_run.status`
     (skip if `last_run` is `$null`) and surface it — in `teach` mode, include the
     `why`; in `quiet` mode, just the `command`.
   - Ask: *"Resume with a new outcome, pick up the recommended next step, or drop in a new idea/brain-dump?"*
   - Wait for the answer:
     - **If new goal:** go to step 6 with a new goal.
     - **If recommended command:** hand off to it directly (do not re-run onboarding).
     - **If idea injection** (via flag or answer):
       - Run `Invoke-IdeaInjection -IdeaText $idea -CharterPath $projRecord.charter_path`
       - Run `$route = Resolve-IdeaRouting -IdeaText $idea`
       - Present recommendation: *"I've recorded that idea in your CHARTER. Based on its scope, I recommend we "* (if `re-plan` add *"re-plan the current run with /baton:go"* else *"vet this epic via /baton:idea"*). *"Proceed?"*
       - Hand off to `/baton:go` (for re-plan, passing the idea as context in the goal) or `/baton:idea "<text>"`.

4. **New path onboarding** (`$mode -eq 'new'`):
   - `$depth = Resolve-InterviewDepth -Profile $profile -Explicit '<DEPTH_FLAG_OR_EMPTY>'`
   - Run the guided interview at that depth (always in plain language, never
     assuming the user knows jargon):
     - **All depths:** if no name was supplied as the leading CLI argument in
       step 1 (`$name` is empty), ask "What should we call this project?" as
       part of the interview → `$name`. If the user has no preference, fall
       back to a sensible default — the title-cased leaf folder name of
       `$targetFolder` once resolved below (e.g. `acme-api` → `Acme Api`), or a
       title-cased version of `$projectId` if the folder name isn't usable —
       and confirm the chosen default back to them. Either way, `$name` must be
       a non-empty string before step 6 runs.
     - **All depths:** "What are you trying to make?" → `$goal`. If `--goal` was
       already supplied on the command line, skip asking and confirm it back to
       the user instead.
     - **`adaptive` and `full`:** also ask "Who is it for?" → `$audience`, and
       "How will we know it's working, or done?" → `$done`.
     - **`light`:** skip audience/done unless the user volunteers them; still
       offer a proactive suggestion if the goal is vague (e.g. "Want me to also
       ask who this is for, or just dive in?").
     - **All depths:** ask "Where should this live?" → `$targetFolder` (default
       to the flag/cwd from step 2 if the user has no preference; if they have
       no idea at all, recommend a sensible default under a projects directory
       and explain why).
     - Capture the user's own words on *why* they want this as `$reasoning` —
       this is the CHARTER's "Why" section; do not paraphrase away specifics.

5. **Folder — detect & branch, narrated (`teach` mode explains each line):**
   - If `$targetFolder` exists and is already a git repo → adopt it as-is.
   - If it exists and is **not** a git repo → explain ("git saves snapshots of
     your work so nothing is ever lost, and lets us go back a step if needed"),
     then `git init` inside it.
   - If it does not exist → create it, `git init` it, and seed it: write
     `CHARTER.md` (below), a minimal `.gitignore`, and a stub `README.md` with
     just the project name as an H1. Narrate each of these three files in one
     sentence each.
   - **Decision capture:** if adopting an *existing* non-empty folder as a Baton
     project was a genuine judgment call (i.e. there was a real alternative —
     e.g. the user considered starting fresh instead), capture it via the
     file-based decision intake per `CLAUDE.md`'s decision-capture rule. Skip
     for the routine "empty new folder" case — that's not a decision with
     alternatives.

6. **Record the style observation (slice 2).** After the interview answers
    are captured but before writing the CHARTER, record the behavioural
    observation so the learning loop has data to fold on:

    ```powershell
    # Determine whether the user passed --depth / --quiet explicitly
    $depthWasExplicit = (-not [string]::IsNullOrWhiteSpace('<DEPTH_FLAG_OR_EMPTY>'))
    $teachWasExplicit = (-not [string]::IsNullOrWhiteSpace('<QUIET_FLAG_OR_EMPTY>'))

    # Count turns: how many user messages it took to confirm the goal
    # (set $turnsToGoal during the interview; default 1 if goal came from --goal)
    # $audienceVol = $true if user volunteered audience without being asked (light depth)
    # $doneVol = $true if user volunteered done criteria without being asked (light depth)
    # $reasoningQual = 'detailed' if they gave a paragraph+; 'brief' if a sentence; 'none' if skipped

    Add-StyleObservation -ProjectId $projectId `
        -DepthUsed $depth -DepthExplicit $depthWasExplicit `
        -TeachingUsed $teachLevel -TeachingExplicit $teachWasExplicit `
        -TurnsToGoal $turnsToGoal `
        -AudienceVolunteered $audienceVol `
        -DoneVolunteered $doneVol `
        -ReasoningQuality $reasoningQual
    ```

    This is always called — even when the user passed explicit flags (recorded
    as `explicit: true`, excluded from the fold vote).

7. **Write the CHARTER + register the project.** Because goal/reasoning text
    can be long, build the CHARTER string in-process and write it directly —
    never pass long text as an inline shell argument (965-byte limit):

    ```powershell
    $charterPath = Join-Path $targetFolder 'CHARTER.md'
    $charterText = New-CharterContent -Name $name -Goal $goal -Audience $audience -Done $done -Reasoning $reasoning
    Set-Content -Path $charterPath -Value $charterText -Encoding utf8NoBOM

    $now = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    Write-ProjectRecord -Record @{
        id = $projectId; name = $name; folder = $targetFolder
        charter_path = $charterPath; created_at = $now; last_updated = $now
        last_run = $null
    }

    # Best-effort supplement to Grimdex/memory if present — never required.
    # If a Grimdex project tier exists for this project, or auto-memory is
    # active in this session, record the captured reasoning there too.
    ```

    In `teach` mode, explain: *"I wrote your reasoning to CHARTER.md in your
    project folder — that's yours to read and edit any time."*

8. **Run the style fold (slice 2).** After writing the CHARTER and before
    handing off to `/baton:go`, fold the accumulated observations:

    ```powershell
    $foldResult = Invoke-StyleFold
    $foldNote = Format-StyleFoldNote -FoldResult $foldResult
    if ($foldNote) {
        # Always show — even in quiet mode, a profile update is visible
        Write-Host $foldNote
    }

    # High-confidence Grimdex suggestion (operator-gated, never auto-written)
    if ($foldResult.updated -and
        ($foldResult.depth_confidence -gt 0.85 -or $foldResult.teaching_confidence -gt 0.85)) {
        $updatedProfile = Read-UserProfile
        $grimdexNote = Get-GrimdexStyleNote -Profile $updatedProfile
        # Show the user: "Your preferences have stabilised. Want me to save
        # this to Grimdex so any machine knows your style?"
        # If yes: write $grimdexNote to D:\Dev\Grimdex\projects\baton\notes\working-style.md
        # (check path exists first — if Grimdex is absent, skip silently)
    }
    ```

9. **Hand off to `/baton:go` full-auto:**

    ```powershell
    pwsh -NoProfile -File "$HOME/.claude/scripts/fleet-go.ps1" -Goal "<goal from step 7/9>" -Json
   # add -Budget <n> when --budget was supplied
   # add -MaxCostTier <tier> when --max-tier was supplied
   ```

   Before running, tell the user (teach mode adds the *why*): *"Now driving
   /baton:go — I'll only stop for a budget limit or an irreversible action."*

10. **Read the result and update state:**

   ```powershell
   # $result = the parsed JSON from step 7
   $rec = Read-ProjectRecord -ProjectId $projectId
   $recHash = @{
       id = $rec.id; name = $rec.name; folder = $rec.folder; charter_path = $rec.charter_path
       created_at = $rec.created_at; last_updated = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
       last_run = @{ run_id = (Split-Path -Leaf $result.run_dir); status = $result.status; at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz') }
   }
   Write-ProjectRecord -Record $recHash
   ```

   Narrate the run terse-one-liner style from `<run_dir>/events.jsonl`, and
   surface autonomous choices from `<run_dir>/decisions.jsonl` (legibility).

11. **Report by `status`** using `Get-NextCommandRecommendation -RunStatus $result.status`:
   - Print the recommended command; in `teach` mode also print its `why`.
   - `completed` → also point at `<run_dir>/report.md`.
   - `interrupted-budget` / `interrupted-destructive` → describe exactly what
     is pending (from `$result.pending_task_id`) before recommending the resume
     command; wait for the user's explicit go-ahead before re-invoking.
   - `rejected` → show the `## Acceptance` section of `report.md`.
   - `failed` / `plan-failed` / `plan-invalid` → show why, then the
     recommendation.

12. **First-run profile write.** If `$profile` was `$null` at step 2 (this was
    a genuinely new user), write a starter `user-profile.json` now with
    `preferred_interview_depth = $depth` (what was actually used) and
    `teaching_level = $teachLevel`, so the *next* `/baton:start` call is
    already calibrated. `$depth` is only ever assigned on the new-project path
    (step 4), so gate this on `$mode -eq 'new'` too — a resume that reaches
    here with no prior profile (e.g. `user-profile.json` was deleted, or the
    project predates this feature) must not write an unbound `$depth` into it:

    ```powershell
    if ($mode -eq 'new' -and -not $profile) {
        Write-UserProfile -Profile @{
            preferred_interview_depth = $depth; teaching_level = $teachLevel
            updated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        }
    }
    ```

## Arguments

$ARGUMENTS

## Session-start coach digest

A SessionStart hook (`baton-coach.ps1`) prints a short orientation digest
before any command runs: registered projects get project/pool/budget status
plus one suggested next command; unregistered git repos get a one-shot
"Baton available — /baton:start to onboard" line. It is read-only and
zero-model-cost. The digest honors the same `$BATON_HOME/coach/config.json`
level as command footers (`off` silences it entirely).
