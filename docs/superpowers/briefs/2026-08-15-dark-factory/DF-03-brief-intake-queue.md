# DF-03 — Brief intake and work queue

Status: SCAFFOLD. Queue technology choice must follow the LOCKED spec if pinned.

## Goal
Turn per-slice briefs (DF-*.md in this directory) into queued, runnable work items, each embedding its acceptance criteria verbatim, so DF-05 verifies against the same text humans reviewed.

## Acceptance criteria
- [ ] Each queued item embeds: brief id, goal, AC list, dependencies, and the config hash of the enqueuing run.
- [ ] Items with incomplete dependencies are never dispatched.
- [ ] Queue is durable (survives restart) and idempotent (re-enqueue of the same brief id does not duplicate work).
- [ ] Brief text is content-addressed; editing a brief after enqueue invalidates the item rather than silently changing scope mid-run.

## Locked-debate flags
- No second intake path (manual dispatch, ad-hoc scripts); the front door is the only entry.
- Queue technology: keep the spec's choice if pinned; otherwise pick the simplest durable option and record it as a new decision, not a reopened one.

## Generalization notes
Safe pattern: briefs are the contract; queue items embed the ACs they will be judged by. No secrets; publishable.
