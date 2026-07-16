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

    # ---- Named review panel: roster, prompt, routing, provenance, degradation ----
    $roleTmp = Join-Path $env:TEMP "gate-role-test-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $roleTmp | Out-Null
    $rolesFixture = Join-Path $roleTmp 'review-roles.yaml'
    Set-Content -LiteralPath $rolesFixture -Encoding utf8NoBOM -Value @'
roles:
  - name: correctness
    lens: "Find logic defects only."
    tier: strong
    enabled: true
  - name: disabled-role
    lens: "This role must not run."
    tier: strong
    enabled: false
  - name: malformed-role
    tier: cheap
    enabled: true
  - name: simplicity
    lens: "Find needless complexity."
    tier: cheap
    enabled: true
'@
    $selectorOriginal = (Get-Item Function:\Select-Capability).ScriptBlock
    try {
        $rolePrompt = Build-ReviewPrompt -Task 'do x' -Artifact 'fn foo' -Role @{
            name = 'security'; lens = 'TRY TO BREAK IT.'
        }
        $rolePromptOpening = @($rolePrompt -split "\r?\n")[0]
        Check 'GP1 role prompt uses role identity as the opening line' (
            $rolePromptOpening -eq 'You are the security reviewer. TRY TO BREAK IT.' -and
            $rolePrompt -notmatch 'You are a strict code/work reviewer')

        $parsedRoles = @(Get-ReviewRoles -Path $rolesFixture)
        Check 'GP2 roster parses valid enabled roles and skips enabled:false' (
            $parsedRoles.Count -eq 2 -and @($parsedRoles.name) -contains 'correctness' -and
            @($parsedRoles.name) -contains 'simplicity' -and @($parsedRoles.name) -notcontains 'disabled-role')
        Check 'GP3 malformed role is tolerated and rejected' (@($parsedRoles.name) -notcontains 'malformed-role')
        Check 'GP4 missing roster returns empty array' (
            @(Get-ReviewRoles -Path (Join-Path $roleTmp 'missing.yaml')).Count -eq 0)

        $seedRefs = Join-Path $roleTmp 'references'
        New-Item -ItemType Directory -Force -Path $seedRefs | Out-Null
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'references/review-roles.yaml') `
            -Destination (Join-Path $seedRefs 'review-roles.yaml')
        $savedBatonHome = $env:BATON_HOME
        try {
            $env:BATON_HOME = Join-Path $roleTmp 'baton-home'
            $seededConfigs = @(Initialize-BatonHome -ReferencesDir $seedRefs)
            $seededRolesPath = Join-Path $env:BATON_HOME 'review-roles.yaml'
            $seededRoleCount = @(Get-ReviewRoles -Path $seededRolesPath).Count
            Set-Content -LiteralPath $seededRolesPath -Encoding utf8NoBOM -Value 'user: edited'
            $secondSeed = @(Initialize-BatonHome -ReferencesDir $seedRefs)
            Check 'GP5 initializer seeds review roster once and never overwrites it' (
                $seededConfigs -contains 'review-roles.yaml' -and
                $seededRoleCount -eq 6 -and
                $secondSeed -notcontains 'review-roles.yaml' -and
                (Get-Content -LiteralPath $seededRolesPath -Raw).Trim() -eq 'user: edited')
        }
        finally {
            if ($null -eq $savedBatonHome) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
            else { $env:BATON_HOME = $savedBatonHome }
        }

        $script:selectorCalls = [System.Collections.ArrayList]@()
        $script:skipCheap = $false
        $script:skipAll = $false
        Set-Item -Path Function:\Select-Capability -Value {
            param(
                [string]$Capability,
                [string]$MaxCostTier,
                [string]$FleetPath,
                [string]$ToolsPath
            )
            [void]$script:selectorCalls.Add($MaxCostTier)
            if ($script:skipAll) { return @() }
            if ($script:skipCheap -and $MaxCostTier -eq 'free') { return @() }
            $selectedName = if ($MaxCostTier -eq 'free') { 'cheap-model' } else { 'strong-model' }
            return [pscustomobject]@{ name = $selectedName; cost_tier = $MaxCostTier }
        }
        $panelDispatcher = {
            param($providerName, $reviewPrompt)
            return @{
                stdout = "[{`"severity`":`"minor`",`"area`":`"provider-area`",`"summary`":`"$providerName finding`"}]"
                stderr = ''; exit_code = 0
            }
        }
        $panelResult = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $panelDispatcher
        Check 'GP6 roster presence auto-selects panel and findings carry role provenance' (
            @($panelResult.findings).Count -eq 2 -and
            @($panelResult.findings.area) -contains 'correctness' -and
            @($panelResult.findings.area) -contains 'simplicity')
        Check 'GP7 strong and cheap roles constrain Select-Capability to paid and free' (
            @($script:selectorCalls) -contains 'paid' -and @($script:selectorCalls) -contains 'free')

        $script:skipCheap = $true
        $emptyDispatcher = { param($providerName, $reviewPrompt); return @{ stdout='[]'; stderr=''; exit_code=0 } }
        $loudResult = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel -FailLoud `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $emptyDispatcher
        Check 'GP8 skipped role is degraded under FailLoud and named in result' (
            $loudResult.degraded -and @($loudResult.degraded_roles) -contains 'simplicity' -and
            $loudResult.reason -match 'simplicity')

        $advisoryResult = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $emptyDispatcher
        Check 'GP9 skipped role remains advisory fail-open without FailLoud' (
            -not $advisoryResult.degraded -and $advisoryResult.verdict -eq 'accept' -and
            @($advisoryResult.degraded_roles) -contains 'simplicity')

        $script:skipCheap = $false
        $badPanelDispatcher = { param($providerName, $reviewPrompt); return @{ stdout='not json'; stderr=''; exit_code=0 } }
        $unparsedPanel = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel -FailLoud `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $badPanelDispatcher
        Check 'GP10 all-unparsed panel is degraded under FailLoud' (
            $unparsedPanel.degraded -and $unparsedPanel.reason -match 'all reviewers')

        $partialPanelDispatcher = {
            param($providerName, $reviewPrompt)
            if ($providerName -eq 'cheap-model') { return @{ stdout='not json'; stderr=''; exit_code=0 } }
            return @{ stdout='[]'; stderr=''; exit_code=0 }
        }
        $partialPanel = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel -FailLoud `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $partialPanelDispatcher
        Check 'GP10b one unusable enabled role degrades a fail-loud panel' (
            $partialPanel.degraded -and @($partialPanel.degraded_roles) -contains 'simplicity' -and
            $partialPanel.reason -match 'unusable review')

        $missingRolesPath = Join-Path $roleTmp 'no-roster.yaml'
        $emptyRolesPath = Join-Path $roleTmp 'empty-roles.yaml'
        Set-Content -LiteralPath $emptyRolesPath -Encoding utf8NoBOM -Value 'roles:'
        $genericDispatcher = { param($providerName, $reviewPrompt); return @{ stdout='[]'; stderr=''; exit_code=0 } }
        $emptyPanelAdvisory = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel `
            -RolesPath $emptyRolesPath -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        $emptyPanelLoud = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel -FailLoud `
            -RolesPath $emptyRolesPath -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        Check 'GP11 explicit panel with empty roster is advisory degraded with a named reason' (
            $emptyPanelAdvisory.degraded -and $emptyPanelAdvisory.verdict -eq 'accept' -and
            @($emptyPanelAdvisory.reviews).Count -eq 0 -and
            $emptyPanelAdvisory.reason -match 'roster' -and $emptyPanelAdvisory.reason -notmatch '^no findings$')
        Check 'GP12 explicit panel with empty roster is degraded under FailLoud' (
            $emptyPanelLoud.degraded -and $emptyPanelLoud.reason -match 'roster')

        $script:skipAll = $true
        $allSkippedAdvisory = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        $allSkippedLoud = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Panel -FailLoud `
            -RolesPath $rolesFixture -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        Check 'GP13 all roles skipped is advisory degraded and not a clean pass' (
            $allSkippedAdvisory.degraded -and @($allSkippedAdvisory.reviews).Count -eq 0 -and
            $allSkippedAdvisory.reason -match 'no reviewer ran \(2 roles skipped\)' -and
            $allSkippedAdvisory.reason -notmatch '^no findings$')
        Check 'GP14 all roles skipped is degraded under FailLoud' (
            $allSkippedLoud.degraded -and $allSkippedLoud.reason -match 'no reviewer ran \(2 roles skipped\)')
        $script:skipAll = $false

        $genericAuto = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' `
            -RolesPath $missingRolesPath -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        $genericExplicit = Invoke-AcceptanceGate -Artifact 'code' -Task 'do x' -Reviewers @('strong-model') `
            -RolesPath $missingRolesPath -FleetPath (Join-Path $roleTmp 'unused-fleet.yaml') `
            -ToolsPath (Join-Path $roleTmp 'unused-tools.yaml') -Dispatcher $genericDispatcher
        Check 'GP15 no panel + no roster preserves generic competitive output' (
            ($genericAuto | ConvertTo-Json -Depth 6 -Compress) -eq
            ($genericExplicit | ConvertTo-Json -Depth 6 -Compress))
    }
    finally {
        Set-Item -Path Function:\Select-Capability -Value $selectorOriginal
        Remove-Item -Recurse -Force $roleTmp -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name selectorCalls,skipCheap,skipAll -ErrorAction SilentlyContinue
    }

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
    $tmpDir = Join-Path $env:TEMP "gate-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $emptyFleet = Join-Path $tmpDir 'fleet.yaml'
    Set-Content -LiteralPath $emptyFleet -Encoding utf8NoBOM -Value @'
