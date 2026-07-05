# Fleet Does the Labor — Slice 1: Round-Trip Proof + Prompt Hardening

**Date:** 2026-07-04 · **Status:** design (approved shape, pending spec review) ·
**Track:** "Fleet does the labor" (make the conductor farm coding work to non-Claude instruments)

## Problem

Baton's whole thesis is *command-and-control for a fleet of coding LLMs*, but
today the fleet only demonstrably works with Claude. The plumbing to invoke
other instruments exists and is real:

- `fleet.yaml` carries a roster of 8 providers with invoke templates
  (`claude`, `codex exec`, `agy`, `gh copilot`, `ollama`, a remote Ollama box,
  two LM Studio pins, `gh models`).
- `Invoke-Fleet` / `Invoke-Fleet-Cli` / the http branch really shell out, with a
  stdin-safe path for large/quoted prompts.
- `Select-Capability` routes by capability + cost; the conductor plans a task
  DAG and routes each task to a chosen provider.

But two things are unproven, and one seam is empty:

1. **No proven end-to-end round-trip.** `fleet doctor` only checks *"is the
   binary on PATH / is the base_url up."* It never sends a prompt and confirms a
   coherent answer comes back. The repo `fleet.yaml` is a shared **seed**; the
   live per-box roster (`~/.baton/fleet.yaml`, box-private) is where real
   templates live and may be wrong or untested for a given machine.
2. **Prompt fragility.** The legacy CLI dispatch path interpolates the prompt via
   `Invoke-Expression` — quote-fragile and subject to the 965-byte argument
   ceiling. Only `stdin: true` providers survive real coding prompts.
3. **The executor seam is empty.** `Invoke-TaskViaFleet` is documented
   *"Non-destructive by construction — it never touches the repo; real
   code/merge execution is wired by a box via `-Spawner`."* So the conductor
   routes, calls, records *which* model it chose and whether it exited 0 — then
   discards the output. Nothing turns a model's work into a repo change.

**This spec covers Slice 1 only:** prove the round-trip and harden the prompt
path, so that a later slice can build the executor on a pipe that is known to
work. Slice 1 does **not** apply repo changes, build the executor, or change
routing. The `-Spawner` executor (gap 3) is Slice 2, a separate spec.

## Goal

A user can run one command and get, per **enabled** instrument on their box, an
honest verdict: *this model actually answered a real prompt* — or *it didn't,
and here's why.* And the dispatch pipe is hardened so the real prompts a future
executor sends won't be mangled.

## Scope & non-goals

**In scope:**

- A live round-trip probe over the enabled roster, surfaced through `fleet doctor`.
- A deterministic, judge-free pass criterion (a canary token).
- Making the stdin dispatch path the default for CLI providers so real prompts
  survive.
- Plain-English + `--json` legibility of the results.
- Hermetic tests (fake dispatcher; never touches real CLIs, network, or
  `~/.baton`).

**Out of scope (later slices / separate specs):**

- The `-Spawner` executor that applies repo changes (Slice 2).
- Any routing / `Select-Capability` change.
- Driving Baton *from* Codex/Gemini (the Command Center Codex-adapter follow-on).
- Per-provider latency benchmarking, sample-output capture, quality scoring.

## Approach (chosen)

**Extend `fleet doctor` with a `--live` probe** rather than adding a new command
or a `/baton:go` preflight. Doctor already iterates enabled providers and reports
`ok | skip | err`; the live probe is a second, opt-in pass over the same roster.
One health surface answers both "is my fleet reachable?" and "does my fleet
actually answer?"

Rejected alternatives:

- **New `/baton:fleet test` command** — a whole new surface that overlaps
  doctor's job. A dedicated command is a reasonable *later* affordance once
  there's more per-provider detail to show; not needed now.
- **Preflight inside `/baton:go`** — couples proof to execution and taxes every
  run. Premature.

## Design

### 1. Surface & modes

`scripts/fleet-doctor.ps1` gains a `-Live` switch (slash surface: `--live`) and
keeps `-Json`.

