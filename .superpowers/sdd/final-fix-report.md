# Final whole-branch fix report

## 2026-08-21 — Choice queue resilience

- `Get-NextAdmittedChoice` now detects admitted cards stranded by a stale cursor, rebuilds the admitted project order, and retries selection once.
- Choice schema validation now runs before timestamp normalization in both read and write paths.
- `Get-Choices` skips malformed card files, emits a warning containing the filename, and continues returning valid cards.
- Added hermetic regressions for stale cursor recovery, schema-before-normalization behavior, and corrupt-file isolation.

Verification:

- `pwsh -NoProfile -File scripts/test-choices-lib.ps1` — PASS
- `pwsh -NoProfile -File scripts/test-fleet-choices.ps1` — PASS
- `pwsh -NoProfile -File scripts/test-seed-overnight-choices.ps1` — PASS
