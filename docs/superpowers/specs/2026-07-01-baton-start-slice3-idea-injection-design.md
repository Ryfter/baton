---
title: /baton:start — Mid-stream idea injection (slice 3)
status: draft
date: 2026-07-01
supersedes: none
relates-to: /baton:start, /baton:go, /baton:idea
---

# /baton:start — Mid-stream idea injection (slice 3)

## Summary

Slice 3 of the `/baton:start` front porch introduces **mid-stream idea injection**. It supports a days-long, idea-driven cadence where a user can dump raw thoughts ("brain-dumps") into an ongoing project without breaking stride. The idea is folded into the project's CHARTER and an LLM classifier automatically determines whether to route the user to a tactical re-plan (`/baton:go`) or a vetting cycle (`/baton:idea`) for epic-scale pivots.

## Goals

- **Brain-dump anytime:** Accept raw text via a `--idea "<text>"` flag or via the interactive Resume prompt.
- **Persistent Context:** Fold the injected idea securely into the user's `CHARTER.md` under a "Decisions & open questions" section with a timestamp.
- **Intelligent Routing:** Evaluate the idea's scope using a fast/cheap LLM (house pattern: `triage` capability model like Haiku) and recommend the appropriate next command:
  - **Re-plan (`/baton:go`)**: For tactical pivots, immediate next steps, or minor scope adjustments.
  - **Backlog (`/baton:idea`)**: For massive new epics, architectural overhauls, or ideas requiring a viability debate.

## Architecture

### Files Modified
- **`scripts/start-lib.ps1`**: Add pure logic and seamed I/O for `Invoke-IdeaInjection` and `Resolve-IdeaRouting`.
- **`commands/start.md`**: Wire the `--idea` flag and the Resume path prompt. 

### `start-lib.ps1` Additions

- `Invoke-IdeaInjection -IdeaText -CharterPath` → appends the idea to the CHARTER.
  - Ensures the "Decisions & open questions" section exists.
  - Appends `- [$(Get-Date)] Idea: $IdeaText`.
- `Build-IdeaRoutingPrompt -IdeaText` → constructs the classification prompt.
- `Get-IdeaRoutingJsonBlock -Text` → parses the JSON output from the LLM.
- `Resolve-IdeaRouting -IdeaText -Dispatcher` → uses `Invoke-Fleet` (via the injectable Dispatcher) to classify the idea. Returns `re-plan` or `backlog`.

### Command Wiring (`commands/start.md`)

- **Step 1:** Add `--idea "<text>"` to argument parsing.
- **Step 3 (Resume):** 
  - If `--idea` is present, immediately execute injection.
  - Otherwise, the interactive prompt becomes: *"Resume with a new outcome, pick up the recommended next step, or drop in a new idea/brain-dump?"*
  - Run `Invoke-IdeaInjection`.
  - Run `Resolve-IdeaRouting`.
  - Present the recommendation: *"I've recorded that idea in your CHARTER. Based on its scope, I recommend we [re-plan the current run / vet this via /baton:idea]. Proceed?"*

## Global constraints (for the plan)
- **965-byte shell-arg limit:** Avoid passing full CHARTER content over CLI args. Use `Set-Content` directly.
- **Box-private:** No changes; CHARTER is user-owned.
- **Fail-open:** If `Resolve-IdeaRouting` fails to parse JSON or hits an API error, fallback to `re-plan`.

## Testing
- **`test-start-lib-s3.ps1`**:
  - `F1/F2`: `Invoke-IdeaInjection` appends safely and creates missing sections.
  - `F3`: `Resolve-IdeaRouting` parses JSON properly.
  - `F4`: `Resolve-IdeaRouting` fallback logic works.