- **Default (no `-Live`):** today's behavior verbatim — reachability probe
  (binary on PATH; `base_url` / env-URL reachable). Byte-for-byte unchanged.
- **`--live`:** for each **enabled** provider, run the reachability check first;
  if it passes, run a live canary round-trip. Disabled providers are `skip`.
- Exit code: `0` if every enabled provider is `live_ok`; `1` if any enabled
  provider fails the live probe. (Matches doctor's existing all-ok/any-bad
  contract.)

### 2. The canary round-trip contract

A new pure-ish helper (in `fleet-lib.ps1` or a small `fleet-probe-lib.ps1`,
implementer's call at plan time) sends a fixed canary prompt and classifies the
result. The probe dispatches through **`Invoke-Fleet`** (not `Invoke-Fleet-Cli`
directly) so both `kind: cli` and `kind: http` providers — including the local
LM Studio / Ollama boxes — are covered by the same code path. A `-Dispatcher`
scriptblock seam is injected for tests.

- **Canary prompt (constant):** `Reply with exactly the word PONG and nothing else.`
- **Canary token (constant):** `PONG`.
- **Pass (`live_ok`):** dispatch returns exit 0 **and** stdout contains `PONG`
  (case-insensitive, substring) **and** it completed within the probe timeout.
- **Fail (`live_fail`):** with a single-word reason:
  - `not-on-PATH` — reachability check failed (cli binary missing).
  - `unreachable` — reachability check failed (http base_url / env URL down).
  - `timeout` — exceeded the probe timeout.
  - `nonzero-exit` — dispatch exit code ≠ 0.
  - `no-canary` — exit 0 but stdout lacks the token (e.g. the CLI printed its
    help text, or the seed template is wrong for this box). **This is the payoff
    line** — it distinguishes "the pipe/template is wrong" from "the model is
    down."
- **Skip (`skip`):** provider disabled in `fleet.yaml`.

**Timeout.** A probe timeout (default 60s; overridable via a `-TimeoutS` param /
`--timeout`) is measured and enforced. `Invoke-Fleet-Cli` does not currently
enforce its `TimeoutS` param, so the probe must wrap the dispatch in an enforced
timeout guard (e.g. a job/async wait) rather than assume the callee honors it;
http providers already carry `timeout_s`. The probe records elapsed seconds per
provider for the report.

**Result shape (per provider):**

```
@{ name; kind; enabled; reachable = $true|$false; live = 'live_ok'|'live_fail'|'skip';
   reason = <string|null>; elapsed_s = <int>|$null }
```

### 3. Prompt robustness (gap 2)

Make the **stdin path the default** for `kind: cli` dispatch in
`Invoke-Fleet-Cli`: when a provider's resolved command is a clean token list
(exe + args, no shell metacharacters requiring interpolation), pass the prompt
via the existing temp-file→stdin mechanism instead of interpolating `{{prompt}}`.
This immunizes real (large, quote-heavy) prompts against the 965-byte ceiling and
quote mangling — the foundation Slice 2's executor depends on.

- Providers already marked `stdin: true` are unchanged.
- Providers whose template still *requires* `{{prompt}}` interpolation (a shell
  form that can't take stdin) keep the legacy path; the change is opportunistic,
  not forced, so no seed template silently breaks.
- The canary probe itself **always** uses the stdin path.
- This must not regress the existing `Invoke-Fleet` cli tests; where a seed
  template's semantics would change, prefer adding `stdin: true` to that seed
  entry over rewriting dispatch behavior invisibly.

> **Open implementation note for the plan:** the exact predicate for "clean token
> list, safe to send via stdin" must be pinned to a concrete, tested rule (e.g.
> "template has no `{{prompt}}` placeholder AND no shell operators
> `| > < & ; $(` ") so behavior is deterministic and covered by a unit test. The
> writing-plans step resolves this to exact code + test cases.

### 4. Legibility

Human report (doctor `--live`), one row per provider, plain English:

```
PROVIDER           REACHABLE  LIVE        DETAIL
codex              yes        live_ok     1.2s
gemini-antigravity yes        live_ok     3.4s
ollama-local       yes        live_fail   timeout>60s
gh-copilot         yes        live_fail   no-canary (returned help text, not an answer)
lm-studio          yes        live_ok     2.1s
github-models      —          skip        disabled in fleet.yaml
```

`--json` emits the array of result shapes above for programmatic use (e.g. a
future dashboard tile).

### 5. Testing (hermetic)

- A **fake `-Dispatcher`** is injected into the probe so the suite never invokes
  a real CLI, touches the network, or reads real `~/.baton`. The fake returns
  canned `@{ stdout; stderr; exit_code }` tuples to exercise every branch:
  `live_ok`, `nonzero-exit`, `no-canary`, `timeout` (simulated), `skip` for
  disabled, and both `not-on-PATH` / `unreachable` reachability fails.
- Temp `fleet.yaml` fixtures; temp `BATON_HOME`; `try/finally` restore. Never
  touch real `~/.baton`, `~/.claude`, `D:\Dev\Grimdex`, or `D:\dev`.
- Stdin-default dispatch gets unit tests for the "clean token list" predicate
  (both directions) and a regression assert that `stdin: true` providers and
  interpolation-required providers are unchanged.
- The live mode against real box CLIs is a **manual** diagnostic, not part of the
  automated suite.

### 6. Deploy & docs

- If a new `fleet-probe-lib.ps1` is introduced, add it to the `bootstrap.ps1`
  deploy manifest **and** add a `test-bootstrap.ps1` deploy assert (the v1.8.0
  coach-lib omission lesson: every new deployed script gets a deploy assert).
- `commands/` doc for `fleet doctor` updated to document `--live` / `--timeout`
  / `--json`.
- `AGENTS.md`: one line noting `fleet doctor --live` as the model-agnostic way to
  verify any box's roster actually answers.
- Plugin version bump (minor) at release.

## House rules (§11, per project standing rules)

- Every shell command arg < 965 bytes; large prompts go via file/stdin.
- CLI errors: `[Console]::Error.WriteLine(...)` + `exit 2` (never `Write-Error`
  under `Stop`). Doctor keeps its existing exit-code contract.
- All file writes `utf8NoBOM`.
- `ConvertFrom-Json` auto-parses ISO dates to `DateTime` — re-stringify on
  round-trip. `ConvertTo-Json` needs `-InputObject @(...)` for guaranteed arrays.
- Never name PS vars `$args/$input/$event/$matches/$host/$pid`.
- Unary-comma flatten `,([object[]]$x)` only on direct-assignment returns; use
  `@($x)` when callers pipe.
- Guard `0/0` NaN in any elapsed/utilization math.
- Box-private: never write real roster/endpoint values into the shared seed
  `fleet.yaml`; placeholder hosts only. The live probe reads the box-private
  live roster at run time.

## Decisions made

- **Prove the round-trip before building the executor** — cheap de-risking slice
  first; the executor (gap 3) is designed against a pipe known to work.
- **Extend `fleet doctor --live`** rather than a new command or a `go` preflight —
  one health surface, minimal new code.
- **Canary-token pass criterion** (`PONG`), judge-free — catches help-text /
  wrong-template / garbage responses, not just exit 0.
- **Stdin path as the CLI dispatch default** — hardens the pipe for the real
  prompts Slice 2 will send.

## Out-of-scope follow-ons (named, not built here)

- **Slice 2 — the `-Spawner` executor:** send the task to the chosen instrument,
  capture its output/edits, turn that into an applied repo change (agentic tools
  edit in-place; chat models emit a diff Baton applies, or file-edit tasks route
  only to agentic instruments — resolved in Slice 2's spec), verify via the
  existing acceptance gate, work on a branch/worktree for reversibility.
- Per-provider latency/quality benchmarking; sample-output capture.
- A dashboard tile consuming `fleet doctor --live --json`.
