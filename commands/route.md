---
description: Recommend the optimal capability (tool or model) for a need — cheapest capable tier first ("optimal, not best"), reading tools.yaml + fleet.yaml. Slice 1 recommends; it does not dispatch (that is the auto-router, a later slice).
argument-hint: "<capability>" [--max-tier local|free|paid] [--local]
---

# /route

Recommend the optimal capability for a need. Reads the `tools.yaml` (capability-specific tools
+ specialty models) and `fleet.yaml` (general models) registries and ranks the candidates that
serve `<capability>`, cheapest cost-tier first. **Recommendation only** — dispatch is manual
until the auto-router slice lands.

## Steps

1. **Parse `$ARGUMENTS`:** the first token is `<capability>` (e.g. `commit-msg`, `ocr`,
   `code-gen`); optional `--max-tier local|free|paid` and `--local`. Empty capability → stop
   with: *"Usage: /route \"<capability>\" [--max-tier local|free|paid] [--local]"*.

2. **Select candidates:**

   ```powershell
   . "$HOME/.claude/scripts/routing-lib.ps1"
   $sel = @{ Capability = '<capability>' }
   if ($local)   { $sel['RequireLocal'] = $true }
   if ($maxTier) { $sel['MaxCostTier']  = '<tier>' }
   $cands = Select-Capability @sel
   ```

3. **Report:**
   - If `$cands` is empty, tell the user no candidate serves `<capability>` and list the known
     ones:

     ```powershell
     Get-KnownCapabilities
     ```

   - Otherwise print the ranked table and state the top pick:

     ```powershell
     $cands | Format-Table name, source, kind, cost_tier, quality, why -AutoSize
     Write-Host "Top pick: $($cands[0].name) — $($cands[0].why)"
     ```

   Note to the user that this is a recommendation; dispatch is manual until the auto-router slice.

4. **On any error** (missing `tools.yaml`/`fleet.yaml`), surface the thrown message and suggest
   `pwsh scripts\bootstrap.ps1 -Force` to deploy the registries.

## Arguments

$ARGUMENTS
