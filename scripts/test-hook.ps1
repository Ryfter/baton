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

# Test 5: Malformed input does not crash; writes to error log
$badEvent = "not-json-at-all"
$badEvent | & pwsh -NoProfile -File $hook -JournalPath $tmpLog -ErrorPath $tmpErr 2>&1 | Out-Null
if (Test-Path $tmpErr) {
    Write-Host "PASS  malformed input handled (error log written)" -ForegroundColor Green
} else {
    Write-Host "FAIL  malformed input did not produce an error log" -ForegroundColor Red
    $failures++
}

Remove-Item $tmpLog, $tmpErr -ErrorAction SilentlyContinue

if ($failures -gt 0) {
    Write-Host "`n$failures test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests passed" -ForegroundColor Green
    exit 0
}
