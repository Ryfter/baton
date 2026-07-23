---
description: Fold a conductor run ledger (plan/events/decisions/acceptance) into the Memory Bridge journal. Idempotent; dry-run previews without writing.
argument-hint: -Run <run-dir|run-id> [--dry-run] [--json]
---

# /baton:memory-ingest

Auto-ingest a finished `/baton:go` run into the box-private memory journal so
`/baton:recall` can warn before the next attempt repeats a known-bad fix.

Shells to the runner:

```powershell
& "$HOME/.claude/scripts/fleet-memory.ps1" ingest $ARGUMENTS
```

## Arguments

| Flag | Meaning |
|---|---|
| `-Run <path\|id>` | Absolute run dir, or a run-id resolved under `$BATON_HOME/runs/` |
| `--dry-run` | Fold + preview rows; write nothing |
| `--json` | Machine-readable result (`written`, `skipped_duplicate`, `rows`, …) |

`$ARGUMENTS` is also accepted positionally as the run-dir/id after `ingest`.

## What gets written

Each row is a normal Memory Bridge entry (`Add-MemoryEvent` shape: problem /
approach / outcome / signature / refs / source=`conductor-ledger`). Mapping is
deterministic:

| Run signal | Memory outcome |
|---|---|
| `failed` / `verification-failed` / `rejected` / `plan-failed` / `plan-rejected` | `fail` |
| `completed` + acceptance `accept` (or no gate) | `pass` |
| `needs-polish` (or acceptance `polish`) | `partial` |

Routing decisions alone are **not** rows (noise). `stakes_basis` and `task_id`
are kept on `refs` when present. Re-ingest of the same `run_id` + signature is a
no-op (`skipped-duplicate`).

Corrupt or missing ledger pieces fail soft (warning, never throw).
