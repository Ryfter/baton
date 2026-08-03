# Usage probes — how Baton sees how much plan you have left

A **usage probe** is how a fleet row answers "how much of this subscription is
already spent?" *before* Baton dispatches to it. The answer feeds the soft caps
in `usage_policy` (`soft_cap_5h`, `soft_cap_weekly`): over cap, Baton reroutes to
a peer or holds; under cap, it dispatches and says nothing.

Probes are **observe-only**. Nothing here spends money, changes an account, or
touches credentials. A probe that fails is a probe that returns nothing, and a
row with no usable observation dispatches exactly as it did before.

---

# Setup walkthrough

Follow these in order. **Every command marked ✅ was actually run on a Windows box
against a real install.** Anything marked ⚠️ is untested and says so — do not treat
it as verified.

Nothing here is required. Baton runs fine without any probe; you just get no cap
enforcement, and `usage_policy` caps silently never engage. That silence is the
reason this page exists.

## Step 1 — install CodexBar (platform decides which one)

There are two separate projects. They are **not** interchangeable, and even the
binary name differs.

| your OS | project | binary |
| --- | --- | --- |
| Windows | [`nesszer/Win-CodexBar`](https://github.com/nesszer/Win-CodexBar) | `codexbar-cli.exe` |
| macOS / Linux | [`steipete/CodexBar`](https://github.com/steipete/CodexBar) | `codexbar` |

**Windows** — install from the Win-CodexBar releases. It lands at
`%LOCALAPPDATA%\Programs\CodexBar\codexbar-cli.exe`, which Baton checks
automatically, so it does not need to be on `PATH`.

**macOS** ⚠️ *untested here* — `brew install steipete/tap/codexbar`

**Linux** ⚠️ *untested here* — release tarball from `steipete/CodexBar`.

> ⚠️ **Only the Windows path is verified.** The transport parses the JSON shape
> emitted by Win-CodexBar. `steipete/CodexBar` documents JSON output and a far
> wider provider set, but its exact field names could not be checked from Windows.
> On macOS/Linux, run Step 2 and confirm the shape before relying on it — a parse
> that guesses wrong yields a confident wrong percentage, which is worse than no
> reading at all.

## Step 2 — confirm CodexBar works on its own, before involving Baton

✅ Check it runs:

```
codexbar-cli --version
```

✅ Ask it for usage as JSON:

```
codexbar-cli usage --provider codex --json --pretty
```

You want a block shaped like this (values will differ):

```json
{ "provider": "codex", "source": "oauth",
  "usage": {
    "primary":   { "window_minutes": 300,   "used_percent": 12.5, "resets_at": "..." },
    "secondary": { "window_minutes": 10080, "used_percent": 40.0, "resets_at": "..." } } }
```

`primary` is the 5-hour window, `secondary` the weekly one. `source` tells you how
the figure was obtained — `oauth`, a browser session, and so on.

**If this step fails, stop here.** Baton cannot fix an unauthenticated CodexBar,
and a broken probe from Baton's side looks identical to a working one that reports
nothing.

## Step 3 — tell the fleet row to use it

Add to the provider's `usage_policy` in your **box-private** `fleet.yaml`
(`$BATON_HOME/fleet.yaml` — never the repo):

```yaml
    usage_policy:
      probe: true
      probe_transport: codexbar-cli
      probe_provider: claude      # what CodexBar calls it, not what Baton calls it
      soft_cap_weekly: 85
      soft_cap_5h: 75
```

Two of these trip people up:

- **`probe_provider` is required and is not inferred.** Baton's row may be
  `claude-sonnet` while CodexBar calls it `claude`. Baton will not guess which
  account you meant — with this absent, the probe simply does not run.
- **`probe: true` alone does nothing** without a transport. Both are needed.

Caps are yours. Baton ships **no** default caps: a row with no `soft_cap_*` is
unmetered, exactly as before.

## Step 4 — confirm Baton sees it

✅ Ask Baton, not CodexBar:

```
baton usage
```

The row should now report a percentage rather than nothing. If it reports nothing
while Step 2 works, the cause is almost always a missing `probe_provider` or a
`probe_transport` that does not match a registered transport name.

## Step 5 — know what a trip looks like

Over cap, Baton reroutes to a peer or holds, and says so in the run's `why`. It
does not stop silently. A held dispatch names the provider and the window that
tripped.

## Optional — a cached local endpoint

Spawning the binary per check is fine at Baton's rate. For frequent polling,
CodexBar can serve cached JSON on loopback ✅:

```
codexbar-cli serve --port 8080
```

## Optional — a quick manual gate

✅ Useful in shell scripts and for eyeballing before a big run:

```
codexbar-cli guard --provider codex --window weekly --min-remaining 15 --json
```

Returns a decision plus an exit code (`0` = ok). Baton deliberately does **not**
route through `guard`: that would move cap policy out of Baton and into CodexBar.
Baton reads raw numbers and applies its own policy.

## Troubleshooting

| symptom | cause |
| --- | --- |
| Baton reports no usage, CodexBar works | missing `probe_provider`, or `probe_transport` name typo |
| probe never runs | `probe: true` missing, or transport name not registered |
| binary not found | not on `PATH` and not at the platform default location — set `probe_command` |
| a browser-sourced provider fails to read cookies | some browsers encrypt the cookie store (Chromium App-Bound Encryption); prefer an OAuth/CLI source for that provider |
| a percentage looks wrong on macOS/Linux | the untested shape above — verify Step 2's field names before trusting it |

---

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
