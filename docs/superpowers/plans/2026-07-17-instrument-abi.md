# Instrument ABI Implementation Plan

**Goal:** Make declared HTTP, Python, and stdio-JSON instruments routable through Baton's existing return contract while preserving CLI behavior, usage fallback, journals, and the d009 agentic boundary.

**Architecture:** `fleet-lib.ps1` owns the transport primitives and normalized result rows. `Invoke-FleetHttpChat` provides the generic OpenAI-compatible HTTP path with hatch override precedence retained in `Invoke-Fleet`; one stdio-JSON helper serves both fleet and tools rows. `routing-dispatch.ps1` widens the tool-kind gate, performs the declared prompt-size pre-flight, and delegates Python to the unchanged CLI execution path. `fleet-executor-lib.ps1` rejects non-CLI rows at the agentic seam.

**Tech stack:** PowerShell 7, `Invoke-RestMethod`, `System.Diagnostics.Process`, hand-rolled YAML readers, JSON over redirected stdio, hermetic PowerShell test fixtures.

## Binding constraints

- The design spec at `docs/superpowers/specs/2026-07-17-instrument-abi-design.md` and decision d091 are authoritative.
- Every invoked transport normalizes to `stdout`, `stderr`, `exit_code`, `duration_s`, `tokens`, and `tokens_basis`; existing downstream usage observations and journals remain intact.
- HTTP model resolution is explicit `-Model` > non-`auto` `model_default` > first `/v1/models` row. HTTP `timeout_s` defaults to 300 seconds.
- A missing HTTP usage block leaves token fields absent until the existing `Get-FleetTokenUsage` estimate fallback runs.
- Stdio JSON requests travel through a UTF-8-no-BOM temp file, never an inline shell argument. Stdout must contain exactly one JSON object.
- `max_prompt_bytes` counts UTF-8 bytes and skips before process/network dispatch. An absent field preserves current behavior.
- `probe` is parsed/declarable only. No new probe adapter is wired in this slice.
- `agentic: true` cannot make an HTTP or stdio-JSON provider edit-eligible.
- Real hosts, rosters, quotas, and allowances stay box-private. Tests and fixtures use loopback and obvious placeholders only.
- No version bump, PR, merge, or live registry mutation. Push only `feature/instrument-abi`.

## Spec-to-master reconciliation

1. **No intervening master drift:** the spec commit `1d9580c` is a direct child of current `master`/`origin/master` `86bc61b`; `master..HEAD` contains only the design spec before this plan.
2. **Current `Invoke-Fleet` includes post-spec-adjacent d083 behavior:** after transport dispatch it adds `usage_observation` and `usage_recorded`, then journals tokens. New paths must flow through that block unchanged; transport failures must be returned as rows, not thrown past it.
3. **The estimate fallback already lives at the correct seam:** `Invoke-Fleet` calls `Get-FleetTokenUsage` only when the result lacks `tokens`. The HTTP helper must therefore omit both token keys when native usage is absent, not synthesize an estimate itself.
4. **The existing `ollama-box2` hatch is not OpenAI-compatible internally:** it POSTs native `/api/generate`. Deleting it intentionally moves the row to `/v1/chat/completions`, as the binding spec requires; this depends on the declared server exposing its OpenAI-compatible endpoint.
5. **The current tools path combines stderr into stdout for CLI calls:** Python must share that byte-for-byte execution branch so the CLI regression remains untouched. Stdio JSON uses separate redirected stderr because its stdout is a protocol channel.
6. **The current agentic predicate trusts an explicit marker before transport:** `Test-ProviderAgentic` needs the d091 transport veto ahead of its existing explicit/inferred checks. Legacy test objects without a `kind` field retain their behavior.
7. **The YAML readers are already additive for flat scalar fields:** `max_prompt_bytes`, `probe`, `agentic`, `endpoint`, and `model_default` need no schema rewrite. Runtime seams will validate/use only the fields relevant to this slice.

## Task 1: Add transport helpers and HTTP coverage

**Files:**
- Modify `scripts/fleet-lib.ps1`
- Modify `scripts/test-fleet-lib.ps1`
- Add `scripts/fixtures/mock-http-server.ps1`

- [x] Add hermetic loopback cases for explicit/pinned/listed model resolution, default/custom endpoint, exact `usage.total_tokens`, exact prompt-plus-completion usage, absent-usage estimate fallback through `Invoke-Fleet`, non-200, and timeout.
- [x] Add a shared UTF-8 prompt-byte helper and normalized failure-row helper where they reduce duplication without changing CLI output.
- [x] Implement `Invoke-FleetHttpChat -Provider -Prompt -Model`, honoring `timeout_s` and optional `endpoint`, and omit token keys when usage is absent.
- [x] Preserve `stub-http.ps1` hatch precedence with a regression assertion.
- [x] Run `scripts/test-fleet-lib.ps1` and commit the HTTP slice.

