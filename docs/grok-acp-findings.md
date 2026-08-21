# grok `agent stdio` (ACP) — protocol findings

**Date:** 2026-08-20 · **Issue:** #196 · **Agent version:** grok 1.0.5 · **Host:** Firefly

Supersedes the earlier "grok is not dispatchable headlessly / TTY mystery" theory
(see `project_grok_headless_blocked` memory, since corrected).

## Root cause of the original hang

Baton's fleet row invokes `grok --prompt-file "{{prompt_file}}"`. Bare `grok` is the
**interactive TUI**, so it waits on a terminal forever — the 3,955 s zero-byte hang.
The headless entry point is a nested subcommand:

```
grok agent stdio      # run the agent over stdio  <- the dispatch path
grok agent headless   # over the Grok WebSocket relay
grok agent serve      # as a WebSocket server
```

`~/.grok/bin/agent.exe` is the **same TUI binary** and hangs identically. The
subcommand is what matters, not the executable.

## What `grok agent stdio` actually speaks

**ACP (Agent Client Protocol) — JSON-RPC 2.0 as newline-delimited JSON.** This is
*not* Baton's `stdio-json` wire format, so the fix is **not** a `command_template`
swap. See "Why an adapter is required" below.

### Verified working

| Step | Method | Result |
|---|---|---|
| 1 | `initialize` (`protocolVersion: 1`) | responds in **0.3–0.4 s** |
| 2 | `authenticate` (`methodId: "cached_token"`) | responds in **0.3 s**, no error |

`initialize` returns:

- `protocolVersion: 1`, `agentVersion: 1.0.5`, `currentWorkingDirectory` (inherits cwd)
- **Models:** `grok-4.6` (500k ctx) and `grok-4.5`; both expose
  `reasoningEffort` of `low | medium | high | xhigh` (default `high`) — an
  effort dimension Baton's routing does not model yet.
- `authMethods`: `cached_token` (from `~/.grok/auth.json`, and the advertised
  default) and `grok.com`. **No interactive login needed** — auth is already satisfied.
- `agentCapabilities.sessionCapabilities: { list, resume, close }` — note there is
  **no `new`** advertised, which may be significant.
- `availableCommands` includes `deep-research`, `goal`, `workflow`, `compact`.

### The open blocker

**`session/new` is received but never returns.** Reproduced with a
120 s ceiling, and again at 150 s.

Evidence it *is* received: sending it immediately triggers `_x.ai/models/update`
(x2), `_x.ai/settings/update` and `_x.ai/announcements/update` notifications. It
begins creating the session and never completes.

Ruled out by test:

- **Not a dead stdin.** Three messages round-trip on one process
  (`initialize`, `authenticate`, then `session/new`); the first two answer normally.
- **Not MCP boot cost.** Sent with `mcpServers: []`. Also retested after removing
  4 local MCP servers (clairvoyance ×3, ollama-remote) — no change.
- **Not client capabilities.** Identical hang with `fs.readTextFile`/`writeTextFile`
  and `terminal` set to both `false` and `true`.
- **Not auth.** `authenticate` succeeds first and the hang is unchanged.

The `--debug-file` log records the `initialize` receipt (`Client type set to:
Generic`) but shows **no session-creation entry**, so the stall is inside grok's
session bootstrap.

### Next things to try (not yet attempted)

1. **`session/load`** with an existing session id — `agentCapabilities.loadSession`
   is `true` and `~/.grok/sessions` holds 366 sessions. If load works where new
   hangs, that is a usable dispatch path on its own.
2. **`session/list`** — advertised under `sessionCapabilities`; a cheap probe of
   whether *any* session method responds.
3. **The leader socket.** `grok agent stdio --leader-socket <path>` defaults to
   `~/.grok/leader.sock`. Session creation may expect a leader process that is
   absent in a bare stdio run. The debug log notes `Relay sync: DISABLED (not in
   TUI mode)`.
4. **Capture a known-good client.** Zed speaks ACP to grok; recording its exact
   frames would settle the required `session/new` shape.

## Why an adapter is required (correction)

Baton's `stdio-json` kind is **Baton's own one-shot protocol**
(`scripts/fleet-lib.ps1` → `Invoke-FleetStdioJson`):

```
stdin  -> {"prompt": "...", "model": "...", "tier_args": [...]}          (one object)
stdout <- {"output": "...", "exit_code": 0, "tokens": N, "tokens_basis": "exact"}
```

ACP is multi-turn, streaming, and JSON-RPC framed. The two cannot be bridged by
configuration. The integration is therefore a small **adapter executable** that
speaks Baton `stdio-json` on one side and ACP on the other:

```yaml
- name: grok-cli
  kind: stdio-json
  command_template: 'pwsh -NoProfile -File scripts/fleet/grok-acp.ps1'
```

The adapter owns: spawn `grok agent stdio` → `initialize` → `authenticate` →
create/load a session → `session/prompt` → accumulate `session/update` chunks →
emit one Baton response object. It is also the right home for the
**idle-timeout** rule from #196 (measure silence, not duration): a slow provider
still emits `session/update`; a hung one does not.

## Harness warning for whoever continues this

Do **not** read the child's stdout via `[System.Threading.Tasks.Task]::Run({...})`
in PowerShell. A scriptblock dispatched that way has no runspace and silently
reads nothing — it appears to work sometimes and not others, which produced
several false "no response" readings during this investigation (probes 3–6).

Use **sequential `ReadLineAsync()` on the main thread**, never overlapping two
reads on the same stream (overlapping throws "The stream is currently in use by a
previous operation"). Working probe: `probe7`/`probe8` pattern.
