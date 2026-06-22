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
    Add-RunDecision -RunDir $runDir -Decision $dec
    Check 'T31 decision appended' ((Get-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') | Measure-Object -Line).Lines -ge 1)

    $plan = @{ run_id='go-unit-1'; goal='convert pdfs'; budget_cap=$null; tasks=@(
        [pscustomobject]@{ id='t1'; desc='research'; command='research-gate'; capability='research'; model_pick=''; depends_on=@(); est_cost_tier='free'; reversible=$true }
    ) }
    $report = Format-RunReport -Plan $plan -Decisions @($dec) -Spend 0.0 -Status 'completed'
    Check 'T32 report names the goal' ($report -match 'convert pdfs')
    Check 'T33 report shows status' ($report -match 'completed')
    Check 'T34 report lists the decision' ($report -match 'docling')
    $reportI = Format-RunReport -Plan $plan -Status 'interrupted-budget' -PendingTaskId 't1'
    Check 'T35 interrupted report names paused task' ($reportI -match 't1')

    Remove-Item -Recurse -Force $tmpHome -ErrorAction SilentlyContinue

    # ---- Task 4: planner prompt + seamed plan phase ----
    $pp = Build-PlannerPrompt -Goal 'convert pdfs to markdown' -RegistryLines @('docling — pdf-extract (local)')
    Check 'T36 planner prompt includes goal' ($pp -match 'convert pdfs to markdown')
    Check 'T37 planner prompt includes registry evidence' ($pp -match 'docling')
    Check 'T38 planner prompt includes schema + reversible rule' (($pp -match '"tasks"') -and ($pp -match 'reversible'))

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

    Write-Host ""
    if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 } else { Write-Host "ALL CHECKS PASS"; exit 0 }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
