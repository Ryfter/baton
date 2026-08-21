# DF-01 — Front-door entrypoint

Status: SCAFFOLD. Verify command name, flags, and exit codes against the LOCKED spec before coding.

## Goal
Provide the single supported entrypoint that boots a dark-factory run exactly as the LOCKED maestro front-door design specifies. No other path may start an overnight run.

## Non-goals
- Changing the front-door contract (LOCKED).
- Worker internals (DF-04).

## Dependencies
- DF-02 (validated fleet config) before first end-to-end run.

## Acceptance criteria
- [ ] The locked front-door command with a valid config starts exactly one run and writes a run manifest (run id, config hash, slice list, start time).
- [ ] Missing or invalid config exits nonzero with an actionable error and starts nothing.
- [ ] A concurrent second invocation on the same run id is refused (single-flight lock).
- [ ] Any behavior differing from the LOCKED spec is a defect, not a feature.
- [ ] No secrets in the manifest or stdout (DF-06 patterns apply).

## Locked-debate flags
- No alternate CLIs, wrappers, or aliases for the front door.
- No flags beyond the LOCKED spec; needs become spec-change requests in the morning report.

## Generalization notes
Safe pattern: one locked front door plus run manifest plus single-flight lock for any unattended agent fleet. Strip org-specific names before publishing.
