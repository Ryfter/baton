# Review Named Panel — Design

**Date:** 2026-07-13 · **Status:** design approved (Kevin), ready for an implementation plan
**Decisions:** coding-first ([d085]); the acceptance node of the golden-path spine, fail-loud on the default path ([d086])
**Extends:** `scripts/gate-lib.ps1` (`Invoke-AcceptanceGate`) — a layer, not a rebuild.

## Problem

Today every reviewer in the acceptance gate gets the **same generic** "strict reviewer" prompt
(`Build-ReviewPrompt`). There is no role specialization — no security lens, architecture lens, etc.
The panel makes the reviewer axis a **roster of named roles** (each a specialized lens), each routed
to the cheapest capable model, reusing the gate's existing merge / verdict / polish-brief machinery.
Per [d086] this panel is the **acceptance node** of the default golden ship path.

## Goal

A fixed, config-driven roster of specialized review-role personas run per diff/artifact, each routed
to the cheapest *capable* model; findings carry role provenance and flow through the existing
dedupe → `agreed` → critical/important/minor verdict → polish brief unchanged.

## Non-goals (YAGNI — deferred to v2 with concrete triggers)

- **Per-finding confirm pass on criticals** — deferred; *trigger to revisit:* solo criticals prove
  noisy in practice (a named panel weakens `agreed` corroboration because roles use distinct lenses).
- **Hard reviewer≠author rule** — deferred; *trigger:* the authoring instrument routes to a review
  role for its own output and self-review misses show up.
- **Parallel resolve / fixing** — out of scope; that stays `/baton:go`'s labor.
- **Non-coding artifact types** — out of scope (coding-first, [d085]).

## Architecture

### 1. Roles roster (config-driven)

A new `review-roles.yaml` under `$BATON_HOME` (parsed with the existing hand-rolled YAML approach,
parallel to `fleet.yaml`/`tools.yaml`). Each role:

```
- name: <short id, e.g. security>
  lens: <the specialized reviewer instruction fragment>
  tier: cheap | strong        # judgment roles = strong; mechanical = cheap
  enabled: true
```

**Shipped coding defaults (6)** — GENERIC, no box-private model IDs (like the fleet seed):

| Role | tier | Lens (essence) |
|---|---|---|
| `correctness` | strong | Does it do what the task says, correctly? Logic/edge-case defects. |
| `security` | strong | **Adversarial** — *try to break it*: authz, injection, secret/tenant leakage, unsafe I/O. |
| `architecture` | strong | Boundaries, coupling, does it fit the existing patterns. |
| `spec-compliance` | strong | Artifact vs. the **original intent** — flag *under-building* / missed requirements. |
| `simplicity` | cheap | Unneeded complexity, dead code, over-engineering. |
| `framework-style` | cheap | Idiom, naming, project conventions. |

### 2. Role-aware prompt

`Build-ReviewPrompt` gains a `-Role` (name + lens); the lens is injected ahead of the existing
strict-JSON findings schema. The task + artifact are unchanged. One prompt per role.

### 3. Reviewer selection: roles → models

Reviewer axis shifts from "N providers, one generic prompt" → "the roster of enabled roles → a model
each." Each role is dispatched to its cheapest capable model via the existing `Select-Capability`
constrained by the role's `tier` (strong ⇒ capable at the higher tier; cheap ⇒ local/free capable).
Judgment roles naturally pull a stronger model with **no special mechanism** — it falls out of
cheapest-capable + the tier hint. A model may serve several roles.

### 4. Findings, merge, verdict — reuse

Each finding gains a **`role`** provenance (reuse the existing `area` field; `area` = role name).
Everything downstream is **unchanged**: `Get-FindingKey` dedupe, `Merge-ReviewFindings` (`agreed`
when ≥2 roles concur), `Get-AcceptanceVerdict` (critical/important/minor → reject/polish/accept),
`Format-PolishBrief`, `Format-GateReport`.

### 5. Fail posture ([d086])

- **Standalone / advisory `/baton:gate`:** fail-open unchanged (no usable review → accept, advisory).
- **As the golden-path acceptance node:** **fail-LOUD** — if the panel is degraded (roles missing a
  capable model, all reviewers unparsed), the ship path surfaces a loud "acceptance degraded" state
  rather than silently accepting. (The exact loud-signal wiring belongs to the golden-path spine spec;
  this spec exposes a `-FailLoud` switch / a degraded flag on the result for the spine to consume.)

## Wiring

- `/baton:gate` gains a **panel mode** (`--panel`, or panel becomes default when `review-roles.yaml`
  exists) selecting the roster instead of generic reviewers.
- `/baton:go`'s acceptance call uses the panel as its **default** acceptance node ([d086]).

## Error handling / edge cases

- No `review-roles.yaml` → fall back to today's generic competitive review (backward compatible).
- A role whose `tier` yields no capable model → that role is skipped, recorded in the degraded set
  (contributes to fail-loud on the golden path; ignored under advisory fail-open).
- Prompt-echoing providers → already handled by `Get-ReviewFindings` (unchanged).
- 965-byte rule → prompts ride the existing stdin-safe provider path (unchanged).

## Testing

Extend `scripts/test-gate-lib.ps1`: role-aware prompt injects the lens; roster parse (+ malformed
role rejected); findings carry role provenance; a strong/cheap role selects the expected tier via a
stubbed `Select-Capability`; degraded-role path sets the degraded flag; backward-compat (no roster →
generic path). Pure functions stay dispatcher-injected; no real `~/.baton`.

## Decisions made

- Layer on `Invoke-AcceptanceGate`, reuse merge/verdict/brief (not a new subsystem).
- Config-driven roster shipping 6 generic coding roles; box-private model IDs never in the seed.
- Keep `critical/important/minor` (map P1/P2/P3 onto it); `role` reuses `area`.
- Fail-loud only as the golden-path node ([d086]); advisory use stays fail-open.
- Confirm-pass, reviewer≠author, resolve, non-coding types → v2 with the triggers above.

## v2 backlog

Confirm-on-critical (second-model) · reviewer≠author exclusion · non-coding artifact types + role
packs (the general-conductor seam, [d085] — low priority).
