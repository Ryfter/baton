# DF-02 — Fleet config schema and validation

Status: SCAFFOLD. Field names must match the real `~/.baton/overnight/fleet.yaml`; reconcile before coding.

## Goal
Define and validate the fleet configuration the front door consumes: workers, per-slice briefs, budgets, allowlists, checkpoint locations. Secrets are referenced, never inlined.

## Non-goals
- Runtime behavior (DF-01, DF-04).
- Moving the fleet config location.

## Acceptance criteria
- [ ] A schema exists; every field documented with type, default, constraint.
- [ ] Validation rejects unknown fields, bad types, and out-of-range budgets with field-level errors.
- [ ] Secret-bearing fields accept env references only (e.g. `env:VAR_NAME`); plaintext secret values fail validation.
- [ ] Config hash is stable across semantically identical files (deterministic canonicalization) so run manifests are comparable.
- [ ] Fixtures cover: minimal valid, full valid, and each invalid class.

## Locked-debate flags
- No renaming existing fleet.yaml fields; additive only if the LOCKED spec allows.
- Keep whatever schema format the spec pins.

## Generalization notes
Safe pattern: env-ref-only secrets, deterministic config canonicalization, fixture-driven schema tests. Publishable once field names are made generic.
