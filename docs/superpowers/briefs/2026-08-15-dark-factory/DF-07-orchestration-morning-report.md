# DF-07 — Overnight orchestration and morning report

Status: SCAFFOLD. Slice ordering and gating must be reconciled with the LOCKED front-door flow.

## Goal
Sequence slices for an unattended run, checkpoint progress for resume, and produce a morning report a human can act on in minutes.

## Acceptance criteria
- [ ] Runs checkpoint after each slice; a crash resumes from the last checkpoint without redoing completed slices.
- [ ] Morning report contains, per slice: status (done/blocked/failed), AC verdict summary from DF-05, artifact index, and any spec-change requests or locked-debate risks.
- [ ] Any condition requiring a locked decision to change halts affected slices and escalates in the report; it does not improvise.
- [ ] Report is redacted per DF-06 and written only to the designated location.
- [ ] A full dry-run mode (no external effects) exists and is exercised in CI.

## Locked-debate flags
- Follow the LOCKED spec's front-door flow for ordering and gating; this brief's dependency order is provisional.
- No autonomous spec-amendment behavior under any circumstances.

## Generalization notes
Safe pattern: checkpoint-per-slice, exception-based escalation, one-page morning report. Publishable generically.
