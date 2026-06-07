#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script = "$PSScriptRoot/statusline-feed.ps1"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("sl-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$pointer = Join-Path $root 'current-run.json'
Set-Content -Path $pointer -Value '{"id":"run_t"}' -Encoding utf8
$fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    $payload = '{"model":{"id":"claude-opus-4-8","display_name":"Opus"},"workspace":{"current_dir":"D:/Dev/coding-agent-orchestrator"},"cost":{"total_cost_usd":1.23}}'
    $out = $payload | & pwsh -NoProfile -File $script -RunsRoot $root -PointerPath $pointer
    Check 'prints a status line' ($out -and $out.Length -gt 0)
    $rj = Join-Path $root 'run_t/run.json'
    Check 'run.json updated' (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'model captured' ($rec.model -eq 'claude-opus-4-8')

    # Empty/garbage payload must not crash and still print something
    $out2 = '' | & pwsh -NoProfile -File $script -RunsRoot $root -PointerPath $pointer
    Check 'survives empty stdin' ($LASTEXITCODE -eq 0)
}
finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
