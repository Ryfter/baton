# Kun Chen transcripts — 3-way synthesis (Grok / GLM 5.3 Flash / Gemini-Antigravity)

Three independent passes over the same 4 transcripts + link index, dispatched in parallel
with no cross-visibility between them. Raw reports: `raw-grok-H-kun-transcripts.md` (most
thorough — grounded, direct file access, ~55KB), `raw-glm-kun-transcripts.md` (full
transcripts embedded in one prompt, no repo access, ~57k tokens in), `raw-gemini-kun-
transcripts.md` (agy/Antigravity, direct file access, shortest).

**All three converged on the same correction to Kevin's framing, independently.** That
convergence is the headline finding — three different models, three different methods
(one reading files live, one working from embedded text only), landed on the same
re-read of what Kun Chen actually does.

## The correction (all 3 models, independently)

Kevin's framing was: "he just looks at models with the least token usage." **None of the
four talks say that.** What Kun actually optimizes for:

1. **A capability class first** (UI/paid-surface → always Fable; native-image-needed →
   Codex, because it has the tool, not because it scored higher; hard planning → a
   premium 3-model set; well-defined bugfix → a cheap set).
2. **Inside that class, whichever cloud seat has the most subscription quota left**
   (`quota-axi`) — this is subscription-forfeiture avoidance on flat-rate Max plans, not
   "cheapest," and not "lowest token count." His own Token Game talk argues explicitly
   that token count is *not* a productivity metric and that token-maxing is a marketing-
   subsidy trap enterprises should not copy.
3. **A human taste veto on top** — "we have leftover Fable quota, why not" is a real
   decision he makes, not an algorithm.

The actual organizing principle across all 4 talks, named directly in the high-throughput
talk: **human attention is the scarce resource, not tokens.** Every tool he built (calm
mode, ahoy, lavish, second mates, bearings) exists to keep the captain's attention off the
middle of the work, not to minimize spend.

## What this means for Baton (converged across all 3 reports)

**Router:** the existing KEEP-BUILD stands, but needs a **capability-class dimension**
added before the cost/quality sort — his table (UI-surface, tool-surface, hard-plan,
well-defined-bugfix, default) is usable as seed taxonomy. Learn *within* a class, not
across a flat global ranking. A global "cheapest that scores well enough" sort would
mis-seat exactly the cases his table exists for (image gen → Codex for the tool, not the
score; paid iOS UI → Fable for taste, not benchmark).

**quota-axi overlay:** confirmed as correct at the ordering already decided
(2026-09-08) — but the *order* matters and wasn't previously pinned down: **class first,
then local-fleet score if a local clears the class's quality bar, then remaining cloud
quota as the tie-break among what's left.** Overlaying quota before class would let
leftover Opus eat bugfixes a local should take; overlaying it after class (correctly) lets
leftover Opus win inside hard-planning, which is the "why not, we have quota" move.

**no-mistakes:** not an always-on gate in his own usage — it's per-project policy
(`direct-PR+yolo` for toys, on for anything that auto-releases or that he'd have asked a
human peer to review). Baton's own repo can keep a hard gate; a future multi-project
factory should carry a policy bit, not a blanket switch.

**Governor:** strongly reconfirmed, from a new angle — his "waste a little context,
set one constant (500k auto-compact) and stop thinking about it" is the same argument
for hard caps that are invisible once set, never a dashboard the human tends. All three
reports flag this as a design law for Baton: **spend-optimization must never become
something Kevin has to watch.** A router that surfaces score-tuning knobs would repeat
the exact mistake his talks warn against.

**Firstmate/Herdr seam:** confirmed live, current (July–Sept 2026 usage), unchanged from
2026-09-08's verdict. New data point: **second mates** — domain-scoped recursive
firstmates, spawned when the liaison saturates, placed on whichever machine has spare
hardware (his headless Mac Mini). This is the missing piece for "who owns what when the
liaison is busy" — matches Kevin's actual hardware shape (Mac Mini + GPU boxes) better
than one liaison doing everything.

## What's adoptable piecemeal (concrete, cross-confirmed)

