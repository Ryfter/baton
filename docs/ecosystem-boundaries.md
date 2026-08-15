# Baton's place in the Grimdex ecosystem

**Date:** 2026-08-14 · **Status:** authoritative for Baton's scope boundaries

Baton is one of three layers. This page states what that means *for Baton* — what Baton
owns, what it must not absorb, and where to send things that don't belong here.

**Canonical brief (source of truth, lives in the public Grimdex engine repo):**
`D:\Dev\Grimdex-engine\docs\2026-08-14-grimdex-ecosystem-architecture.md` ·
<https://github.com/Ryfter/Grimdex/blob/main/docs/2026-08-14-grimdex-ecosystem-architecture.md>

If anything here conflicts with that brief, the brief wins.

## The Law

> **Bloat is the enemy of Grimdex. Context is the purpose of Grimlore. Execution is the
> purpose of Baton.**

**Grimdex governs *how*. Grimlore remembers *why*, *who*, and context. Grimdex Baton
determines *what happens next* and executes it.**

## The layer inventory

| **Grimdex** — rules | **Grimlore** — context | **Baton** — action |
|---|---|---|
| conventions · lessons · rules | design · rationale · history | **orchestrate · execute · route** |
| schemas · gates · standards | environment · user · company | **build · test · verify · deploy** |
| validation · security guidance | audience · hardware · models | **agents · models · workflows** |
| project rules → universal rules | research · project knowledge | |

**A layer is defined by the question it answers, not the nouns it touches** — so the same noun
appears in more than one column. Both overlaps are Baton's to get right:

### `models` span all three layers

| Layer | Question | Baton's example |
|---|---|---|
| **Grimlore** | *What is it?* | The fleet roster as **knowledge**: which models exist, their context windows, availability, standing observations. |
| **Grimdex** | *What are the rules for using it?* | Spend ceilings, which depth tier is permitted at which stakes, what may never be routed off-box. |
| **Baton** | *How do I use it?* | Selection, routing, CLI flags, retries — **and enforcing Grimdex's rules at dispatch.** |

**Grimdex writes the spend rule; Baton enforces it.** The usage governor, cost meter, pre-flight
quota probe, depth policy, and `max_cost_tier` ceiling are **runtime machinery and stay in
Baton** — they are not moving to Grimdex. What Grimdex owns is the *constraint* those mechanisms
implement. Grimdex prescribes and never runs anything; that is the Law.

Practical read for Baton: `fleet.yaml`'s roster facts are Grimlore-shaped knowledge, the policy
they're checked against is Grimdex-shaped, and every line of code that does the checking is
Baton's and stays Baton's.

