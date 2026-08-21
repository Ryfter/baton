# DF-05 — Acceptance-criteria verifier

Status: SCAFFOLD. Done-ness definition defers to the LOCKED spec wherever they differ.

## Goal
Machine-check each item against the exact ACs embedded at intake (DF-03); anything not machine-checkable routes to a human-review list in the morning report instead of being self-attested.

## Acceptance criteria
- [ ] Verifier output is machine-readable: per-AC pass/fail/unverifiable, with evidence pointers (test names, file paths, command-output refs).
- [ ] An item is done only when every AC passes; any fail, or unverifiable-without-human, marks it blocked-for-review.
- [ ] Verifier runs are hermetic (same inputs, same verdict) and re-runnable from artifacts alone.
- [ ] Self-attested completion without evidence is recorded as fail.

## Locked-debate flags
- Never soften ACs to make them pass; changing an AC is a brief edit that invalidates the queue item (DF-03) and is a human, daytime decision.
- If the LOCKED spec defines done-ness differently, the spec wins.

## Generalization notes
Safe pattern: acceptance-gated completion, evidence pointers, no self-attestation. Core publishable pattern; no secrets.
