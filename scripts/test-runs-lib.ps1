#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/runs-lib.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("runs-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" }
    else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    Set-RunRecord -RunsRoot $root -Id 'run_t' -Name 't' -Model 'claude-opus-4-8' -Status 'running'
    $rj = Join-Path $root 'run_t/run.json'
    Check 'run.json written' (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'name persisted' ($rec.name -eq 't')
    Check 'status persisted' ($rec.status -eq 'running')

    Add-RunEvent -RunsRoot $root -Id 'run_t' -Kind 'action' -What 'read file' -Why 'map blast radius'
    $ej = Join-Path $root 'run_t/events.jsonl'
    Check 'events.jsonl written' (Test-Path $ej)
    $ev = (Get-Content $ej | Select-Object -First 1) | ConvertFrom-Json
    Check 'event what' ($ev.what -eq 'read file')
    Check 'event why' ($ev.why -eq 'map blast radius')

    Set-RunStatus -RunsRoot $root -Id 'run_t' -Status 'needs-you' -ParkedQuestion 'which strategy?'
    $rec2 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status updated' ($rec2.status -eq 'needs-you')
    Check 'question set' ($rec2.parked_question -eq 'which strategy?')

    Set-GlobalStrip -RunsRoot $root -SpendTodayUsd 12.5 -ActiveRuns 3
    $idx = Join-Path $root 'index.json'
    Check 'index.json written' (Test-Path $idx)

    Check 'answer absent -> null' ($null -eq (Get-RunAnswer -RunsRoot $root -Id 'run_t'))
    Set-Content -Path (Join-Path $root 'run_t/answer.txt') -Value 'use a grace window' -NoNewline
    Check 'answer read back' ((Get-RunAnswer -RunsRoot $root -Id 'run_t') -eq 'use a grace window')
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
