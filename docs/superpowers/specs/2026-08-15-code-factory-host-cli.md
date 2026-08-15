# Code-factory host: standalone CLI vs. running inside an agent CLI

**Date:** 2026-08-15
**Status:** recommendation
**Scope:** where Baton's long-running code factory should LIVE — its own CLI, or
hosted inside an existing provider-agnostic agent CLI (opencode, aider, goose, codex).

## Recommendation

**Baton stays its own standalone CLI. Host agent CLIs are wired in as fleet
PROVIDERS, never as the host process.** No pilot, no dual-track.

## The tradeoff, stated once

Hosting inside opencode/aider/goose/codex buys one real thing: their per-provider
transport, auth, and model plumbing, which Baton currently maintains itself in
`scripts/fleet-lib.ps1` (cli / http / stdio-json transports, stdin promotion,
`{{prompt_file}}`, quote-safety per provider). That is genuine, ongoing maintenance
Baton would shed.

It costs the thing Baton exists for: **cross-provider arbitration.** Those CLIs are
single-session agent frontends. Each one owns provider selection for its own session
— that is its core loop. Baton's core loop is choosing BETWEEN providers on cost,
capability, usage state, and learned effective cost, then failing over when one dies.
Put Baton inside one of them and there are two routers in the stack, with the host's
router underneath and authoritative. Baton would be reduced to prompting whichever
model the host already picked.

The exchange is bad in one direction: transport plumbing is bounded, well-understood
work Baton has already paid for. Losing arbitration removes the product.

## Evidence from this repo

1. **The fleet registry is the architecture.** `references/fleet.yaml` carries 13
   provider rows across three cost tiers with per-row capability claims, context
   floors, budgets, saturation, usage policy, and edit-eligibility (`agentic`,
   `diff_apply`). None of this has a home inside a single-session agent CLI.

2. **opencode is ALREADY modelled as a provider, not a host** —
   `references/fleet.yaml:226` is an `opencode` row (`kind: cli`, `cost_tier: free`,
   `enabled: false`). The repo's own answer to "what is opencode to Baton?" was
   settled when that row was written: a candidate to route to.

3. **Governance layers have no host-CLI analogue.** The Usage Governor's
   route-around-exhausted (`scripts/routing-lib.ps1`, `Select-Capability` step 3b),
   the frozen verification contract (`Get-FrozenVerificationContract` reads
   `git show <base>:.baton/verification.json` so a worker cannot edit its own
   oracle), the Plan Gate and Acceptance Gate panels, the per-run event/decision
   ledgers, and `BATON_HOME` state are all cross-session, cross-provider concerns.
   A host CLI's unit of state is one session.

4. **Baton already exposes itself where hosting would be needed.** The `baton_mcp`
   FastMCP server ships 8 tools (`baton_route`, `baton_fleet_doctor`, …) and is
   auto-registered via `.mcp.json`. Any MCP-speaking agent CLI can already drive
   Baton *without* Baton surrendering the host process. That is the integration
   direction that costs nothing.

5. **This PR's failover walk only exists above the provider layer.**
   `Invoke-CapabilityFailover` walks a cost-ordered roster spanning claude / codex /
   grok / gemini / local rows. Inside a host CLI there is no such roster to walk —
   the roster is the host's, and its failover policy is not Baton's.

## What this rules in

- Keep enrolling agent CLIs as rows. `opencode` should be enabled and given explicit
  `capabilities` once someone verifies its headless flags, exactly like the `grok-cli`
  row's `{{prompt_file}}` note.
- Keep `baton_mcp` as the outward integration surface for agents that want to call
  Baton.

## What this rules out

- Porting the conductor loop into an opencode/goose plugin.
- Depending on a host CLI's provider list in place of `fleet.yaml`.

## Revisit if

A host CLI exposes a documented, stable API for *declining to route* — letting an
embedded orchestrator name the exact provider per call and observe that provider's
quota state. That is the only shape in which hosting keeps arbitration, and none of
opencode, aider, goose, or codex offers it today.
