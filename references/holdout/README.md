# Hold-out validation (builder-blind)

Hold-out scenarios live under `.baton/holdout/` and are frozen from the **base commit** at run start (same immutability model as `.baton/verification.json`).

## Why

Coding agents accumulate bias during implementation. Hold-out checks run **after** labor with scenarios the builder never saw — Cole Medin dark-factory pattern.

## Layout

```
.baton/holdout/
  manifest.json       # schema_version 1, lists scenarios
  scenarios/          # optional human-readable criteria (reviewer-only)
```

## manifest.json

```json
{
  "schema_version": 1,
  "scenarios": [
    {
      "id": "smoke-import",
      "title": "Package imports cleanly",
      "argv": ["python3", "-c", "import mypkg"]
    }
  ]
}
```

## Rules

1. **Builder must not read** `.baton/holdout/` — exclude from `allowed_paths` and labor prompts.
2. **Validator / hold-out runner** reads from `git show <base>:.baton/holdout/manifest.json`.
3. Scenarios use **argv-only** checks (no shell escapes).
4. Copy `references/holdout-example/manifest.json` when onboarding a repo.

## Baton commands

```powershell
pwsh -NoProfile -File scripts/fleet-gate.ps1 holdout -RepoPath . -BaseSha HEAD -Worktree .
```

See `scripts/holdout-lib.ps1` and `docs/superpowers/specs/2026-08-22-dark-factory-cache-worktrees-design.md`.