providers:
  - name: plain-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'echo {{prompt}}'
'@
    $emptyTools = Join-Path $tmpDir 'tools.yaml'
    Set-Content -LiteralPath $emptyTools -Encoding utf8NoBOM -Value "tools: []`n"
    $threw = $false
    try { Invoke-AcceptanceGate -Artifact 'a' -Task 'b' -Reviewers @() -FleetPath $emptyFleet -ToolsPath $emptyTools } catch { $threw = $true }
    Check 'G35 no reviewers -> throws' ($threw)

    # ---- Task 4: CLI (child process, hermetic BATON_HOME) ----
    $canned = Join-Path $tmpDir 'canned-review.ps1'
    Set-Content -LiteralPath $canned -Encoding utf8NoBOM -Value @'
[void]([Console]::In.ReadToEnd())
Write-Output '[{"severity":"important","area":"correctness","summary":"off by one"}]'
'@
    $cliFleet = Join-Path $tmpDir 'cli-fleet.yaml'
    Set-Content -LiteralPath $cliFleet -Encoding utf8NoBOM -Value @"
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
    Set-Content -LiteralPath $artFx -Encoding utf8NoBOM -Value 'function foo() { return 1 }'
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

    # F5: an unmatched '[' in echoed prose BEFORE a valid findings array must not swallow
    # it. The old single linear pass kept depth>0 to EOF and lost the later array; the
    # cursor-restart scan skips past the lone opener and still finds the valid block.
    $loneOpen = @'
Consider the list [ of concerns below before the JSON:
[
  { "severity": "important", "area": "risk", "summary": "no rollback path for the migration" }
]
'@
    $loBlocks = @(Get-FindingsJsonBlocks -Raw $loneOpen)
    Check 'GE7 lone [ in prose does not swallow the later valid array' (@($loBlocks | Where-Object { $_ -match 'no rollback path' }).Count -eq 1)
    $lo = Get-ReviewFindings -Output $loneOpen
    Check 'GE8 findings parse past a lone [ in prose' ($lo.parsed -and @($lo.findings).Count -eq 1 -and $lo.findings[0].summary -match 'no rollback path')
}
finally {
    if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED"; exit 1 }
    Write-Host "`nALL PASS"
}
