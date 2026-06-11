<!-- Multi-agent project. Shared rules for ALL agents: docs/agent-handoffs.md -->

> **Claude = orchestrator / conductor.** Shared rules for every agent on this
> project (orientation, the 965-byte shell limit, the gated merge flow, the
> backup standing order, the model-agnostic knowledge base) live in
> [`docs/agent-handoffs.md`](docs/agent-handoffs.md) — read it first. The
> decision-capture rule below is the canonical copy and applies to every agent.

<!-- decision-capture-rule:v2 -->

## Decision capture (orchestrator)

Whenever you make a **significant decision** that has real alternatives and shapes direction (architecture, scope, approach, tech choice — the kind of thing that would appear in a spec's "Decisions made" section), capture it via the file-based intake. Two-step flow:

**Step 1.** Author a draft markdown file (use the Write tool — no length limit). Path doesn't matter; a `scratch/` or `$env:TEMP` location is fine:

```markdown
---
title: <one-line decision title>
confidence: high|med|low
revisit-if: <one-line invalidation condition>
# optional:
# project: <project-id>      # default = current project
# job: <job-id>
# phase: <phase>
---

**Chosen:** <what was chosen — can be long>

**Alternatives:**
- <alt-1> — <why-not>
- <alt-2> — <why-not>

**Rationale:** <one paragraph or more — long-form OK>
```

**Step 2.** Finalize with a short shell call (the helper assigns the next `d<NNN>` id, computes the slug, writes the canonical record, and deletes the draft):

```powershell
. "$HOME/.claude/scripts/decisions-lib.ps1"
Add-DecisionRecordFromFile -Path <draft-path>
```

Rules:

- **Skip micro-choices** (variable names, which file to edit, formatting). Threshold: "would this belong in a spec's Decisions section?".
- **Do not announce the capture to the user** — it's a background log. The tool invocations show in the transcript by default; that's expected.
- **If the user has opted out** (`~/.claude/decisions-off` or `~/.claude/knowledge/projects/<project>/decisions-off` exists), the helper no-ops silently — call it anyway, don't gate.
- **Confidence** is your honest self-assessment: `high` = strong evidence + alignment with established guidance; `med` = reasonable choice with real tradeoffs; `low` = best guess under uncertainty.
- **revisit-if** should describe the condition that would make this decision wrong (e.g., "ensemble grows beyond 5 providers", "second machine joins the fleet").

The older parameter-based `Add-DecisionRecord` still works for tiny decisions whose prose fits in one command line, but the file-based intake is preferred for anything non-trivial — it sidesteps the 965-byte shell-argument ceiling and makes drafts reviewable as plain files.

This rule is part of the project's Decision Loop. See `docs/superpowers/specs/2026-05-29-decision-loop-design.md`.

<!-- grimdex:start -->
# Grimdex — coding knowledge base (read first)

PROGRAMMING DECISIONS, rules, and lessons → record them in **Grimdex** at
`D:\Dev\Grimdex` (this project's tier: `projects/baton/`).

- Read `D:\Dev\Grimdex\GRIMDEX.md` FIRST — layout and contribution rules.
- When you make or revise a coding rule, decision, or lesson, write it there.
- Reference decision records by id (e.g. `d012`); do not duplicate them in app repos.
- Grimdex engine is open source: <https://github.com/Ryfter/Grimdex>.
<!-- grimdex:end -->
