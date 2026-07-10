#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/gate-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: severity rank + per-reviewer parse (pure) ----
    Check 'G1 critical -> 3'  ((Get-FindingSeverityRank 'critical')  -eq 3)
    Check 'G2 important -> 2' ((Get-FindingSeverityRank 'important') -eq 2)
    Check 'G3 minor -> 1'     ((Get-FindingSeverityRank 'minor')     -eq 1)
    Check 'G4 unknown -> 0'   ((Get-FindingSeverityRank 'banana')    -eq 0)
    Check 'G5 case-insensitive' ((Get-FindingSeverityRank 'CRITICAL') -eq 3)

    $bare = Get-ReviewFindings -Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
    Check 'G6 bare array parses' ($bare.parsed -and @($bare.findings).Count -eq 1 -and $bare.findings[0].severity -eq 'important')
    $empty = Get-ReviewFindings -Output '[]'
    Check 'G7 empty array -> parsed, 0 findings' ($empty.parsed -and @($empty.findings).Count -eq 0)
    $bad = Get-ReviewFindings -Output 'I could not find any structured issues, sorry.'
    Check 'G8 garbage -> not parsed' (-not $bad.parsed -and @($bad.findings).Count -eq 0)
    $prose = Get-ReviewFindings -Output 'Here are my findings: [{"severity":"minor","area":"style","summary":"naming"}] — done.'
    Check 'G9 array-in-prose parses' ($prose.parsed -and @($prose.findings).Count -eq 1 -and $prose.findings[0].area -eq 'style')
    $unk = Get-ReviewFindings -Output '[{"severity":"blocker","area":"x","summary":"y"}]'
    Check 'G10 unknown severity floored to minor, not dropped' ($unk.parsed -and @($unk.findings).Count -eq 1 -and $unk.findings[0].severity -eq 'minor')
    $trim = Get-ReviewFindings -Output '[{"severity":" Important ","area":"  perf ","summary":" slow "}]'
    Check 'G11 fields normalized/trimmed' ($trim.findings[0].severity -eq 'important' -and $trim.findings[0].area -eq 'perf' -and $trim.findings[0].summary -eq 'slow')

    # ---- Task 2: reconcile + verdict (pure) ----
    $r1 = @{ reviewer='r1'; parsed=$true; findings=@(
        @{severity='important';area='correctness';summary='off by one'},
        @{severity='minor';area='style';summary='naming'}) }
    $r2 = @{ reviewer='r2'; parsed=$true; findings=@(
        @{severity='critical';area='correctness';summary='off by one'}) }
    $m = Merge-ReviewFindings -Reviews @($r1,$r2)
    Check 'G12 same finding merges to one' (@($m.merged).Count -eq 2)
    $corr = @($m.merged | Where-Object { $_.area -eq 'correctness' })[0]
    Check 'G13 merge keeps higher severity' ($corr.severity -eq 'critical')
    Check 'G14 merged finding agreed + both raisers' ($corr.agreed -and $corr.raised_by.Count -eq 2)
    $styl = @($m.merged | Where-Object { $_.area -eq 'style' })[0]
    Check 'G15 solo finding not agreed' (-not $styl.agreed -and $styl.raised_by.Count -eq 1)

    $rbad = @{ reviewer='r3'; parsed=$false; findings=@() }
    $m2 = Merge-ReviewFindings -Reviews @($r1,$rbad)
    Check 'G16 unparsed reviewer listed' (@($m2.unparsed) -contains 'r3' -and @($m2.merged).Count -eq 2)
    $m3 = Merge-ReviewFindings -Reviews @($rbad)
    Check 'G17 all-unparsed -> empty merged' (@($m3.merged).Count -eq 0)

    $vc = Get-AcceptanceVerdict -MergedFindings @(@{severity='critical';area='a';summary='b'})
    Check 'G18 critical -> reject' ($vc.verdict -eq 'reject' -and $vc.counts.critical -eq 1)
    $vp = Get-AcceptanceVerdict -MergedFindings @(@{severity='important';area='a';summary='b'})
    Check 'G19 important -> polish' ($vp.verdict -eq 'polish' -and $vp.counts.important -eq 1)
    $vm = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'})
    Check 'G20 minor only -> accept' ($vm.verdict -eq 'accept' -and $vm.counts.minor -eq 1)
    $vn = Get-AcceptanceVerdict -MergedFindings @()
    Check 'G21 none -> accept, reason no findings' ($vn.verdict -eq 'accept' -and $vn.reason -match 'no findings')
    $vt = Get-AcceptanceVerdict -MergedFindings @(@{severity='minor';area='a';summary='b'}) -PolishAt 'minor'
    Check 'G22 tunable threshold: minor -> polish when PolishAt=minor' ($vt.verdict -eq 'polish')

    # ---- Task 3: formatters (pure) ----
    $fset = @(
        @{severity='critical';area='correctness';summary='off by one';agreed=$true;raised_by=@('r1','r2')},
        @{severity='important';area='security';summary='unescaped input';agreed=$false;raised_by=@('r1')},
        @{severity='minor';area='style';summary='naming';agreed=$false;raised_by=@('r2')})
    $brief = Format-PolishBrief -Verdict @{verdict='polish'} -MergedFindings $fset
    Check 'G23 brief lists critical + important' ($brief -match 'off by one' -and $brief -match 'unescaped input')
    Check 'G24 brief excludes minor' ($brief -notmatch 'naming')
    Check 'G25 brief agreed before solo' ($brief.IndexOf('off by one') -lt $brief.IndexOf('unescaped input'))
    $acc = Format-PolishBrief -Verdict @{verdict='accept'} -MergedFindings @()
    Check 'G26 accept brief says no polish' ($acc -match 'No polish needed')

    $rep = Format-GateReport -Result @{
        verdict='polish'; reason='1 important finding(s)'
        counts=@{critical=0;important=1;minor=1}; findings=$fset[1..2]; unparsed=@('r3') }
    Check 'G27 report shows verdict + counts' ($rep -match 'POLISH' -and $rep -match '1 important')
    Check 'G28 report groups solo + notes unparsed' ($rep -match 'Solo' -and $rep -match 'r3')

    # ---- Task 4: seamed Invoke-AcceptanceGate (injected dispatcher) ----
    Check 'G29 prompt carries schema + task + artifact' (
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'severity' -and
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'do x' -and
        (Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo') -match 'fn foo')

    $disp = {
        param($n,$p)
        if ($n -eq 'r1') { return @{ stdout='[{"severity":"important","area":"correctness","summary":"off by one"},{"severity":"minor","area":"style","summary":"naming"}]'; stderr=''; exit_code=0 } }
        elseif ($n -eq 'r2') { return @{ stdout='[{"severity":"important","area":"correctness","summary":"off by one"}]'; stderr=''; exit_code=0 } }
        else { return @{ stdout='no json here'; stderr=''; exit_code=0 } }
    }
    $g = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r2') -Dispatcher $disp
    Check 'G30 two reviewers -> polish, 2 findings' ($g.verdict -eq 'polish' -and @($g.findings).Count -eq 2)
    $corrG = @($g.findings | Where-Object { $_.area -eq 'correctness' })[0]
    Check 'G31 shared finding agreed' ($corrG.agreed)
    Check 'G32 result shape' ($g.Contains('polish_brief') -and $g.Contains('reviews') -and @($g.reviews).Count -eq 2)

    $g2 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r1','r3') -Dispatcher $disp
    Check 'G33 garbage reviewer degraded, survivor counted' (@($g2.unparsed) -contains 'r3' -and $g2.verdict -eq 'polish')
    $g3 = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('r3') -Dispatcher $disp
    Check 'G34 all-unparsed -> accept, flagged' ($g3.verdict -eq 'accept' -and $g3.reason -match 'no usable review')

    # zero reviewers + a fleet with no review-capable provider -> throws
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "gate-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $emptyFleet = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -LiteralPath $emptyFleet -Encoding utf8 -Value @'
providers:
  - name: plain-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'echo {{prompt}}'
'@
    $emptyTools = Join-Path $tmpDir 'tools.yaml'
    Set-Content -LiteralPath $emptyTools -Encoding utf8 -Value "tools: []`n"
    $threw = $false
    try { Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -Reviewers @() -FleetPath $emptyFleet -ToolsPath $emptyTools } catch { $threw = $true }
    Check 'G35 no reviewers -> throws' ($threw)

    # ---- Task 4: CLI (child process, hermetic BATON_HOME) ----
    $canned = Join-Path $tmpDir 'canned-review.ps1'
    Set-Content -LiteralPath $canned -Encoding utf8 -Value @'
[void]([Console]::In.ReadToEnd())
Write-Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
'@
    $cliFleet = Join-Path $tmpDir 'cli-fleet.yaml'
    Set-Content -LiteralPath $cliFleet -Encoding utf8 -Value @"
providers:
  - name: rev-canned
    kind: cli
    enabled: true
    cost_tier: paid
    stdin: true
    capabilities: [review]
    command_template: 'pwsh -NoProfile -File "$canned"'
"@
    $artFx = Join-Path $tmpDir 'artifact.txt'
    Set-Content -LiteralPath $artFx -Encoding utf8 -Value 'function foo() { return 1 }'
    $gateCli = Join-Path $PSScriptRoot 'fleet-gate.ps1'
    $env:BATON_HOME = $tmpDir
    Copy-Item -LiteralPath $cliFleet -Destination (Join-Path $tmpDir 'fleet.yaml') -Force
    try {
        $cliOut = & pwsh -NoProfile -File $gateCli run --task 'do x' --file $artFx --reviewers 'rev-canned' 2>&1 | Out-String
        Check 'G36 CLI run prints verdict' ($cliOut -match 'ACCEPTANCE GATE' -and $cliOut -match 'POLISH')
        $cliJson = & pwsh -NoProfile -File $gateCli run --task 'do x' --file $artFx --reviewers 'rev-canned' --json 2>&1 | Out-String
        Check 'G37 CLI --json has verdict key' ($cliJson -match '"verdict"')
        & pwsh -NoProfile -File $gateCli run --file $artFx --reviewers 'rev-canned' 2>$null | Out-Null
        Check 'G38 CLI missing --task -> exit 2' ($LASTEXITCODE -eq 2)
        & pwsh -NoProfile -File $gateCli bogus 2>$null | Out-Null
        Check 'G39 CLI unknown subcommand -> exit 2' ($LASTEXITCODE -eq 2)
    }
    finally {
        Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }

    # ---- Task E: findings parse hardening for prompt-echoing reviewers (codex) ----
    # A realistic codex-shaped raw reply: CLI banner + echoed prompt (carrying the
    # findings SCHEMA array whose severity has '|', and the plan's own arrays incl.
    # ["t1"]) + the ANSWER array + a duplicated answer whose closing ] is split from
    # the objects by a `tokens used` trailer (invalid JSON). Cribbed from codex-raw.txt.
    $codexRaw = @'
OpenAI Codex v0.144.0
--------
model: gpt-5.6-sol
--------
user
Respond with ONLY a JSON array matching this schema exactly — no prose.

Schema:
[
  { "severity": "critical|important|minor",
    "area": "scope|ordering|cost",
    "summary": "<one line: the specific issue>" }
]

## Plan (JSON)
{
  "tasks": [
    { "id": "t1", "description": "delete the existing test suite", "depends_on": [] },
    { "id": "t2", "description": "add the --csv flag", "depends_on": ["t1"] }
  ]
}

codex
[
  { "severity": "critical", "area": "scope", "summary": "t1 destructively deletes the usage test suite" },
  { "severity": "important", "area": "ordering", "summary": "t2 depends on the unrelated deletion t1" }
]
[
  { "severity": "critical", "area": "scope", "summary": "t1 destructively deletes the usage test suite" },
  { "severity": "important", "area": "ordering", "summary": "t2 depends on the unrelated deletion t1" }
tokens used
14,350
]
'@
    $ce = Get-ReviewFindings -Output $codexRaw
    Check 'GE1 codex echo: parsed from the ANSWER, not echo' ($ce.parsed -and @($ce.findings).Count -eq 2)
    $ceSev = @($ce.findings | ForEach-Object { $_.severity })
    Check 'GE2 codex echo: answer severities (critical+important), no schema placeholder' (
        ($ceSev -contains 'critical') -and ($ceSev -contains 'important') -and
        (-not (@($ce.findings | Where-Object { $_.summary -match 'one line' }).Count)))

    # Echoed schema only, no answer array (and no bare []) -> not parsed.
    $schemaOnly = @'
OpenAI Codex v0.144.0
user
Respond with ONLY a JSON array matching this schema.

Schema:
[
  { "severity": "critical|important|minor",
    "area": "scope|ordering",
    "summary": "the specific issue" }
]

codex
'@
    $so = Get-ReviewFindings -Output $schemaOnly
    Check 'GE3 echoed-schema-only reply -> not parsed' (-not $so.parsed -and @($so.findings).Count -eq 0)

    # Last balanced block is an echoed plan fragment ["t2"]; the earlier valid findings
    # array must win via shape validation.
    $tailNoise = @'
Here is my review of the plan:
[
  { "severity": "minor", "area": "style", "summary": "rename foo to bar for clarity" }
]
Referenced tasks: ["t2"]
'@
    $tn = Get-ReviewFindings -Output $tailNoise
    Check 'GE4 findings win over trailing ["t2"] fragment' (
        $tn.parsed -and @($tn.findings).Count -eq 1 -and $tn.findings[0].summary -match 'rename foo')

    # Get-FindingsJsonBlocks: brackets inside a JSON string do not split a block.
    $blkStr = '[{"severity":"minor","area":"style","summary":"index expr a[0] is fine"}]'
    $blks = @(Get-FindingsJsonBlocks -Raw $blkStr)
    Check 'GE5 brackets inside strings do not split blocks' ($blks.Count -eq 1)
    $bs = Get-ReviewFindings -Output $blkStr
    Check 'GE6 string-embedded brackets still parse to one finding' ($bs.parsed -and @($bs.findings).Count -eq 1)
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
