#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/research-gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: pure parse / escalation / fallback ----
    $adoptJson = '{"recommendation":"adopt","options":[{"name":"markitdown","kind":"library","fit":"strong","note":"doc->md"}],"rationale":"exists","next_action":"spike","confidence":0.82,"risk_if_wrong":"low"}'
    Check 'T1 json block extracted from prose' ((Get-GateJsonBlock -Raw ("noise " + $adoptJson + " tail")) -eq $adoptJson)
    Check 'T2 no json -> empty' ((Get-GateJsonBlock -Raw 'no braces here') -eq '')

    $v = ConvertTo-GateHashtable -RawStdout ('```json' + "`n" + $adoptJson + "`n" + '```')
    Check 'T3 fenced json parses recommendation' ($v.recommendation -eq 'adopt')
    Check 'T4 options normalized to array' (@($v.options).Count -eq 1)
    Check 'T5 escalation defaults injected' (($v.escalated -eq $false) -and ($v.ContainsKey('escalation_needed')))
    Check 'T6 garbage -> null' ($null -eq (ConvertTo-GateHashtable -RawStdout 'not json'))

    Check 'T7 low confidence escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.5; risk_if_wrong='low'; recommendation='adopt' })
    Check 'T8 high risk escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='high'; recommendation='adopt' })
    Check 'T9 inconclusive escalates' (Test-GateEscalationNeeded -Verdict @{ confidence=0.9; risk_if_wrong='low'; recommendation='inconclusive' })
    Check 'T10 confident low-risk adopt does not escalate' (-not (Test-GateEscalationNeeded -Verdict @{ confidence=0.85; risk_if_wrong='low'; recommendation='adopt' }))

    $fb = New-GateFallback -Reason 'no worker'
    Check 'T11 fallback is inconclusive' ($fb.recommendation -eq 'inconclusive')
    Check 'T12 fallback has no options' (@($fb.options).Count -eq 0)
    Check 'T13 fallback flagged for escalation' ($fb.escalation_needed -eq $true)

    # ---- Task 2: evidence / prompt / memo (pure) ----
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "rg-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $toolsYaml = @"
tools:
  - name: docling
    enabled: true
    cost_tier: local
    capability: pdf-extract
  - name: disabled-tool
    enabled: false
    cost_tier: local
    capability: ocr
"@
    $tmpTools = Join-Path $tmpDir 'tools.yaml'
    Set-Content -Path $tmpTools -Value $toolsYaml -Encoding utf8NoBOM
    $reg = Get-ToolsRegistrySummary -Path $tmpTools
    Check 'T14 registry lists enabled tool' ($reg -contains 'docling — pdf-extract (local)')
    Check 'T15 registry omits disabled tool' (-not (@($reg) | Where-Object { $_ -like 'disabled-tool*' }))

    $jobDir = Join-Path $tmpDir 'job1'
    $ensDir = Join-Path $jobDir 'phases/research/ensemble-2026-06-18T10-00-00'
    New-Item -ItemType Directory -Force -Path $ensDir | Out-Null
    Set-Content -Path (Join-Path $ensDir 'synthesis.md') -Value 'PRIOR FINDINGS HERE' -Encoding utf8NoBOM
    Check 'T16 ensemble synthesis found' ((Get-EnsembleSynthesis -JobDir $jobDir) -match 'PRIOR FINDINGS')
    Check 'T17 no job dir -> empty synthesis' ((Get-EnsembleSynthesis -JobDir (Join-Path $tmpDir 'nojob')) -eq '')

    $prompt = Build-GatePrompt -TaskText 'convert pdfs to markdown' -RegistryLines $reg -EnsembleText 'PRIOR FINDINGS' -KbHits @() -SearchEvidence @()
    Check 'T18 prompt includes task' ($prompt -match 'convert pdfs to markdown')
    Check 'T19 prompt includes registry evidence' ($prompt -match 'docling')
    Check 'T20 prompt includes verdict schema' ($prompt -match 'build\|adopt\|adapt\|inconclusive')

    $memo = Format-GateMemo -Verdict @{ recommendation='adopt'; confidence=0.8; risk_if_wrong='low'
        options=@([pscustomobject]@{ name='markitdown'; kind='library'; fit='strong'; note='doc->md' })
        rationale='exists already'; next_action='spike it'; escalated=$false }
    Check 'T21 memo shows recommendation' ($memo -match 'ADOPT')
    Check 'T22 memo lists option' ($memo -match 'markitdown')
    Check 'T23 memo shows next action' ($memo -match 'spike it')

    # ---- Task 3: seamed evidence search ----
    $script:searchCalls = 0
    $stubSearcher = { param($q) $script:searchCalls++; @(
        [pscustomobject]@{ source='web'; title='markitdown'; snippet='doc to md'; url='https://x/md' }) }
    Check 'T24 offline makes zero searcher calls' (
        ((Invoke-EvidenceSearch -Query 'q' -Searcher $stubSearcher).Count -eq 0) -and ($script:searchCalls -eq 0))
    $ev = Invoke-EvidenceSearch -Query 'q' -Searcher $stubSearcher -Deep
    Check 'T25 deep gathers normalized evidence' ((@($ev).Count -eq 1) -and ($ev[0].title -eq 'markitdown') -and ($script:searchCalls -eq 1))
    $throwSearcher = { param($q) throw 'network down' }
    Check 'T26 searcher throw degrades to empty (no throw)' ((Invoke-EvidenceSearch -Query 'q' -Searcher $throwSearcher -Deep).Count -eq 0)

    # ---- Task 4: orchestration (stubbed dispatcher + searcher) ----
    $fleetYaml = @"
