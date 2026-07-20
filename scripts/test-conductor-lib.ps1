#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/conductor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

try {
    # ---- Task 1: plan parsing (pure) ----
    Check 'T1 run id has go- prefix and dashed timestamp' `
        ((New-RunId -Now ([datetime]'2026-06-18T14:22:05')) -eq 'go-2026-06-18T14-22-05')

    $planJson = '{"run_id":"x","goal":"convert pdfs","budget_cap":null,"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","model_pick":"claude-haiku","depends_on":[],"est_cost_tier":"free","reversible":true},{"id":"t2","desc":"build","command":"code-parallel","capability":"code-gen","depends_on":["t1"],"est_cost_tier":"paid"}]}'
    Check 'T2 json block extracted from prose' ((Get-JsonBlock -Raw ("noise " + $planJson + " tail")) -eq $planJson)
    Check 'T3 no json -> empty' ((Get-JsonBlock -Raw 'no braces') -eq '')

    $p = ConvertTo-PlanObject -RawStdout ('```json' + "`n" + $planJson + "`n" + '```')
    Check 'T4 plan parses goal' ($p.goal -eq 'convert pdfs')
    Check 'T5 plan budget_cap null preserved' ($null -eq $p.budget_cap)
    Check 'T6 tasks normalized to array of 2' (@($p.tasks).Count -eq 2)
    Check 'T7 depends_on is array' (@($p.tasks[1].depends_on) -contains 't1')
    Check 'T8 missing reversible defaults true' ($p.tasks[1].reversible -eq $true)
    Check 'T9 missing est_cost_tier defaults free' ((ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"a","desc":"d"}]}').tasks[0].est_cost_tier -eq 'free')
    Check 'T10 garbage -> null' ($null -eq (ConvertTo-PlanObject -RawStdout 'not json'))
    Check 'T11 no tasks key -> null' ($null -eq (ConvertTo-PlanObject -RawStdout '{"goal":"x"}'))

    # ---- VF1: verify_profile + allowed_paths normalization (d082 V2) ----
    $pj = '{"tasks":[{"id":"t1","desc":"edit","capability":"code-gen","verify_profile":"unit","allowed_paths":["src/a.py","tests/a.py"]},{"id":"t2","desc":"doc","capability":"summarize"}]}'
    $vfPlan1 = ConvertTo-PlanObject -RawStdout $pj
    $vft1 = @($vfPlan1.tasks)[0]; $vft2 = @($vfPlan1.tasks)[1]
    Check 'VF1a verify_profile preserved' ($vft1.verify_profile -eq 'unit')
    Check 'VF1b allowed_paths preserved' (@($vft1.allowed_paths).Count -eq 2 -and $vft1.allowed_paths[0] -eq 'src/a.py')
    Check 'VF1c absent verify_profile -> empty' ($vft2.verify_profile -eq '')
    Check 'VF1d absent allowed_paths -> empty' (@($vft2.allowed_paths).Count -eq 0)

    # ---- ST1: additive stakes schema normalization + validation (d086 PR-B) ----
    $stakesPlan = ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"auth change","stakes":"high","stakes_basis":"security-sensitive authentication change"},{"id":"t2","desc":"legacy task"}]}'
    Check 'ST1a supplied stakes preserved' ($stakesPlan.tasks[0].stakes -eq 'high')
    Check 'ST1b supplied stakes_basis preserved' ($stakesPlan.tasks[0].stakes_basis -eq 'security-sensitive authentication change')
    Check 'ST1c omitted stakes defaults standard' ($stakesPlan.tasks[1].stakes -eq 'standard')
    Check 'ST1d omitted stakes basis marks legacy default' ($stakesPlan.tasks[1].stakes_basis -eq 'legacy plan omitted stakes')
    Check 'ST1e invalid supplied stakes rejects the plan' ($null -eq (ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"bad","stakes":"critical","stakes_basis":"not allowed"}]}'))
    Check 'ST1f supplied stakes without a basis rejects the plan' ($null -eq (ConvertTo-PlanObject -RawStdout '{"tasks":[{"id":"t1","desc":"bad","stakes":"high"}]}'))

    # ---- Task 2: DAG order + guards (pure) ----
    $mk = { param($id,$deps,$tier='free',$rev=$true) [pscustomobject]@{ id=$id; desc=$id; command=''; capability=''; model_pick=''; depends_on=@($deps); est_cost_tier=$tier; reversible=$rev } }
    $tasks = @( (& $mk 't2' @('t1')), (& $mk 't1' @()), (& $mk 't3' @('t1','t2')) )
    $order = Resolve-TaskOrder -Tasks $tasks
    Check 'T12 topo order puts t1 first' ($order[0].id -eq 't1')
    Check 'T13 topo order respects deps (t2 before t3)' (([array]($order.id)).IndexOf('t2') -lt ([array]($order.id)).IndexOf('t3'))
    Check 'T14 order returns all tasks' (@($order).Count -eq 3)

    $cyc = @( (& $mk 'a' @('b')), (& $mk 'b' @('a')) )
    $threw = $false; try { Resolve-TaskOrder -Tasks $cyc } catch { $threw = $true }
    Check 'T15 cycle throws' $threw

    $unknown = @( (& $mk 'a' @('zzz')) )
    $threw2 = $false; try { Resolve-TaskOrder -Tasks $unknown } catch { $threw2 = $true }
    Check 'T16 unknown dependency throws' $threw2

    Check 'T17 paid tier estimates the per-call figure' ((Get-TaskCostEstimate -Tier 'paid' -PaidPerCall 0.05) -eq 0.05)
    Check 'T18 free tier estimates zero' ((Get-TaskCostEstimate -Tier 'free' -PaidPerCall 0.05) -eq 0.0)
    Check 'T19 local tier estimates zero' ((Get-TaskCostEstimate -Tier 'local') -eq 0.0)

    Check 'T20 null cap never exceeds' (-not (Test-BudgetExceeded -CumulativeSpend 99 -TaskEstimate 99 -BudgetCap $null))
    Check 'T21 over cap exceeds' (Test-BudgetExceeded -CumulativeSpend 0.08 -TaskEstimate 0.05 -BudgetCap 0.10)
    Check 'T22 under cap does not exceed' (-not (Test-BudgetExceeded -CumulativeSpend 0.02 -TaskEstimate 0.05 -BudgetCap 0.10))

    Check 'T23 reversible:false is destructive' (Test-TaskDestructive -Task (& $mk 'x' @() 'free' $false))
    Check 'T24 reversible:true is not destructive' (-not (Test-TaskDestructive -Task (& $mk 'x' @() 'free' $true)))

    # ---- Task 3: ledgers, run dir, report (pure + IO) ----
    $tmpHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-test-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpHome | Out-Null
    $runDir = Initialize-RunDir -RunId 'go-unit-1' -Root $tmpHome
    Check 'T25 run dir created' (Test-Path $runDir)
    Check 'T26 run dir named for run id' ((Split-Path $runDir -Leaf) -eq 'go-unit-1')

    $ev = New-RunEvent -TaskId 't1' -Kind 'started' -Message 'hello'
    Check 'T27 event has utc ts and kind' (($ev.kind -eq 'started') -and ($ev.ts -match 'Z$'))
    Add-RunEvent -RunDir $runDir -EventObj $ev
    Add-RunEvent -RunDir $runDir -EventObj (New-RunEvent -TaskId 't1' -Kind 'finished')
    $evLines = Get-Content -LiteralPath (Join-Path $runDir 'events.jsonl')
    Check 'T28 two events appended as jsonl' (@($evLines).Count -eq 2)
    Check 'T29 event line is valid json' ((($evLines[0] | ConvertFrom-Json).kind) -eq 'started')

    $dec = New-RunDecision -TaskId 't1' -Chose 'docling' -Alternatives @('markitdown') -Why 'already wired' -CostTier 'local'
    Check 'T30 decision records choice + alts' (($dec.chose -eq 'docling') -and (@($dec.alternatives) -contains 'markitdown'))
    Check 'T30a legacy decision retains planner cost_tier without depth fields' (
        $dec.cost_tier -eq 'local' -and $null -eq $dec.stakes -and $null -eq $dec.selected_cost_tier)
    $legacyDecisionOk = $true
    try { $legacyDecision = New-RunDecision 'legacy' 'worker' @() 'why' 'free' ([datetime]'2024-01-02T03:04:05Z') } catch { $legacyDecisionOk = $false }
    Check 'T30b legacy positional decision timestamp remains compatible' (
        $legacyDecisionOk -and $legacyDecision.task_id -eq 'legacy' -and $legacyDecision.ts -eq '2024-01-02T03:04:05Z')
    Add-RunDecision -RunDir $runDir -Decision $dec
    Check 'T31 decision appended' ((Get-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') | Measure-Object -Line).Lines -ge 1)

    $depthDec = New-RunDecision -TaskId 't2' -Chose 'codex' -Why 'high-stakes route' -CostTier 'local' `
        -Stakes high -StakesBasis 'authentication boundary' -DepthTier high -DepthApplied $true `
        -SelectionMode champion -TierCap paid -SelectedCostTier paid
    Add-RunDecision -RunDir $runDir -Decision $depthDec
    $depthRow = (Get-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Check 'T31a serialized depth decision keeps estimate and additive policy fields' (
        $depthRow.cost_tier -eq 'local' -and $depthRow.stakes -eq 'high' -and
        $depthRow.stakes_basis -eq 'authentication boundary' -and $depthRow.depth_tier -eq 'high' -and
        $depthRow.depth_applied -eq $true -and $depthRow.selection_mode -eq 'champion' -and
        $depthRow.tier_cap -eq 'paid' -and $depthRow.selected_cost_tier -eq 'paid')

    $plan = @{ run_id='go-unit-1'; goal='convert pdfs'; budget_cap=$null; tasks=@(
        [pscustomobject]@{ id='t1'; desc='research'; command='research-gate'; capability='research'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true }
    ) }
    $report = Format-RunReport -Plan $plan -Decisions @($dec) -Spend 0.0 -Status 'completed'
    Check 'T32 report names the goal' ($report -match 'convert pdfs')
    Check 'T33 report shows status' ($report -match 'completed')
    Check 'T34 report lists the decision' ($report -match 'docling')
    $depthReport = Format-RunReport -Plan $plan -Decisions @($depthDec) -Spend 0.0 -Status 'completed'
    Check 'T34a report decision line exposes stakes depth mode cap and actual tier' (
        $depthReport -match 'stakes: high' -and $depthReport -match 'authentication boundary' -and
        $depthReport -match 'depth: high' -and $depthReport -match 'mode: champion' -and
        $depthReport -match 'cap: paid' -and $depthReport -match 'selected tier: paid')
    $reportI = Format-RunReport -Plan $plan -Status 'interrupted-budget' -PendingTaskId 't1'
    Check 'T35 interrupted report names paused task' ($reportI -match 't1')

    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue

    # ---- Task 4: planner prompt + seamed plan phase ----
    $pp = Build-PlannerPrompt -Goal 'convert pdfs to markdown' -RegistryLines @('docling — pdf-extract (local)')
    Check 'T36 planner prompt includes goal' ($pp -match 'convert pdfs to markdown')
    Check 'T37 planner prompt includes registry evidence' ($pp -match 'docling')
    Check 'T38 planner prompt includes schema + reversible rule' (($pp -match '"tasks"') -and ($pp -match 'reversible'))
    Check 'ST1g planner prompt requires stakes and stakes_basis' (($pp -match '"stakes"') -and ($pp -match '"stakes_basis"'))
    Check 'ST1h planner prompt explains low/standard/high classification' (($pp -match 'low for narrow') -and ($pp -match 'high for security'))
    # v1.11.1: codex planned capability "code-parallel" (a baton COMMAND name) and no
    # provider claims it -> walk failed. The schema must pin the routing vocabulary.
    Check 'T38a planner schema constrains capability vocabulary' (($pp -match 'code-gen') -and ($pp -notmatch '"capability": "<capability or empty>"'))
    # #119: planner schema must teach verify_profile + allowed_paths (plan gate / VerifyPreflight).
    Check 'VP1a planner prompt includes verify_profile' ($pp -match 'verify_profile')
    Check 'VP1b planner prompt includes allowed_paths' ($pp -match 'allowed_paths')
    Check 'VP1c planner prompt requires profile for code-gen when available' ($pp -match 'must name a verify_profile')
    Check 'VP1d planner prompt fails-closed red intermediate rule' ($pp -match 'failing-test \+ fix pair must be ONE task')
    # #125: schema wording must match directory-prefix enforcement (trailing '/').
    Check 'VP1e allowed_paths schema documents exact paths OR directory prefix ending in /' (
        ($pp -match 'directory prefix ending in') -and ($pp -match 'never guess')
    )
    Check 'VP1f allowed_paths schema notes * globs are NOT supported on this path' (
        ($pp -match 'globs are NOT supported') -or ($pp -match '\* globs are NOT supported')
    )

    # VP2: with a committed .baton/verification.json, evidence lists profile names (hermetic).
    $vpRepo = Join-Path ([System.IO.Path]::GetTempPath()) "cond-vp-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $vpRepo | Out-Null
    try {
        & git -C $vpRepo init -q 2>$null | Out-Null
        & git -C $vpRepo config user.email 'test@test.local' 2>$null | Out-Null
        & git -C $vpRepo config user.name 'baton-test' 2>$null | Out-Null
        $vpCfgDir = Join-Path $vpRepo '.baton'
        New-Item -ItemType Directory -Force -Path $vpCfgDir | Out-Null
        $vpCfg = @{ schema = 1; profiles = @{ 'pytest-full' = @{ preset = 'pytest'; args = @('tests') } } }
        ConvertTo-Json -InputObject $vpCfg -Depth 6 | Set-Content -LiteralPath (Join-Path $vpCfgDir 'verification.json') -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $vpRepo 'README.md') -Value 'seed' -Encoding utf8NoBOM
        & git -C $vpRepo add -A 2>$null | Out-Null
        & git -C $vpRepo commit -q -m 'seed verify config' 2>$null | Out-Null
        $ppWith = Build-PlannerPrompt -Goal 'add a feature' -RepoPath $vpRepo
        Check 'VP2a evidence lists verification profile from repo' ($ppWith -match 'Verification profiles available in the target repo: pytest-full')
        Check 'VP2b profile name appears in prompt' ($ppWith -match 'pytest-full')
    } finally {
        Remove-Item -Recurse -Force $vpRepo -ErrorAction SilentlyContinue
    }

    # VP3: no config / no repo => no profiles line, no throw.
    $ppBare = Build-PlannerPrompt -Goal 'docs only'
    Check 'VP3a no RepoPath => no profiles line' ($ppBare -notmatch 'Verification profiles available')
    $vpEmpty = Join-Path ([System.IO.Path]::GetTempPath()) "cond-vp-empty-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $vpEmpty | Out-Null
    try {
        & git -C $vpEmpty init -q 2>$null | Out-Null
        & git -C $vpEmpty config user.email 'test@test.local' 2>$null | Out-Null
        & git -C $vpEmpty config user.name 'baton-test' 2>$null | Out-Null
        Set-Content -LiteralPath (Join-Path $vpEmpty 'README.md') -Value 'seed' -Encoding utf8NoBOM
        & git -C $vpEmpty add -A 2>$null | Out-Null
        & git -C $vpEmpty commit -q -m 'seed no verify' 2>$null | Out-Null
        $ppNoCfg = $null
        $vpThrew = $false
        try { $ppNoCfg = Build-PlannerPrompt -Goal 'add a feature' -RepoPath $vpEmpty }
        catch { $vpThrew = $true }
        Check 'VP3b repo without verification.json => no throw' (-not $vpThrew)
        Check 'VP3c repo without verification.json => no profiles line' ($ppNoCfg -and ($ppNoCfg -notmatch 'Verification profiles available'))
        $ppBadPath = $null
        $vpBadThrew = $false
        try { $ppBadPath = Build-PlannerPrompt -Goal 'x' -RepoPath (Join-Path $vpEmpty 'does-not-exist') }
        catch { $vpBadThrew = $true }
        Check 'VP3d nonexistent RepoPath => no throw' (-not $vpBadThrew)
        Check 'VP3e nonexistent RepoPath => no profiles line' ($ppBadPath -and ($ppBadPath -notmatch 'Verification profiles available'))
        # #125: no RepoPath / non-repo => no top-level-directories line either.
        Check 'VL0a no RepoPath => no top-level-directories line' ($ppBare -notmatch 'Target repo top-level directories:')
        Check 'VL0b nonexistent RepoPath => no top-level-directories line' ($ppBadPath -and ($ppBadPath -notmatch 'Target repo top-level directories:'))
    } finally {
        Remove-Item -Recurse -Force $vpEmpty -ErrorAction SilentlyContinue
    }

    # VL1: temp git repo with top-level dirs => evidence lists them (hermetic; no model calls).
    $vlRepo = Join-Path ([System.IO.Path]::GetTempPath()) "cond-vl-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $vlRepo | Out-Null
    try {
        & git -C $vlRepo init -q 2>$null | Out-Null
        & git -C $vlRepo config user.email 'test@test.local' 2>$null | Out-Null
        & git -C $vlRepo config user.name 'baton-test' 2>$null | Out-Null
        foreach ($dname in @('app', 'docs', 'scripts', 'tests')) {
            $dpath = Join-Path $vlRepo $dname
            New-Item -ItemType Directory -Force -Path $dpath | Out-Null
            Set-Content -LiteralPath (Join-Path $dpath '.keep') -Value '' -Encoding utf8NoBOM
        }
        Set-Content -LiteralPath (Join-Path $vlRepo 'README.md') -Value 'seed' -Encoding utf8NoBOM
        & git -C $vlRepo add -A 2>$null | Out-Null
        & git -C $vlRepo -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m 'seed layout' 2>$null | Out-Null
        Check 'VL1-commit seed commit succeeded' ($LASTEXITCODE -eq 0)
        $ppLayout = $null
        $vlThrew = $false
        try { $ppLayout = Build-PlannerPrompt -Goal 'touch app code' -RepoPath $vlRepo }
        catch { $vlThrew = $true }
        Check 'VL1a with dirs => no throw' (-not $vlThrew)
        Check 'VL1b evidence lists top-level directories line' ($ppLayout -match 'Target repo top-level directories:')
        # Anchor to the evidence line (schema example also contains "app/" — do not match bare).
        Check 'VL1c evidence includes app and tests on layout line' (
            ($ppLayout -match 'Target repo top-level directories:.*\bapp\b') -and
            ($ppLayout -match 'Target repo top-level directories:.*\btests\b')
        )
        # --full-tree: RepoPath = subdirectory must still list REPO-ROOT top-level dirs.
        $vlSub = Join-Path $vlRepo 'app'
        $ppSub = $null
        $vlSubThrew = $false
        try { $ppSub = Build-PlannerPrompt -Goal 'touch app code' -RepoPath $vlSub }
        catch { $vlSubThrew = $true }
        Check 'VL1d RepoPath=subdir => no throw' (-not $vlSubThrew)
        Check 'VL1e RepoPath=subdir still lists repo-root dirs (full-tree)' (
            ($ppSub -match 'Target repo top-level directories:.*\bapp\b') -and
            ($ppSub -match 'Target repo top-level directories:.*\bdocs\b') -and
            ($ppSub -match 'Target repo top-level directories:.*\bscripts\b')
        )
        # Single-pass tokens: dir literally named {{Goal}} must not expand to goal text in layout.
        $hostileName = '{{Goal}}'
        $hostilePath = Join-Path $vlRepo $hostileName
        New-Item -ItemType Directory -Force -Path $hostilePath | Out-Null
        Set-Content -LiteralPath (Join-Path $hostilePath '.keep') -Value '' -Encoding utf8NoBOM
        & git -C $vlRepo add -A 2>$null | Out-Null
        & git -C $vlRepo -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m 'add hostile dir name' 2>$null | Out-Null
        Check 'VL1f hostile-name commit succeeded' ($LASTEXITCODE -eq 0)
        $goalText = 'UNIQUE_GOAL_MARKER_xyzzy'
        $ppHostile = Build-PlannerPrompt -Goal $goalText -RepoPath $vlRepo
        # Layout line must not contain the expanded goal (single-pass). Hostile name is
        # also filtered by the safe-name regex, so it should not appear either.
        $layoutMatch = [regex]::Match($ppHostile, 'Target repo top-level directories:([^\r\n]+)')
        $layoutBody = if ($layoutMatch.Success) { $layoutMatch.Groups[1].Value } else { '' }
        Check 'VL1g layout line present after hostile dir' ($layoutMatch.Success)
        Check 'VL1h goal text does NOT appear inside layout line (single-pass)' ($layoutBody -notmatch [regex]::Escape($goalText))
        Check 'VL1i hostile {{Goal}} dir name filtered from layout' ($layoutBody -notmatch [regex]::Escape('{{Goal}}'))
        # Non-git directory path: no line, no throw.
        $vlNongit = Join-Path ([System.IO.Path]::GetTempPath()) "cond-vl-nongit-$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Force -Path $vlNongit | Out-Null
        try {
            $ppNongit = $null
            $vlNgThrew = $false
            try { $ppNongit = Build-PlannerPrompt -Goal 'x' -RepoPath $vlNongit }
            catch { $vlNgThrew = $true }
            Check 'VL2a non-git path => no throw' (-not $vlNgThrew)
            Check 'VL2b non-git path => no top-level-directories line' ($ppNongit -and ($ppNongit -notmatch 'Target repo top-level directories:'))
        } finally {
            Remove-Item -Recurse -Force $vlNongit -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -Recurse -Force $vlRepo -ErrorAction SilentlyContinue
    }

    $refFleet = Join-Path $PSScriptRoot '../references/fleet.yaml'
    $tmpTools = Join-Path ([System.IO.Path]::GetTempPath()) "cond-tools-$([System.IO.Path]::GetRandomFileName()).yaml"
    Set-Content -Path $tmpTools -Value 'tools: []' -Encoding utf8NoBOM
    $cannedPlan = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $disp = { param($c,$p) @{ stdout = $cannedPlan; stderr=''; exit_code = 0; duration_s = 1 } }
    $plan = Invoke-PlanPhase -Goal 'convert pdfs' -RunId 'go-unit-2' -FleetPath $refFleet -ToolsPath $tmpTools -Dispatcher $disp
    Check 'T39 plan phase returns a plan' ($null -ne $plan)
    Check 'T40 plan phase stamps run id' ($plan.run_id -eq 'go-unit-2')
    Check 'T41 plan phase stamps goal' ($plan.goal -eq 'convert pdfs')
    Check 'T42 plan phase parsed the task' (@($plan.tasks).Count -eq 1)

    $dispBad = { param($c,$p) @{ stdout = 'not json'; stderr=''; exit_code = 0; duration_s = 1 } }
    Check 'T43 unparseable planner reply -> null' ($null -eq (Invoke-PlanPhase -Goal 'x' -FleetPath $refFleet -ToolsPath $tmpTools -Dispatcher $dispBad))

    # ---- Multi-model planner replies (v1.11.1): providers like `codex exec` echo the
    # prompt (which itself contains the JSON schema) before the answer, and may emit
    # the answer JSON more than once. Greedy first-{-to-last-} spans echo+answer ->
    # invalid JSON. The parser must recover the LAST parseable tasks-bearing block. ----
    $echoSchema = @'
Reading prompt from stdin...
OpenAI Codex v0.144.0
--------
user
Respond with ONLY valid JSON matching this schema - no prose, no fences.
Schema:
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<capability or empty>", "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
## Goal
make hello.md

2026-07-09T20:52:19.577311Z ERROR codex_memories_write::phase2: Phase 2 no changes
codex
{"run_id":"real","goal":"make hello.md","budget_cap":null,"tasks":[{"id":"t1","desc":"Create hello.md","command":"","capability":"code-gen","model_pick":"","depends_on":[],"est_cost_tier":"local","reversible":true}]}
{"run_id":"real","goal":"make hello.md","budget_cap":null,"tasks":[{"id":"t1","desc":"Create hello.md","command":"","capability":"code-gen","model_pick":"","depends_on":[],"est_cost_tier":"local","reversible":true}]}
tokens used
20,090
'@
    $pEcho = ConvertTo-PlanObject -RawStdout $echoSchema
    Check 'T43a prompt-echoing provider reply parses' ($null -ne $pEcho)
    Check 'T43b parsed the ANSWER not the echoed schema' (($pEcho.run_id -eq 'real') -and ($pEcho.tasks[0].desc -eq 'Create hello.md'))
    Check 'T43c single clean JSON still parses (regression)' ($null -ne (ConvertTo-PlanObject -RawStdout $cannedPlan))
    $schemaOnly = "prose {`n" + '"run_id": "<id>", "tasks": []' + "`n} more prose"
    Check 'T43d tasks-less block still -> null' ($null -eq (ConvertTo-PlanObject -RawStdout $schemaOnly))
    $braceInString = 'noise {"run_id":"r2","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"use {curly} chars","command":"","capability":"","model_pick":"","depends_on":[],"est_cost_tier":"free","reversible":true}]} tail'
    Check 'T43e braces inside JSON strings survive the scan' ((ConvertTo-PlanObject -RawStdout $braceInString).tasks[0].desc -eq 'use {curly} chars')
    # Echo-ONLY reply (provider died after echoing the prompt, e.g. usage-limit, but
    # exited 0): the echoed schema must NOT be mistaken for a plan — its placeholder
    # est_cost_tier "local|free|paid" is the reject signature.
    $echoOnly = @'
user
Schema:
{
  "run_id": "<id>",
  "goal": "<the goal>",
  "budget_cap": null,
  "tasks": [
    { "id": "t1", "desc": "<what>", "command": "<baton command or empty>",
      "capability": "<capability or empty>", "model_pick": "<model or empty>",
      "depends_on": [], "est_cost_tier": "local|free|paid", "reversible": true }
  ]
}
## Goal
make hello.md

ERROR: You have hit your usage limit. Try again later.
'@
    Check 'T43f echo-only reply (no answer) -> null, schema not mistaken for a plan' ($null -eq (ConvertTo-PlanObject -RawStdout $echoOnly))

    Remove-Item -Force $tmpTools -ErrorAction SilentlyContinue

    # ---- Task 5: the conductor loop (seamed) ----
    $tmpHome2 = Join-Path ([System.IO.Path]::GetTempPath()) "cond-loop-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpHome2 | Out-Null
    $mkTask = { param($id,$deps,$tier='free',$rev=$true) [pscustomobject]@{ id=$id; desc="do $id"; command='x'; capability='reasoning'; model_pick=''; depends_on=@($deps); est_cost_tier=$tier; reversible=$rev } }

    # Happy path: 3 tasks, all reversible, under budget.
    $planner = { param($goal) @{ run_id='ignored'; goal=$goal; budget_cap=$null; tasks=@( (& $mkTask 't1' @()), (& $mkTask 't2' @('t1')), (& $mkTask 't3' @('t2')) ) } }
    $seen = [System.Collections.ArrayList]@()
    $spawner = { param($task) [void]$seen.Add($task.id); @{ ok=$true; spend=0.0; chose='claude-haiku'; why="ran $($task.id)"; alternatives=@('local-x') } }
    $run1 = Join-Path $tmpHome2 'go-loop-1'
    $r1 = Invoke-Conductor -Goal 'do the thing' -RunDir $run1 -Planner $planner -Spawner $spawner
    Check 'T44 completed status' ($r1.status -eq 'completed')
    Check 'T45 tasks ran in dependency order' (($seen[0] -eq 't1') -and ($seen[2] -eq 't3'))
    Check 'T46 plan.json written' (Test-Path (Join-Path $run1 'plan.json'))
    Check 'T47 report.md written' (Test-Path (Join-Path $run1 'report.md'))
    Check 'T48 decisions logged for each task' ((Get-Content -LiteralPath (Join-Path $run1 'decisions.jsonl') | Measure-Object -Line).Lines -eq 3)
    Check 'T49 events include finished' ((Get-Content -LiteralPath (Join-Path $run1 'events.jsonl') -Raw) -match 'finished')

    $depthPlanner = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@(
        [pscustomobject]@{ id='td'; desc='secure change'; command='x'; capability='code-gen'; model_pick=''; depends_on=@(); est_cost_tier='local'; reversible=$true; stakes='high'; stakes_basis='authentication boundary' }
    ) } }
    $depthSpawner = { param($task) @{
        ok=$true; spend=0.0; chose='codex'; why='routed'; alternatives=@(); stakes=$task.stakes; stakes_basis=$task.stakes_basis
        depth_tier='high'; depth_applied=$true; selection_mode='champion'; tier_cap='paid'; selected_cost_tier='paid'
    } }
    $depthRun = Join-Path $tmpHome2 'go-loop-depth'
    $depthResult = Invoke-Conductor -Goal 'secure it' -RunDir $depthRun -Planner $depthPlanner -Spawner $depthSpawner
    $depthLogged = (Get-Content -LiteralPath (Join-Path $depthRun 'decisions.jsonl') -Raw | ConvertFrom-Json)
    Check 'T49a conductor copies resolved spawner policy into the task decision' (
        $depthResult.status -eq 'completed' -and $depthLogged.cost_tier -eq 'local' -and
        $depthLogged.stakes -eq 'high' -and $depthLogged.stakes_basis -eq 'authentication boundary' -and
        $depthLogged.depth_tier -eq 'high' -and $depthLogged.depth_applied -eq $true -and
        $depthLogged.selection_mode -eq 'champion' -and $depthLogged.tier_cap -eq 'paid' -and
        $depthLogged.selected_cost_tier -eq 'paid')

    # Budget interrupt: a paid task that would cross a tiny cap halts BEFORE running.
    $seenB = [System.Collections.ArrayList]@()
    $spawnerB = { param($task) [void]$seenB.Add($task.id); @{ ok=$true; spend=0.0; chose='m'; why=''; alternatives=@() } }
    $plannerB = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=0.01; tasks=@( (& $mkTask 't1' @() 'free'), (& $mkTask 't2' @('t1') 'paid') ) } }
    $r2 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-2') -BudgetCap 0.01 -PaidPerCall 0.05 -Planner $plannerB -Spawner $spawnerB
    Check 'T50 budget interrupt status' ($r2.status -eq 'interrupted-budget')
    Check 'T51 budget interrupt names pending task' ($r2.pending_task_id -eq 't2')
    Check 'T52 paid task did NOT run' (-not ($seenB -contains 't2'))

    # Destructive interrupt: a reversible:false task halts before running.
    $seenD = [System.Collections.ArrayList]@()
    $spawnerD = { param($task) [void]$seenD.Add($task.id); @{ ok=$true; spend=0.0; chose='m'; why=''; alternatives=@() } }
    $plannerD = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( (& $mkTask 't1' @()), (& $mkTask 't2' @('t1') 'free' $false) ) } }
    $r3 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-3') -Planner $plannerD -Spawner $spawnerD
    Check 'T53 destructive interrupt status' ($r3.status -eq 'interrupted-destructive')
    Check 'T54 destructive task did NOT run' (-not ($seenD -contains 't2'))

    # Plan failure: planner returns null.
    $r4 = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $tmpHome2 'go-loop-4') -Planner { param($goal) $null } -Spawner $spawner
    Check 'T55 plan-failed status' ($r4.status -eq 'plan-failed')

    Remove-Item -Recurse -Force $tmpHome2 -ErrorAction SilentlyContinue

    # ---- Task 6: CLI child-process (zero network) ----
    $cli = Join-Path $PSScriptRoot 'fleet-go.ps1'
    Check 'T56 fleet-go.ps1 exists' (Test-Path $cli)
    $cliHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-cli-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $cliHome | Out-Null
    $env:BATON_HOME = $cliHome
    $env:BATON_GO_TEST_PLAN = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_SPAWN = '1'
    $out = & pwsh -NoProfile -File $cli -Goal 'convert pdfs' -Json 2>&1 | Out-String
    Check 'T57 CLI exits cleanly and reports completed' ($out -match 'completed')
    $runRoot = Join-Path $cliHome 'runs'
    $made = @(Get-ChildItem -Path $runRoot -Directory -ErrorAction SilentlyContinue)
    Check 'T58 CLI created a run dir' (@($made).Count -ge 1)
    Check 'T59 CLI wrote report.md' (Test-Path (Join-Path $made[0].FullName 'report.md'))

    # d058: CLI acceptance phase via the BATON_GO_TEST_GATE seam (reject -> rejected)
    $env:BATON_HOME = $cliHome
    $env:BATON_GO_TEST_PLAN = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_SPAWN = '1'
    $env:BATON_GO_TEST_GATE = 'reject'
    $outG = & pwsh -NoProfile -File $cli -Goal 'convert pdfs' -GateArtifact 'finished work' -Json 2>&1 | Out-String
    Check 'T60c CLI gate reject -> rejected status' ($outG -match 'rejected')
    Remove-Item Env:\BATON_GO_TEST_GATE -ErrorAction SilentlyContinue

    Remove-Item Env:\BATON_HOME, Env:\BATON_GO_TEST_PLAN, Env:\BATON_GO_TEST_SPAWN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $cliHome -ErrorAction SilentlyContinue

    # ---- d058: acceptance-phase pure helpers ----
    Check 'T60 Resolve-GateArtifact returns literal artifact' ((Resolve-GateArtifact -Artifact 'the diff text') -eq 'the diff text')
    Check 'T61 Resolve-GateArtifact empty when neither given' ((Resolve-GateArtifact) -eq '')
    Check 'T62 Resolve-GateArtifact bogus diff range -> empty (fail-open)' ((Resolve-GateArtifact -Diff 'no-such-ref-zzz..also-no-ref-zzz') -eq '')
    $acc = Format-AcceptanceSection -Gate @{ verdict='polish'; reason='1 important finding'; counts=@{critical=0;important=1;minor=2}; polish_brief='[important][api] fix the thing' }
    Check 'T63 acceptance section shows verdict + counts' (($acc -match '## Acceptance') -and ($acc -match 'polish') -and ($acc -match '1 important'))
    Check 'T64 polish brief present when not accept' ($acc -match 'fix the thing')
    $accA = Format-AcceptanceSection -Gate @{ verdict='accept'; reason='no blocking findings'; counts=@{critical=0;important=0;minor=0}; polish_brief='No polish needed' }
    Check 'T65 accept omits the polish brief block' ($accA -notmatch '### Polish brief')

    # ---- d058: acceptance phase (seamed -Gater) ----
    $gtHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-gate-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $gtHome | Out-Null
    $gPlanner = { param($goal) @{ run_id='x'; goal=$goal; budget_cap=$null; tasks=@( [pscustomobject]@{ id='t1'; desc='do t1'; command='x'; capability='reasoning'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true } ) } }
    $gSpawner = { param($task) @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }

    # no gate target -> completed, no acceptance.json
    $rn = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-none') -Planner $gPlanner -Spawner $gSpawner
    Check 'T66 no gate target -> completed' ($rn.status -eq 'completed')
    Check 'T67 no gate target -> no acceptance.json' (-not (Test-Path (Join-Path $gtHome 'r-none/acceptance.json')))

    # accept -> completed + acceptance.json + ## Acceptance in report
    $gaterAccept = { param($art,$goal) @{ verdict='accept'; reason='clean'; counts=@{critical=0;important=0;minor=1}; polish_brief='No polish needed'; findings=@(); reviews=@(); unparsed=@() } }
    $ra = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-accept') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'finished work' -Gater $gaterAccept
    Check 'T68 accept verdict -> completed' ($ra.status -eq 'completed')
    Check 'T69 accept writes acceptance.json' (Test-Path (Join-Path $gtHome 'r-accept/acceptance.json'))
    Check 'T70 report has ## Acceptance' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-accept/report.md') -Raw) -match '## Acceptance')

    # polish -> completed + brief in report + gate event
    $gaterPolish = { param($art,$goal) @{ verdict='polish'; reason='1 important'; counts=@{critical=0;important=1;minor=0}; polish_brief='[important][x] do better'; findings=@(); reviews=@(); unparsed=@() } }
    $rp = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-polish') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterPolish
    Check 'T71 polish verdict -> completed' ($rp.status -eq 'completed')
    Check 'T72 polish brief in report' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-polish/report.md') -Raw) -match 'do better')
    Check 'T73 gate event logged' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-polish/events.jsonl') -Raw) -match '"kind":"gate"')

    # reject -> rejected status
    $gaterReject = { param($art,$goal) @{ verdict='reject'; reason='1 critical'; counts=@{critical=1;important=0;minor=0}; polish_brief='[critical][x] broken'; findings=@(); reviews=@(); unparsed=@() } }
    $rr = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-reject') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterReject
    Check 'T74 reject verdict -> rejected status' ($rr.status -eq 'rejected')

    # gate throws -> fail-open completed + warn event
    $gaterThrow = { param($art,$goal) throw 'reviewer exploded' }
    $rt = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-throw') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterThrow
    Check 'T75 gate throw -> completed (fail-open)' ($rt.status -eq 'completed')
    Check 'T76 gate throw logs warn event' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-throw/events.jsonl') -Raw) -match 'acceptance gate failed')

    # gater returns a result with NO verdict -> fail-open completed + 'no verdict' warn event
    $gaterNoVerdict = { param($art,$goal) @{ reason='x' } }
    $rnv = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-noverdict') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work' -Gater $gaterNoVerdict
    Check 'T77 gate no-verdict -> completed (fail-open)' ($rnv.status -eq 'completed')
    Check 'T78 gate no-verdict logs produced-no-verdict warn' ((Get-Content -LiteralPath (Join-Path $gtHome 'r-noverdict/events.jsonl') -Raw) -match 'produced no verdict')
    Check 'T79 gate no-verdict -> no acceptance.json' (-not (Test-Path (Join-Path $gtHome 'r-noverdict/acceptance.json')))

    # Execute policy is represented by the explicit acceptance switches. Legacy
    # direct callers stay advisory; fail-loud callers stop shipping on infra loss
    # and on a polish verdict.
    $rpf = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-polish-loud') -Planner $gPlanner -Spawner $gSpawner `
        -GateArtifact 'work' -Gater $gaterPolish -AcceptanceGate -AcceptanceFailLoud
    Check 'T79a fail-loud polish -> needs-polish' ($rpf.status -eq 'needs-polish')
    $rtf = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-throw-loud') -Planner $gPlanner -Spawner $gSpawner `
        -GateArtifact 'work' -Gater $gaterThrow -AcceptanceGate -AcceptanceFailLoud
    Check 'T79b fail-loud gate throw -> acceptance-degraded' ($rtf.status -eq 'acceptance-degraded')
    $rnf = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-noverdict-loud') -Planner $gPlanner -Spawner $gSpawner `
        -GateArtifact 'work' -Gater $gaterNoVerdict -AcceptanceGate -AcceptanceFailLoud
    Check 'T79c fail-loud no verdict -> acceptance-degraded' ($rnf.status -eq 'acceptance-degraded')
    $gaterDegraded = { param($art,$goal) @{ verdict='accept'; reason='role lost'; counts=@{critical=0;important=0;minor=0}; polish_brief=''; findings=@(); reviews=@(); unparsed=@(); degraded=$true } }
    $rdf = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-degraded-loud') -Planner $gPlanner -Spawner $gSpawner `
        -GateArtifact 'work' -Gater $gaterDegraded -AcceptanceGate -AcceptanceFailLoud
    Check 'T79d fail-loud degraded panel -> acceptance-degraded' ($rdf.status -eq 'acceptance-degraded')

    # Explicit policy must reach the real acceptance-gate call, while a library
    # caller that merely supplies an artifact remains default-on for compatibility.
    function Invoke-AcceptanceGate {
        param($Artifact,$Task,$MaxCostTier,$FleetPath,$ToolsPath,[switch]$Panel,[switch]$FailLoud)
        return @{ verdict='accept'; reason="panel=$([bool]$Panel);loud=$([bool]$FailLoud)"; counts=@{critical=0;important=0;minor=0}; polish_brief=''; findings=@(); reviews=@(); unparsed=@(); degraded=$false }
    }
    $rFlags = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-flags') -Planner $gPlanner -Spawner $gSpawner `
        -GateArtifact 'work' -AcceptanceGate -AcceptancePanel -AcceptanceFailLoud
    Check 'T79e panel and fail-loud reach Invoke-AcceptanceGate' ($rFlags.acceptance.reason -eq 'panel=True;loud=True')
    $rLegacyArtifact = Invoke-Conductor -Goal 'g' -RunDir (Join-Path $gtHome 'r-legacy-artifact') -Planner $gPlanner -Spawner $gSpawner -GateArtifact 'work'
    Check 'T79f non-execute library artifact remains default-on' ($rLegacyArtifact.acceptance.verdict -eq 'accept')
    . "$PSScriptRoot/gate-lib.ps1"

    Remove-Item -Recurse -Force $gtHome -ErrorAction SilentlyContinue

    # ---- T80-T86: effective cost wiring (slice 1) ----
    $ecRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-ec-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $ecRoot | Out-Null
    try {
        # A run that completes with a gate verdict -> effective-cost.json + report section.
        $ecPlan = @{ run_id = 'go-ec-1'; goal = 'demo'; budget_cap = $null; tasks = @(
            @{ id = 't1'; desc = 'do it'; deps = @(); est_cost_tier = 'paid'; reversible = $true }
        ) }
        $ecGate = @{ verdict = 'polish'; reason = '1 important finding(s)'; counts = @{ critical=0; important=1; minor=0 }; polish_brief = 'fix it'; findings = @(); reviews = @(); unparsed = @() }
        $ecTaskCosts = @(@{ id='t1'; worker='claude-haiku'; cost=2.0 })
        $ecRd = Join-Path $ecRoot 'go-ec-1'; New-Item -ItemType Directory -Force -Path $ecRd | Out-Null
        $ecRes = Complete-Run -RunDir $ecRd -Plan $ecPlan -Decisions @() -Spend 2.0 -Status 'completed' -Gate $ecGate -TaskCosts $ecTaskCosts
        $ecPath = Join-Path $ecRd 'effective-cost.json'
        Check 'T80 effective-cost.json written when gate verdict present' (Test-Path $ecPath)
        $ecObj = Get-Content $ecPath -Raw | ConvertFrom-Json
        Check 'T81 record verdict matches the gate' ($ecObj.verdict -eq 'polish')
        Check 'T82 record effective_cost = cost / quality (>cost when quality<1)' ($ecObj.effective_cost -gt $ecObj.cost)
        Check 'T83 record attributes the producing worker' ($ecObj.workers[0].worker -eq 'claude-haiku')
        Check 'T84 returned run object carries effective_cost' ($null -ne $ecRes.effective_cost)
        $ecRep = Get-Content (Join-Path $ecRd 'report.md') -Raw
        Check 'T85 report.md has the ## Effective cost section' ($ecRep -match '(?m)^## Effective cost')

        # No gate -> no effective-cost.json, no section (byte-for-byte invariant).
        $ecRd2 = Join-Path $ecRoot 'go-ec-2'; New-Item -ItemType Directory -Force -Path $ecRd2 | Out-Null
        $ecPlan2 = @{ run_id = 'go-ec-2'; goal = 'demo'; budget_cap = $null; tasks = @() }
        $ecRes2 = Complete-Run -RunDir $ecRd2 -Plan $ecPlan2 -Decisions @() -Spend 0.0 -Status 'completed'
        Check 'T86 no gate -> no effective-cost.json and null effective_cost' ((-not (Test-Path (Join-Path $ecRd2 'effective-cost.json'))) -and ($null -eq $ecRes2.effective_cost))

        # Full Invoke-Conductor path: numerator is the cost-tier ESTIMATE (paid -> 0.05),
        # NOT the placeholder realized spend (0.0) the stub spawner returns.
        $ecPlanner = { param($g) @{ run_id='x'; goal=$g; budget_cap=$null; tasks=@(
            [pscustomobject]@{ id='t1'; desc='paid task'; command='x'; capability='reasoning'; model_pick=''; depends_on=@(); est_cost_tier='paid'; reversible=$true }
        ) } }
        $ecSpawner = { param($t) @{ ok=$true; spend=0.0; chose='w1'; why='ran'; alternatives=@() } }   # spend 0.0 = production reality
        $ecGater   = { param($art,$goal) @{ verdict='polish'; reason='1 important'; counts=@{critical=0;important=1;minor=0}; polish_brief='x'; findings=@(); reviews=@(); unparsed=@() } }
        $ecRd3 = Join-Path $ecRoot 'go-ec-3'
        $ecRes3 = Invoke-Conductor -Goal 'demo' -RunDir $ecRd3 -Planner $ecPlanner -Spawner $ecSpawner -GateArtifact 'work' -Gater $ecGater
        $ecObj3 = Get-Content (Join-Path $ecRd3 'effective-cost.json') -Raw | ConvertFrom-Json
        Check 'T87 numerator is the estimate (0.05), not placeholder spend (0)' ($ecObj3.cost -eq 0.05)
        Check 'T88 effective_cost is non-zero (0.05 / 0.62)' ($ecObj3.effective_cost -gt 0)
    }
    finally {
        Remove-Item -LiteralPath $ecRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- Slice B: shadow A/B ----
    # SB1/SB2: -Template override on Build-PlannerPrompt
    $sbTpl = "SHADOWTPL {{schema}} {{evi}} {{Goal}}"
    $sbOut = Build-PlannerPrompt -Goal 'g1' -Template $sbTpl
    Check 'SB1 valid -Template used verbatim' ($sbOut -match 'SHADOWTPL' -and $sbOut -match 'g1')
    $sbOut2 = Build-PlannerPrompt -Goal 'g1' -Template 'BROKEN no placeholders'
    Check 'SB2 invalid -Template falls back to the normal chain' ($sbOut2 -notmatch 'BROKEN')

    # Hermetic BATON_HOME with a seeded pool + one challenger for the rest.
    $sbPrevHome = $env:BATON_HOME
    try {
        $sbHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-sb-$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Force -Path (Join-Path $sbHome 'prompts') | Out-Null
        $env:BATON_HOME = $sbHome
        $sbSeed = Join-Path $sbHome 'prompts/conductor-planner.txt'
        Set-Content -LiteralPath $sbSeed -Value 'LIVEPROMPT {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        $sbPoolDir = Join-Path $sbHome 'prompts/pool'
        [void](Initialize-PromptPool -SeedPromptPath $sbSeed -PoolDir $sbPoolDir)
        $sbP = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbChall = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbChall.offline.minibatch.win_rate_vs_champion = 0.8
        $sbP.candidates = @($sbP.candidates) + @($sbChall)
        Set-Content -LiteralPath (Join-Path $sbPoolDir 'p002.txt') -Value 'CHALLPROMPT {{schema}} {{evi}} {{Goal}}' -Encoding utf8NoBOM
        Save-PromptPool -Pool $sbP -PoolDir $sbPoolDir

        # SB3: challenger assignment writes shadow.json + event and routes the template.
        $sbRun1 = Initialize-RunDir -RunId 'go-sb-1' -Root (Join-Path $sbHome 'runs')
        $sbSeen = @{ prompt = '' }
        $sbDisp = { param($cand, $prompt) $sbSeen.prompt = $prompt; @{ stdout = '{"tasks":[{"id":"t1","desc":"d"}]}'; exit_code = 0 } }.GetNewClosure()
        $sbResolver = { @{ shadow = $true; variant_id = 'p002'; role = 'challenger'
                           template = (Get-Content -Raw (Join-Path $sbPoolDir 'p002.txt')); challenger_id = 'p002' } }.GetNewClosure()
        $sbFleet = Join-Path $sbHome 'fleet.yaml'
        Set-Content -LiteralPath $sbFleet -Value "providers:`n  - name: stub`n    kind: cli`n    enabled: true`n    platform: claude`n    cost_tier: free`n    capabilities: [reasoning]" -Encoding utf8NoBOM
        $sbPlanRes = Invoke-PlanPhase -Goal 'shadow goal' -RunId 'go-sb-1' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun1 -ShadowResolver $sbResolver
        $sbShadowJson = Join-Path $sbRun1 'shadow.json'
        Check 'SB3a shadow.json written with variant/role' ((Test-Path $sbShadowJson) -and ((Get-Content -Raw $sbShadowJson | ConvertFrom-Json).variant_id -eq 'p002'))
        Check 'SB3b challenger template reached the planner dispatch' ($sbSeen.prompt -match 'CHALLPROMPT' -and $sbSeen.prompt -match 'shadow goal')
        $sbEv1 = Get-Content -LiteralPath (Join-Path $sbRun1 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB3c shadow event logged' (@($sbEv1 | Where-Object { $_.kind -eq 'shadow' }).Count -eq 1)

        # SB4: resolver says no shadow -> no shadow.json, no event, normal prompt.
        $sbRun2 = Initialize-RunDir -RunId 'go-sb-2' -Root (Join-Path $sbHome 'runs')
        [void](Invoke-PlanPhase -Goal 'plain goal' -RunId 'go-sb-2' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun2 -ShadowResolver { @{ shadow = $false; reason = 'no challenger' } })
        Check 'SB4 no-shadow run leaves no shadow.json' ((-not (Test-Path (Join-Path $sbRun2 'shadow.json'))) -and ($sbSeen.prompt -match 'LIVEPROMPT'))

        # SB5: champion role -> shadow.json role=champion, live-file prompt used.
        $sbRun3 = Initialize-RunDir -RunId 'go-sb-3' -Root (Join-Path $sbHome 'runs')
        [void](Invoke-PlanPhase -Goal 'champ goal' -RunId 'go-sb-3' -FleetPath $sbFleet -ToolsPath (Join-Path $sbHome 'tools.yaml') `
            -Dispatcher $sbDisp -RunDir $sbRun3 -ShadowResolver { @{ shadow = $true; variant_id = 'p001'; role = 'champion'; template = $null; challenger_id = 'p002' } })
        Check 'SB5 champion role recorded, live prompt used' (((Get-Content -Raw (Join-Path $sbRun3 'shadow.json') | ConvertFrom-Json).role -eq 'champion') -and ($sbSeen.prompt -match 'LIVEPROMPT'))

        # SB6: Complete-Run on a GATED shadow run accrues verdict + realized cost.
        $sbPlanObj = @{ run_id = 'go-sb-1'; goal = 'shadow goal'; budget_cap = $null; tasks = @() }
        $sbGate = @{ verdict = 'accept'; reason = 'fine'; counts = @{ critical = 0; important = 0; minor = 0 }; polish_brief = ''; findings = @(); reviews = @(); unparsed = @() }
        [void](Complete-Run -RunDir $sbRun1 -Plan $sbPlanObj -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter1 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbC2 = @($sbAfter1.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB6 gated shadow run accrued: runs=1 accept=1 cost=0.10 rework=0' `
            ((([int]$sbC2.live.runs) -eq 1) -and (([int]$sbC2.live.accept) -eq 1) -and (([double]$sbC2.live.realized_cost_usd) -eq 0.10) -and (([double]$sbC2.live.rework_cost_usd) -eq 0.0))

        # SB7: UNGATED shadow run accrues cost + runs only.
        $sbRun4 = Initialize-RunDir -RunId 'go-sb-4' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun4 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun4 -Plan @{ run_id = 'go-sb-4'; goal = 'g'; budget_cap = $null; tasks = @() } -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.05 }))
        $sbC2b = @(((Get-PromptPool -PoolDir $sbPoolDir).pool).candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB7 ungated shadow run: cost-only accrual' ((([int]$sbC2b.live.runs) -eq 2) -and (([int]$sbC2b.live.accept) -eq 1) -and (([double]$sbC2b.live.realized_cost_usd) -eq 0.15))

        # SB8: auto-retire fires at threshold when the challenger is losing in dollars.
        $sbP3 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbChampRec = @($sbP3.candidates | Where-Object { $_.id -eq 'p001' })[0]
        $sbChallRec = @($sbP3.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbChampRec.live = @{ runs = 5; accept = 4; polish = 1; reject = 0; realized_cost_usd = 1.0; rework_cost_usd = 0.2 }
        $sbChallRec.live = @{ runs = 4; accept = 0; polish = 2; reject = 2; realized_cost_usd = 2.0; rework_cost_usd = 2.0 }
        Save-PromptPool -Pool $sbP3 -PoolDir $sbPoolDir
        $sbRun5 = Initialize-RunDir -RunId 'go-sb-5' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun5 'shadow.json') -Encoding utf8NoBOM
        $sbGateRej = @{ verdict = 'reject'; reason = 'bad'; counts = @{ critical = 1; important = 0; minor = 0 }; polish_brief = ''; findings = @(); reviews = @(); unparsed = @() }
        [void](Complete-Run -RunDir $sbRun5 -Plan @{ run_id = 'go-sb-5'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGateRej -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter5 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbRetired = @($sbAfter5.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB8a losing challenger auto-retired with provenance' `
            (($sbRetired.status -eq 'retired') -and ($sbRetired.retired_reason -match 'live A/B loss vs p001') -and ($sbRetired.retired_by -eq 'p001') -and (([string]$sbRetired.retired_at) -match 'Z$'))
        $sbEv5 = Get-Content -LiteralPath (Join-Path $sbRun5 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB8b auto-retire logged as warn shadow event' (@($sbEv5 | Where-Object { ($_.kind -eq 'shadow') -and ($_.level -eq 'warn') }).Count -ge 1)

        # SB9: fail-open — corrupt pool never breaks the run.
        Set-Content -LiteralPath (Join-Path $sbPoolDir 'pool.json') -Value '{ not json !!!' -Encoding utf8NoBOM
        $sbRun6 = Initialize-RunDir -RunId 'go-sb-6' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun6 'shadow.json') -Encoding utf8NoBOM
        $sbRes6 = Complete-Run -RunDir $sbRun6 -Plan @{ run_id = 'go-sb-6'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @()
        Check 'SB9 corrupt pool: run completes normally (fail-open)' (($sbRes6.status -eq 'completed') -and (Test-Path (Join-Path $sbRun6 'report.md')))

        # SB10: winning challenger -> promote recommendation event, NOT retired.
        $sbP4 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbW1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbW1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbW1.live = @{ runs = 6; accept = 5; polish = 1; reject = 0; realized_cost_usd = 1.2; rework_cost_usd = 0.2 }
        $sbW2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbW2.offline.minibatch.win_rate_vs_champion = 0.8
        $sbW2.live = @{ runs = 5; accept = 5; polish = 0; reject = 0; realized_cost_usd = 0.5; rework_cost_usd = 0.0 }
        $sbP4.candidates = @($sbW1, $sbW2)
        Save-PromptPool -Pool $sbP4 -PoolDir $sbPoolDir
        $sbRun7 = Initialize-RunDir -RunId 'go-sb-7' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p001'; role = 'champion'; challenger_id = 'p002'; assigned = '2026-07-02T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun7 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun7 -Plan @{ run_id = 'go-sb-7'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter7 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbEv7 = Get-Content -LiteralPath (Join-Path $sbRun7 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        Check 'SB10 winning challenger: promote event, still a candidate' `
            ((@($sbAfter7.candidates | Where-Object { $_.id -eq 'p002' })[0].status -eq 'candidate') -and `
             (@($sbEv7 | Where-Object { ($_.kind -eq 'shadow') -and ($_.message -match 'promote|--apply') }).Count -ge 1))

        # SB11: promote nudge is one-shot — second winning run emits no duplicate.
        $sbC7 = @($sbAfter7.candidates | Where-Object { $_.id -eq 'p002' })[0]
        Check 'SB11a first promote run stamps promote_recommended_at' (([string]$sbC7.promote_recommended_at) -match 'Z$')
        $sbRun8 = Initialize-RunDir -RunId 'go-sb-8' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p001'; role = 'champion'; challenger_id = 'p002'; assigned = '2026-07-03T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun8 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun8 -Plan @{ run_id = 'go-sb-8'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGate -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        # events.jsonl is created lazily on first Add-RunEvent; the one-shot nudge
        # legitimately writes none here, so the file may not exist at all.
        $sbEv8Path = Join-Path $sbRun8 'events.jsonl'
        $sbEv8 = if (Test-Path $sbEv8Path) { Get-Content -LiteralPath $sbEv8Path | ForEach-Object { $_ | ConvertFrom-Json } } else { @() }
        Check 'SB11b second winning run: no duplicate promote event' (@($sbEv8 | Where-Object { ($_.kind -eq 'shadow') -and ($_.message -match 'promote via') }).Count -eq 0)

        # SB12: verdict evaluates the ASSIGNED challenger, not a newer higher-wr rival.
        $sbP5 = @{ schema = 1; champion = 'p001'; candidates = @() }
        $sbX1 = New-PoolCandidateRecord -Id 'p001' -Parent $null -Origin 'seed' -Status 'champion' -PromptTokens 12
        $sbX1.offline.minibatch.win_rate_vs_champion = 0.5
        $sbX1.live = @{ runs = 5; accept = 4; polish = 1; reject = 0; realized_cost_usd = 1.0; rework_cost_usd = 0.2 }
        $sbX2 = New-PoolCandidateRecord -Id 'p002' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 10
        $sbX2.offline.minibatch.win_rate_vs_champion = 0.6
        $sbX2.live = @{ runs = 4; accept = 1; polish = 2; reject = 1; realized_cost_usd = 3.0; rework_cost_usd = 2.5 }
        $sbX3 = New-PoolCandidateRecord -Id 'p003' -Parent 'p001' -Origin 'mutation' -Status 'candidate' -PromptTokens 9
        $sbX3.offline.minibatch.win_rate_vs_champion = 0.9   # newer, shinier — but NOT the one that ran
        $sbP5.candidates = @($sbX1, $sbX2, $sbX3)
        Save-PromptPool -Pool $sbP5 -PoolDir $sbPoolDir
        $sbRun9 = Initialize-RunDir -RunId 'go-sb-9' -Root (Join-Path $sbHome 'runs')
        @{ variant_id = 'p002'; role = 'challenger'; challenger_id = 'p002'; assigned = '2026-07-03T00:00:00Z' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sbRun9 'shadow.json') -Encoding utf8NoBOM
        [void](Complete-Run -RunDir $sbRun9 -Plan @{ run_id = 'go-sb-9'; goal = 'g'; budget_cap = $null; tasks = @() } -Gate $sbGateRej -TaskCosts @(@{ id = 't1'; worker = 'stub'; cost = 0.10 }))
        $sbAfter9 = (Get-PromptPool -PoolDir $sbPoolDir).pool
        $sbX2b = @($sbAfter9.candidates | Where-Object { $_.id -eq 'p002' })[0]
        $sbX3b = @($sbAfter9.candidates | Where-Object { $_.id -eq 'p003' })[0]
        Check 'SB12 assigned challenger judged (auto-retired), rival untouched' `
            (($sbX2b.status -eq 'retired') -and ($sbX2b.retired_by -eq 'p001') -and ($sbX3b.status -eq 'candidate'))
    } finally { $env:BATON_HOME = $sbPrevHome }

    # ---- Slice 2 (d078): -DiffProvider seam ----
    $tmpDp = Join-Path ([System.IO.Path]::GetTempPath()) "cond-dp-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $tmpDp | Out-Null
    try {
        $dpPlanner = { param($g) @{ run_id='go-dp'; goal=$g; budget_cap=$null; tasks=@([pscustomobject]@{ id='t1'; desc='d'; command=''; capability='code-gen'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true }) } }
        $dpSpawn = { param($t) @{ ok=$true; spend=0.0; chose='stub'; why='w'; alternatives=@() } }
        $dpGater = { param($gArt, $gGoal) @{ verdict='accept'; reason="saw:$gArt"; counts=@{critical=0;important=0;minor=0}; polish_brief=''; findings=@(); reviews=@(); unparsed=@() } }

        $runDp1 = Initialize-RunDir -RunId 'go-dp-1' -Root $tmpDp
        $dp1 = { "diff --git a/x b/x`n+produced-by-walk" }
        $rDp1 = Invoke-Conductor -Goal 'g' -RunDir $runDp1 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider $dp1
        Check 'DP1 changes.diff written' (Test-Path (Join-Path $runDp1 'changes.diff'))
        Check 'DP2 gate received the produced diff' ($rDp1.acceptance.reason -match 'produced-by-walk')
        Check 'DP3 run completed with accept' ($rDp1.status -eq 'completed')

        $runDp2 = Initialize-RunDir -RunId 'go-dp-2' -Root $tmpDp
        $rDp2 = Invoke-Conductor -Goal 'g' -RunDir $runDp2 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { '' }
        Check 'DP4 empty diff -> no changes.diff' (-not (Test-Path (Join-Path $runDp2 'changes.diff')))
        Check 'DP5 empty diff + no gate target -> no acceptance section' ($null -eq $rDp2.acceptance)

        $runDp3 = Initialize-RunDir -RunId 'go-dp-3' -Root $tmpDp
        $rDp3 = Invoke-Conductor -Goal 'g' -RunDir $runDp3 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { '' } -GateArtifact 'fallback-artifact'
        Check 'DP6 empty produced diff falls back to -GateArtifact' ($rDp3.acceptance.reason -match 'fallback-artifact')

        $runDp4 = Initialize-RunDir -RunId 'go-dp-4' -Root $tmpDp
        $rDp4 = Invoke-Conductor -Goal 'g' -RunDir $runDp4 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater -DiffProvider { throw 'boom' }
        Check 'DP7 throwing diff provider is fail-open (run completes)' ($rDp4.status -eq 'completed')
        Check 'DP8 fail-open logged a gate warn event' ((Get-Content -Raw (Join-Path $runDp4 'events.jsonl')) -match 'diff provider failed')

        $runDp5 = Initialize-RunDir -RunId 'go-dp-5' -Root $tmpDp
        $rDp5 = Invoke-Conductor -Goal 'g' -RunDir $runDp5 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater `
            -DiffProvider { '' } -AcceptanceGate -AcceptanceFailLoud
        Check 'DP9 empty/no-op diff is a clean completed run, not degraded' ($rDp5.status -eq 'completed' -and $null -eq $rDp5.acceptance)

        $runDp6 = Initialize-RunDir -RunId 'go-dp-6' -Root $tmpDp
        $rDp6 = Invoke-Conductor -Goal 'g' -RunDir $runDp6 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater `
            -DiffProvider { throw 'boom' } -AcceptanceGate -AcceptanceFailLoud
        Check 'DP10 fail-loud diff provider throw -> acceptance-degraded' ($rDp6.status -eq 'acceptance-degraded')

        $runDp7 = Initialize-RunDir -RunId 'go-dp-7' -Root $tmpDp
        $rDp7 = Invoke-Conductor -Goal 'g' -RunDir $runDp7 -Planner $dpPlanner -Spawner $dpSpawn -Gater $dpGater `
            -DiffProvider $dp1 -AcceptanceGate:$false -AcceptanceFailLoud
        Check 'DP11 explicit acceptance disable still records changes.diff' (
            $rDp7.status -eq 'completed' -and $null -eq $rDp7.acceptance -and (Test-Path (Join-Path $runDp7 'changes.diff')))
    } finally {
        Remove-Item -Recurse -Force $tmpDp -ErrorAction SilentlyContinue
    }

    # ---- PG1-PG8: opt-in Plan Gate phase (d080, Slice 2) ----
    # Hermetic: -Planner/-Spawner stub the plan + walk, -PlanGateDispatcher stubs the
    # reviewer roster, -Dispatcher stubs the revise-pass worker. -FleetPath points at the
    # reference fleet so the revise pass's Select-Capability(reasoning) resolves a candidate
    # (no network — the dispatch is always stubbed). Zero real model calls.
    $pgHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-pg-$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Force -Path $pgHome | Out-Null
    $refFleetPG = Join-Path $PSScriptRoot '../references/fleet.yaml'
    $pgTools = Join-Path $pgHome 'tools.yaml'; Set-Content -LiteralPath $pgTools -Value 'tools: []' -Encoding utf8NoBOM
    $pgCliHome = $null
    try {
        $pgTask = { param($id,$deps) [pscustomobject]@{ id=$id; desc="do $id"; command='x'; capability='reasoning'; model_pick=''; depends_on=@($deps); est_cost_tier='free'; reversible=$true } }
        $pgPlanner = { param($goal) @{ run_id='orig'; goal=$goal; budget_cap=$null; tasks=@( (& $pgTask 't1' @()), (& $pgTask 't2' @('t1')) ) } }
        $revisedPlanJson = '{"run_id":"ignored","goal":"g","budget_cap":null,"tasks":[{"id":"t1-rev","desc":"revised task","command":"","capability":"reasoning","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
        $gateAccept    = { param($n,$p) @{ exit_code = 0; stdout = '[]' } }
        $gateCritical  = { param($n,$p) @{ exit_code = 0; stdout = '[{"severity":"critical","area":"risk","summary":"will delete prod"}]' } }
        $gateImportant = { param($n,$p) @{ exit_code = 0; stdout = '[{"severity":"important","area":"ordering","summary":"reorder t1 and t2"}]' } }

        # PG1: NO -PlanGate -> byte-for-byte default (no plan-review.json, walk runs).
        $pgSeen1 = [System.Collections.ArrayList]@()
        $pgSpawn1 = { param($t) [void]$pgSeen1.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run1 = Join-Path $pgHome 'pg-1'
        $rPG1 = Invoke-Conductor -Goal 'g' -RunDir $run1 -Planner $pgPlanner -Spawner $pgSpawn1
        Check 'PG1 no -PlanGate -> completed' ($rPG1.status -eq 'completed')
        Check 'PG1b no -PlanGate -> no plan-review.json' (-not (Test-Path (Join-Path $run1 'plan-review.json')))
        Check 'PG1c no -PlanGate -> walk ran both tasks' (@($pgSeen1).Count -eq 2)

        # PG2: accept (2 reviewers, empty findings) -> completed + plan-review.json + event.
        $pgSeen2 = [System.Collections.ArrayList]@()
        $pgSpawn2 = { param($t) [void]$pgSeen2.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run2 = Join-Path $pgHome 'pg-2'
        $rPG2 = Invoke-Conductor -Goal 'g' -RunDir $run2 -Planner $pgPlanner -Spawner $pgSpawn2 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateAccept -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG2 accept -> completed' ($rPG2.status -eq 'completed')
        Check 'PG2b plan-review.json verdict accept' ((Get-Content -Raw (Join-Path $run2 'plan-review.json') | ConvertFrom-Json).verdict -eq 'accept')
        Check 'PG2c plan-gate event present' ((Get-Content -Raw (Join-Path $run2 'events.jsonl')) -match '"kind":"plan-gate"')
        Check 'PG2d walk proceeded' (@($pgSeen2).Count -eq 2)

        # PG3: a critical finding -> plan-rejected, revise_brief.md, NO task dispatch, report.
        $pgSeen3 = [System.Collections.ArrayList]@()
        $pgSpawn3 = { param($t) [void]$pgSeen3.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run3 = Join-Path $pgHome 'pg-3'
        $rPG3 = Invoke-Conductor -Goal 'g' -RunDir $run3 -Planner $pgPlanner -Spawner $pgSpawn3 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateCritical -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG3 critical finding -> plan-rejected' ($rPG3.status -eq 'plan-rejected')
        Check 'PG3b revise_brief.md written' (Test-Path (Join-Path $run3 'revise_brief.md'))
        Check 'PG3c NO task dispatch (walk never ran)' (@($pgSeen3).Count -eq 0)
        Check 'PG3d report.md written' (Test-Path (Join-Path $run3 'report.md'))

        # PG4: an important finding + revise enabled -> exactly ONE revise dispatch,
        # plan.json overwritten with the revised DAG, walk proceeds on it, completed.
        $pgReviseCount = @{ n = 0 }
        $reviseDisp = { param($cand,$prompt) $pgReviseCount.n++; @{ exit_code = 0; stdout = $revisedPlanJson } }
        $pgSeen4 = [System.Collections.ArrayList]@()
        $pgSpawn4 = { param($t) [void]$pgSeen4.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run4 = Join-Path $pgHome 'pg-4'
        $rPG4 = Invoke-Conductor -Goal 'g' -RunDir $run4 -Planner $pgPlanner -Spawner $pgSpawn4 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDisp -FleetPath $refFleetPG -ToolsPath $pgTools -NormalizeMissingStakes -StakesOverride high
        Check 'PG4 revise -> completed' ($rPG4.status -eq 'completed')
        Check 'PG4b exactly ONE revise dispatch' ($pgReviseCount.n -eq 1)
        $pg4Plan = Get-Content -Raw (Join-Path $run4 'plan.json') | ConvertFrom-Json
        Check 'PG4c plan.json overwritten with revised plan' ((@($pg4Plan.tasks).Count -eq 1) -and ($pg4Plan.tasks[0].id -eq 't1-rev'))
        Check 'PG4d walk ran the revised plan' ($pgSeen4 -contains 't1-rev')
        Check 'PG4e operator stakes override survives plan revision' (
            $pg4Plan.tasks[0].stakes -eq 'high' -and $pg4Plan.tasks[0].stakes_basis -eq 'operator override: --stakes high')

        $pgPlannerStaked = { param($goal) @{ run_id='orig'; goal=$goal; budget_cap=$null; tasks=@(
            [pscustomobject]@{ id='t1'; desc='original'; command='x'; capability='reasoning'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true; stakes='standard'; stakes_basis='ordinary bounded task' }
        ) } }
        $pgSeen4f = [System.Collections.ArrayList]@()
        $pgSpawn4f = { param($t) [void]$pgSeen4f.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run4f = Join-Path $pgHome 'pg-4f'
        $rPG4f = Invoke-Conductor -Goal 'g' -RunDir $run4f -Planner $pgPlannerStaked -Spawner $pgSpawn4f `
            -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDisp `
            -FleetPath $refFleetPG -ToolsPath $pgTools -NormalizeMissingStakes
        Check 'PG4f revised plan missing stakes emits the applied-policy warning' (
            $rPG4f.status -eq 'completed' -and
            (Get-Content -Raw (Join-Path $run4f 'events.jsonl')) -match 'missing stakes normalized to standard.*applied policy: depth med, economy routing')

        # #101: -RequireTaskStakes hard-fails when a task lacks stakes (no normalize, no override).
        $pgSeenReq = [System.Collections.ArrayList]@()
        $pgSpawnReq = { param($t) [void]$pgSeenReq.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $runReq = Join-Path $pgHome 'pg-require-stakes'
        $rReq = Invoke-Conductor -Goal 'g' -RunDir $runReq -Planner $pgPlanner -Spawner $pgSpawnReq -RequireTaskStakes
        Check 'PG4g RequireTaskStakes + missing stakes -> plan-invalid' (
            $rReq.status -eq 'plan-invalid' -and
            (Get-Content -Raw (Join-Path $runReq 'events.jsonl')) -match 'PLAN-INVALID .+ task\(s\) missing stakes: t1, t2' -and
            @($pgSeenReq).Count -eq 0)
        $runReqOk = Join-Path $pgHome 'pg-require-stakes-ok'
        $rReqOk = Invoke-Conductor -Goal 'g' -RunDir $runReqOk -Planner $pgPlannerStaked -Spawner $pgSpawnReq -RequireTaskStakes
        Check 'PG4h RequireTaskStakes + present stakes -> completed' ($rReqOk.status -eq 'completed')

        # F2 (#101 review): the RequireTaskStakes revise re-check must reject INVALID-value
        # stakes, not just missing ones — parity with the initial hard-require pass. In the
        # live path ConvertTo-PlanObject already rejects out-of-set stakes at revise-parse
        # time (fail-open to the original plan), so an invalid value can only reach the
        # re-check if that upstream guard is ever bypassed. This drives the re-check guard
        # directly: shadow Invoke-PlanRevise to hand back a revised plan whose task carries
        # an out-of-set 'urgent' stakes. The real function is restored right after.
        function Invoke-PlanRevise {
            param($Goal, $PlanJson, $ReviseBrief, $Run, $RunDir, $MaxCostTier, $FleetPath, $ToolsPath, $RegistryLines, $Dispatcher)
            @{ run_id = $Run.run_id; goal = $Goal; budget_cap = $Run.budget_cap; tasks = @(
                [pscustomobject]@{ id='t1-rev'; desc='revised'; command=''; capability='reasoning'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true; stakes='urgent'; stakes_basis='revised' }
            ) }
        }
        $pgSeenInv = [System.Collections.ArrayList]@()
        $pgSpawnInv = { param($t) [void]$pgSeenInv.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $runInv = Join-Path $pgHome 'pg-require-revise-invalid'
        $rInv = Invoke-Conductor -Goal 'g' -RunDir $runInv -Planner $pgPlannerStaked -Spawner $pgSpawnInv `
            -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant `
            -FleetPath $refFleetPG -ToolsPath $pgTools -RequireTaskStakes
        Check 'PG4i RequireTaskStakes revise re-check rejects invalid-value stakes -> plan-invalid, no dispatch' (
            $rInv.status -eq 'plan-invalid' -and
            (Get-Content -Raw (Join-Path $runInv 'events.jsonl')) -match 'task t1-rev has invalid stakes/stakes_basis' -and
            @($pgSeenInv).Count -eq 0)
        . "$PSScriptRoot/conductor-lib.ps1"   # restore the real Invoke-PlanRevise after the shadow

        # F3 (#101 review): precedence — -RequireTaskStakes (hard contract) wins over
        # -NormalizeMissingStakes when BOTH are passed; missing stakes must halt, not normalize.
        $pgSeenBoth = [System.Collections.ArrayList]@()
        $pgSpawnBoth = { param($t) [void]$pgSeenBoth.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $runBoth = Join-Path $pgHome 'pg-require-wins'
        $rBoth = Invoke-Conductor -Goal 'g' -RunDir $runBoth -Planner $pgPlanner -Spawner $pgSpawnBoth -RequireTaskStakes -NormalizeMissingStakes
        Check 'PG4j RequireTaskStakes wins over NormalizeMissingStakes (both -> plan-invalid halt)' (
            $rBoth.status -eq 'plan-invalid' -and
            (Get-Content -Raw (Join-Path $runBoth 'events.jsonl')) -match 'PLAN-INVALID .+ task\(s\) missing stakes' -and
            (Get-Content -Raw (Join-Path $runBoth 'events.jsonl')) -notmatch 'missing stakes normalized to standard' -and
            @($pgSeenBoth).Count -eq 0)

        # PG5: important finding + -PlanRevise:$false -> no revise dispatch, original walked,
        # event notes the disabled auto-revise.
        $pgReviseCount5 = @{ n = 0 }
        $reviseDisp5 = { param($cand,$prompt) $pgReviseCount5.n++; @{ exit_code = 0; stdout = $revisedPlanJson } }
        $pgSeen5 = [System.Collections.ArrayList]@()
        $pgSpawn5 = { param($t) [void]$pgSeen5.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run5 = Join-Path $pgHome 'pg-5'
        $rPG5 = Invoke-Conductor -Goal 'g' -RunDir $run5 -Planner $pgPlanner -Spawner $pgSpawn5 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDisp5 -PlanRevise:$false -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG5 revise disabled -> completed' ($rPG5.status -eq 'completed')
        Check 'PG5b no revise dispatch' ($pgReviseCount5.n -eq 0)
        $pg5Plan = Get-Content -Raw (Join-Path $run5 'plan.json') | ConvertFrom-Json
        Check 'PG5c original plan walked (t1,t2)' ((@($pg5Plan.tasks).Count -eq 2) -and ($pgSeen5 -contains 't1'))
        Check 'PG5d event notes auto-revise disabled' ((Get-Content -Raw (Join-Path $run5 'events.jsonl')) -match 'auto-revise disabled')

        # PG6: revise pass returns unparseable garbage -> fail-open to the ORIGINAL plan,
        # event notes it, walk proceeds, completed.
        $pgReviseCount6 = @{ n = 0 }
        $reviseDispBad = { param($cand,$prompt) $pgReviseCount6.n++; @{ exit_code = 0; stdout = 'not json at all' } }
        $pgSeen6 = [System.Collections.ArrayList]@()
        $pgSpawn6 = { param($t) [void]$pgSeen6.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run6 = Join-Path $pgHome 'pg-6'
        $rPG6 = Invoke-Conductor -Goal 'g' -RunDir $run6 -Planner $pgPlanner -Spawner $pgSpawn6 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDispBad -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG6 revise garbage -> completed (fail-open)' ($rPG6.status -eq 'completed')
        Check 'PG6b revise was attempted once' ($pgReviseCount6.n -eq 1)
        $pg6Plan = Get-Content -Raw (Join-Path $run6 'plan.json') | ConvertFrom-Json
        Check 'PG6c original plan walked (revise failed open)' ((@($pg6Plan.tasks).Count -eq 2) -and ($pgSeen6 -contains 't2'))
        Check 'PG6d event notes revise fail-open' ((Get-Content -Raw (Join-Path $run6 'events.jsonl')) -match 'revise pass failed to parse')

        $pgSeen6L = [System.Collections.ArrayList]@()
        $pgSpawn6L = { param($t) [void]$pgSeen6L.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run6L = Join-Path $pgHome 'pg-6-loud'
        $rPG6L = Invoke-Conductor -Goal 'g' -RunDir $run6L -Planner $pgPlanner -Spawner $pgSpawn6L -PlanGate -PlanGateFailLoud `
            -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDispBad -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG6e fail-loud revise failure -> plan-gate-degraded' ($rPG6L.status -eq 'plan-gate-degraded')
        Check 'PG6f fail-loud revise failure runs no tasks' (@($pgSeen6L).Count -eq 0)

        # PG7: understaffed roster (<2 reviewers) -> fail-open accept, walk proceeds,
        # plan-review.json flags fail_open.
        $pgSeen7 = [System.Collections.ArrayList]@()
        $pgSpawn7 = { param($t) [void]$pgSeen7.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run7 = Join-Path $pgHome 'pg-7'
        $rPG7 = Invoke-Conductor -Goal 'g' -RunDir $run7 -Planner $pgPlanner -Spawner $pgSpawn7 -PlanGate -PlanReviewers @('one') -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG7 understaffed roster -> completed (fail-open)' ($rPG7.status -eq 'completed')
        Check 'PG7b plan-review.json fail_open true' ((Get-Content -Raw (Join-Path $run7 'plan-review.json') | ConvertFrom-Json).fail_open -eq $true)
        Check 'PG7c walk proceeded' (@($pgSeen7).Count -eq 2)

        $pgSeen7L = [System.Collections.ArrayList]@()
        $pgSpawn7L = { param($t) [void]$pgSeen7L.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run7L = Join-Path $pgHome 'pg-7-loud'
        $rPG7L = Invoke-Conductor -Goal 'g' -RunDir $run7L -Planner $pgPlanner -Spawner $pgSpawn7L -PlanGate -PlanGateFailLoud `
            -PlanReviewers @('one') -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG7d fail-loud understaffed -> plan-gate-degraded' ($rPG7L.status -eq 'plan-gate-degraded')
        Check 'PG7e fail-loud understaffed writes degraded result and runs no tasks' (
            (Get-Content -Raw (Join-Path $run7L 'plan-review.json') | ConvertFrom-Json).degraded -eq $true -and @($pgSeen7L).Count -eq 0)

        # PG9 (F4): a THROW from the revise pass's roster resolution (Select-Capability on a
        # malformed fleet/tools file) is fail-open — the WHOLE revise pass sits in one try, so
        # ANY failure returns the ORIGINAL plan with the fail-open event. Shadow Select-Capability
        # to throw (the roster call sits before dispatch); the revise dispatcher must NEVER run.
        # The real function is restored right after via re-dot-sourcing routing-lib.
        function Select-Capability { throw 'malformed fleet file at revise time' }
        $pgReviseCount9 = @{ n = 0 }
        $reviseDisp9 = { param($cand,$prompt) $pgReviseCount9.n++; @{ exit_code = 0; stdout = $revisedPlanJson } }
        $pgSeen9 = [System.Collections.ArrayList]@()
        $pgSpawn9 = { param($t) [void]$pgSeen9.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run9 = Join-Path $pgHome 'pg-9'
        $rPG9 = Invoke-Conductor -Goal 'g' -RunDir $run9 -Planner $pgPlanner -Spawner $pgSpawn9 -PlanGate -PlanReviewers @('a','b') -PlanGateDispatcher $gateImportant -Dispatcher $reviseDisp9 -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG9 revise roster throw -> completed (fail-open)' ($rPG9.status -eq 'completed')
        Check 'PG9b revise dispatcher never reached (threw before dispatch)' ($pgReviseCount9.n -eq 0)
        $pg9Plan = Get-Content -Raw (Join-Path $run9 'plan.json') | ConvertFrom-Json
        Check 'PG9c original plan walked (t1,t2)' ((@($pg9Plan.tasks).Count -eq 2) -and ($pgSeen9 -contains 't2'))
        Check 'PG9d event notes revise fail-open' ((Get-Content -Raw (Join-Path $run9 'events.jsonl')) -match 'revise pass failed to parse')
        . "$PSScriptRoot/routing-lib.ps1"   # restore the real Select-Capability after the shadow

        # PGcli: fleet-go plumbing + BATON_GO_TEST_PLANGATE seam end-to-end (child process,
        # accept path). Exercises -PlanGate + comma-joined -PlanReviewers + the env seam.
        $pgCliHome = Join-Path ([System.IO.Path]::GetTempPath()) "cond-pgcli-$([System.IO.Path]::GetRandomFileName())"
        New-Item -ItemType Directory -Force -Path $pgCliHome | Out-Null
        $pgDispFile = Join-Path $pgCliHome 'pgdisp.ps1'
        Set-Content -LiteralPath $pgDispFile -Encoding utf8NoBOM -Value 'function Invoke-TestPlanGateDispatch { param($Name, $Prompt) @{ exit_code = 0; stdout = "[]" } }'
        $env:BATON_HOME = $pgCliHome
        $env:BATON_GO_TEST_PLAN = '{"tasks":[{"id":"t1","desc":"research","command":"research-gate","capability":"research","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
        $env:BATON_GO_TEST_SPAWN = '1'
        $env:BATON_GO_TEST_PLANGATE = $pgDispFile
        $outPG = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'fleet-go.ps1') -Goal 'convert pdfs' -PlanGate -PlanReviewers 'a,b' -Json 2>&1 | Out-String
        Check 'PGcli CLI -PlanGate accept -> completed' ($outPG -match 'completed')
        $pgCliRuns = @(Get-ChildItem -Path (Join-Path $pgCliHome 'runs') -Directory -ErrorAction SilentlyContinue)
        Check 'PGcli CLI wrote plan-review.json' ((@($pgCliRuns).Count -ge 1) -and (Test-Path (Join-Path $pgCliRuns[0].FullName 'plan-review.json')))
        Remove-Item Env:\BATON_HOME, Env:\BATON_GO_TEST_PLAN, Env:\BATON_GO_TEST_SPAWN, Env:\BATON_GO_TEST_PLANGATE -ErrorAction SilentlyContinue

        # PG8: a THROW from the gate infrastructure itself is fail-open at the conductor
        # level — warn event + walk as-is. Shadow Invoke-PlanGate to force the throw; this
        # is the LAST plan-gate check and the real function is restored right after.
        function Invoke-PlanGate { throw 'plan gate infrastructure exploded' }
        $pgSeen8 = [System.Collections.ArrayList]@()
        $pgSpawn8 = { param($t) [void]$pgSeen8.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run8 = Join-Path $pgHome 'pg-8'
        $rPG8 = Invoke-Conductor -Goal 'g' -RunDir $run8 -Planner $pgPlanner -Spawner $pgSpawn8 -PlanGate -PlanReviewers @('a','b') -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG8 gate throw -> completed (fail-open)' ($rPG8.status -eq 'completed')
        Check 'PG8b gate throw logs warn event + walk ran' (((Get-Content -Raw (Join-Path $run8 'events.jsonl')) -match 'plan gate failed') -and (@($pgSeen8).Count -eq 2))

        $pgSeen8L = [System.Collections.ArrayList]@()
        $pgSpawn8L = { param($t) [void]$pgSeen8L.Add($t.id); @{ ok=$true; spend=0.0; chose='m'; why='ran'; alternatives=@() } }
        $run8L = Join-Path $pgHome 'pg-8-loud'
        $rPG8L = Invoke-Conductor -Goal 'g' -RunDir $run8L -Planner $pgPlanner -Spawner $pgSpawn8L -PlanGate -PlanGateFailLoud `
            -PlanReviewers @('a','b') -FleetPath $refFleetPG -ToolsPath $pgTools
        Check 'PG8c fail-loud gate throw -> plan-gate-degraded without null reason crash' ($rPG8L.status -eq 'plan-gate-degraded')
        Check 'PG8d fail-loud gate throw runs no tasks' (@($pgSeen8L).Count -eq 0)
        . "$PSScriptRoot/plan-gate-lib.ps1"   # restore the real Invoke-PlanGate after the shadow
    } finally {
        Remove-Item Env:\BATON_HOME, Env:\BATON_GO_TEST_PLAN, Env:\BATON_GO_TEST_SPAWN, Env:\BATON_GO_TEST_PLANGATE -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $pgHome -ErrorAction SilentlyContinue
        if ($pgCliHome) { Remove-Item -Recurse -Force $pgCliHome -ErrorAction SilentlyContinue }
    }

    # ---- VF2-VF7: Conductor -Verify preflight + event/status seam (d082 V2) ----
    # Hermetic: stub -Spawner returns canned verification metadata, stub -VerifyPreflight
    # short-circuits the real freeze. No worktree, no real runner.
    function New-VfRun { $d = Join-Path $env:TEMP "vf-$([guid]::NewGuid())"; New-Item -ItemType Directory -Force $d | Out-Null; $d }
    $vfPlan = { param($g) @{ goal=$g; budget_cap=$null; tasks=@([pscustomobject]@{ id='t1'; desc='edit'; command=''; capability='code-gen'; depends_on=@(); est_cost_tier='free'; reversible=$true; verify_profile='unit'; allowed_paths=@() }) } }

    # VF2: -Verify pass -> completed + task-verification-passed event
    $d = New-VfRun
    $sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); verification=@{ verdict='pass'; grade='strong'; failure_category=''; proves='suite passes'; retried=$false } } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
    Check 'VF2 status completed' ($res.status -eq 'completed')
    Check 'VF2 passed event' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification-passed' }).Count -ge 1)
    Check 'VF2 started event (review M1 — 6-kind contract literal)' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification-started' }).Count -ge 1)
    Remove-Item $d -Recurse -Force

    # VF3: -Verify check-fail (verdict fail) -> verification-failed status + event
    $d = New-VfRun
    $sp = { param($t) @{ ok=$false; spend=0.0; chose='w'; why='fail'; alternatives=@(); verification=@{ verdict='fail'; grade='invalid'; failure_category='check-failed'; proves='x'; retried=$true; first_failure_category='check-failed' } } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
    Check 'VF3 status verification-failed' ($res.status -eq 'verification-failed')
    Check 'VF3 retry event' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-retry-started' }).Count -ge 1)
    Check 'VF3 failed event' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification-failed' }).Count -ge 1)
    Remove-Item $d -Recurse -Force

    # VF4: scope-violation -> verification-failed + task-scope-violation event, no 'failed'
    $d = New-VfRun
    $sp = { param($t) @{ ok=$false; spend=0.0; chose='w'; why='scope'; alternatives=@(); verification=@{ verdict='scope-violation'; grade='invalid'; failure_category='protected-path-mutated'; proves='x'; retried=$false } } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
    Check 'VF4 status verification-failed' ($res.status -eq 'verification-failed')
    Check 'VF4 scope event' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-scope-violation' }).Count -ge 1)
    Remove-Item $d -Recurse -Force

    # VF5: preflight fail -> plan-invalid before the walk (spawner never called)
    $d = New-VfRun
    $called = [ref]$false
    $sp = { param($t) $called.Value = $true; @{ ok=$true; spend=0.0; chose='w'; why=''; alternatives=@() } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$false; reason="unknown-profile 'unit'" } }
    Check 'VF5 status plan-invalid' ($res.status -eq 'plan-invalid')
    Check 'VF5 spawner not called' (-not $called.Value)
    Remove-Item $d -Recurse -Force

    # VF6: unverified task (no contract) -> completed + task-unverified event
    $d = New-VfRun
    $sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); unverified=$true } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp -Verify -VerifyPreflight { param($p) @{ ok=$true } }
    Check 'VF6 status completed' ($res.status -eq 'completed')
    Check 'VF6 unverified event' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-unverified' }).Count -ge 1)
    Remove-Item $d -Recurse -Force

    # VF7: -Verify ABSENT -> byte-for-byte unchanged (no verification events even if $r carries them)
    $d = New-VfRun
    $sp = { param($t) @{ ok=$true; spend=0.0; chose='w'; why='ok'; alternatives=@(); verification=@{ verdict='pass'; grade='strong'; failure_category=''; proves='x'; retried=$false } } }
    $res = Invoke-Conductor -Goal 'g' -RunDir $d -Planner $vfPlan -Spawner $sp   # no -Verify
    Check 'VF7 status completed' ($res.status -eq 'completed')
    Check 'VF7 no verification events' (@(Get-Content (Join-Path $d 'events.jsonl') | Where-Object { $_ -match 'task-verification' }).Count -eq 0)
    Remove-Item $d -Recurse -Force

    # ---- VF8: verification.json under tasks/<id>/ renders a ## Verification report section ----
    $d = New-VfRun
    $td = Join-Path $d 'tasks/t1'; New-Item -ItemType Directory -Force $td | Out-Null
    @{ verdict='pass'; grade='strong'; failure_category=''; proves='the suite passes'; retried=$true } | ConvertTo-Json | Set-Content (Join-Path $td 'verification.json') -Encoding utf8NoBOM
    $plan = & $vfPlan 'g'
    $sec = Format-VerificationSection -RunDir $d -Plan $plan
    Check 'VF8a section present' ($sec -match '## Verification')
    Check 'VF8b pass+grade rendered' ($sec -match 'PASS \(grade strong\)')
    Check 'VF8c retry noted' ($sec -match 'after 1 retry')
    Check 'VF8d proves rendered' ($sec -match 'the suite passes')
    $empty = Format-VerificationSection -RunDir (New-VfRun) -Plan $plan
    Check 'VF8e no verified task -> empty' ($empty -eq '')
    Remove-Item $d -Recurse -Force

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
