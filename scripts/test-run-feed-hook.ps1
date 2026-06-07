#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$hook = "$PSScriptRoot/hooks/run-feed.ps1"
$root = Join-Path ([System.IO.Path]::GetTempPath()) ("runfeed-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$pointer = Join-Path $root 'current-run.json'
Set-Content -Path $pointer -Value '{"id":"run_t"}' -Encoding utf8
$fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    $evt = '{"tool_name":"Read","tool_input":{"file_path":"D:/x/auth.ts"},"tool_response":{"exit_code":0}}'
    $evt | & pwsh -NoProfile -File $hook -RunsRoot $root -PointerPath $pointer
    $ej = Join-Path $root 'run_t/events.jsonl'
    Check 'event appended' (Test-Path $ej)
    $ev = (Get-Content $ej | Select-Object -Last 1) | ConvertFrom-Json
    Check 'plain-english what' ($ev.what -like '*auth.ts*')

    # Fix #2: hook must update run.json (current_step + files_touched)
    $rj2 = Join-Path $root 'run_t/run.json'
    Check 'run.json exists after Read event' (Test-Path $rj2)
    $rec2 = Get-Content $rj2 -Raw | ConvertFrom-Json
    Check 'current_step set after Read event'      ($rec2.current_step -and $rec2.current_step.Length -gt 0)
    Check 'files_touched contains auth.ts'         ($rec2.files_touched -contains 'auth.ts')

    # Write event: files_touched should accumulate (not reset existing)
    $evt2 = '{"tool_name":"Write","tool_input":{"file_path":"D:/x/schema.ts"},"tool_response":{"exit_code":0}}'
    $evt2 | & pwsh -NoProfile -File $hook -RunsRoot $root -PointerPath $pointer
    $rec3 = Get-Content $rj2 -Raw | ConvertFrom-Json
    Check 'files_touched accumulates Write file'   ($rec3.files_touched -contains 'schema.ts')
    Check 'files_touched still has auth.ts'        ($rec3.files_touched -contains 'auth.ts')

    # No pointer -> no crash, no event
    Remove-Item $pointer
    '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | & pwsh -NoProfile -File $hook -RunsRoot $root -PointerPath $pointer
    Check 'no pointer = no new run dir' (-not (Test-Path (Join-Path $root 'run_none')))
}
finally { if (Test-Path $root) { Remove-Item -Recurse -Force $root } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
