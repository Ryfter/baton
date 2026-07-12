#!/usr/bin/env pwsh
# Test harness for scripts/hooks/log-tool-call.ps1
# Feeds canned PostToolUse events on stdin and asserts the journal line shape.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks\log-tool-call.ps1'
$tmpLog = Join-Path $env:TEMP "test-journal-$(Get-Random).md"
$tmpErr = Join-Path $env:TEMP "test-journal-err-$(Get-Random).log"

$failures = 0
function Assert-Match($label, $actual, $pattern) {
    if ($actual -match $pattern) {
        Write-Host "PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $label" -ForegroundColor Red
        Write-Host "      expected match: $pattern"
        Write-Host "      actual:         $actual"
        $script:failures++
    }
}

$env:CAO_STATE_PATH = Join-Path $env:TEMP "test-hook-nostate-$(Get-Random).json"
try {
    # Test 1: Bash tool calling ollama → hook records it
    $event1 = @{
        tool_name = 'Bash'
        tool_input = @{ command = 'ollama run devstral:24b "refactor session.ts"' }
        tool_response = @{ exit_code = 0; duration_ms = 38000 }
    } | ConvertTo-Json -Depth 5 -Compress

    $event1 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $line = (Get-Content $tmpLog -Tail 1)
    Assert-Match 'bash ollama line shape' $line '\| hook \| bash:ollama run devstral.*\| 38s \| exit:0'

    # Test 2: Bash tool with non-zero exit
    $event2 = @{
        tool_name = 'Bash'
        tool_input = @{ command = 'gemini -p "summarize foo"' }
        tool_response = @{ exit_code = 1; duration_ms = 4200 }
    } | ConvertTo-Json -Depth 5 -Compress

    $event2 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $line = (Get-Content $tmpLog -Tail 1)
    Assert-Match 'bash gemini non-zero exit' $line '\| hook \| bash:gemini.*\| 4s \| exit:1'

    # Test 3: Agent tool dispatch
    $event3 = @{
        tool_name = 'Agent'
        tool_input = @{ subagent_type = 'octopus-coder'; description = 'implement TokenStore' }
        tool_response = @{ exit_code = 0; duration_ms = 51000 }
    } | ConvertTo-Json -Depth 5 -Compress

    $event3 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $line = (Get-Content $tmpLog -Tail 1)
    Assert-Match 'agent subagent line shape' $line '\| hook \| agent:octopus-coder \| 51s \| exit:0 \| "implement TokenStore"'

    # Test 4: Non-dispatch tool (Read) is skipped
    $event4 = @{
        tool_name = 'Read'
        tool_input = @{ file_path = 'C:\foo.txt' }
        tool_response = @{ exit_code = 0; duration_ms = 12 }
    } | ConvertTo-Json -Depth 5 -Compress

    $before = (Get-Content $tmpLog).Count
    $event4 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $after = (Get-Content $tmpLog).Count
    if ($after -eq $before) {
        Write-Host "PASS  Read tool is skipped" -ForegroundColor Green
    } else {
        Write-Host "FAIL  Read tool was not skipped (line count went $before -> $after)" -ForegroundColor Red
        $failures++
    }

    # Test 5: Malformed input does not crash; writes to error log (and the line count grows)
    $errBefore = if (Test-Path $tmpErr) { (Get-Content $tmpErr).Count } else { 0 }
    $badEvent = "not-json-at-all"
    $badEvent | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr 2>&1 | Out-Null
    $errAfter = if (Test-Path $tmpErr) { (Get-Content $tmpErr).Count } else { 0 }
    if ($errAfter -gt $errBefore) {
        $newLines = (Get-Content $tmpErr) | Select-Object -Last ($errAfter - $errBefore)
        if (($newLines -join "`n") -match 'hook crashed') {
            Write-Host "PASS  malformed input handled (error log grew $errBefore -> $errAfter, mentions 'hook crashed')" -ForegroundColor Green
        } else {
            Write-Host "FAIL  malformed input grew error log but no 'hook crashed' line" -ForegroundColor Red
            $failures++
        }
    } else {
        Write-Host "FAIL  malformed input did not produce a new error log line" -ForegroundColor Red
        $failures++
    }

    # Test 6: Bash command containing a pipe → target is sanitized
    $event5 = @{
        tool_name = 'Bash'
        tool_input = @{ command = 'ollama run llama3:8b | tee out.txt' }
        tool_response = @{ exit_code = 0; duration_ms = 1000 }
    } | ConvertTo-Json -Depth 5 -Compress

    $event5 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $line = (Get-Content $tmpLog -Tail 1)
    # After split on ' | ', there should be exactly 5 fields (ts, source=hook, target, elapsed, exit) when no brief
    $fields = $line -split ' \| '
    Assert-Match 'pipe-in-command produces 5 pipe-separated fields' "$($fields.Count)" '^5$'
    Assert-Match 'pipe in target was sanitized to ¦' $line 'ollama run llama3:8b ¦ tee out.txt'

    # Test 7: Agent description containing a pipe → brief is sanitized
    $event6 = @{
        tool_name = 'Agent'
        tool_input = @{ subagent_type = 'octopus-coder'; description = 'fix | bug in module' }
        tool_response = @{ exit_code = 0; duration_ms = 2000 }
    } | ConvertTo-Json -Depth 5 -Compress

    $event6 | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr | Out-Null
    $line = (Get-Content $tmpLog -Tail 1)
    Assert-Match 'pipe in description was sanitized to ¦' $line 'fix ¦ bug in module'

} finally {
    Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
    Remove-Item $tmpLog, $tmpErr -ErrorAction SilentlyContinue
}