providers:
  - name: rg-haiku
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [research]
    command_template: 'echo'
  - name: rg-sonnet
    kind: cli
    enabled: true
    cost_tier: paid
    capabilities: [research]
    command_template: 'echo'
"@
    $tmpFleet = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -Path $tmpFleet -Value $fleetYaml -Encoding utf8NoBOM

    $adoptReply = '{"recommendation":"adopt","options":[{"name":"markitdown","kind":"library","fit":"strong","note":"x"}],"rationale":"r","next_action":"n","confidence":0.85,"risk_if_wrong":"low"}'
    $okDisp = { param($c,$p) @{ stdout=$adoptReply; stderr=''; exit_code=0; duration_s=1 } }
    $rg = Invoke-ResearchGate -Task 'convert pdfs' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp
    Check 'T27 adopt verdict returned' ($rg.recommendation -eq 'adopt')
    Check 'T28 not escalated when confident' (-not ($rg.escalated -eq $true))

    $lowReply  = '{"recommendation":"adopt","options":[],"rationale":"r","next_action":"n","confidence":0.5,"risk_if_wrong":"low"}'
    $highReply = '{"recommendation":"adopt","options":[{"name":"pandoc","kind":"tool","fit":"strong","note":"y"}],"rationale":"r2","next_action":"n2","confidence":0.9,"risk_if_wrong":"low"}'
    $script:dispN = 0
    $escDisp = { param($c,$p) $script:dispN++; if ($script:dispN -eq 1) { @{ stdout=$lowReply; exit_code=0 } } else { @{ stdout=$highReply; exit_code=0 } } }
    $rg2 = Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $escDisp
    Check 'T29 low confidence triggers escalation' (($rg2.escalated -eq $true) -and ($rg2.confidence -eq 0.9))
    Check 'T30 escalated_from records first pick' ($null -ne $rg2.escalated_from)

    $failDisp = { param($c,$p) @{ stdout=''; stderr='boom'; exit_code=1 } }
    $rg3 = Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $failDisp
    Check 'T31 dispatch failure -> fallback inconclusive' ($rg3.recommendation -eq 'inconclusive')

    $emptyFleet = Join-Path $tmpDir 'empty-fleet.yaml'
    Set-Content -Path $emptyFleet -Value "providers: []" -Encoding utf8NoBOM
    $rg4 = Invoke-ResearchGate -Task 't' -FleetPath $emptyFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp
    Check 'T32 no worker -> fallback inconclusive' ($rg4.recommendation -eq 'inconclusive')

    $script:deepCalls = 0
    $deepSearcher = { param($q) $script:deepCalls++; @() }
    [void](Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp -Searcher $deepSearcher)
    Check 'T33 offline run makes zero searcher calls' ($script:deepCalls -eq 0)
    [void](Invoke-ResearchGate -Task 't' -FleetPath $tmpFleet -ToolsPath $tmpTools -NoKb -Dispatcher $okDisp -Searcher $deepSearcher -Deep)
    Check 'T34 deep run invokes searcher' ($script:deepCalls -eq 1)

    # ---- Task 5: CLI (child process; zero network) ----
    $cli = Join-Path $PSScriptRoot 'fleet-research-gate.ps1'
    $env:BATON_RG_TEST_JSON  = $adoptReply
    $env:BATON_RG_TEST_FLEET = $tmpFleet
    $env:BATON_RG_TEST_TOOLS = $tmpTools
    $env:BATON_HOME = $tmpDir   # no current-job.json here -> standalone path
    $stdout = & pwsh -NoProfile -File $cli -Text 'convert pdfs to markdown' 2>&1 | Out-String
    Check 'T35 CLI standalone prints memo to stdout' ($stdout -match 'RESEARCH GATE' -and $stdout -match 'ADOPT')
    $jsonStdout = & pwsh -NoProfile -File $cli -Text 'x' -Json 2>&1 | Out-String
    Check 'T36 CLI --json emits json' ($jsonStdout -match '"recommendation"')
    $outFile = Join-Path $tmpDir 'memo.md'
    & pwsh -NoProfile -File $cli -Text 'x' -Out $outFile 2>&1 | Out-Null
    Check 'T37 CLI --out writes file' ((Test-Path $outFile) -and ((Get-Content $outFile -Raw) -match 'RESEARCH GATE'))

    # Active-job path: writes into phases/research/
    $jobId = 'rgjob'
    $jobHome = Join-Path $tmpDir 'jobhome'
    New-Item -ItemType Directory -Force -Path (Join-Path $jobHome "jobs/$jobId") | Out-Null
    Set-Content -Path (Join-Path $jobHome 'current-job.json') -Value (@{ job_id=$jobId; phase='research' } | ConvertTo-Json) -Encoding utf8NoBOM
    $env:BATON_HOME = $jobHome
    & pwsh -NoProfile -File $cli -Text 'convert pdfs' 2>&1 | Out-Null
    $gateFiles = Get-ChildItem -Path (Join-Path $jobHome "jobs/$jobId/phases/research") -Filter 'gate-*.md' -ErrorAction SilentlyContinue
    Check 'T38 CLI within a job writes gate memo to research phase' (@($gateFiles).Count -ge 1)
    Remove-Item Env:\BATON_RG_TEST_JSON, Env:\BATON_RG_TEST_FLEET, Env:\BATON_RG_TEST_TOOLS, Env:\BATON_HOME -ErrorAction SilentlyContinue
}
finally {
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
}