- **Capability-class dispatch table** as router seed taxonomy, human-pinnable per class.
- **Quota as tie-break, not ranker** — wire it in *after* class + local-bar.
- **Per-project gate policy** (`no-mistakes | direct-PR | yolo`) keyed on blast radius +
  "would a human peer have reviewed this?"
- **Hide the middle, instrument the ends** — no live tool-call stream to the captain by
  default; a "captain's calls" / PARKED-ON-HUMAN list (his `bearings`) as the actual human
  HUD, not a token ticker.
- **One constant auto-compact threshold, then stop tuning it.**
- **Tiny global prefs file** (~30 lines: don't overweight dev-cost in technical decisions,
  E2E-first bugfixes, fix red CI you walked past, no em-dash, no agent co-author) +
  **fat per-project memory grown from corrections** — not a fancy memory system.
- **Ban un-evaluated public skills** — his 177k-star skill that measurably made results
  worse (Program Bench: +5% tokens, worse output) is the concrete cautionary case.
- **AXI constraints on Baton's own agent-facing CLIs** — prefer `gh` over GitHub MCP
  (measured 3x tokens, 2x latency for the same task); token-dense output for anything
  Baton writes for an agent to read.
- **gnhf-style overnight**: verifiable objective + token cap + iteration cap + stop
  condition, wake to a branch (not an auto-PR) — already the lean for `baton go
  --overnight`.
- **Second mates / headless labor box** pattern for scale-out once the liaison saturates.
- **Anti-gaming reporting rule**: never surface token counts as a success metric anywhere
  in Baton's own output. GLM's citation: a 7,000-engineer study (Jellyfish) found the
  highest token-spenders produced ~2x the output at ~10x the cost.

## The core tension, resolved

Kun's system is the right **human-systems architecture** — one interruptible liaison,
domain deputies, hidden middles, risk-metered gates, quota as a cloud-only tie-break.
It's the wrong **model-economics architecture** for a fleet that includes local GPUs and
real (non-subsidized) API prices — he has zero local inference and never mentions it; his
"why not spend leftover Fable" move is the $200/mo subsidy talking, which his own Token
Game talk tells *enterprises* explicitly not to copy.

Baton's differentiator survives this cross-check intact, with one addition the transcripts
justify: **class-aware measured routing + Governor, with local-fleet scores competing
inside any class a local can clear, and cloud quota only as the tie-break for what's
left.** That is "smarter" in the sense Kevin actually meant — not "always the frontier
model," since Kun's own dispatch table already sends well-defined bugfixes to
Luna/Sonnet-tier models, not Opus. The gap Baton closes that Kun's factory cannot: Kun's
seating is hand-curated taste in a JSON file re-derived from a video; Baton's is meant to
notice, on its own, the week a local 32B starts passing the well-defined-bugfix class and
re-seat it — Kun updates `crew-dispatch.json` by hand when he feels like it; Baton's
router is supposed to notice automatically and permanently.

**Verdict for Kevin:** don't adopt Kun's religion (leftover-quota-burn as a default, one
giant liaison prompt, Nix-as-a-Baton-dependency). Adopt his scarcity model (attention,
not tokens), his class-first dispatch shape, his gate-metering-by-risk, and his refusal to
let the human watch the middle. The 2026-09-08 stack decision does not need to be
reopened — it needs the one refinement above (class before quota) written into the
router's design when that work starts.

## Not yet decided (deferred, not urgent)

- Whether to seat **Pi** as the liaison harness specifically (vs. crewmate-only) — Kun's
  Sept talk uses Pi as his day-to-day liaison switcher, which is stronger evidence than
  the 2026-09-08 "Pi = optional local-model worker" framing accounted for. Revisit only
  when the lead-orchestrator fork (§2 of `00-DECISION-consolidated.md`) is actually
  decided — this doesn't resolve it, it just adds a data point.
- **Lavish**-style interactive decision artifacts as a captain-interface pattern (not a
  Baton product) for the PARKED-ON-HUMAN surface — worth a spike once GitHub Projects
  table view ships, not before.
- **Backpass** (session-log → AGENTS.md proposal mining) — closest existing analog is
  `/learn` + projectmem; flagged, not added, per the standing adoption-mania caution.
