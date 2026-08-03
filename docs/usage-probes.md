# Usage probes — how Baton sees how much plan you have left

A **usage probe** is how a fleet row answers "how much of this subscription is
already spent?" *before* Baton dispatches to it. The answer feeds the soft caps
in `usage_policy` (`soft_cap_5h`, `soft_cap_weekly`): over cap, Baton reroutes to
a peer or holds; under cap, it dispatches and says nothing.

Probes are **observe-only**. Nothing here spends money, changes an account, or
touches credentials. A probe that fails is a probe that returns nothing, and a
row with no usable observation dispatches exactly as it did before.

## Transports

Which probe a row uses is resolved by **transport name**, never by guessing from
the platform. Register the name in `usage_policy.probe_transport`:

| transport | what it reads | typical rows |
| --- | --- | --- |
| `codex-rate-limit` | the codex app-server's own rate-limit RPC | codex CLI rows |
| `codexbar-cli` | a local `codexbar-cli` binary that reports plan allowance per window | rows whose vendor exposes no CLI usage call of its own |

A row whose transport name is unregistered — a typo, or a transport that has not
shipped yet — is simply **not probed**. It still dispatches. Baton never
substitutes "some other probe that might work."

## `codexbar-cli` — the recommended usage check on Windows

For providers with no usage RPC of their own, `codexbar-cli` is currently the
**only** way Baton can see remaining plan allowance on Windows, and therefore the
only way their soft caps are enforceable rather than decorative.

Baton runs it as `codexbar-cli usage --provider <name> --json`, reads stdout, and
normalizes what comes back. It is a read; there is no login step, no cookie
handling, and no credential storage anywhere in Baton. The tool's own `source`
field reports *how* it obtained a figure (an OAuth session, a browser session,
and so on), and Baton carries that through onto every observation as
`codexbar:<source>` so provenance survives into the cache and the journal.

Notes:

- **Get the Windows port.** The upstream `steipete/CodexBar` project is
  macOS/Linux only; the Windows build is the one this transport expects.
- **`codexbar-cli serve`** exposes a cached loopback endpoint, worth running if
  you check usage frequently by hand. Baton's own probe already caches (default
  10 minutes per row) and does not need it.
- Some accounts cannot be read at all on a given box — a provider whose only
  route is a browser session may be blocked by OS-level encryption of the
  browser's storage. That is a `$null` observation, not an error: the row
  dispatches unprobed.

### Configuring a row

In your **box-private** `~/.baton/fleet.yaml` (never in the repo):

```yaml
  - name: <your-row-name>
    kind: cli
    # ...
    usage_policy:
      probe: true
      probe_transport: codexbar-cli
      probe_provider: <the tool's own name for this account>
      # optional, only if the binary is not on PATH:
      probe_command: <full path to codexbar-cli>
      soft_cap_5h: <percent>
      soft_cap_weekly: <percent>
```

`probe_provider` is **required** and is never inferred. Baton's row names and the
probe tool's provider names are different vocabularies, and a wrong guess would
report someone else's account as this row's remaining budget. With no
`probe_provider`, the transport does not resolve and nothing is launched — this
is the one part of the probe path that fails **closed**.

Binary resolution order: `probe_command` → `codexbar-cli` on `PATH` → the default
per-user install location under `LOCALAPPDATA`. No absolute user path is
hardcoded in the repo.

## Model-scoped sub-quotas (`scope_id`)

Some plans meter **per-model sub-quotas** alongside the plan-wide 5-hour and
weekly windows. The plan-wide weekly can look comfortable while one model's own
weekly window is completely exhausted. A probe that read only the plan-wide
windows would report the comfortable number and route work to a model with
nothing left.

So Baton emits **every** reported window as its own observation. Scoped ones
carry the window's `scope_id`; plan-wide ones carry none. A fleet row can bind
itself to a scope:

```yaml
      scope_id: <the window id the probe reports for that model>
```

The rules:

- **Unbound row** → judged on the plan-wide windows only. Another model's
  exhausted sub-quota is not its problem.
- **Bound row** → judged on the plan-wide windows **and** its scoped window. It
  is over cap when *either* crosses, so an exhausted sub-quota holds the row even
  while the plan-wide window has room.
- **Bound row whose `scope_id` is missing from the response** → falls back to the
  **plan-wide** windows. Never to "unlimited."

That last rule is the load-bearing one. **The set of windows is
plan-dependent and changes when the account's tier changes** — a downgrade can
remove a model-scoped window from the response entirely. Losing a scoped window
means losing *information*, not gaining headroom. Treating its absence as "no
limit" would silently uncap the row at the exact moment the plan got smaller.
Nothing in Baton keys off a known window id; `scope_id` is a free-form string
compared against whatever the response actually contains, so a renamed or retired
window degrades to the plan-wide answer instead of breaking.

An absent or empty set of scoped windows is normal, not an error.

## What a failed probe does

Observation is deliberately **fail-soft**: a missing binary, a non-zero exit,
unparseable output, a timeout, an out-of-range percentage, or an unrecognized
window duration all resolve to "no observation for that window." Nothing throws,
and the caller carries on and dispatches. The cap *decision* is the part that
fails closed — but it can only decide about numbers it actually has.

Individual bad windows are dropped rather than coerced: a percentage outside
0–100, a non-finite value, an unparseable reset timestamp, or a window duration
Baton does not recognize is discarded while the other windows in the same
response are still used.
