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

} catch { Write-Host "ERROR: $($_.Exception.Message)"; exit 1 }
Write-Host ""; if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
