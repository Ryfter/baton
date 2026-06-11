#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet escape hatch for the lm-studio-small registry entry: a second pinned model
  on the SAME LM Studio server (d043 big+small pattern — one serving process per
  box arbitrates its own VRAM). Delegates to Invoke-LmStudio; the provider's own
  model_default does the pinning.
  Convention: Invoke-LmStudioSmall($provider, $prompt, $model) -> @{ stdout; exit_code; duration_s; stderr? }
#>

. (Join-Path $PSScriptRoot 'lm-studio.ps1')

function Invoke-LmStudioSmall {
    param($provider, $prompt, $model)
    return Invoke-LmStudio $provider $prompt $model
}
