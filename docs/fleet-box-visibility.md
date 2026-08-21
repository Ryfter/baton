# Fleet box visibility — who is busy, right now

**Date:** 2026-08-20 · **Library:** `scripts/lms-device-lib.ps1` ·
**Tests:** `scripts/test-lms-device-lib.ps1` · **Decision:** baton-d120

Answers "is anything running on my boxes?" across every LM Link device from one
machine — the precondition for any concurrency or local-resource governor work.

## The problem it solves

LM Link joins all boxes under one `localhost:1234` endpoint, but **box identity is
invisible to the REST API**: both `/v1/models` and the native `/api/v1/models`
omit the device. Only the `lms` CLI carries `deviceIdentifier`. So Baton cannot
learn placement or load over HTTP; it must shell out.

## The two primitives

```powershell
lms link status   # human-formatted: identifier -> friendly name, connected state
lms ps --json     # machine-readable: loaded models WITH deviceIdentifier + status
```

`lms ps --json` is the important one. Each row carries `deviceIdentifier`,
`identifier`, `sizeBytes`, `contextLength`, `queued`, `parallel`, and `status`.

**`status` is the busy signal.** Observed values: `processingPrompt` and
`generating` mean actively working; `loaded` means resident but idle. A model can
hold VRAM while idle, so *resident* and *busy* are different questions and are
reported separately.

Only devices with something loaded appear in `lms ps`, so idle boxes must be
recovered from `lms link status` — the library reports them explicitly as idle
rather than omitting them.

## Usage

```powershell
. ./scripts/lms-device-lib.ps1
Get-LmsBoxActivity | ForEach-Object {
    '{0,-16} reachable={1,-5} busy={2,-5} vram={3:n1}GB' -f `
        $_.name, $_.reachable, $_.busy, ($_.vram_bytes / 1GB)
}
```

Live output while a job ran on the work box:

```
Droid            reachable=True  busy=False vram=0.0GB
Firefly          reachable=True  busy=False vram=0.0GB
ITSCM-KRANK2     reachable=True  busy=True  vram=18.1GB
Wraith2          reachable=True  busy=False vram=0.0GB
```

## API

| Function | Kind | Purpose |
|---|---|---|
| `Convert-LmsLinkStatus -Text` | pure | Parse `lms link status` → devices + local name |
| `Test-LmsStatusBusy -Status` | pure | Is an `lms ps` status actively working? |
| `Resolve-LmsBoxActivity -LoadedRows -DeviceMap` | pure | Fold rows into one record per box |
| `Get-LmsDeviceMap` | shells out | `lms link status` |
| `Get-LmsLoadedRows` | shells out | `lms ps --json` |
| `Get-LmsBoxActivity` | shells out | One call for the whole picture |

The pure functions are unit-tested offline against sample text with placeholder
hostnames; only the `Get-Lms*` wrappers touch the real CLI. Per the box-private
rule, no real hostnames or model rosters appear in the tests.

## Parsing gotcha (caught by test)

`lms link status` nests loaded-model bullets under a device:

```
  - ITSCM-KRANK2
    Status: connected
    Identifier: <hash>
    Loaded Models Instances:
      - some-model@q5_k_m      <- NOT a device
```

A naive `^\s*-\s+(.+)$` treats that nested bullet as a fifth device. The parser
gates on indent depth (device bullets sit at depth <= 3).

## Known gap

`Get-LmsBoxActivity` reports **model-attributable** VRAM only. A box busy with
non-LM-Studio GPU work (a game, a training run, another runtime) reports
`busy=False`. Per the one-model-server-per-box rule this is acceptable for
routing, but it is not a general GPU-load check.

## Note on running the suite

There is **no aggregate test runner on `master` or this branch.** `scripts/test-all.ps1`
exists only on `feat/code-factory-provider-failover` (PR #189, still draft), so the
front-door plan's instruction to "register the suite in `test-all.ps1`" carries an
undocumented dependency on #189 landing first. Until then, run suites individually:

```powershell
pwsh -NoProfile -File scripts/test-lms-device-lib.ps1
```

85 `scripts/test-*.ps1` suites exist; there is also no CI workflow (`.github/workflows`
is absent), so nothing runs them automatically.
