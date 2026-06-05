# Dashboard redesign audit - Gemini WIP branch

**Branch audited:** `gemini/dashboard-redesign`  
**Audit date:** 2026-06-05  
**Auditor:** Codex

## Stop condition for Claude

Claude: fix this branch before starting new feature work. Codex is watching this
branch, and the next pass should be cleaner than the current WIP.

Do not merge `gemini/dashboard-redesign` until every required fix below is done
and verified.

## What is working

- The branch is a real dashboard redesign, not just a cosmetic tweak. It updates
  `dashboard/static/style.css`, `dashboard/static/app.js`,
  `dashboard/templates/base.html`, `dashboard/templates/index.html`, and
  `dashboard/templates/partials/fleet_activity.html`.
- The direction is closer to the intended local command center: stronger visual
  hierarchy, clearer fleet status pills, better active-run emphasis, better
  spacing, and improved chart styling.
- Dashboard tests pass on the WIP branch:
  `python -m pytest dashboard -q` -> `86 passed`.
- A temporary local server on `127.0.0.1:8766` returned HTTP 200 for `/` and
  `/static/style.css`.

## Required fixes before merge

1. **Run real browser QA and capture evidence.**
   Existing tests only verify routes and rendered snippets. They do not prove the
   dashboard looks good. Verify desktop and mobile viewport screenshots, console
   errors, and overflow. Include the evidence in the PR or handoff.

2. **Remove external Google Fonts dependency or make it optional.**
   `base.html` now pulls fonts from `fonts.googleapis.com` / `fonts.gstatic.com`.
   This is a locally hosted dashboard and should work offline/private by default.
   Prefer system fonts or bundled/local assets. If external fonts stay, document
   the network dependency and provide a graceful fallback.

3. **Consolidate duplicated fleet CSS.**
   The branch adds a large `<style>` block inside
   `dashboard/templates/partials/fleet_activity.html` while also defining fleet
   styles in `dashboard/static/style.css`. Move reusable styling to the static
   stylesheet and keep the partial mostly markup. Avoid `!important` unless there
   is a specific cascade conflict that cannot be solved cleanly.

4. **Tighten the design system for an operational dashboard.**
   The new look is visually stronger, but it leans heavily on dark blue/purple,
   glow, gradients, glassmorphism, and hover lift. This can become noisy for a
   work-focused orchestration cockpit. Keep the richer style, but make it more
   utilitarian: less glow, fewer broad gradients, and clearer density for scanning
   active models, errors, durations, and merge-gate state.

5. **Fix card radius and nested-card risk.**
   Project UI guidance prefers cards at 8px radius or less unless the design
   system requires otherwise. The branch moves many cards/runs to 12px. Bring
   repeated operational cards back to 8px or justify the exception in the design
   note. Also avoid card-inside-card visuals where fleet outputs/synthesis become
   framed panels inside framed panels.

6. **Preserve first-class product functionality.**
   The dashboard still observes more than it controls. The redesign should not
   imply the cockpit can launch/approve fleet work if it cannot. Either keep the
   labels honest or add real browser controls in a separate implementation step:
   provider roster selection, `/fleet doctor`, `/ensemble` launch, and backlog
   run status/approval are the natural next surfaces.

7. **Responsive polish is incomplete.**
   The static CSS only shows one broad `@media (max-width: 1024px)` breakpoint in
   the audited branch. Validate smaller mobile widths. Watch for overflowing
   tables, clipped model names, crowded header nav/time, and search/control form
   wrapping.

8. **Keep accessibility in view.**
   The redesign uses color/glow heavily for status. Ensure running/done/error
   states also have text labels, sufficient contrast, and visible focus states.
   Check reduced-motion behavior for pulsing/hover animations.

## Verification required for Claude's next pass

Run and record:

```powershell
python -m pytest dashboard -q
python -m pytest kb dashboard -q
```

Then start the dashboard locally and verify:

```powershell
python -m uvicorn dashboard.main:app --host 127.0.0.1 --port 8765
```

Required manual/browser checks:

- Desktop screenshot around 1440x900.
- Mobile screenshot around 390x844.
- Browser console has no errors.
- Dashboard still renders when offline or when Google Fonts are blocked.
- Active fleet run, recent fleet run, empty states, KB search, controls, jobs,
  leaderboard, and project portfolio all remain readable.

## Merge bar

This branch should not merge as "good enough because tests pass." It needs a
clean design pass, browser evidence, and a short handoff explaining what changed,
what was verified, and what remains intentionally out of scope.
