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

} catch { Write-Host "ERROR: $($_.Exception.Message)"; exit 1 }
Write-Host ""; if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