**Paired policy — and Baton holds ground truth (`grimdex:d022`).** Quota rules ("use up to 50% of the
Codex window, 100% on its last day") are *deliberately* duplicated: Grimlore documents the policy
with its reasoning, Grimdex carries the enforceable rule, Baton enforces at dispatch. The halves
are bound by a shared `policy_id` and reconciled by the weekly KB audit rather than by memory.

⚠️ **The numbers in `~/.baton/fleet.yaml` are the only copy that governs behavior.** When a soft
cap, `usage_policy`, or depth policy changes here, the paired Grimlore concept and Grimdex rule
are stale until updated — and the audit checks the prose *against Baton*, not prose against
prose. Never treat a documented number as authoritative over the running config.

### `gates` / `validation` (Grimdex) vs `test` / `verify` (Baton)

Grimdex **defines** the gate and the standard; Baton **runs** it. This is already how Baton's
quality gates work — the division is intentional, not accidental, and it is the same shape as
the spend rule above.

### `project rules → universal rules`

Two content types **and** the gate between them: a project rule is content in its own tier until
the promotion gate is tripped and it becomes a universal rule. Baton's own d-records live in the
project tier (`grimdex-know` → `projects/baton/`) and may be promoted upward from there.

## What Baton owns

Baton is the **action/orchestration layer** — where motion happens. It consumes the
governing framework (Grimdex) and the relevant durable context (Grimlore), then coordinates
and executes:

- Coding and edits.
- Agent/model/tool orchestration and routing.
- Task sequencing and workflow state.
- Testing, verification, review, and security checks **as required by Grimdex governance**.
- Movement from *objective → work → checked result → delivery*.

That is the existing golden path (`d086`), restated in ecosystem terms: `/baton:go` is
Baton's execution of the "what happens next, and when" mandate.

## What Baton must NOT absorb

This is the load-bearing half. Baton *discovers* rules and context constantly while
executing — that is exactly why it is tempting, and wrong, to keep them here.

| Baton discovers… | It belongs in… | Why |
|---|---|---|
| A rule about how future coding work should be done | **Grimdex** (`projects/<id>/` → promotions) | Baton is not the permanent home for durable rules. |
| Why a decision was made, who the work serves, environment/hardware/audience facts | **Grimlore** | Baton is not the permanent home for long-term context. |
| An application's own subject-matter knowledge | **The application** (per `d009`) | Domain KB is the app's, not the harness's. |

> **Do not let Baton become the permanent home for durable rules or long-term context
> simply because it discovers them during execution.**

The inverse also holds: **do not turn Grimlore into an execution engine.** If something
must *happen*, it is Baton's, full stop.

## The boundary test

When a new Baton feature is proposed, classify it first:

1. Does it change **HOW** coding work should be done? → that's a **Grimdex** rule; Baton
   may *enforce* it, but it doesn't *own* it.
2. Does it explain **WHY** something exists, **WHO** it's for, or surrounding **CONTEXT**?
   → **Grimlore**.
3. Does it decide **WHAT** happens next / **WHEN**, or require **ACTION**? → **Baton**.
   Build it here.

*Grimdex prescribes. Grimlore explains. Baton acts.*

Note the asymmetry in #1: Grimdex "defines expectations for how work is coded, checked,
and secured without trying to become every tool that performs those checks." Baton **is**
one of those tools. Scanners, linters, test runners, and review panels are *invoked and
enforced by* Grimdex rules and *executed by* Baton — that division is intentional and
already how Baton's gates work.

## Interaction model

> Grimdex tells Baton **how** work must be performed. Grimlore gives Baton the durable
> context to understand **why** the work exists, **who** it serves, and the environment
> around it. Baton then **executes**. No layer becomes bloated middleware.

**Open — do not overcommit:** query routing. Baton needs access to relevant Grimdex
guidance *and* Grimlore context, but whether it queries both directly or goes through a shared
context-loading mechanism is an open implementation question. Do not build one in on
assumption. (Note: today Baton reaches Grimdex via plain file paths + the pointer stanza,
and Grimlore does not exist yet, so nothing forces the question.)

## Project isolation

An agent working on Project A must not casually receive Project B context. Baton's default
context load is:

```
universal Grimdex guidance + Project A Grimdex guidance
  + relevant universal Grimlore context + Project A Grimlore context
```

Cross-project retrieval does not happen just because Baton *can* see everything. Knowledge
crosses a project boundary only through deliberate, provenance-backed promotion.

## Naming

**The context layer is Grimlore**, renamed 2026-08-14 from the source brief's "Grimdex Wiki."
Grimdex had already reserved the name *Grimlore* for a future general second-brain KB; the
reservation is spent on this role. Grimlore is a **sibling** of Grimdex, not a component of it —
`Grimdex` (rules) / `Grimlore` (context) / `Baton` (action). For Baton, the practical effect is
vocabulary only: it consumes a context layer either way.

**"Grimdex Baton" is the working name and is not frozen.** Government/company metaphors (a
chief-of-staff/orchestrator role) remain conceptual possibilities. The musical model
(conductor / orchestrator / instrument, `docs/glossary.md`) is Baton's *internal* vocabulary
and is unaffected either way. **Do not rename anything unless explicitly asked.**

⚠️ **"Rules layer" is Grimdex's position, not its contents.** Decisions and lessons stay in
Grimdex — they are the evidence its rules are built from. A decision record's *Rationale* is the
*why behind a rule* (Grimdex's); the *why behind the work* — purpose, audience, environment — is
Grimlore's. **Baton's decision-capture rule is unchanged:** d-records keep going to
`grimdex-know` at `projects/baton/decisions/`, not to Grimlore.

## Assumptions to discard

- **Open Brain / AWS is not part of this architecture branch.** Do not let it shape Baton's
  design decisions unless explicitly reintroduced.
- **Grimdex-Know is not an architectural peer** and not a knowledge service Baton talks to.
  It is a private, personalized Grimdex instance — for this rig, the repo behind
  `D:\Dev\Grimdex`. Baton reads *Grimdex*; whose instance it is, is not Baton's concern.
- The public Grimdex repo is **not** anyone's personal knowledge store.

## Related

- [`docs/glossary.md`](glossary.md) — the ecosystem terms are defined at the top.
- [`docs/DECISIONS.md`](DECISIONS.md) — Baton's decision log; `d033` (Grimdex ↔ Baton mutual
  independence) and `d086` (the golden path spine) are the load-bearing prior art.
- Grimdex-tier decision records — `grimdex:d018` (three-layer boundary + the Grimlore rename),
  `grimdex:d019` (Grimdex-Know is not a peer), `grimdex:d020` (how this entered `GRIMDEX.md`),
  `grimdex:d021` (OKF adoption), `grimdex:d022` (paired policy) — in the private
  instance, `projects/grimdex/decisions/`.
