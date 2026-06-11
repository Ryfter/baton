# Overnight Capability Floor-Finder — Design (general)

**Status:** Design sketch (general). **Not a must-have** — captured so the thinking
isn't lost; promote to a full spec → plan when it's picked up. 2026-06-10.

**Goal:** An unattended, surge-paced harness that measures, across the fleet, *the
smallest/cheapest model that can reliably finish a small coding atom by iterating
against a test* — and emits the result as routing-grade data. Run while Kevin sleeps;
stop at token budget or dawn.

**One-line thesis:** Turn "how small/prescriptive must an atom be for a local model to
finish it?" from a guess into a measured surface — empirical input to the draft→finish
cascade (Engine Slice B) and finer-grained fuel for the routing learning loop.

---

## Why

The whole cost-optimization endgame (d026) rests on offloading small coding atoms to
cheap/local models and reserving frontier tokens for planning + verification. The open
question is the **capability floor**: which model can finish which *kind* of atom, at
which *level of specification*, within a bounded debug loop. Today that's a guess. This
harness measures it, unattended, as a recurring job — so the cascade is designed on data,
not intuition.

It also closes two existing loops:

- **First consumer of the prime-hours surge.** Slice A's `Get-CapacityProfile` computes a
  weekend/off-peak `concurrency_factor` that nothing consumes yet (flagged as a review
  nit). An overnight queue-drainer running at surge concurrency is exactly what that hook
  was built for. Overnight = off-peak = surge = run more.
- **Finer-grained routing data.** Each result is a row in the same GitHub-backed
  `(capability × candidate) → quality` dataset the router already learns from (d028/d029),
  at function-*type* granularity. The floor-finder is the routing loop's data generator.

## Non-goals

- Not a leaderboard or a research paper. The output is *operational* tuning data for our
  own atomizer/cascade, not a published benchmark.
- Not the cascade itself (that's Slice B) — this measures the inputs the cascade needs.
- Not a human-graded eval. The oracle is a deterministic test; zero human attention.

---

## The matrix

The harness sweeps a 3-axis grid and records, per cell, **pass@k-with-debugging** (the
model sees each failing test's error and fixes — *not* blind retry), plus avg attempts and
tokens spent.

| Axis | What it varies | Default buckets |
|---|---|---|
| **Model** | the capability/cost curve (want the curve, not one point) | local fleet (e.g. qwen-coder sizes, devstral) + Haiku as a cheap-paid reference + a frontier "gold" anchor |
| **Function type** | a 20-line parser ≠ a 20-line DP ≠ 20 lines of error-handling | transform · algorithmic · stateful/IO · API-glue · numeric · edge-case-heavy (~6 coarse; refine later) |
| **Spec level** (the "how much how" dial) | the actionable axis — how much hand-holding the atom carries | test-only · test+signature · test+pseudocode |
| **Attempt budget** | does iteration help, or do small models plateau at try ~2? | success as a *function* of N attempts (cap N) |

**Output is a fitness surface:** `(model, function-type, spec-level) → P(green within N) +
avg-attempts + tokens`. From it you read off (a) the floor — cheapest model clearing a
chosen bar per function type; (b) the per-cell spec-level the atomizer should emit; (c)
where iteration is wasted → an escalate-early signal.

---

## Architecture (components)

1. **Atom bank** — a corpus of `{ id, function-type, signature, hidden test, optional
   pseudocode, source }` benchmark atoms. The upfront build (see *Benchmark source*).
2. **Runner** — for each (atom × model × spec-level): construct the prompt at that spec
   level, dispatch to the model via the existing fleet/routing dispatch path, run the test,
   and on failure feed the error back for up to N attempts (the **iterate-debug loop**).
   Reuses the routing escalate primitive; the new piece is *loop-until-green* (today's
   dispatch is one-shot per candidate).
3. **Oracle** — the atom's hidden test (`pwsh`/`pytest`), run in isolation. Deterministic,
   fast, the only correctness signal. The model never sees the test body unless the
   spec-level says so — only the pass/fail + error text.
4. **Scheduler / pacer** — unattended driver that consumes `Get-CapacityProfile` to size
   max-parallel (surge → more), drains a work queue, and **stops at token budget or a
   configured wake time**. Writes progress to the runs feed for the morning read-out.
5. **Recorder** — appends each cell result to a results store (routing-grade JSONL), and a
   morning **summary report** (the surface, the floors, surprises).

## Benchmark source (the key fork)

**Recommended default: harvest our own tested code + a small standard anchor.**

- **Harvest** — every function in our repos that has a test is a ready-made atom: strip the
  impl, keep `signature + test`, task = "reconstruct." Domain-relevant (our PowerShell +
  FastAPI/Python idioms), free, effectively infinite. This is what we *trust*.
- **Anchor** — a small slice of a standard set (HumanEval/MBPP) to sanity-check our numbers
  against published pass@k. This is what makes the numbers *legible*, not what we trust.

**Contamination is the #1 way this lies to you.** If a model trained on our public repos or
on the (notoriously leaked) standard sets, "reconstruct" overstates real capability.
Mitigations, designed in from the start: prefer private/recent code; mutate atoms (rename
symbols, tweak a requirement) so memorization ≠ success; track source so contaminated cells
are flagged, not silently trusted.

Alternatives considered: *standard-set-only* (comparable but heavily contaminated, not our
idioms); *synthesize-fresh* (clean, but labor-heavy and may not reflect real work).

---

## Data + connections

- **Result schema (sketch):** `{ ts, atom_id, function_type, model, spec_level, attempts,
  passed, tokens_in, tokens_out, source, contamination_flag }` → append-only JSONL in the
  GitHub-backed knowledge store, alongside `routing-ratings.jsonl`.
- **Feeds the router:** these rows refine `Get-CapabilityQuality` at function-type grain.
- **Feeds Slice B (cascade):** the per-cell spec-level + floor tell the atomizer how
  prescriptive to be and which tier to draft on for which work.
- **Dogfoods Slice A:** consumes the surge profile; runs in the off-peak window the gate
  already classifies.
- **Conductor/Fleet (d035):** this *is* the Fleet doing grunt work overnight while the
  Conductor/Orchestrator sleep — a clean fit for the 3-tier model.

## Open questions (resolve at promote-to-plan time)

- Benchmark source mix + contamination handling (default above; confirm).
- Function-type taxonomy granularity (start coarse ~6; let data suggest splits).
- Attempt cap N and per-attempt context budget (small models run out of context holding
  error+code — size atoms with headroom).
- Where the iterate-debug loop lives: extend `routing-dispatch.ps1` with a loop-until-green
  mode, or a sibling harness that calls the dispatch primitive in a loop.
- Wake-time / budget config: reuse `prime-hours.yaml` windows, or a dedicated job config.

## Out of scope

- The draft→finish cascade (Slice B). The advisor (cost/speed dials). The autonomous
  run-loop. Per-prompt similarity. This harness only *measures the floor and emits data.*
