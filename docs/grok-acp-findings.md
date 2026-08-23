# grok `agent stdio` (ACP) — protocol findings

**Date:** 2026-08-20, **corrected 2026-08-23** · **Issues:** #196, #197 ·
**Agent version:** grok 1.0.5 · **Host:** Firefly

## SOLVED 2026-08-23 — the hang is MCP server import, and grok IS dispatchable

**Both earlier root causes were wrong.** grok runs headlessly. `grok -p` returns
correct output and exits with a real exit code once one thing is fixed.

### The chain

1. `grok mcp list` reports **"No MCP servers configured."** grok's own registry is empty.
2. `grok inspect` nonetheless shows **12 MCP servers**, auto-imported from *other agents'*
   config files: `.mcp.json [cursor]` (cwd-relative), `~/.claude.json [claude]`, and
   installed plugins.
3. On session creation grok boots **all of them** and blocks on `mcp_ensure_initialized`.
4. Several never come up (`error=MCP service error: Transport closed`), and the wait
   **overruns its own bound** — observed `elapsed_ms=45847` against `timeout_sec=30`.
5. Session creation therefore never completes, so **every** path that needs a session
   hangs: `grok -p`, `--prompt-file`, and ACP `session/new` alike.
6. `grok models` needs no session — which is exactly why it returns in 0.83 s.

### Proof

| Command | Result |
|---|---|
| `grok -p "…"` from `D:\Dev\Baton` (has `.mcp.json`) | hangs, zero bytes, killed at 60 s |
| `grok --no-leader -p "…"` | hangs identically — leader socket is **not** the cause |
| `grok --cwd <empty dir> -p "Reply with exactly: PONG"` | **`PONG`** — correct output |
| same, second run | **exit 1 in 47 s**: `API error (status 402): Grok Build usage balance exhausted` |

Dropping the cwd `.mcp.json` removes 7 of the 12 servers and that is enough to get
through session creation. The 402 on the follow-up run is a **separate** finding — the
Grok Build balance is exhausted — and it is what a *healthy* failure looks like: fast,
structured, non-zero exit.

### Why this was missed twice

The debug log names the cause in one line, and `--debug-file` was never run:

```
WARN xai_grok_shell::session::acp_session::mcp: MCP server failed to initialize
     server="clairvoyance__clairvoyance" elapsed_ms=45847 timeout_sec=30
     error=MCP service error: Transport closed
INFO xai_grok_instrumentation: event="timing" name="mcp_ensure_initialized" elapsed_us=46161070
```

The 2026-08-20 session did remove some MCP servers and observed that `initialize` got
faster — then concluded MCP was "ruled out" because `session/new` still hung. It had the
right suspect and stopped one step early: the servers it removed were not the ones still
timing out, and `clairvoyance__clairvoyance` comes from Cursor's `.mcp.json`, not from
`~/.claude.json` where the cleanup was applied.

This also retroactively explains the "directory trust" red herring. `.mcp.json` is
**cwd-relative**, so grok's behaviour genuinely did change with the directory Baton
dispatched from — which looks exactly like a trust problem and is not one.

### Re-enabling the fleet row

Three things gate it, in order:

1. **Isolate MCP.** Dispatch from a worktree with no `.mcp.json`, or add one declaring
   `{"mcpServers":{}}`. Do not delete `D:\Dev\Baton\.mcp.json` — it serves Claude Code
   and Cursor and is not grok's to consume.
2. **Budget the latency.** Even clean, startup ran 45–90 s before first byte because
   `~/.claude.json` servers still boot. That is overhead on every dispatch, and it is why
   #196's *silence, not duration* idle-timeout is the right shape.
3. **Balance.** Grok Build reports the usage balance exhausted (402). Nothing dispatches
   until that is topped up or renewed.

Decision: baton-d136. Supersedes baton-d135 (which retracted the "wrong command" story
but had not yet found the cause) and the fix-shape half of baton-d122.

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
