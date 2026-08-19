# Local front door — bare `baton`, a mouth that cannot run out

**Date:** 2026-08-18
**Status:** design — not authorized to build until an implementation plan exists
**Audience:** any agent implementing the Baton front door
**Decisions:** `baton-d119` (the mouth must be unexhaustible), `baton-d120` (identifier-based placement + work-box exclusion), `baton-d121` (bare `baton`; STT-only voice)
**Supersedes (in part):** `baton-d108` — its own `revisit-if` fired (the Mac mini now runs work concurrently with the PC)
**Extends:** `docs/superpowers/specs/2026-08-15-maestro-front-door-design.md` (job record, layers, admission)
**Companions:** `~/.claude/knowledge/projects/baton/design-notes/2026-08-15-code-factory-architecture.md`

---

## Problem

Every conversational surface in Baton is a **prompt that Claude Code executes**.
`start-lib.ps1` — the front porch with interview depth, charter, style journal — is
pure resolvers and JSON stores. The talking is Claude's job. `baton go` is one-shot:
goal in, report out, no turns. `verbs.yaml` says it outright: *"interactive skins like
start/init are out of scope."*

So when Claude's 5-hour window empties — or worse, the 7-day allotment — the **engine is
fine**. Codex, Grok, OpenRouter and every LM Studio model still dispatch. What dies is the
only mouth. Kevin cannot use Baton, not because the factory stopped, but because nothing
is left to talk to.

This is a smaller problem than "make Baton work without Claude." The factory already works
without Claude. What is missing is **a process that holds a conversation**.

## Goal

Typing `baton` — no subcommand — starts a conversation with a model that **cannot be
exhausted**, shapes a long dump into a job, fires `baton go --execute`, and narrates what
happened. With Claude at 0% for seven days, this still works.

## The load-bearing property

**The mouth must be unexhaustible.**

