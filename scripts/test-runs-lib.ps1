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

    # --- Fix #1 regression: partial update (Set-RunStatus) must not clobber cost/tokens ---
    Set-RunRecord -RunsRoot $root -Id 'run_cost' -Name 'costtest' -Status 'running' `
        -CostUsd 12.40 -TokensIn 41000 -TokensOut 7000 -Worktree $true
    Set-RunStatus -RunsRoot $root -Id 'run_cost' -Status 'needs-you' -ParkedQuestion 'q?'
    $rc = Get-Content (Join-Path $root 'run_cost/run.json') -Raw | ConvertFrom-Json
    Check 'partial update preserves cost_usd'    ([double]$rc.cost_usd   -eq 12.40)
    Check 'partial update preserves tokens_in'   ([int]$rc.tokens_in    -eq 41000)
    Check 'partial update preserves tokens_out'  ([int]$rc.tokens_out   -eq 7000)
    Check 'partial update preserves worktree'    ($rc.worktree -eq $true)
    Check 'partial update still changes status'  ($rc.status -eq 'needs-you')
    Check 'partial update still sets parked_q'   ($rc.parked_question -eq 'q?')

    # --- Fix #3: FilesTouched writer ---
    Set-RunRecord -RunsRoot $root -Id 'run_files' -Name 'filetest' -Status 'running' `
        -FilesTouched @('auth.ts', 'validator.ts')
    $rf = Get-Content (Join-Path $root 'run_files/run.json') -Raw | ConvertFrom-Json
    Check 'files_touched round-trips 2 items'    ($rf.files_touched.Count -eq 2)
    Check 'files_touched contains auth.ts'       ($rf.files_touched -contains 'auth.ts')
    Check 'files_touched contains validator.ts'  ($rf.files_touched -contains 'validator.ts')

    # Single-element must stay a JSON array (not a bare string)
    Set-RunRecord -RunsRoot $root -Id 'run_files' -FilesTouched @('only.ts')
    $raw2 = Get-Content (Join-Path $root 'run_files/run.json') -Raw | ConvertFrom-Json
    Check 'single-element files_touched is array' ($raw2.files_touched -is [System.Array] -or $raw2.files_touched.Count -eq 1)
    Check 'single-element files_touched value'    ($raw2.files_touched[0] -eq 'only.ts')

    # --- SP2: current-run wiring ---
    Set-CurrentRun -RunsRoot $root -Id 'job-x1' -Name 'wire SP2' -Model 'claude-opus-4-8' -Project 'baton'
    $curPath = Join-Path $root 'current-run.json'
    Check 'current-run.json written'  (Test-Path $curPath)
    $cur = Get-Content $curPath -Raw | ConvertFrom-Json
    Check 'current id'                ($cur.id -eq 'job-x1')
    Check 'current name'              ($cur.name -eq 'wire SP2')
    $seed = Get-Content (Join-Path $root 'job-x1/run.json') -Raw | ConvertFrom-Json
    Check 'run record seeded running' ($seed.status -eq 'running')

    Clear-CurrentRun -RunsRoot $root
    Check 'current-run.json removed'  (-not (Test-Path $curPath))
    Check 'run record survives clear' (Test-Path (Join-Path $root 'job-x1/run.json'))
    # idempotent: second clear must not throw
    Clear-CurrentRun -RunsRoot $root
    Check 'clear is idempotent'       (-not (Test-Path $curPath))
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
