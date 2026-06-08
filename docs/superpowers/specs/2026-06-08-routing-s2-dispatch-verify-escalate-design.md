---
title: Capability-routing optimizer — Slice 2: auto-dispatch + verify/escalate
date: 2026-06-08
status: design
decisions: [d026]
slice: 2 of 3
---

# Auto-dispatch + verify/escalate (routing Slice 2)

## Why

`d026` set the routing north star: an **auto-router with a learning loop** that picks the
*optimal* (not best) capability for a need and offloads grunt work off Claude to cut cost.
It ships in three slices. **Slice 1** shipped the *selector* — `Select-Capability` ranks the
candidates that can serve a capability, cheapest cost-tier first, as a recommendation only.

**This is Slice 2: pull the trigger.** Given a capability *and a prompt*, the router now
**dispatches** the cheapest capable candidate, **verifies** the output with a deterministic
heuristic check, and **escalates** up the ranked ladder when the check fails — ending at
"escalate to conductor" (Claude) when every candidate fails. Every attempt is **journaled**
to a structured log that becomes Slice 3's learning substrate and the shareable dataset.

Slice 2 still ships only free, deterministic verification. The novelty is the *machinery*:
dispatch any candidate, walk the cost ladder on failure, and log it all — behind a
**grader seam** so Slice 3 can swap in an LLM-judge + human-rating grader without touching
the dispatch/escalate/journal code.

## Decisions carried in

- **d026:** auto-router + learning loop; 3-slice decomposition; this is Slice 2.
- **Grading (this brainstorm):** **heuristic checks behind a pluggable grader seam.** Slice 2
  ships the deterministic grader (`Test-RoutingOutputHeuristic`); `Invoke-RoutedCapability`
  takes a `-Grader` scriptblock (default = heuristic). The seam is the strategic concept
  Slice 3 fills (LLM-judge + the user's ratings). "It didn't work" → escalate now;
  "not good enough" → Slice 3's job. (Concept-anchoring: build the seam at n=1 because the
  roadmap will fill it next slice; the heuristic body stays YAGNI-simple.)
- **Escalation ladder:** reuse `Select-Capability`'s already-cost-ascending candidate list —
  escalation is "advance to the next candidate." Terminal outcome when all fail =
  `escalate-to-conductor` (PowerShell cannot invoke Claude; Claude *is* the orchestrator).
- **Journal:** new structured `~/.claude/routing-journal.jsonl` (one JSON object per attempt),
  not the markdown `model-routing-log.md` — structured rows are what Slice 3's learning loop
  and the shareable dataset need.
- **Dispatch scope:** text prompt-in / text-out capabilities only — `tools.yaml` `kind: cli`
  entries and `fleet.yaml` models. File-input tools (`pdf-extract`, `ocr`) keep their existing
  Python path and are out of scope.
- **Surface:** extend `/route` with a `--run "<prompt>"` action. Auto-dispatch with **no
  per-step confirm** (autonomy); **print the full ladder walked** (legibility).
- **Language:** PowerShell (`routing-dispatch.ps1`), mirroring Slice 1 + `Invoke-Fleet`.

## Non-goals (out of scope for Slice 2)

- LLM-judge grading, calibration runs, the user's ratings, learned quality scoring, the
  shareable dataset publish step — **Slice 3** (the grader seam is the only hook left for it).
- File-input capabilities (`pdf-extract`, `ocr`) — dispatched via their existing Python path.
- `kind: http` and `kind: python` tool dispatch — skipped with a logged reason; only `cli`
  tools and fleet models are dispatched in Slice 2.
- Invoking Claude programmatically as the final ladder rung — the terminal state is a flagged
  `escalate-to-conductor` outcome the conductor reads and acts on.
- The fully-autonomous folder→repo run-loop (a future epic built on this router).

## Architecture

One new file plus a `/route` extension, a bootstrap entry, and a test suite.

### `scripts/routing-dispatch.ps1` (new)

