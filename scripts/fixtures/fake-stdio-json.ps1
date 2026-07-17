#!/usr/bin/env pwsh
param(
    [ValidateSet('happy','malformed','response-nonzero','process-nonzero','stderr','timeout')]
    [string]$Mode = 'happy',
    [string]$CapturePath
)

$requestText = [Console]::In.ReadToEnd()
if ($CapturePath) {
    Set-Content -LiteralPath $CapturePath -Value $requestText -Encoding utf8NoBOM
}

if ($Mode -eq 'malformed') {
    [Console]::Out.Write('not-json')
    exit 0
}
if ($Mode -eq 'process-nonzero') {
    [Console]::Error.WriteLine('fake child process failure')
    exit 7
}
if ($Mode -eq 'timeout') {
    Start-Sleep -Seconds 120
    exit 0
}

try { $request = $requestText | ConvertFrom-Json -ErrorAction Stop }
catch {
    [Console]::Error.WriteLine("request parse failed: $($_.Exception.Message)")
    exit 8
}

if ($Mode -eq 'response-nonzero') {
    $response = [ordered]@{
        output = 'declared failure output'
        stderr = 'declared child failure'
        exit_code = 4
        tokens = 9
        tokens_basis = 'exact'
    }
} else {
    if ($Mode -eq 'stderr') { [Console]::Error.WriteLine('fake child warning') }
    $response = [ordered]@{
        output = "child:$($request.prompt)|model:$($request.model)|tier:$($request.tier_args)"
        exit_code = 0
        tokens = 123
        tokens_basis = 'exact'
    }
}
[Console]::Out.Write((ConvertTo-Json -InputObject $response -Depth 6 -Compress))
exit 0
