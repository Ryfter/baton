# Verified Labor — Baton's reconciled Ringer design (d082)

**Date:** 2026-07-10 · **Status:** authorized to build (Kevin: "use them to implement ringer type functionality and checks") · **Decision:** d082
**Inputs:** `codex-ringer.md` (the adopted technical spine — normative reference for contract details, safety §12, test matrix §16), `gemini-ringer.md`, `grok-ringer.md` (master), `grok-ringer-critique.md` (master), `codex-ringer-peer-critique.md` — three fleet specs + two cross-critiques, commissioned by Kevin 2026-07-10.

## 1. What this is

Baton learns Ringer's lesson natively: **a labor task passes only when an independent, executable contract produces durable evidence — and the system remembers whether that happened on the first try.** No Ringer code, runtime, template, or registry entry ships in Baton (PolyForm Shield boundary). Codex's spec is the spine; this document records only Baton's adjudications of the critiques and the slice map. Where this spec is silent, `codex-ringer.md` governs.

## 2. Adjudications (the disagreements the critiques left open)

| # | Question | Ruling |
|---|---|---|
| A1 | Parallelism timing (Grok: named early slice; Codex: vague post-V4) | **Artifact-batch fan-out is V3**, immediately after conductor integration — independent non-repo-edit tasks, isolated per-task artifact dirs under the run, bounded concurrency. Repo-batch (child worktrees) stays late (V5). The "swarm joy" arrives one slice after trust, not four. |
| A2 | Gemini severity (Grok: "design theater"; Codex: "strongest UX intent") | Politely defer, explicitly keep: the **single-cockpit principle** (never a second dashboard), the **CLI narration report format** (route → worker → check → retry → proves; adopted as the literal `report.md`/stdout shape in V2), and the **a11y/offline requirements** (reduced-motion, focus rings, WCAG AA, no CDN) as binding constraints on any later UI slice. UI-2/UI-3 cockpit + rookie board + Chart.js scoreboard: deferred until real multi-task data exists; placeholder metrics must render `n=0 / insufficient_data`, never fabricated samples. |
| A3 | License framing (Gemini: "None (Cleanroom)") | Never "none." Standing language: *native reimplementation carries no distribution/dependency risk, but that is not a substitute for counsel review; any public adapter/bundling remains blocked pending licensor clearance.* Private, local, unregistered, pinned-commit Ringer dogfooding is blessed (V6) — outside the plugin, no bootstrap wiring, no imported eval rows. |
| A4 | Verify-optional death spiral (Grok's strongest finding) | Two-part cure. (1) **Authoring sugar in V1**: `references/verify-presets.yaml` — named presets (`pytest`, `pwsh-suite`, `file-exists-nonempty`, …) that expand to safe argv; profiles may be preset-refs; planner few-shots teach `verify_profile` selection in V2. (2) **Graduation policy**: V2 ships opt-in (`-Verify`), mirroring the Plan Gate's opt-in→default-on pattern; a named V4 decision flips `-Execute` + capability ∈ {code-gen, code-transform} to require-verify with an explicit `-AllowUnverified` escape. Optional-forever is rejected. |
| A5 | Non-zero-worker/zero-exit-check loophole | Closed: for edit tasks, a verification pass ADDITIONALLY requires the existing proof-by-diff signal (non-empty task diff) and `expect_files` entries must be non-empty **with content** hashes distinct from pre-task state where they pre-existed. Exit codes alone never pass. |
| A6 | Plan Gate `verification` finding area | Deferred exactly as Codex ruled (its H7): separate decision after d080 bakes live. Grok's review-checklist content is parked in this spec's appendix for that day. |
| A7 | Cross-platform argv (`python` vs `python3`) | Solved at the preset layer: presets carry per-platform argv variants resolved at contract-freeze time; raw profiles must be platform-explicit and lint warns otherwise. |

## 3. Slice map (each slice = own plan; SDD per house rules)

- **V0 — d082 decision record** (this doc + Grimdex record): boundary, spine adoption, adjudications above. *Done with this spec.*
- **V1 — `scripts/verification-lib.ps1` + presets + hermetic suite.** Pure: contract normalize/lint (argv-only; reject `sh -c`/`pwsh -Command`/`cmd /c`/`python -c`; path-root + `..`/symlink containment), preset expansion, protected-path hashing, frozen-contract resolution from base revision, argv runner (`System.Diagnostics.Process`, closed stdin, process-group kill, timeout, output cap), evidence grading (`strong|bounded|weak|invalid` — deterministic from contract+diff), result object. New files only — **buildable off current master in parallel with the plan-gate merge.**
- **V2 — Conductor/executor integration + one retry + narration.** `verify_profile`/`allowed_paths` through plan normalization; preflight contract freeze before labor; verify after each agentic attempt; outcome precedence per codex-ringer §7 (plus A5); exactly one evidence-informed retry in the same worktree; fail-closed on scope/oracle violations (no retry); `unverified` marking for legacy tasks; `tasks/<id>/` evidence tree + `attempts.jsonl` + the six event kinds; report gains the Gemini narration block. Opt-in `-Verify`. Requires the merged plan-gate conductor.
- **V3 — Artifact-batch parallelism.** Ready-set derivation from the existing DAG; concurrent dispatch (bounded semaphore) of independent tasks whose writes are confined to per-task artifact dirs (no repo edits); per-task verification as in V2. The demo slice.
- **V4 — Observe-only telemetry + graduation decision.** First-try/rescued/infra rates by capability×worker with sample counts and grade mix; NEVER writes `effective-cost.json`; routing untouched until a separate weights/floors decision. Ships alongside the require-verify default flip for `-Execute` edit tasks.
- **V5 — Repo-batch parallelism + cockpit conversation.** Child worktree per ready task; durable patch/branch per task; only then does the Swarm Cockpit (UI-2) conversation open, under A2's constraints.
- **V6 — Optional private Ringer comparison.** Unregistered, pinned, outside the plugin; manual result inspection only.

## 4. Binding constraints (inherited + house)

Everything in codex-ringer §12 (safety) and §13 (Windows-native; no WSL in the public path) is binding. Fail-CLOSED is the verification posture (contrast the advisory gates' fail-open — a task that demands verification and can't get it fails). House rules per usual: 965-byte args, utf8NoBOM, `[Console]::Error`+exit 2, no reserved var names, unary-comma discipline, hermetic tests in temp dirs, box-private data never in the repo, bootstrap manifest + assert for every new lib.

## 5. Appendix — parked Plan Gate verification checklist (for the post-d080 decision)

Does the check exercise the requested behavior rather than a proxy? Can the worker modify or spoof the oracle? Are allowed paths narrow enough? Does the command exist on the target platform? Is the timeout proportionate? Is the contract stronger than proof-by-diff alone?