# --- Plan 3: tagging tests ---
Write-Host ""
Write-Host "=== Plan 3: state-file-driven job/phase tagging ===" -ForegroundColor Cyan

$tagTmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "cao-hook-tag-$(Get-Random)") -Force
$tagJournal = Join-Path $tagTmp 'journal.md'
$tagErr     = Join-Path $tagTmp 'err.log'
$tagState   = Join-Path $tagTmp 'current-job.json'

# Helper to run the hook with a specific state path
function Invoke-HookWithState($json, $statePath) {
    $env:CAO_STATE_PATH = $statePath
    try {
        return $json | pwsh -NoProfile -File scripts/hooks/log-tool-call.ps1 `
            -JournalPath $tagJournal -ErrorPath $tagErr 2>&1
    } finally {
        Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue
    }
}

$sampleEvent = @{
    tool_name = 'Bash'
    tool_input = @{ command = 'ollama run devstral:24b "hello"' }
    tool_response = @{ exit_code = 0; duration_ms = 2000 }
} | ConvertTo-Json -Depth 5 -Compress

# Case A: no state file → line has NO job: / phase: trailing tags
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = @(Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -match 'job:') { throw "FAIL: no-state case should not have job: tag, got: $line" }
if ($line -match 'phase:') { throw "FAIL: no-state case should not have phase: tag, got: $line" }
Write-Host "  ok: no state file → no tags" -ForegroundColor Green

# Case B: state file present → line has both tags
Set-Content -Path $tagState -Value (@{ job_id = 'j-2026-05-26-test'; phase = 'research' } | ConvertTo-Json) -Encoding utf8NoBOM
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = @(Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -notmatch 'job:j-2026-05-26-test') { throw "FAIL: should contain job tag, got: $line" }
if ($line -notmatch 'phase:research')        { throw "FAIL: should contain phase tag, got: $line" }
Write-Host "  ok: state file set → trailing tags appended" -ForegroundColor Green

# Case C: corrupted state file → graceful fallback (no tags, no crash)
Set-Content -Path $tagState -Value '{ broken json' -Encoding utf8NoBOM
Remove-Item $tagJournal -ErrorAction SilentlyContinue
Invoke-HookWithState $sampleEvent $tagState | Out-Null
$line = @(Get-Content $tagJournal | Where-Object { $_ -match '\| hook \|' })[-1]
if ($line -match 'job:') { throw "FAIL: corrupted state should yield no tags, got: $line" }
Write-Host "  ok: corrupted state → graceful fallback, no tags" -ForegroundColor Green

Remove-Item $tagTmp -Recurse -Force

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed" -ForegroundColor Green
    exit 0
}
