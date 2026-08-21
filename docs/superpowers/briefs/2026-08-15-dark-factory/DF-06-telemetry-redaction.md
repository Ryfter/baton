# DF-06 — Telemetry and secret redaction

Status: SCAFFOLD. Telemetry destination defers to the LOCKED spec if pinned.

## Goal
Collect structured logs and metrics from the run and guarantee no secrets leave the machine in any artifact, log, or report.

## Acceptance criteria
- [ ] A redaction pass runs at emission time on every log line, artifact, and report before write.
- [ ] A secret-scan gate fails the run if any known-secret pattern appears in outputs; patterns are seeded from env-ref names and a generic denylist, never from real secret values.
- [ ] Redaction is tested with planted fake-secret fixtures proven scrubbed.
- [ ] The morning report (DF-07) embeds only redacted content; raw logs stay local by default.

## Locked-debate flags
- Telemetry backend: keep the spec's pin; otherwise default local-only, and treat any remote sink as a spec-change request.

## Generalization notes
Safe, high-value pattern: redact-at-emission plus planted-secret fixture tests. Publishable; the denylist itself must stay generic.
