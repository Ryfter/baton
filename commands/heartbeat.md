---
description: Pin the 5-hour usage window to a clock time you choose. One minimal call at the reset boundary anchors the next window, and the same tick clears expired lockouts and stamps session liveness for free.
argument-hint: "[--status] [--anchor \"<reset time>\"] [--now] [--skip-anchor] [--install] [--uninstall] [--print-schedule]"
---

# /baton:heartbeat

The 5-hour usage window starts at its **first request**, not at a fixed clock time. A window
nobody touches at reset drifts to whenever work happens to begin, so the boundaries wander and
you can't plan around them. One tiny request just after reset pins the next boundary where you
want it.

Three jobs run on each beat; only the first spends anything:

1. **Anchor** (costs ~26k input / ~60 output tokens on haiku) — the minimal
   subscription-authenticated request that starts the window.
2. **Clear expired lockouts** (free) — workers whose `reset_at` has passed get an explicit
   `clear` row, so the labor pool stops reporting a lockout that is over.
3. **Session liveness** (free) — stamps a marker the dashboard can read to tell a live session
   from one that merely hasn't hit its TTL.

## Steps

1. Parse `$ARGUMENTS` for the flags below and run:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-heartbeat.ps1" -Status
   # --anchor "<time>"  -> -Anchor "<time>"   (seed the reset time: '3:50', '03:50', or a full timestamp)
   # --now              -> -Now               (fire a beat immediately)
   # --skip-anchor      -> -SkipAnchor        (free half only; spends nothing)
   # --install          -> -Install           (register the next one-shot scheduled task)
   # --uninstall        -> -Uninstall         (remove the task)
   # --print-schedule   -> -PrintSchedule     (print the schtasks command instead of running it)
   ```

2. With no flags it reports the anchor, the next boundary, and how many beats have run. That
   path spends nothing — prefer it when the user just asks "when does my window reset?"

3. Relay the beat's own numbers (tokens in/out, cost, cleared workers, next boundary). Do not
   re-run the beat to answer a follow-up question; read the reported result.

## Notes

- **Seed the anchor first.** `/baton:heartbeat --anchor "3:50"` where `3:50` is when the window
  currently resets. A bare clock time resolves to the most recent occurrence at or before now,
  never a future one — the schedule is never built from a boundary that hasn't happened.
- **Boundaries are `anchor + N x 5h`,** computed fresh each run. A late or skipped beat cannot
  make the cadence creep. A successful anchor re-anchors state to its own fire time, so the
  model and the real window stay in sync.
- **5 hours does not divide 24,** so no fixed daily time can express the cadence. The scheduled
  task is a **one-shot that re-registers itself** after each beat (`-Reschedule`).
- **Never `--bare`.** That flag is cheaper and would load nothing, but its auth becomes strictly
  `ANTHROPIC_API_KEY` (OAuth and keychain are never read) — it would bill the API and touch no
  subscription window at all. Anchoring requires the subscription path, which carries an
  irreducible ~25k of built-in system prompt and tool schemas.
- **A failed anchor never blocks the free half.** If the model call fails (not logged in,
  offline), the lockout clearing and liveness stamp still run, the failure is reported, and the
  anchor is left untouched rather than recording a window start that never happened.
- The scheduled task runs from the **deployed** script path (`~/.claude/scripts`), so re-run
  `bootstrap.ps1` after pulling changes to the heartbeat.