## Task 2: Add stdio-JSON for fleet and tools

**Files:**
- Modify `scripts/fleet-lib.ps1`
- Modify `scripts/routing-dispatch.ps1`
- Add `scripts/fixtures/fake-stdio-json.ps1`
- Modify `scripts/test-fleet-lib.ps1`
- Modify `scripts/test-routing-dispatch.ps1`

- [x] Add fake-child modes for happy output, malformed stdout, response-declared nonzero exit, process nonzero exit, stderr preservation, and timeout.
- [x] Implement a generic stdio-JSON invoker using `ProcessStartInfo`, redirected streams, async stdout/stderr drains, an overall timeout, process-tree cleanup, and request JSON loaded from a UTF-8-no-BOM temp file.
- [x] Send `{prompt, model, tier_args}` and normalize the one response object to the shared row. Treat extra/malformed JSON and any process/response nonzero exit honestly.
- [x] Dispatch fleet `kind: stdio-json` through the generic helper and tools `kind: stdio-json` through the same helper.
- [x] Run the two targeted suites and commit the stdio slice.

## Task 3: Widen tools routing and enforce declaration guards

**Files:**
- Modify `scripts/routing-dispatch.ps1`
- Modify `scripts/test-routing-dispatch.ps1`
- Modify `scripts/test-routing-lib.ps1` if candidate passthrough assertions are needed

- [x] Widen `Invoke-Tool` so `python` shares the existing CLI execution branch and `http` delegates to `Invoke-FleetHttpChat`.
- [x] Replace the CLI-only candidate gate with the supported set `cli`, `python`, `http`, `stdio-json`; preserve the existing loud journaled unknown-kind skip contract.
- [x] Resolve the full declared fleet/tool row before dispatch, count prompt UTF-8 bytes, and emit a journaled `prompt_too_large` skip before invoking any dispatcher when the declared positive ceiling is exceeded.
- [x] Assert all new kinds reach an injected dispatcher, unknown kinds remain loud, `prompt_too_large` names the byte ceiling, and no call occurs on an oversized prompt.
- [x] Assert `probe`, `agentic`, `endpoint`, and `max_prompt_bytes` survive the existing flat YAML readers without adding box-private values.
- [x] Run routing and fleet targeted suites and commit the routing/declaration slice.

## Task 4: Preserve the d009 executor boundary and remove redundant hatches

**Files:**
- Modify `scripts/fleet-executor-lib.ps1`
- Modify `scripts/test-fleet-executor-lib.ps1`
- Delete `scripts/fleet/lm-studio.ps1`
- Delete `scripts/fleet/lm-studio-small.ps1`
- Delete `scripts/fleet/ollama-box2.ps1`

- [x] Add executor tests proving explicit `agentic: true` is refused for HTTP and stdio-JSON while CLI explicit/inferred behavior remains unchanged.
- [x] Put the transport veto at `Test-ProviderAgentic`, the executor eligibility seam used by initial and substitute selection.
- [x] Change `Invoke-Fleet` HTTP dispatch order to hatch-if-present, otherwise generic; add stdio-JSON dispatch; leave CLI dispatch unchanged.
- [x] Delete only the three named redundant hatches and confirm `stub-http.ps1` remains.
- [x] Run executor, fleet, and routing suites and commit the cleanup/boundary slice.

## Task 5: Full verification and branch handoff

- [x] Run `python -m pytest kb dashboard -q` as required by `AGENTS.md`; record the exact pytest total.
- [x] Enumerate and run every `scripts/test-*.ps1` suite with `pwsh -NoProfile -File`, without stopping after the first failure. Capture each suite's exact printed PASS/FAIL totals and exit code.
- [x] Fix regressions incrementally, rerun affected suites, then rerun the complete PowerShell set before claiming green.
- [x] Run `git diff --check`; inspect `git status --short`; scan changed PowerShell for forbidden automatic-variable names and unsafe encodings; confirm every divide is guarded and array JSON uses `ConvertTo-Json -InputObject @(...)`.
- [x] Confirm tests used only unique `$env:TEMP` roots with `try/finally`, loopback HTTP, and fake child processes; confirm no real Baton/Claude home or live model server was touched.
- [x] Commit any verification fixes with focused messages.
- [x] Push `feature/instrument-abi` and report files, commit SHAs, reconciliation deltas, exact suite counts, and open questions. Do not open a PR or merge.
