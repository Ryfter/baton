# Authenticated HTTP instruments

Baton's generic HTTP transport (`Invoke-FleetHttpChat`, `scripts/fleet-lib.ps1`)
originally served exactly one kind of endpoint: a model server on localhost with
no authentication. This document covers the fields that let it reach a *paid*
OpenAI-compatible endpoint, and the OpenRouter setup that is the first user.

## The fields

Add these to any `kind: http` row in `fleet.yaml`:

| Field | Default | Meaning |
|---|---|---|
| `api_key_env` | — | **Name of the environment variable** holding the credential. Never the credential. |
| `auth_header` | `Authorization` | Header the credential is sent in. Use `x-api-key` for that dialect. |
| `auth_prefix` | `Bearer ` | String prepended to the credential. An explicitly empty value sends the raw key. |
| `headers` | — | Nested map of static request headers (attribution, tenant ids, …). |

```yaml
  - name: some-paid-endpoint
    kind: http
    enabled: true
    cost_tier: paid
    base_url: 'https://api.example.com'
    model_default: 'vendor/model-id'
    api_key_env: EXAMPLE_API_KEY
    headers:
      X-Title: Baton
```

### Two rules the transport enforces

**A declared key that is not set is a loud failure, before any network call.**
It is never downgraded to an anonymous request. Against a paid endpoint an
anonymous call is a 401 whose message explains nothing; against a permissive one
it would bill the wrong account. `fleet doctor` reports the same condition up
front (`err … EXAMPLE_API_KEY not set`) so it surfaces at health-check time
rather than at the first piece of real labor.

**The credential is scrubbed from anything journaled.** Transport errors pass
through `Protect-FleetSecret` before they land in `stderr`, so a key cannot leak
into the fleet journal via an exception message.

### What these rows can and cannot do

`kind: http` can never be agentic (d091) — there is no file-edit harness behind
an HTTP POST, and the executor refuses an explicit `agentic: true` on one. Paid
HTTP rows are for judgment and drafting: `review`, `plan-review`, `judge`,
`reasoning`, `summarize`, `synthesize`. Edit-eligible labor stays on the CLI rows.

## OpenRouter

One key reaches ~400 models across every major lab, billed per token from a
prepaid balance. It is the first **prepaid** provider in the fleet — every other
paid row is a flat subscription where over-use costs latency, not money. That
difference drives the whole setup below.

### 1. Get a key and cap it

1. Create a key at <https://openrouter.ai/settings/keys>.
2. **Set a credit limit on the key itself.** This is the backstop: it is
   enforced by OpenRouter, so no bug in Baton's routing can spend past it. The
   in-fleet policy is the second line of defence, never the only one.

### 2. Export it

```powershell
# Persist for future sessions (User scope), then load into the current one.
[Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', '<your-key>', 'User')
$env:OPENROUTER_API_KEY = '<your-key>'
```

The key belongs in the environment, never in `fleet.yaml` — the registry stores
only the variable's *name*, so the file stays safe to commit and to share.

### 3. Verify

```powershell
baton fleet doctor            # expect: openrouter … alive; OPENROUTER_API_KEY set
pwsh -NoProfile -File scripts\smoke-openrouter.ps1
```

The smoke script runs the canary battery against every enabled OpenRouter row
and prints the account's credit position before and after, so the cost of the
smoke itself is visible. It refuses to run — with the variable named — when the
key is missing, rather than letting each row 401 in turn.

### The rows

| Row | Model | Purpose |
|---|---|---|
| `openrouter` | `deepseek/deepseek-v4-flash` | Cheap 1M-context general workhorse (`code-gen`, `reasoning`, `summarize`). |
| `openrouter-gap` | `z-ai/glm-4.7` | Lineage diversity for the gates: `review`, `plan-review`, `judge`. |
| `openrouter-free` | `nvidia/nemotron-3.5-lightning:free` | $0 utility tier: `summarize-short`, `classify`, `triage`, `extract-json`. |

Two notes on the picks:

- **Pin explicitly, never `auto`.** Same reasoning as the local rows (d043):
  spend has to be attributable to a known model. OpenRouter's catalog changes
  weekly — re-check <https://openrouter.ai/models> before changing a pin.
- **The gap row is deliberately not a reasoning model.** A thinking preamble
  breaks the strict-JSON parse that `review` and `judge` depend on — the same
  trap that put `phi-4` rather than a qwen3.5 variant on `lm-studio-small`.

### Why a separate gap row at all

A review panel of four frontier models that were trained on overlapping data
produces correlated opinions. A reviewer with no shared ancestry disagrees in
different places, which is the entire value of a panel. That is worth more per
dollar than a fourth frontier opinion, and at GLM-4.7 prices it is roughly two
orders of magnitude cheaper than one.

### Free-tier caveats

`:free` models are rate-limited and their throughput varies with load. The daily
request ceiling scales with the account's credit balance. They are registered
for cheap utility work, not for anything on a critical path.
