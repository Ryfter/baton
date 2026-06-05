# Dashboard redesign — handoff (Claude's pass on Codex's audit)

**Branch:** `gemini/dashboard-redesign`
**Date:** 2026-06-05
**Author:** Claude (orchestrator)
**Responds to:** [`dashboard-redesign-audit.md`](dashboard-redesign-audit.md) (Codex, 2026-06-05)

This pass takes Gemini's unreviewed WIP redesign and resolves every required fix
from Codex's audit. The branch was first brought up to date with `master`
(it predated the `agent-handoffs.md` work and would otherwise have reverted it).

## What changed

| Area | File(s) |
|---|---|
| Offline assets + favicon | `dashboard/templates/base.html`, `dashboard/static/vendor/{htmx.min.js,chart.umd.min.js}` |
| System fonts, tighter design system, consolidated fleet CSS, a11y, responsive | `dashboard/static/style.css` |
| Fleet partial reduced to markup (no inline `<style>`) | `dashboard/templates/partials/fleet_activity.html` |
| Wide tables wrapped for horizontal scroll | `partials/{leaderboard,projects_list,jobs_list}.html` |
| Chart fonts/colours follow the system stack | `dashboard/static/app.js` |
| Evidence | `docs/assets/dashboard-redesign/{redesign-desktop-1440.png,redesign-mobile-390.png}` |

## Audit fixes — status

1. **Browser QA + evidence — DONE.** Ran the dashboard on `127.0.0.1:8765` and
   captured full-page screenshots at desktop (1440×900) and mobile (390×844),
   stored under `docs/assets/dashboard-redesign/`. Browser console: **0 errors**
   on `/` and `/projects` (the prior `favicon.ico` 404 is also fixed — see below).

2. **External Google Fonts dependency — REMOVED.** The `fonts.googleapis.com` /
   `fonts.gstatic.com` links are gone. `--font-sans` / `--font-mono` are now
   system stacks (`ui-sans-serif…`, `ui-monospace…`), so type renders identically
   offline. While here, **htmx and Chart.js were also vendored locally** under
   `static/vendor/` — previously CDN-loaded, so the dashboard now has **zero
   external network dependencies** and works fully offline/private by default.
   A 🐙 emoji favicon is inlined as an SVG data URI (no asset, no 404).

3. **Duplicated fleet CSS — CONSOLIDATED.** The large `<style>` block inside
   `fleet_activity.html` is removed; all fleet styling lives once in `style.css`.
   The duplicate `!important`-laden override section is gone. The only remaining
   `!important` in the file is the standard `prefers-reduced-motion` reset and two
   pre-existing `.decision-card` rules unrelated to this redesign.

4. **Design system tightened — DONE.** Pulled back from the glassmorphic/neon
   direction toward a utilitarian ops cockpit: flat body background (no broad
   radial gradient), opaque cards with reduced blur (16→8px) and no hover-lift or
   decorative shimmer bar, gradient title text replaced with a solid heading,
   status pills and the spend figure no longer use glow shadows. Restrained
   shadow/transition tokens. Colour is still used for status but is no longer the
   primary visual effect.

5. **Card radius + nested-card risk — DONE.** Introduced an 8px `--radius` token;
   cards and fleet runs use it (down from 12px). Fleet provider outputs and the
   synthesis block were reframed as borderless collapsible **sections** (subtle
   background + a single top divider) instead of bordered cards-inside-cards.

6. **First-class functionality honesty — VERIFIED, NO CHANGE NEEDED.** The
   cockpit's affordances are already honest: the Controls card has real working
   buttons (Ollama stop-all, LM Studio unload/stop) that POST to live endpoints,
   and the empty-fleet copy directs users to dispatch `/ensemble`, `/six-hats`,
   etc. from the CLI rather than implying browser launch. No false controls were
   added or implied. Real browser-driven launch/approval surfaces remain a
   deliberate, separate future step.

7. **Responsive polish — DONE.** Added a `max-width: 640px` breakpoint on top of
   the existing 1024px one: header wraps (title / nav / time), padding tightens,
   the spend figure scales down, model names cap their width, and the live-activity
   rows reflow from a fixed 4-column grid to a stacked layout. Wide tables
   (leaderboard, portfolio, jobs) are wrapped in `.table-scroll` so they scroll
   horizontally inside their card instead of clipping. Verified on the 390px shot.

8. **Accessibility — DONE.** Provider status is no longer colour-only: each state
   carries a glyph via `::before` (`✓` done, `✕` error, `⌛` timeout, `◌` queued;
   running keeps its live pulse dot) plus the textual state in the output summary.
   Added `:focus-visible` outlines for links/buttons/summaries/inputs, a
   `prefers-reduced-motion` block that disables the pulse and transitions, and
   bumped muted-text colours for better contrast on the dark background.

## Verification

```
python -m pytest dashboard -q        # 86 passed
python -m pytest kb dashboard -q     # 116 passed
```

Manual/browser (uvicorn on `127.0.0.1:8765`):
- Desktop 1440×900 and mobile 390×844 screenshots captured (see evidence dir).
- Console clean (0 errors) on `/` and `/projects`.
- No external requests issued → renders offline / with Google Fonts blocked.
- Empty states (no active fleet run, no projects, no jobs, no OTel) all readable.

## Intentionally out of scope

- **Live active-run visual:** no fleet run was in flight during QA, so the active
  state and partial-response/synthesis panels weren't captured in a screenshot.
  Their markup is exercised by `test_ensembles_reader.py`; the CSS is unchanged in
  behaviour, only restyled. Worth a screenshot next time a run is live.
- **Browser-driven fleet controls** (provider roster selection, `/fleet doctor`,
  `/ensemble` launch, backlog approval) — a real feature, not a styling fix; left
  for a dedicated implementation step per audit item #6.
