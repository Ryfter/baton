---
name: baton-layers
description: >-
  Enforces Baton layer seating and TOKEN BUDGET. Ox Alpha + Grok 4.6 for labor;
  Opus for regular sprints; Fable ≤1/hour for sprint bundles; Codex/Grok review
  if under 40% usage. Use when choosing models or Maestro roles.
disable-model-invocation: false
---

# Baton layer seating + token budget

## Auto-route (first step on any ask)

On any user message that names a project or asks for work:

1. `~/.baton/overnight/bin/ensure-conductors.sh`
2. Resolve project id → attach task to running Conductor job → fan Orchestrators
3. **Never** ask Kevin to spawn Conductors, serialize projects, or pause Baton

See `docs/maestro-autoroute.md` and `~/.baton/overnight/LAYER-SEATING.md`.

## Default burn

1. **Ox Alpha** — mouth, conductor, grunt, verify
2. **Grok 4.6** — coding / agentic (+ review if usage &lt; 40%)
3. Weaker/free — research / writing
4. **Codex** — agentic / review if usage &lt; 40%

## Sprint seats

- **Opus 5** — regular sprint orchestration
- **Fable** — bundle-of-sprints gate only; **≤ 1 pass per hour**; re-reviews allowed but sparingly (Kevin-limited credits)
- Do **not** Fable every sprint or stack Fable inside the hour

Live policy: `~/.baton/overnight/LAYER-SEATING.md`

## Load Grimlore (before planning)

Context layer repo: `/Users/kev/Dev/Grimlore` (private). **Explains** why/who/environment — never prescribe.

1. Read `projects/<id>/` for the active project (`baton`, `answerbot`, …) plus `universal/environment/` and `universal/models/` when seating matters.
2. Prefer `projects/baton/BATON.md` as the Baton load brief.
3. **Ask First** before treating agent drafts as verified (`generated:` without `verified:` is a claim).
4. **Never** paste private Grimlore bodies into Ox Alpha / OpenRouter prompts — structure-only or non-secret fleet-map facts only.
5. Quality → draft proposals: `~/.baton/overnight/bin/propose-grimlore-fold.sh` (writes under `grimlore-proposals/`, not auto into the repo).

## Efficiency Officer (token-saver built in)

Before large instrument prompts, Conductor runs `efficiency-lib.ps1` (fail-open). Manual: `/baton:efficiency select …`. Skill: `.cursor/skills/baton-efficiency/`. Octopus zip skill is **deprecated**.

## Scope (`baton-d108`)

Maestro = code · Mouth/Conductor = Ox Alpha · Orchestrator = Opus · Instruments = Ox/Grok first
