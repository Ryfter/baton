#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Fleet escape hatch for LM Studio (OpenAI-compatible HTTP API).
  Convention: Invoke-LmStudio($provider, $prompt, $model) -> @{ stdout; exit_code; duration_s; stderr? }
#>

function Invoke-LmStudio {
    param($provider, $prompt, $model)
    $endpoint = "$($provider.base_url)/v1/chat/completions"
    $start = Get-Date
    try {
        # Model resolution: explicit arg > pinned model_default > server's first
        # listed model. 'auto' is treated as unpinned (d043: pin explicit models —
        # data[0].id is whatever sorts first in the library, NOT a sane default).
        $modelName = if ($model) { $model }
                     elseif ($provider.model_default -and $provider.model_default -ne 'auto') { $provider.model_default }
                     else {
                         $models = Invoke-RestMethod "$($provider.base_url)/v1/models" -TimeoutSec 10
                         $models.data[0].id
                     }
        $body = @{
            model    = $modelName
            messages = @(@{ role = 'user'; content = $prompt })
            stream   = $false
        } | ConvertTo-Json -Depth 10
        # 300s: a large pinned model may cold-load (~17 GB) before generating.
        $timeoutS = if ($provider.timeout_s) { [int]$provider.timeout_s } else { 300 }
        $resp = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body `
                                  -ContentType 'application/json' -TimeoutSec $timeoutS
        $text = $resp.choices[0].message.content
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = $text; stderr = ''; exit_code = 0; duration_s = $duration }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = 1; duration_s = $duration }
    }
}