Dot-sources `routing-lib.ps1` (for `Select-Capability`, `Read-Tools`, `Get-CostTierRank`) and
`fleet-lib.ps1` (for `Invoke-Fleet`, `Invoke-Fleet-Cli`'s stdin pattern). Four functions.

#### 1. `Invoke-Tool` — dispatch a `tools.yaml` cli entry

```
Invoke-Tool
  -Tool <hashtable>      # a Read-Tools entry (name, kind, command_template, stdin, ...)
  -Prompt <string>
  [-TimeoutS <int> = 120]
-> @{ stdout; stderr; exit_code; duration_s }
```

Mirrors `Invoke-Fleet-Cli` but for tools: no `env` block, no `-Model`. When `stdin: true`,
pipe the prompt to the command via the robust temp-file/stdin path (immune to embedded
quotes/`$`/backticks) — identical to `Invoke-Fleet-Cli`'s stdin branch. `command_template`
is a clean token list (e.g. `ollama run nuextract`); split on whitespace and invoke via the
call operator. On exception → `@{ stdout=''; stderr=<msg>; exit_code=-1; duration_s=<n> }`.

#### 2. `Test-RoutingOutputHeuristic` — the default grader

```
Test-RoutingOutputHeuristic
  -Capability <string>
  -Result <hashtable>    # the dispatch result {stdout, exit_code, ...}
-> @{ passed = <bool>; score = <double>; reason = <string> }
```

The grader **contract**: any grader is a function/scriptblock of `(Capability, Result)`
returning `{passed, score, reason}`. The heuristic implementation:

1. **Base gate:** `exit_code -ne 0` → fail (`reason = "exit <n>"`). Whitespace-only/empty
   stdout → fail (`reason = "empty output"`).
2. **Per-capability validator** (switch; only obvious, free checks):
   - `struct-extract` → `stdout` parses via `ConvertFrom-Json` (in try/catch); fail →
     `reason = "not valid JSON"`.
   - `commit-msg` → at least one non-blank line and a non-empty first line (subject);
     fail → `reason = "no commit subject line"`.
   - default (incl. `code-gen`, `reasoning`, `summarize`) → base gate only; non-empty
     output suffices (semantic quality is Slice 3).
3. **Score:** `1.0` if passed, else `0.0` (heuristic is binary; Slice 3's grader yields a
   continuous score into the same field).

#### 3. `Invoke-RoutedCapability` — the dispatch/verify/escalate loop

```
Invoke-RoutedCapability
  -Capability <string>
  -Prompt <string>
  [-MaxCostTier <local|free|paid>] [-RequireLocal]
  [-TimeoutS <int> = 120]
  [-Grader <scriptblock> = (the heuristic grader)]      # THE SEAM Slice 3 fills
  [-Dispatcher <scriptblock>]                           # test injection; default = real dispatch
  [-ToolsPath <p>] [-FleetPath <p>] [-JournalPath <p>]
-> [pscustomobject] outcome (see below)
```

Logic:

1. `candidates = Select-Capability -Capability $Capability [filters]`. Empty → return
   `@{ status = 'no-candidate'; capability; attempts = @() }`.
2. For each candidate in order (cheapest tier first — Slice 1 already sorted):
   - **Skip non-dispatchable kinds:** a `tools` candidate whose `kind` is not `cli`
     (e.g. `python`, `http`) → record a skipped attempt
     (`passed=$false; reason='unsupported kind <k> in Slice 2'`), journal it, continue.
   - **Dispatch:** if `-Dispatcher` provided, call it `(candidate, $Prompt)`; else real
     dispatch — `source = 'tools'` → `Invoke-Tool`; `source = 'fleet'` → `Invoke-Fleet`
     (`-NoJournal`, since Slice 2 writes its own richer journal). Dispatch returns the
     `{stdout, exit_code, duration_s, ...}` result; an exception is caught and turned into
     an `exit_code = -1` result (→ grader fails it).
   - **Verify:** `& $Grader -Capability $Capability -Result $result`.
   - **Journal:** `Write-RoutingJournalLine` for this attempt.
   - **Pass → win:** return
     `@{ status='passed'; capability; winner=<candidate-name>; result; attempts=@(...) }`.
   - **Fail → continue** to the next candidate.
3. Loop exhausted → return
   `@{ status='escalate-to-conductor'; capability; attempts=@(...) }`.

`attempts` is an ordered array of `@{ candidate; source; kind; cost_tier; passed; score;
reason; duration_s }` — the full trace `/route` prints and Slice 3 reads.

#### 4. `Write-RoutingJournalLine` — append a structured row

```
Write-RoutingJournalLine
  -Capability <string> -Candidate <string> -Source <string> -Kind <string>
  -CostTier <string> -ExitCode <int> -DurationS <int>
  -Passed <bool> -Score <double> -Reason <string>
  [-JournalPath <p> = ~/.claude/routing-journal.jsonl]
  [-Timestamp <string>]     # injectable for deterministic tests
```

Appends one JSON object (`ConvertTo-Json -Compress`) per line via `Add-Content
-Encoding utf8NoBOM`. Fields: `ts, capability, candidate, source, kind, cost_tier,
exit_code, duration_s, passed, score, reason`. A write failure is caught and surfaced as a
warning — it never crashes the dispatch loop. JSONL (append-only) needs no seed file; it is
created on first write.

### `commands/route.md` — add the `--run` action

```
/route <capability> [--max-tier local|free|paid] [--local] [--run "<prompt>"]
```

- **Without `--run`:** unchanged Slice-1 behavior (ranked recommendation table, top pick).
- **With `--run`:** dot-source `routing-dispatch.ps1`; call `Invoke-RoutedCapability`; then
  print the **ladder walked** — one line per attempt: `cost_tier candidate ✓/✗ (Ns) reason`
  — followed by the outcome:
  - `passed` → the winner name + its `stdout`.
  - `escalate-to-conductor` → "all N candidates failed — escalating to the conductor," with
    the per-candidate reasons, so Claude decides/does it.
  - `no-candidate` → no candidate serves `<capability>`; list `Get-KnownCapabilities`.
  - Footer: "logged N attempts to routing-journal.jsonl".

### `scripts/bootstrap.ps1` (+ `scripts/test-bootstrap.ps1`)

- Add `'routing-dispatch.ps1'` to the libs deploy array (next to `routing-lib.ps1`).
- `route.md` is already deployed (Slice 1); no command-array change.
- `test-bootstrap.ps1`: one dry-run-stdout assertion that `routing-dispatch.ps1` deploys.
- No `routing-journal.jsonl` seed — created on first write.

### `scripts/test-routing-dispatch.ps1` (new) — tests

Project PS harness: `Check($name,$cond)` → `$script:fail`; temp fixtures + journal path under
`[System.IO.Path]::GetTempPath()`; try/finally cleanup; `exit 1`/`0`.

## Data flow

```
/route commit-msg --run "<staged diff>"
  → Invoke-RoutedCapability -Capability commit-msg -Prompt "<diff>"
       → Select-Capability → [git-commit-message (tools, cli, local)]
       → Invoke-Tool git-commit-message (diff via stdin) → {stdout, exit 0}
       → heuristic grader (commit-msg): non-empty subject → passed
       → journal {passed:true, score:1.0, ...}
       → outcome status=passed, winner=git-commit-message
  → /route prints: "local git-commit-message ✓ (0.4s) → <msg>; logged 1 attempt"

/route code-gen --run "<task>"
  → candidates cheapest-first: ollama-local(local), gemini(free), codex(paid)
  → ollama-local → Invoke-Fleet → empty output → grader fail "empty output" → journal → next
  → gemini → Invoke-Fleet → non-empty → grader pass → journal → winner
  → /route prints ladder: "local ollama-local ✗ (2s) empty output / free gemini ✓ (5s)
    → <output>; logged 2 attempts"
```

## Error handling

| Condition | Behavior |
|---|---|
| No candidate serves the capability | `status='no-candidate'`; `/route` lists `Get-KnownCapabilities`. |
| Candidate is a non-`cli` tool (`python`/`http`) | Skipped attempt, `reason='unsupported kind … in Slice 2'`, journaled, continue. |
| Dispatch throws / times out | Caught → `exit_code=-1` result → grader fails it → escalate. |
| Grader scriptblock throws | Treated as a failed attempt (`reason='grader error: <msg>'`); escalate. |
| All candidates fail | `status='escalate-to-conductor'` with per-candidate reasons. |
| Journal write fails | `Write-Warning`; loop continues (a logging fault never loses the result). |
| `tools.yaml` / `fleet.yaml` missing | `Read-Tools`/`Read-Fleet` throw the deploy hint (run bootstrap). |

## Testing

`scripts/test-routing-dispatch.ps1`:

- **Grader — base gate:** `exit_code=1` → fail; empty/whitespace stdout → fail; non-empty +
  exit 0 (default capability) → pass.
- **Grader — per-capability:** `struct-extract` with valid JSON → pass, with non-JSON → fail;
  `commit-msg` with a subject line → pass, blank → fail.
- **Escalation via injected `-Dispatcher`:** dispatcher returns fail for candidate 1, fail for
  2, pass for 3 → outcome `status=passed`, `winner` = 3rd candidate, `attempts.Count -eq 3`.
- **All-fail:** dispatcher fails every candidate → `status='escalate-to-conductor'`,
  `attempts.Count` equals candidate count.
- **No candidate:** unknown capability → `status='no-candidate'`, `attempts` empty.
- **Non-cli skip:** a fixture `tools.yaml` candidate with `kind: python` for the capability →
  attempt recorded with `reason` mentioning unsupported kind; loop proceeds to the next.
- **Journal:** `Write-RoutingJournalLine -JournalPath <temp> -Timestamp <fixed>` writes one
  line that round-trips via `ConvertFrom-Json` with every expected field; a second call
  appends (file has 2 lines).
- **Order:** with a local and a paid candidate both passing, the local one is dispatched first
  (only one attempt; paid never dispatched).

Bootstrap smoke (`test-bootstrap.ps1`): dry-run stdout shows `routing-dispatch.ps1`.

## Build order (TDD)

1. `routing-dispatch.ps1` skeleton (dot-sources) + `Test-RoutingOutputHeuristic` + grader tests.
2. `Write-RoutingJournalLine` + journal tests (temp path, injected timestamp).
3. `Invoke-Tool` (stdin dispatch) — unit test with a cross-platform echo-style fixture command.
4. `Invoke-RoutedCapability` (loop + `-Dispatcher`/`-Grader` injection + skip-kind) + escalation
   / all-fail / no-candidate / order tests.
5. `commands/route.md` `--run` action.
6. bootstrap deploy + `test-bootstrap.ps1` assertion.

## Success criteria

- `/route commit-msg --run "<diff>"` dispatches the local tool, verifies, prints the result,
  and appends one journal row.
- A failing cheap candidate escalates to the next; the ladder walked is printed; each attempt
  is journaled.
- All-fail yields `escalate-to-conductor` with reasons, not a crash.
- The `-Grader` seam lets a test inject a custom grader and change pass/fail without editing
  the loop — proving Slice 3 can plug in its judge.
- `routing-dispatch.ps1` deploys via bootstrap.
- Gate green: `test-routing-dispatch.ps1` + the existing Python + PowerShell suites + bootstrap
  smoke.
