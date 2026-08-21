# Dark-Factory Slice — Decomposition Index

Status: SCAFFOLD. Produced without read access to `docs/superpowers/specs/2026-08-15-maestro-front-door-design.md` (LOCKED), `docs/next-session.md`, and `~/.baton/overnight/fleet.yaml`. Reconcile slice boundaries, names, and pinned choices against the LOCKED spec before implementation.

## Slice map
- DF-01 Front-door entrypoint (implements the LOCKED front-door contract)
- DF-02 Fleet config schema and validation
- DF-03 Brief intake and work queue
- DF-04 Worker execution loop (sandboxed)
- DF-05 Acceptance-criteria verifier
- DF-06 Telemetry and secret redaction
- DF-07 Overnight orchestration and morning report

Provisional dependency order: DF-02, then DF-01, then DF-03, then DF-04, then DF-05, then DF-07. DF-06 runs parallel to DF-04. Reconcile against the LOCKED spec's flow.

## Locked-debate guardrails (flag, never reopen)
Any brief or PR that touches the following is flagged and escalated, not improvised:
1. Front-door command surface (name, flags, exit codes) — LOCKED by the 2026-08-15 spec.
2. Orchestration paradigm (agent loop vs deterministic pipeline), if the spec pins it.
3. Repo layout, naming conventions, test/CI framework, queue/sandbox technology, if the spec pins them.
4. Anything the spec marks decided/locked/non-negotiable.

Rule: briefs may reference locked decisions; they must not re-litigate them. If a slice appears to require changing a locked decision, halt the affected slices and record a spec-change request in the morning report (DF-07).

## Safe-to-generalize Ox Alpha / overnight patterns (no secrets)
Safe to extract and publish:
- Brief decomposition: small units, one owner, explicit acceptance criteria.
- Acceptance-gated completion: done means all ACs pass with evidence; never self-attested.
- Checkpoint/resume for long unattended runs.
- Quarantine-on-failure with morning-report escalation.
- Redact-at-emission telemetry with planted-secret fixture tests.
- Env-ref-only secrets in fleet config; deterministic config canonicalization.

Not safe without redaction or templating:
- Any real `fleet.yaml` contents: hostnames, tokens, model endpoints, internal URLs, personal paths, org codenames.
- Logs, manifests, or reports embedding account IDs, keys, or user-identifying paths.

## Per-brief template
Goal / Non-goals / Dependencies / Acceptance criteria / Locked-debate flags / Generalization notes.
