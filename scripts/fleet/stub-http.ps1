#!/usr/bin/env pwsh
<# Test-only fleet escape hatch. Returns a canned response without any network. #>

function Invoke-StubHttp {
    param($provider, $prompt, $model)
    return @{ stdout = "stub-http-response:$prompt"; stderr = ''; exit_code = 0; duration_s = 0 }
}
