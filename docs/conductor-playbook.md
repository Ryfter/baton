# Conductor playbook — the ship-loop choreography

The operating loop any conductor (Claude, Codex front door, a future session with zero
memory) replays to ship one task through the fleet. Distilled from the runs that shipped
v1.15–v1.17 and #94. Terms per [`docs/glossary.md`](glossary.md). This is choreography
*between* the operator's taste seams — design forks and merge words always belong to the
operator.

## The loop

1. **Intake** — pick the task (operator's word or the agreed order). Confirm the governing
   spec/design exists and reconcile it against current master; resolve or default any open
   forks (state the default; the operator can redirect at the merge gate).
2. **Brief** — write the build brief to a FILE from `prompts/build-brief.txt` (965-byte
   rule). The brief names: reading list, scope blocks, house rules, verify contract, and
   "no PR, no merge — conductor handles it."
3. **Dispatch** — cut the branch, farm the build to the implementer instrument
   (background). Pre-flight the provider's usage when a probe exists (d090 soft caps);
   over-cap = hold and ask the operator.
4. **Cap-death protocol** (when an instrument dies at its usage limit): commit+push partial
   work as WIP ("intent, not truth" for sketch tests), write a resume brief, schedule the
   re-dispatch at the provider's stated reset. Proven twice — never lose the work.
5. **Verify independently** — never trust the implementer's green claim (d059): run the
   full local gate + pytest yourself.
6. **Review fan-out** (concurrent): deep adversarial reviewer via
   `prompts/review-adversarial.txt` (full u10 diff) + free local lenses via
   `prompts/review-lens-*.txt` (SPLIT the diff per lens — prod code vs tests, u3, <40KB
   each; oversized local prompts die silently like a dead server — probe with a 6-token
   ask to distinguish).
7. **Adjudicate** — local-lens findings are tripwires: confirm each against the deep
   review (convergence = signal) or a reproduce-or-refute dispatch. Spot-check every
   Critical against the source yourself before acting.
8. **Fix pass** — dispatch via `prompts/fix-pass.txt`, usually to the reviewer that found
   the issues (a reviewer can implement its own scoped findings — proven twice). Product
   forks discovered in review are NOT fixed silently: escalate to the operator
   (ship-soft/#101 pattern).
9. **Re-verify** — full gate again on the fixed tip.
10. **PR + the word** — open the PR with the fleet narrative and verification numbers.
    NOTHING merges without the operator's explicit, per-PR word.
11. **Record** — evidence comment on the issue; d-record for real decisions
    (Add-DecisionRecordFromFile, silently); Grimdex lesson for anything evidence-traced;
    memory + KB push (backup standing order); release rides its own PR (d084) when the
    node completes.

## Standing constraints (non-negotiable)

- Merge word is per-PR; approval never transfers.
- Box-private data never enters the repo — placeholders in seeds/docs/tests.
- Instruments never merge; the conductor never lets them.
- Fail-loud beats fail-open everywhere except advisory signals.
- One clean retry — whether verification-driven or failover-driven — never over partial edits.
