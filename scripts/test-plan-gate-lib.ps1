#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/plan-gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

# ---- Hermetic setup: temp BATON_HOME + fixture fleet/tools. NEVER touch real
#      ~/.baton or ~/.claude. try/finally restores the env either way. ----
$origBatonHome = $env:BATON_HOME
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "plan-gate-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$env:BATON_HOME = $tmpDir

$fixtureFleet = Join-Path $tmpDir 'fixture-fleet.yaml'
Set-Content -LiteralPath $fixtureFleet -Encoding utf8NoBOM -Value @'
providers:
  - name: plan-rev-a
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [plan-review]
  - name: plan-rev-b
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [plan-review]
  - name: other-cli
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [review]
'@
$fixtureTools = Join-Path $tmpDir 'fixture-tools.yaml'
Set-Content -LiteralPath $fixtureTools -Encoding utf8NoBOM -Value "tools: []`n"

try {
    # ---- Case 1: verdict map (pure) ----
    $vc = Get-PlanReviewVerdict -MergedFindings @(@{severity='critical';area='scope';summary='x'})
    Check '1a critical -> reject' ($vc.verdict -eq 'reject' -and $vc.counts.critical -eq 1 -and $vc.reason -eq '1 critical finding(s)')
    $vr = Get-PlanReviewVerdict -MergedFindings @(@{severity='important';area='scope';summary='x'})
    Check '1b important (no critical) -> revise' ($vr.verdict -eq 'revise' -and $vr.counts.important -eq 1 -and $vr.reason -eq '1 important finding(s)')
    $vm = Get-PlanReviewVerdict -MergedFindings @(@{severity='minor';area='scope';summary='x'})
    Check '1c minor only -> accept' ($vm.verdict -eq 'accept' -and $vm.counts.minor -eq 1 -and $vm.reason -match 'minor')
    $vn = Get-PlanReviewVerdict -MergedFindings @()
    Check '1d empty -> accept, no findings' ($vn.verdict -eq 'accept' -and $vn.reason -eq 'no findings')

    # ---- Case 2: merge agreed vs solo through Invoke-PlanGate ----
    $disp2 = {
        param($n,$p)
        if ($n -eq 'p1') { return @{ stdout='[{"severity":"important","area":"scope","summary":"missing rollback task"},{"severity":"minor","area":"cost","summary":"redundant heavy fetch"}]'; stderr=''; exit_code=0 } }
        elseif ($n -eq 'p2') { return @{ stdout='[{"severity":"important","area":"scope","summary":"missing rollback task"}]'; stderr=''; exit_code=0 } }
        else { return @{ stdout='[]'; stderr=''; exit_code=0 } }
    }
    $g2 = Invoke-PlanGate -Goal 'ship feature' -PlanJson '{"tasks":[]}' -Reviewers @('p1','p2') -Dispatcher $disp2
    Check '2a two reviewers -> revise, 2 findings' ($g2.verdict -eq 'revise' -and @($g2.findings).Count -eq 2)
    $scopeF = @($g2.findings | Where-Object { $_.area -eq 'scope' })[0]
    Check '2b shared finding agreed, both raisers' ($scopeF.agreed -and $scopeF.raised_by.Count -eq 2)
    $costF = @($g2.findings | Where-Object { $_.area -eq 'cost' })[0]
    Check '2c solo finding not agreed' (-not $costF.agreed -and $costF.raised_by.Count -eq 1)
    Check '2d result shape has revise_brief + reviewers + fail_open false' ($g2.Contains('revise_brief') -and $g2.Contains('reviewers') -and -not $g2.fail_open -and @($g2.reviewers) -contains 'p1' -and @($g2.reviewers) -contains 'p2')

    # ---- Case 3: one unparseable reviewer -> survivor still drives verdict ----
    $disp3 = {
        param($n,$p)
        if ($n -eq 'p1') { return @{ stdout='[{"severity":"important","area":"risk","summary":"no rollback"}]'; stderr=''; exit_code=0 } }
        else { return @{ stdout='no json here, sorry'; stderr=''; exit_code=0 } }
    }
    $g3 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('p1','p3') -Dispatcher $disp3
    Check '3a garbage reviewer listed unparsed' (@($g3.unparsed) -contains 'p3')
    Check '3b survivor finding still drives verdict' ($g3.verdict -eq 'revise' -and @($g3.findings).Count -eq 1)
    Check '3c not fail_open (partial unparsed only)' (-not $g3.fail_open)

    # ---- Case 4: ALL reviewers unparseable -> fail-open accept ----
    $disp4 = { param($n,$p) return @{ stdout='not json at all'; stderr=''; exit_code=0 } }
    $g4 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('p3','p4') -Dispatcher $disp4
    Check '4a all-unparsed -> accept' ($g4.verdict -eq 'accept')
    Check '4b reason flags fail-open accept' ($g4.reason -eq 'no usable review obtained (fail-open accept)')
    Check '4c fail_open true' ($g4.fail_open -eq $true)

    # ---- Case 5: understaffed (<2 reviewers) -> immediate fail-open, ZERO dispatch ----
    $script:dispatchCount5 = 0
    $disp5 = { param($n,$p) $script:dispatchCount5++; return @{ stdout='[]'; stderr=''; exit_code=0 } }
    $g5 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('only-one') -Dispatcher $disp5
    Check '5a understaffed -> accept' ($g5.verdict -eq 'accept')
    Check '5b fail_open true' ($g5.fail_open -eq $true)
    Check '5c reason mentions understaffed' ($g5.reason -match 'understaffed')
    Check '5d zero dispatches occurred' ($script:dispatchCount5 -eq 0)
    Check '5e reviewers echoes the lone name' ((($g5.reviewers -join ',') -eq 'only-one'))

    # Fail-loud rewrites the same early-understaffed path into an explicit degraded
    # result. It must still dispatch nobody, but it may no longer masquerade as accept.
    $script:dispatchCount5L = 0
    $disp5L = { param($n,$p) $script:dispatchCount5L++; return @{ stdout='[]'; stderr=''; exit_code=0 } }
    $g5L = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('only-one') -Dispatcher $disp5L -FailLoud
    Check '5f fail-loud understaffed -> degraded result' ($g5L.degraded -eq $true -and $g5L.verdict -eq 'degraded')
    Check '5g fail-loud understaffed is not fail-open' ($g5L.fail_open -eq $false)
    Check '5h fail-loud understaffed still dispatches nobody' ($script:dispatchCount5L -eq 0)

    # ---- Case 5.5: duplicate reviewer names collapse to one -> understaffed fail-open,
    #      ZERO dispatch. `-Reviewers dup,dup` must not pose as a competitive pair. ----
    $script:dispatchCount55 = 0
    $disp55 = { param($n,$p) $script:dispatchCount55++; return @{ stdout='[{"severity":"critical","area":"risk","summary":"x"}]'; stderr=''; exit_code=0 } }
    $g55 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('dup','dup') -Dispatcher $disp55
    Check '5.5a duplicate pair dedupes to understaffed -> fail_open' ($g55.fail_open -eq $true)
    Check '5.5b dedup fail-open verdict accept' ($g55.verdict -eq 'accept')
    Check '5.5c dedup reason mentions understaffed' ($g55.reason -match 'understaffed')
    Check '5.5d ZERO dispatches (never posed as a pair)' ($script:dispatchCount55 -eq 0)
    Check '5.5e reviewers echoes the single deduped name' ((($g55.reviewers -join ',') -eq 'dup'))
    # Case-insensitive dedupe: Codex vs codex is the same reviewer.
    $script:dispatchCount55b = 0
    $disp55b = { param($n,$p) $script:dispatchCount55b++; return @{ stdout='[]'; stderr=''; exit_code=0 } }
    $g55b = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('Codex','codex') -Dispatcher $disp55b
    Check '5.5f case-insensitive dedupe -> fail_open, zero dispatch' ($g55b.fail_open -eq $true -and $script:dispatchCount55b -eq 0)

    # ---- Case 6: roster resolution — no -Reviewers, fixture grants plan-review to 2 ----
    $disp6 = { param($n,$p) return @{ stdout='[]'; stderr=''; exit_code=0 } }
    $g6 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -FleetPath $fixtureFleet -ToolsPath $fixtureTools -Dispatcher $disp6
    Check '6a resolves exactly the 2 plan-review claimants' (@($g6.reviewers).Count -eq 2 -and (@($g6.reviewers) -contains 'plan-rev-a') -and (@($g6.reviewers) -contains 'plan-rev-b'))
    Check '6b empty findings from both -> accept' ($g6.verdict -eq 'accept' -and -not $g6.fail_open)

    # ---- Case 7: nonzero exit_code from a reviewer -> treated unparsed ----
    $disp7 = {
        param($n,$p)
        if ($n -eq 'p1') { return @{ stdout='[{"severity":"minor","area":"cost","summary":"nit"}]'; stderr=''; exit_code=0 } }
        else { return @{ stdout='[{"severity":"critical","area":"risk","summary":"would have been critical"}]'; stderr='boom'; exit_code=1 } }
    }
    $g7 = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('p1','p2') -Dispatcher $disp7
    Check '7a nonzero exit reviewer unparsed' (@($g7.unparsed) -contains 'p2')
    Check '7b its findings excluded from verdict (accept, minor only)' ($g7.verdict -eq 'accept' -and $g7.counts.critical -eq 0)
    $g7L = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('p1','p2') -Dispatcher $disp7 -FailLoud
    Check '7c fail-loud requires two usable reviews' ($g7L.degraded -eq $true -and @($g7L.degraded_reviewers) -contains 'p2')

    $g4L = Invoke-PlanGate -Goal 'g' -PlanJson '{}' -Reviewers @('p3','p4') -Dispatcher $disp4 -FailLoud
    Check '7d fail-loud all-unparsed is degraded' ($g4L.degraded -eq $true -and @($g4L.degraded_reviewers).Count -eq 2)

    # ---- Case 8: Build-PlanReviewPrompt contract ----
    $goal8 = 'migrate the billing service to v2'
    $plan8 = 'plan body with "embedded quotes" and a literal $1 token'
    $prompt8 = Build-PlanReviewPrompt -Goal $goal8 -PlanJson $plan8
    Check '8a contains goal text' ($prompt8.Contains($goal8))
    Check '8b contains plan JSON verbatim (quotes + literal $1 preserved)' ($prompt8.Contains($plan8))
    Check '8c contains area vocabulary' ($prompt8.Contains('scope|ordering|cost|risk|missing-task|overbuild|capability|reversibility'))
    Check '8d contains ONLY-JSON instruction' ($prompt8.Contains('ONLY a JSON array'))
    Check '8e names goal + plan sections' ($prompt8.Contains('## Goal') -and $prompt8.Contains('## Plan (JSON)'))

    # ---- Case 9: Format-ReviseBrief ordering (agreed-first, then severity desc) ----
    $fset9 = @(
        @{severity='important';area='scope';summary='agreed important';agreed=$true;raised_by=@('p1','p2')},
        @{severity='critical';area='risk';summary='solo critical';agreed=$false;raised_by=@('p1')},
        @{severity='minor';area='style';summary='naming nit';agreed=$false;raised_by=@('p2')})
    $brief9 = Format-ReviseBrief -Verdict @{verdict='revise'} -MergedFindings $fset9
    Check '9a brief lists critical + important' ($brief9 -match 'agreed important' -and $brief9 -match 'solo critical')
    Check '9b brief excludes minor' ($brief9 -notmatch 'naming nit')
    Check '9c agreed group sorts before solo, even when solo is higher severity' ($brief9.IndexOf('agreed important') -lt $brief9.IndexOf('solo critical'))
    Check '9d header names REVISE BRIEF' ($brief9 -match '^REVISE BRIEF')
    $accBrief9 = Format-ReviseBrief -Verdict @{verdict='accept'} -MergedFindings @()
    Check '9e accept -> no-op line' ($accBrief9 -eq 'No revision needed — plan accepted as-is.')

    # ---- Case 10: Format-PlanGateReport shows fail-open note ----
    $failOpenResult = @{
        verdict='accept'; reason='understaffed plan-review roster (fewer than 2 reviewers) — fail-open'
        counts=@{critical=0;important=0;minor=0}; findings=@(); unparsed=@(); fail_open=$true
    }
    $rep10 = Format-PlanGateReport -Result $failOpenResult
    Check '10a report shows PLAN GATE header + verdict' ($rep10.Contains('PLAN GATE') -and $rep10.Contains('ACCEPT'))
    Check '10b report contains fail-open note' ($rep10.Contains('Note: gate failed open (understaffed plan-review roster) — plan NOT peer-reviewed.'))

    # Sanity: a non-fail-open report omits the note.
    $normalResult = @{
        verdict='revise'; reason='1 important finding(s)'
        counts=@{critical=0;important=1;minor=0}
        findings=@(@{severity='important';area='scope';summary='x';agreed=$false;raised_by=@('p1')})
        unparsed=@(); fail_open=$false
    }
    $rep10b = Format-PlanGateReport -Result $normalResult
    Check '10c non-fail-open report omits the note' (-not $rep10b.Contains('failed open'))

    # ---- Case 11: CLI child-process smokes (fleet-plan-gate.ps1) — hermetic
    #      via the BATON_PLANGATE_TEST_DISPATCH env seam, never a real model. ----
    $cliScript = Join-Path $PSScriptRoot 'fleet-plan-gate.ps1'
    $planFile = Join-Path $tmpDir 'plan.json'
    Set-Content -LiteralPath $planFile -Encoding utf8NoBOM -Value '{"tasks":[]}'

    $out11a = & pwsh -NoProfile -File $cliScript run --goal 'g' 2>&1 | Out-String
    Check '11a missing --plan -> exit 2' ($LASTEXITCODE -eq 2)
    Check '11a stderr non-empty' ($out11a.Trim().Length -gt 0)

    $missingPlan = Join-Path $tmpDir 'does-not-exist.json'
    & pwsh -NoProfile -File $cliScript run --goal 'g' --plan $missingPlan 2>$null | Out-Null
    Check '11b nonexistent plan path -> exit 2' ($LASTEXITCODE -eq 2)

    $dispatchEmpty = Join-Path $tmpDir 'dispatch-empty.ps1'
    Set-Content -LiteralPath $dispatchEmpty -Encoding utf8NoBOM -Value @'
function Invoke-TestPlanGateDispatch($name, $prompt) {
    return @{ stdout = '[]'; stderr = ''; exit_code = 0 }
}
'@
    $env:BATON_PLANGATE_TEST_DISPATCH = $dispatchEmpty
    try {
        $out11c = & pwsh -NoProfile -File $cliScript run --goal 'g' --plan $planFile --reviewers p1,p2 2>&1 | Out-String
        $exit11c = $LASTEXITCODE
        Check '11c happy path stub reviewers [] -> exit 0' ($exit11c -eq 0)
        Check '11c stdout shows PLAN GATE ACCEPT' ($out11c -match 'PLAN GATE .* verdict: ACCEPT')

        $out11e = & pwsh -NoProfile -File $cliScript run --goal 'g' --plan $planFile --reviewers p1,p2 --json 2>&1 | Out-String
        $json11e = $null
        try { $json11e = $out11e | ConvertFrom-Json } catch { }
        Check '11e --json output parses and has verdict' ($null -ne $json11e -and $null -ne $json11e.verdict)
    } finally {
        Remove-Item Env:\BATON_PLANGATE_TEST_DISPATCH -ErrorAction SilentlyContinue
    }

    $dispatchCritical = Join-Path $tmpDir 'dispatch-critical.ps1'
    Set-Content -LiteralPath $dispatchCritical -Encoding utf8NoBOM -Value @'
function Invoke-TestPlanGateDispatch($name, $prompt) {
    return @{ stdout = '[{"severity":"critical","area":"risk","summary":"will break prod"}]'; stderr = ''; exit_code = 0 }
}
'@
    $env:BATON_PLANGATE_TEST_DISPATCH = $dispatchCritical
    try {
        $out11d = & pwsh -NoProfile -File $cliScript run --goal 'g' --plan $planFile --reviewers p1,p2 2>&1 | Out-String
        $exit11d = $LASTEXITCODE
        Check '11d critical finding -> exit 1' ($exit11d -eq 1)
        Check '11d stdout shows REJECT' ($out11d -match 'REJECT')
        Check '11d stdout shows revise brief header' ($out11d -match 'REVISE BRIEF')
    } finally {
        Remove-Item Env:\BATON_PLANGATE_TEST_DISPATCH -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    if ($null -eq $origBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $origBatonHome }

    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
