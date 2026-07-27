---
description: Lazy per-project window service — hygiene, "what's next" candidates, and a short SessionStart briefing, keyed on the 5-hour usage-window grid.
argument-hint: "[--status] [--now] [--project <path>] [--json]"
---

# /baton:window-service

Once per 5-hour usage window, each *active* project gets free (and one cheap) chores
attached to the same grid the heartbeat anchors. Activity is the trigger: the first
tool call in a project after a window boundary claims the work; idle terminals fire
nothing.

| Work | Scope | Cost |
|---|---|---|
| usage-probe refresh | machine (in `/baton:heartbeat`) | free |
| journal + worktree hygiene | project | free |
| grok-cli "what's next" list | project | one `grok-cli` call |
| short SessionStart briefing | project | free to write; injected on every session start |

## Steps

1. Parse `$ARGUMENTS` and run:

   ```powershell
   pwsh -File "$HOME/.claude/scripts/fleet-window-service.ps1" -Status
   # --now              -> -Now               (service this project now; ignores claim)
   # --project <path>   -> -Project <path>    (default: cwd)
   # --json             -> -Json
   ```

2. With no flags (or `--status`) it reports whether the project is due, the current
   window serial, and whether a briefing exists. That path spends nothing.

3. `--now` runs hygiene + candidates + briefing immediately. The PostToolUse hook
   already claims and spawns this detached on the first tool call of a new window —
   manual `--now` is for smoke-testing or forcing a refresh.

## Knobs

Both default **on**. Written under `$BATON_HOME/window-service/`:

| File | Purpose |
|---|---|
| `config.json` | global: `{ "enabled": true, "candidates_enabled": true }` |
| `<project-key>.config.json` | per-project override of the same keys |

- **`enabled: false`** — whole feature off (no claims, no hook spawn, no briefing inject).
- **`candidates_enabled: false`** — skip the only paid step (the `grok-cli` call). Hygiene
  and briefing still run; the briefing notes that candidates were disabled.

## Notes

- **Dormant until a heartbeat anchor exists.** No grid → no serial → no servicing.
  Seed with `/baton:heartbeat --anchor "3:50"`.
- **Exactly one service per (project, window).** Atomic claim via exclusive file create;
  two sessions in the same project race and only one wins.
- **Briefing is byte-capped (default 2000).** It is injected into Claude's context on
  *every* SessionStart in that project, so an oversized digest is a recurring token tax.
  Oversized text is truncated and marked `[truncated]` at write time.
- **Hygiene is non-destructive.** Journals that exceed the size cap are rotated to
  `<name>.1` (at most one rotation kept). `git worktree prune` clears *stale
  registrations* only — live worktree directories are never deleted.
- Re-run `bootstrap.ps1` after pulling so the deployed `~/.claude/scripts` copy matches.