Everything else in the factory may run out — that is what the failover walk (PR #189)
exists for. The front door may not. If the thing you talk to can hit 0%, nothing has been
fixed.

Every decision below follows from that sentence.

## Non-goals

- **TTS.** Baton's output is diffs, status tables, verdict rows, PR links — worse spoken
  than read. Away-from-desk status is a *notification* problem, not a speech one.
- **Wraith2.** 8 GB caps it below any role in this design; it is already disabled as
  `ollama-box2` for the same reason. Identifier-based placement means adding it later is
  one more load target, not a redesign.
- A web page, a Buzz seat, Gantt/Kanban, training, durability past reboot. All still
  governed by the 2026-08-15 front-door spec.
- Merging without Kevin's word.

---

## 1. Where the mouth sits

The four layers of `baton-d108` are unchanged. The mouth is **Conductor's talk surface** —
the layer that was always specified as "allowed to be chatty," but whose only
implementation was Claude Code.

Maestro stays silent and deterministic. The 2026-08-15 spec forbids a chatty Maestro
because *"it would spend tokens to decide when to spend tokens."* That rationale is about
**quota**. A local model spends none and cannot be exhausted, so the ban does not reach it.
Nothing here makes Maestro chatty.

## 2. `converse` — a capability, not a hardcoded model

A new capability claim, declared in `fleet.yaml` like any other:

```yaml
capabilities: [converse, judge, extract-json]
```

Routing for `converse` differs from every other capability in exactly one way:

> **Cost tiers `local` and `free` are preferred. A `paid` provider is never selected
> automatically — only via an explicit opt-in flag.**

Without that rule the router would cheerfully pick Claude for the front door and recreate
the problem. This is the mechanical expression of the load-bearing property.

Which model fills the role is the operator's choice, not Baton's. Kevin points it at
`gemma-4-12b-qat`; someone else points it at Kiro, ChatGPT, or a 4B on a Raspberry Pi.
Baton's job is to route, degrade honestly, and **report which tier answered** — never to
decide the roster.

## 3. Model placement — the device problem

This is the section most likely to be skimmed and most likely to cause an incident.

**LM Link is live across four devices** (`lms link status`): `Firefly` (this PC, RTX 5090),
`ITSCM-KRANK2` (work), `droid.local` (Mac mini), `Wraith2` (laptop). Remote models are
reachable **through `localhost:1234` as if local** — LM Studio routes internally. LM Link
is **account-based, not LAN-based**; a work machine on a corporate network joins the pool.

Three consequences, in order of severity:

### 3a. Bare model keys are ambiguous and can route work off-box

Ten LLM keys exist on more than one device, including the mouth candidate:

```
google/gemma-4-12b-qat    droid.local + ITSCM-KRANK2
google/gemma-4-31b        Firefly     + ITSCM-KRANK2
zai-org/glm-4.7-flash     Firefly     + ITSCM-KRANK2
nvidia/nemotron-3-nano    Firefly     + ITSCM-KRANK2
qwen/qwen3.5-9b           Firefly     + ITSCM-KRANK2
```

Per `lms load --help`, a multi-match resolves to *"the preferred device (if set), or the
first matching model."* No preferred device is set. Baton's prompts carry repo contents,
so an unlucky resolution processes personal source on an employer-managed machine.

**Requirement:** Baton never sends a bare model key.

### 3b. Placement is by identifier, not `base_url`

Models are loaded deliberately on a chosen device under a stable name, and addressed by
that name — per LM Studio's docs, *"the identifier can be used to refer to the model in
the API."*

```
lms load google/gemma-4-12b-qat  --identifier baton-mouth  --ttl 3600
lms load qwen/qwen3.5-35b-a3b    --identifier baton-coder   -c 65536
```

This **supersedes the `base_url` ≈ box assumption** baked into the fleet registry and the
saturation logic. Box identity now comes from `lms ls --json` → `deviceIdentifier`, which
the REST API omits entirely (`/v1/models` and the native `/api/v1/models` both lack it —
verified). A device-aware inventory pass is therefore a prerequisite, not a nicety.

### 3c. The work box is excluded by default

`ITSCM-KRANK2` is **never an automatic target.** Opt-in per run, explicit, logged. This is
a data-placement guard, not a performance one; it holds regardless of how Kevin resolves
the policy question for himself.

`lms link set-preferred-device` is set as a global backstop so that even an unguarded path
cannot drift onto it.

## 4. The conversation loop

### 4a. Trust boundary

> **The small model proposes. Deterministic code disposes. Kevin confirms anything that
> spends money or writes code.**

This is what makes a 12B safe in front of a code factory. The model is never trusted to
decide that work should start.

### 4b. Two call shapes, one model

| Call | History | Reasoning | Output |
|---|---|---|---|
| **Talk** | full conversation | on | prose |
| **Extract** | current brief only | **off** | strict JSON via `response_format: json_schema` |

Reasoning must be **off** for extraction. `gemma-4-12b-qat` reports
`reasoning.default: on`, and a thinking preamble breaking a strict-JSON parse is exactly
the June 2026 judge outage (`qwen3.5-9b`). The same trap, one slot over.

The model's *only* structured job is `{project, goal, stakes}`. Everything else it emits is
prose. Intent classification is a separate tiny strict-JSON call
(`chat | work | status | hold`), which small models do reliably.

### 4c. Flow

```
baton                       (no args)
  └─ resolve `converse` provider        (local/free preferred)
  └─ ensure placement                   lms ps → load baton-mouth if absent
  └─ precheck reachability              lms link status  (sub-second, see 4d)
  └─ resume last project, else ask which
  └─ loop:
       read from InputSource            (stdin now; STT later — see §6)
       talk call        → prose reply
       intent call      → chat | work | status | hold
       if work:  extract call → {project, goal, stakes}
                 SHOW the parsed job, confirm, then fire
       fire:     job record → baton go --execute
       narrate:  status, provider chosen, quota posture
```

`baton --help` and `baton verbs` keep the verb list. Every existing verb is untouched.

### 4d. Reachability must be prechecked, not timed out

`ollama-box2` carries `timeout_s: 180`. The #189 failover walk *would* route around a dead
box — after burning that timeout. For labor that is acceptable. For a conversation surface
it is fatal: three minutes of dead air before the mouth notices the Mac is asleep is worse
than never distributing at all.

LM Link makes this worse before it makes it better: because everything answers on
`localhost`, a sleeping device cannot be detected by connecting to a `base_url`. The
reachability signal is `lms link status` / `lms ps`, and it must be checked **before** the
turn, not discovered by timeout during it.

### 4e. Degradation

| Condition | Behaviour |
|---|---|
| droid.local unreachable | fall back to next `converse` candidate on Firefly; say so in one line |
| LM Studio down entirely | no conversation; `baton go --goal "…"` still works — print that plainly |
| every paid provider capped | **mouth still talks**, job queues as `waiting-quota`, fires at next window |
| Claude at 0% | irrelevant to the front door by construction |

The mouth never silently falls back to a paid provider. That is the property, enforced.

## 5. Job record

Unchanged from the 2026-08-15 spec — `$BATON_HOME/maestro/jobs/<id>.json` plus
`events.jsonl`. The loop is one more writer of the same record. It does not invent a
parallel store, and it does not bypass admission.

## 6. Voice — slice 2, behind a seam

STT is the high-value half and TTS is dropped (§Non-goals). The asymmetry is structural:
**input is prose, output is artifacts.**

One design constraint in slice 1 makes slice 2 additive rather than a rewrite:

> **The loop reads from an `InputSource`, never from `Read-Host` directly.**

Slice 2 then supplies a Whisper source. Verified viable: OpenVINO GenAI's `WhisperPipeline`
targets the NPU with `STATIC_PIPELINE: true`. `Intel(R) AI Boost` is present and healthy on
this box (Core Ultra 9 285K). It runs off system RAM, so it never touches the 32 GB the
coder needs.

Two requirements for that slice, recorded now so they are not lost:

- **Push-to-talk, not wake-word.** Long dumps need a held key; always-listening produces
  false triggers mid-sentence.
- **The transcript is editable before it becomes the goal.** Whisper will mangle exactly
  this vocabulary — "Baton", "Grok", `fleet.yaml`, `lm-studio-small`, issue numbers. Speak
  → see → fix → send. Same principle as §4a: never let a small model's misread become an
  executed job.

## 7. Fixes folded in on the way past

Both are live defects found while designing this, both in `~/.baton/fleet.yaml`, which
**harnesses must not edit** — Kevin applies them.

1. **`lm-studio-small` is pinned to `phi-4`, which is not served by Firefly.** Every judge
   call currently dials a model that does not exist. **Re-pin, do not delete:** it is the
   sole live `judge` claimant (`routing-learn.ps1:310` → `Get-JudgeModel` →
   `Select-Capability -Capability 'judge' -RequireLocal`). Deleting the row falls back to
   `Get-CheapestLocalModel`, which takes the 30B coder — and resurrects the file-order
   fragility `baton-d044` was written to kill. Its other three claims (`extract-json`,
   `commit-msg`, `summarize-short`) have zero call sites today.

2. **The co-residency assumption is stale.** The row's comment says the coder is
   "~17-18 GB … leaves headroom for the small sibling below." `qwen/qwen3-coder-30b` is
   **25.10 GB**. With the 6.66 GB sibling that is 31.8 GB on a 32 GB card, before KV cache.
   Moving the small model to droid.local is not an optimisation — it is what makes the
   coder viable at all.

**Adjacent, larger levers** (noted, not required): `qwen/qwen3.5-35b-a3b` is 22.07 GB —
3 GB cheaper than the current coder, newer, MoE. And KV-cache quantisation typically frees
more than every other lever combined; worth checking the current setting before optimising
elsewhere.

## 8. Placement plan

| Device | Role | Model |
|---|---|---|
| **droid.local** | mouth, judge | `gemma-4-12b-qat` (reasoning off for judge), `nemotron-3-nano-4b` |
| **Firefly** | labor — one big model at a time | `qwen3.5-35b-a3b`, full 32 GB |
| **ITSCM-KRANK2** | excluded by default | opt-in per run only |
| **Wraith2** | out of scope | `ollama-box2` row retired; LM Link serves it as a consumer |

## 9. Testing

Existing conventions: bespoke `Check '<name>' (<bool>)` suites under `scripts/test-*.ps1`,
registered with `test-all.ps1` (currently 84).

The loop must be testable **with no model running**, using the same seam pattern as
`conductor-lib.ps1` (`-Planner` / `-Spawner` / `-Dispatcher`): inject a dispatcher
scriptblock and an `InputSource`. Cases that must exist:

- mouth resolves to a local/free provider; a paid provider is **never** auto-selected
- `converse` roster empty → honest failure, not a silent Claude fallback
- device unreachable → falls to next candidate without burning a timeout
- ambiguous model key → refuses to dispatch by bare key
- work-box target → refused unless explicitly opted in
- extract call returns malformed JSON → asks again, never fabricates a job
- intent `work` → job shown and confirmed before anything fires

## 10. Success

Slice 1 is done when, with **no Claude Code session open**:

1. `baton` starts a conversation.
2. A long pasted dump becomes a proposed `{project, goal, stakes}` shown for confirmation.
3. Confirming fires `baton go --execute` and it runs on a non-Claude instrument.
4. Status comes back in the same conversation in plain language.
5. With every paid provider capped, the mouth still talks and the job queues.

Not done: voice, TTS, web page, Buzz, Wraith2, merging.

## 11. Open

- **droid.local chip / unified memory** — unconfirmed. `gemma-4-12b-qat` is already
  resident there, which proves it fits; sizing the judge alongside it needs the number.
- **Whisper model size on a 13 TOPS NPU** — measure in slice 2; do not assume large-v3.
- **KV-cache quantisation setting on Firefly** — unread.
