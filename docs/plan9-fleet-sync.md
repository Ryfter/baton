# Plan 9 — Cross-machine fleet sync over Tailscale

Distributed inference across the home LAN: dispatch fleet prompts to an Ollama
box on another machine, reached over a Tailscale tunnel, with journal entries
attributable to the machine that issued them.

## 1. Secure tunnel (Tailscale)

The remote box joins the tailnet; its Ollama API is reached at the box's
Tailscale IP. No port-forwarding or public exposure — traffic stays inside the
encrypted mesh. Verify reachability before enabling:

```powershell
Invoke-RestMethod http://<tailscale-ip>:11434/api/tags   # lists installed models
```

The remote host must bind Ollama to the tailnet interface (not just localhost):
set `OLLAMA_HOST=0.0.0.0:11434` on that machine.

## 2. Per-host fleet config

`ollama-box2` is a `kind: http` provider routed through
`scripts/fleet/ollama-box2.ps1`, which calls the native `/api/generate`
endpoint. (The local `ollama run` CLI hangs against a remote host, so the HTTP
path is required — not an optimization.)

```yaml
  - name: ollama-box2
    kind: http
    enabled: true
    cost_tier: local
    model_default: 'dolphin3:8b'
    base_url: 'http://100.115.71.9:11434'   # the box's Tailscale address
```

`base_url` and `model_default` are **per-host** — edit them in your deployed
`$BATON_HOME/fleet.yaml` (default `~/.baton/fleet.yaml`). `references/fleet.yaml` carries a working example
(wraith2). Pick a `model_default` that fits the box's VRAM.

Test it: `/fleet test ollama-box2 "hello"`.

## 3. Origin-host journal tagging

Every fleet invocation appends a `host:<name>` tag to its
`model-routing-log.md` line, so a journal merged across machines stays
attributable per node:

```
2026-06-03T13:04:00-06:00 | fleet | ollama-box2 | 4s | exit:0 | "summarize ..." | host:FIREFLY
```

The host is the **dispatching** machine (the node that ran `Invoke-Fleet`), not
the box that served the model — the served box is already identified by the
provider name. Resolution order: `CAO_FLEET_HOST` env override →
`COMPUTERNAME` → OS hostname. The tag is a trailing field, so existing
positional parsers (dashboard, `parse-otel`) are unaffected.
