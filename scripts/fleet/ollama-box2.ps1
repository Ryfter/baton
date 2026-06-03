#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet escape hatch for a remote Ollama box reached over the network/Tailscale
  (Plan 9 / issue #20). Talks to the native Ollama HTTP API directly rather than
  proxying through the local `ollama run` CLI, which hangs/errors against a remote
  host — the /api/generate endpoint is reliable.

  Convention: Invoke-OllamaBox2($provider, $prompt, $model)
    -> @{ stdout; stderr; exit_code; duration_s }

  Provider fields used: base_url (e.g. http://100.115.71.9:11434), model_default.
#>

function Invoke-OllamaBox2 {
    param($provider, $prompt, $model)
    $start = Get-Date
    try {
        $modelName = if ($model) { $model } else { $provider.model_default }
        if (-not $modelName) { throw "ollama-box2: no -Model given and no model_default in fleet.yaml." }
        if (-not $provider.base_url) { throw "ollama-box2: provider has no base_url." }
        $body = @{ model = $modelName; prompt = $prompt; stream = $false } | ConvertTo-Json -Depth 6
        $resp = Invoke-RestMethod -Uri "$($provider.base_url.TrimEnd('/'))/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 300
        $text = ([string]$resp.response).Trim()
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $text; stderr = ''; exit_code = 0; duration_s = $duration }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = 1; duration_s = $duration }
    }
}
