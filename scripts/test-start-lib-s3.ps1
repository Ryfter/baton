#!/usr/bin/env pwsh
# Unit-style tests for start-lib.ps1 slice 3 — mid-stream idea injection.
# Hermetic: temp dirs, injected paths, zero network.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'start-lib.ps1')

$script:pass = 0; $script:fail = 0
function Assert-Equal($expected, $actual, $msg) {
    if ($expected -ne $actual) { $script:fail++; Write-Host "FAIL  $msg`n  expected: $expected`n  actual:   $actual" -ForegroundColor Red }
    else { $script:pass++; Write-Host "PASS  $msg" -ForegroundColor Green }
}
function Assert-True($cond, $msg) {
    if (-not $cond) { $script:fail++; Write-Host "FAIL  $msg" -ForegroundColor Red }
    else { $script:pass++; Write-Host "PASS  $msg" -ForegroundColor Green }
}

Write-Host "`n=== F-series: Idea Injection ===" -ForegroundColor Cyan

$tmpF = Join-Path $env:TEMP "baton-s3-test-F-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpF -Force > $null
$charterF = Join-Path $tmpF 'CHARTER.md'

# F1: Append to existing section
Set-Content -Path $charterF -Value "## Decisions & open questions`n- [2026-07-01] Old note" -Encoding utf8NoBOM
$res = Invoke-IdeaInjection -IdeaText "Use a fast LLM" -CharterPath $charterF
Assert-True $res 'F1: Invoke-IdeaInjection returns true on success'
$content = Get-Content -LiteralPath $charterF -Raw
Assert-True ($content -match 'Use a fast LLM') 'F1: Idea text appended'
Assert-True ($content -match 'Old note') 'F1: Old notes preserved'

# F2: Create section if missing
$charterF2 = Join-Path $tmpF 'CHARTER2.md'
Set-Content -Path $charterF2 -Value "# My Project`n## Goal`nTo do things" -Encoding utf8NoBOM
$res2 = Invoke-IdeaInjection -IdeaText "Another idea" -CharterPath $charterF2
$content2 = Get-Content -LiteralPath $charterF2 -Raw
Assert-True ($content2 -match '## Decisions & open questions') 'F2: Section created'
Assert-True ($content2 -match 'Another idea') 'F2: Idea appended to new section'

# F3: Resolve-IdeaRouting parses valid JSON
$mockDispatch1 = {
    param($cand, $prompt)
    return 'Here is the output: { "route": "backlog", "reasoning": "Massive rewrite", "confidence": 0.95 }'
}
$route1 = Resolve-IdeaRouting -IdeaText "Rewrite the whole backend in Rust" -Dispatcher $mockDispatch1
Assert-Equal 'backlog' $route1 'F3: parses backlog route from JSON'

# F4: Resolve-IdeaRouting fail-open on bad JSON
$mockDispatch2 = {
    param($cand, $prompt)
    return 'I cannot help with that.'
}
$route2 = Resolve-IdeaRouting -IdeaText "Just fix a typo" -Dispatcher $mockDispatch2
Assert-Equal 're-plan' $route2 'F4: fails open to re-plan on bad output'

Remove-Item $tmpF -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "PASS: $script:pass  FAIL: $script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
