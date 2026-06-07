#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-runs-bridge.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    # queued -> queued
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'queued' -Name 'wire bridge'
    $rid = 'backlog-issue-22-codex'
    $rj  = Join-Path $root "$rid/run.json"
    Check 'run.json created'        (Test-Path $rj)
    $rec = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status queued'           ($rec.status -eq 'queued')
    Check 'model recorded'          ($rec.model -eq 'codex')
    Check 'name recorded'           ($rec.name -eq 'wire bridge')
    $ej = Join-Path $root "$rid/events.jsonl"
    Check 'one event appended'      ((Get-Content $ej).Count -eq 1)

    # running -> running, with branch -> tree + worktree
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'running' -Branch 'auto/issue-22-codex'
    $rec2 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status running'          ($rec2.status -eq 'running')
    Check 'tree = branch'           ($rec2.tree -eq 'auto/issue-22-codex')
    Check 'worktree true'           ($rec2.worktree -eq $true)
    Check 'started_at preserved'    ($rec2.started_at -eq $rec.started_at)
    Check 'two events now'          ((Get-Content $ej).Count -eq 2)

    # done -> done
    Publish-ItemRun -RunsRoot $root -Id 'issue-22' -Model 'codex' -State 'done'
    $rec3 = Get-Content $rj -Raw | ConvertFrom-Json
    Check 'status done'             ($rec3.status -eq 'done')
    $lastDone = (Get-Content $ej | Select-Object -Last 1) | ConvertFrom-Json
    Check 'done event kind result' ($lastDone.kind -eq 'result')
    Check 'done event status'      ($lastDone.status -eq 'done')

    # blocked -> failed, with reasons
    Publish-ItemRun -RunsRoot $root -Id 'issue-99' -Model 'codex' -State 'blocked' -Reasons @('scope: out-of-scope edits', 'tests: exit 1')
    $rb = Get-Content (Join-Path $root 'backlog-issue-99-codex/run.json') -Raw | ConvertFrom-Json
    Check 'blocked -> failed'       ($rb.status -eq 'failed')
    Check 'current_step from reason'($rb.current_step -like 'blocked: scope*')
    $eb = (Get-Content (Join-Path $root 'backlog-issue-99-codex/events.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Check 'block event status failed' ($eb.status -eq 'failed')
    Check 'block event why has reasons' ($eb.why -like '*tests: exit 1*')

    # default name when omitted
    Publish-ItemRun -RunsRoot $root -Id 'issue-7' -Model 'gemini' -State 'queued'
    $rd = Get-Content (Join-Path $root 'backlog-issue-7-gemini/run.json') -Raw | ConvertFrom-Json
    Check 'default name = id'       ($rd.name -eq 'issue-7')
    Check 'default project'         ($rd.project -eq 'coding-agent-orchestrator')
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
