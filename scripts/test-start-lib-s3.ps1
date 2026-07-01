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

Write-Host "`n=== G-series: dispatch-result normalization (defect regression) ===" -ForegroundColor Cyan

# G1: Dispatcher returns a HASHTABLE (mirrors Invoke-Fleet's real shape) with
# valid backlog JSON in .stdout and a zero exit_code -> route parses normally.
$mockDispatch3 = {
    param($cand, $prompt)
    return @{ stdout = '{ "route": "backlog", "reasoning": "Big rewrite", "confidence": 0.9 }'; exit_code = 0 }
}
$route3 = Resolve-IdeaRouting -IdeaText "Rearchitect the whole pipeline" -Dispatcher $mockDispatch3
Assert-Equal 'backlog' $route3 'G1: hashtable dispatch result with stdout+exit_code 0 parses backlog'

# G2: Dispatcher returns a HASHTABLE with a non-zero exit_code -> fail open to
# re-plan WITHOUT attempting to parse the (garbage) stdout.
$mockDispatch4 = {
    param($cand, $prompt)
    return @{ stdout = 'garbage'; exit_code = 1 }
}
$route4 = Resolve-IdeaRouting -IdeaText "Doesn't matter" -Dispatcher $mockDispatch4
Assert-Equal 're-plan' $route4 'G2: hashtable dispatch result with non-zero exit_code fails open to re-plan'

# G3: Dispatcher returns a plain JSON STRING (regression — must keep working
# after the hashtable-normalization fix).
$mockDispatch5 = {
    param($cand, $prompt)
    return '{ "route": "re-plan", "reasoning": "Small tweak", "confidence": 0.8 }'
}
$route5 = Resolve-IdeaRouting -IdeaText "Tweak the retry count" -Dispatcher $mockDispatch5
Assert-Equal 're-plan' $route5 'G3: plain string dispatch result still parses (regression)'

# G4: Invoke-IdeaInjection must insert idea text LITERALLY — regex replacement
# metacharacters ($1, $$) in the idea must not corrupt the CHARTER.
$charterF3 = Join-Path $tmpF 'CHARTER3.md'
Set-Content -Path $charterF3 -Value "## Decisions & open questions`n- [2026-07-01] Old note" -Encoding utf8NoBOM
$dangerousIdea = 'costs $$ and uses $1 tokens'
$res3 = Invoke-IdeaInjection -IdeaText $dangerousIdea -CharterPath $charterF3
Assert-True $res3 'G4: Invoke-IdeaInjection returns true with dangerous idea text'
$content3 = Get-Content -LiteralPath $charterF3 -Raw
Assert-True ($content3.Contains($dangerousIdea)) 'G4: literal $$ / $1 idea text preserved verbatim in CHARTER'

# G5: Dispatcher returns a HASHTABLE with a zero exit_code but MALFORMED JSON
# in .stdout -> fail open to re-plan.
$mockDispatch6 = {
    param($cand, $prompt)
    return @{ stdout = 'not json at all'; exit_code = 0 }
}
$route6 = Resolve-IdeaRouting -IdeaText "Whatever" -Dispatcher $mockDispatch6
Assert-Equal 're-plan' $route6 'G5: hashtable dispatch result with malformed JSON stdout fails open to re-plan'

Remove-Item $tmpF -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "PASS: $script:pass  FAIL: $script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
