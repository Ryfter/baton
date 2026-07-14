# Review Named Panel — Implementation Brief (for the fleet implementer)

**Spec (READ FIRST):** `docs/superpowers/specs/2026-07-13-review-named-panel-design.md`
**Extends:** `scripts/gate-lib.ps1` (`Invoke-AcceptanceGate`, `Build-ReviewPrompt`) — a LAYER, do not rewrite the merge/verdict/brief functions.
**Branch:** `feature/review-named-panel` (you are on it). Do NOT commit — leave edits staged for review.

## Global constraints (Baton house rules — obey exactly)
- PowerShell 7. Writes use `utf8NoBOM`. Never name variables `$args`/`$input`/`$event`/`$matches`/`$host`/`$pid`.
- CLI errors: `[Console]::Error.WriteLine(msg)` then `exit 2`. Hooks exit 0.
- 965-byte shell-arg limit: reviewer prompts ride the existing stdin-safe provider path (unchanged) — do not add long inline args.
- Tests NEVER touch the real `~/.baton`, `~/.claude`, or `D:\Dev\Grimdex`. Use `$env:TEMP` dirs + `try/finally` cleanup, and dispatcher/`Select-Capability` injection.
- The shipped roster seed is GENERIC — NO box-private model IDs (mirror how `references/fleet.yaml` seeds generic examples). Tiers are `cheap|strong`, mapped to model selection at runtime, never hard-coded model names.
- Backward compatible: with no roster present, behavior is byte-for-byte the existing generic competitive review.

## Tasks

### Task 1 — Roster config + parser
- Create `references/review-roles.yaml` (the shipped seed) with 6 generic coding roles, each `{name, lens, tier: cheap|strong, enabled: true}`:
  - `correctness` (strong): "Does it do what the TASK says, correctly? Logic and edge-case defects only."
  - `security` (strong): "Adversarial: TRY TO BREAK IT — authz, injection, secret/tenant leakage, unsafe I/O."
  - `architecture` (strong): "Boundaries, coupling, and whether it fits existing patterns."
  - `spec-compliance` (strong): "Artifact vs. the ORIGINAL intent — flag under-building / missed requirements."
  - `simplicity` (cheap): "Unneeded complexity, dead code, over-engineering."
  - `framework-style` (cheap): "Idiom, naming, project conventions."
- Add `Get-ReviewRoles -Path <yaml>` to `gate-lib.ps1` using the SAME hand-rolled YAML approach the fleet/tools libs use (do not add a YAML dependency). Returns an array of role hashtables; skips `enabled:false`; tolerates a missing file (returns `@()`).
- Add `Initialize-BatonHome` seeding of `review-roles.yaml` if absent (seed-if-absent, like `fleet.yaml`) — find where the existing seeds live and follow that pattern.

### Task 2 — Role-aware prompt
- Give `Build-ReviewPrompt` an optional `-Role` param (a role hashtable with `name` + `lens`). When present, inject `You are the <name> reviewer. <lens>` ahead of the existing strict-JSON findings schema. Task + Artifact + schema unchanged. No `-Role` → today's generic prompt, verbatim.

### Task 3 — Panel dispatch in `Invoke-AcceptanceGate`
- Add a `-Panel` switch and an optional `-RolesPath` (default `$BATON_HOME/review-roles.yaml`).
- When `-Panel` (or the roster file exists and no explicit `-Reviewers`): for each enabled role, pick its model via the EXISTING `Select-Capability` constrained by the role's tier (`strong` → allow up to `-MaxCostTier`; `cheap` → prefer `local`/`free` capable), dispatch the role-lens prompt, and set each finding's `area` = role name (role provenance). One model may serve several roles. Reuse `Get-ReviewFindings`, `Merge-ReviewFindings`, `Get-AcceptanceVerdict`, `Format-PolishBrief`, `Format-GateReport` UNCHANGED.
- A role whose tier yields no capable model is SKIPPED and recorded in a `degraded` list.

### Task 4 — Fail-loud flag (d086)
- Add a `-FailLoud` switch. Default (advisory) behavior unchanged: no usable review → fail-open accept. With `-FailLoud`: if the panel is degraded (any skipped role, or all reviewers unparsed), set `result.degraded = $true` and `result.reason` to name the degradation; DO NOT silently accept — surface the degraded state (the golden-path caller consumes this). Add `degraded` (bool) + `degraded_roles` (array) to the returned object.

### Task 5 — Wiring
- `scripts/fleet-gate.ps1`: add a `--panel` flag that sets `-Panel` (and pass `--fail-loud` → `-FailLoud`). Keep the existing generic path when `--panel` is absent.
- Update `commands/gate.md` argument-hint + body to document `--panel` and `--fail-loud`.

### Task 6 — Tests (`scripts/test-gate-lib.ps1`, dispatcher-injected)
Add asserts: role-aware prompt injects the lens; roster parse + `enabled:false` skipped + missing-file → `@()`; malformed role tolerated; findings carry role provenance in `area`; a `strong` vs `cheap` role selects the expected tier via a STUBBED `Select-Capability`; degraded-role sets `degraded=$true` under `-FailLoud` but fails-open without it; backward-compat (no `-Panel`, no roster → identical generic output). Run `pwsh -NoProfile -File scripts/test-gate-lib.ps1` and report pass/fail counts.

## Done = all six tasks implemented, `test-gate-lib.ps1` green, no changes to the reused merge/verdict/brief functions, seed carries no box-private model IDs. Report what you changed per file and the test output. Do NOT commit.
