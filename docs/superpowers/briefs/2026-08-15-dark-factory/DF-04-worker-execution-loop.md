# DF-04 — Worker execution loop (sandboxed)

Status: SCAFFOLD. Sandbox and allowlist defaults must match the LOCKED spec.

## Goal
Execute queued items in isolation with enforced budgets, an egress allowlist, and artifacts written only to designated locations.

## Acceptance criteria
- [ ] No network egress beyond the configured allowlist; violations are blocked and logged (redacted).
- [ ] Per-item time and cost budgets from fleet config are enforced; exhaustion marks the item failed, not hung.
- [ ] Artifacts are written only to the run's designated directory; writes elsewhere fail the item.
- [ ] A crashed worker's item retries at most once (poison-item counter prevents infinite retry).
- [ ] Worker logs are structured and stream to DF-06 for redaction; no plaintext secret reaches disk.

## Locked-debate flags
- Sandbox technology and allowlist contents: keep the spec's pins; widening the allowlist is a spec-change request, never a PR.
- No interactive/human-in-the-loop hooks; dark-factory means unattended.

## Generalization notes
Safe pattern: allowlist egress, hard budgets, poison-item counters, artifacts-in-designated-dir-only. Publishable generically.
