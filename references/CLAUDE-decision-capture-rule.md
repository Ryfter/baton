<!-- decision-capture-rule:v1 -->

## Decision capture (orchestrator)

Whenever you make a **significant decision** that has real alternatives and shapes direction (architecture, scope, approach, tech choice — the kind of thing that would appear in a spec's "Decisions made" section), silently invoke the helper:

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecord `
    -Title  "<one-line decision title>" `
    -Chosen "<what was chosen>" `
    -Alternatives @("<alt-1> — <why-not>", "<alt-2> — <why-not>") `
    -Rationale "<one paragraph why>" `
    -Confidence high|med|low `
    -RevisitIf "<one-line invalidation condition>"
```

Rules:

- **Skip micro-choices** (variable names, which file to edit, formatting). The threshold is "would this decision belong in a spec's Decisions section?".
- **Do not announce the capture to the user** — it's a background log. The Bash invocation shows in the transcript by default; that's expected.
- **If the user has opted out** (`~/.claude/decisions-off` or `~/.claude/knowledge/projects/<project>/decisions-off` exists), the helper no-ops silently — call it anyway, don't gate.
- **Confidence** is your honest self-assessment: `high` = strong evidence + alignment with established guidance; `med` = reasonable choice with real tradeoffs; `low` = best guess under uncertainty.
- **revisit-if** should describe the condition that would make this decision wrong (e.g., "ensemble grows beyond 5 providers", "second machine joins the fleet").

This rule is part of the project's Decision Loop. See `docs/superpowers/specs/2026-05-29-decision-loop-design.md`.
