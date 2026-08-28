# Task 3 Report — Dispatcher + help + remove room tests

**Status:** Complete  
**Branch:** `worktree/brave-cloud-a808`

## Summary

Demoted the Maestro room from the default CLI path. Bare `baton` and bare `maestro` now print 3-line passive status. Updated `Show-BatonHelp` copy per harness pivot spec. Removed room integration tests (R*, ST*, Q*, old B*) and replaced with passive/admit assertions (B1–B3, H5/H5b). Deleted dead room entry code from `maestro.ps1`.

## Changes

| File | Change |
|---|---|
| `scripts/baton.ps1` | `Show-BatonHelp` — passive status, admit, status, quota usage lines; removed "you are in Maestro" |
| `scripts/test-baton-cli.ps1` | H3b/H3c help assertions; H5 passive status + H5b not-room |
| `scripts/test-maestro-cli.ps1` | Removed R1–R10, Q1–Q2, K5, ST1–ST3, old B1–B7; added B1–B3 |
| `scripts/maestro.ps1` | Deleted `Invoke-BatonRoom`, `Read-BatonRoomLine`, `Get-BatonRoomCardText`, nested `Write-BatonRoomCard` (~208 lines) |

## Room lib helpers retained

`Format-MaestroRoomBanner`, `Format-MaestroRoomRedraw`, `Format-MaestroInputRedraw`, `Get-MaestroRoomScrollItems`, etc. remain in `maestro-lib.ps1` because G1–G20 unit tests still exercise them directly (G14/G15/G16 among others).

## Orphaned code (not deleted this task)

`Start-MaestroWatchIfNeeded` and `Test-MaestroHermeticHome` in `maestro.ps1` were only called from `Invoke-BatonRoom`. Safe to remove in S1 lib cleanup.

## Test results

```
pwsh -NoProfile -File scripts/test-maestro-cli.ps1  → OK (62 assertions)
pwsh -NoProfile -File scripts/test-baton-cli.ps1     → ALL CHECKS PASS
pwsh -NoProfile -File scripts/test-cursor-quota.ps1  → OK (17 assertions)
```

## Concerns

1. **Dead watch helpers** — `Start-MaestroWatchIfNeeded` / `Test-MaestroHermeticHome` unused after room removal; low risk, defer to S1.
2. **Room formatters in lib** — still present for G* tests; full lib deletion deferred per plan (S1).
3. **`--goal` alias** — still not in `verbs.yaml` flag_aliases for `admit` (carried from Task 2); direct `--goal` works on both runners.

## Commit

Message: `refactor(cli): demote Maestro room; bare baton is passive status`
