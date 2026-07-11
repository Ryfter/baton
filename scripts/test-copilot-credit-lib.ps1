#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/copilot-credit-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ccb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$savedHome = $env:BATON_HOME
$savedSeam = $env:BATON_COPILOT_TEST_USAGE
$env:BATON_HOME = $tmp

# Canned billing response: 1018 credits across 3 models + one non-Copilot row (excluded).
$fixture = @'
{
  "usageItems": [
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "GPT-5",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 612, "grossAmount": 6.12, "netQuantity": 612, "netAmount": 6.12 },
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "Claude-Sonnet",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 300, "grossAmount": 3.00, "netQuantity": 300, "netAmount": 3.00 },
    { "product": "Copilot AI Credits", "sku": "AI Credit", "model": "Gemini",
      "unitType": "ai-credits", "pricePerUnit": 0.01,
      "grossQuantity": 106, "grossAmount": 1.06, "netQuantity": 106, "netAmount": 1.06 },
    { "product": "Actions Minutes", "sku": "Other", "model": "n/a",
      "unitType": "minutes", "pricePerUnit": 0.008,
      "grossQuantity": 999, "grossAmount": 7.99, "netQuantity": 999, "netAmount": 7.99 }
  ]
}
'@
$fixturePath = Join-Path $tmp 'usage-fixture.json'
Set-Content -Path $fixturePath -Value $fixture -Encoding utf8NoBOM

function New-TestFleet {
    param([string]$Name, [string[]]$ExtraLines)
    $p = Join-Path $tmp $Name
    $lines = @('providers:', '  - name: gh-copilot', '    kind: cli', '    enabled: true', '    cost_tier: paid', "    command_template: 'gh models run {{model}}'")
    if ($ExtraLines) { $lines += $ExtraLines }
    Set-Content -Path $p -Value ($lines -join "`n") -Encoding utf8NoBOM
    return $p
}
$fleetFull  = New-TestFleet -Name 'fleet-full.yaml'  -ExtraLines @('    budget: 1500', '    credit_reset_day: 10')
$fleetWarn  = New-TestFleet -Name 'fleet-warn.yaml'  -ExtraLines @('    budget: 1200', '    credit_reset_day: 10')
$fleetNoRst = New-TestFleet -Name 'fleet-norst.yaml' -ExtraLines @('    budget: 1500')
$fleetBare  = New-TestFleet -Name 'fleet-bare.yaml'  -ExtraLines @()
$fleetBadRd = New-TestFleet -Name 'fleet-badrd.yaml' -ExtraLines @('    budget: 1500', '    credit_reset_day: 31')
$T0 = [datetime]::Parse('2026-07-20T12:00:00Z').ToUniversalTime()

try {
    # ---- reason classifier (pure) ----
    Check 'C1 404 -> insufficient-scope' ((Get-CopilotFetchReason -ErrorText 'HTTP 404: Not Found') -eq 'insufficient-scope')
    Check 'C2 user-scope text -> insufficient-scope' ((Get-CopilotFetchReason -ErrorText "needs the 'user' scope") -eq 'insufficient-scope')
    Check 'C3 network error -> fetch-failed' ((Get-CopilotFetchReason -ErrorText 'connection refused') -eq 'fetch-failed')
    Check 'C3b 403 not-accessible -> insufficient-scope' ((Get-CopilotFetchReason -ErrorText 'HTTP 403: Resource not accessible by personal access token') -eq 'insufficient-scope')

    # ---- config reader ----
    $cfg = Get-CopilotCreditConfig -FleetPath $fleetFull
    Check 'C4 config reads budget + reset day' ($cfg.budget -eq 1500 -and $cfg.reset_day -eq 10 -and $cfg.warn_pct -eq 80)
    Check 'C5 config: no fields -> nulls + default warn' ((Get-CopilotCreditConfig -FleetPath $fleetBare).budget -eq $null -and (Get-CopilotCreditConfig -FleetPath $fleetBare).warn_pct -eq 80)
    Check 'C6 config: reset day 31 out of range -> ignored' ((Get-CopilotCreditConfig -FleetPath $fleetBadRd).reset_day -eq $null)
    Check 'C7 config: missing fleet file -> nulls, no throw' ((Get-CopilotCreditConfig -FleetPath (Join-Path $tmp 'nope.yaml')).budget -eq $null)

    # ---- usage fold (injected fetcher) ----
    $u = Get-CopilotCreditUsage -Fetcher { param($login) $fixture }.GetNewClosure()
    Check 'U1 folds used across Copilot rows only' ($u.ok -and [double]$u.used -eq 1018)
    Check 'U2 folds dollar amount' ([math]::Round([double]$u.amount, 2) -eq 10.18)
    Check 'U3 by_model has 3 rows, top is GPT-5 612' (@($u.by_model).Count -eq 3 -and $u.by_model[0].model -eq 'GPT-5' -and [double]$u.by_model[0].credits -eq 612)
    Check 'U4 non-Copilot product excluded' (-not (@($u.by_model) | Where-Object { $_.model -eq 'n/a' }))

    $uThrow = Get-CopilotCreditUsage -Fetcher { param($login) throw 'HTTP 404: Not Found' }
    Check 'U5 fetcher throw 404 -> ok=false insufficient-scope' ((-not $uThrow.ok) -and $uThrow.reason -eq 'insufficient-scope')
    $uJunk = Get-CopilotCreditUsage -Fetcher { param($login) 'this is not json' }
    Check 'U6 non-JSON -> fetch-failed' ((-not $uJunk.ok) -and $uJunk.reason -eq 'fetch-failed')
    $uOrg = Get-CopilotCreditUsage -Fetcher { param($login) '{"message":"no billing here"}' }
    Check 'U7 no usageItems shape -> org-managed' ((-not $uOrg.ok) -and $uOrg.reason -eq 'org-managed')
    $uEmpty = Get-CopilotCreditUsage -Fetcher { param($login) '{"usageItems":[]}' }
    Check 'U8 empty usageItems -> ok, used 0' ($uEmpty.ok -and [double]$uEmpty.used -eq 0)

    # ---- test seam (env file) ----
    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $uSeam = Get-CopilotCreditUsage
    Check 'U9 BATON_COPILOT_TEST_USAGE seam serves the fixture' ($uSeam.ok -and [double]$uSeam.used -eq 1018)
    $env:BATON_COPILOT_TEST_USAGE = $null

    # ---- forecast branches ----
    $fx = { param($login) $fixture }.GetNewClosure()
    $f = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher $fx
    Check 'F1 status ok' ($f.status -eq 'ok')
    Check 'F2 remaining 482, pct 68' ([double]$f.remaining -eq 482 -and [int]$f.pct -eq 68)
    Check 'F3 cycle window: elapsed 10, left 21, resets 2026-08-10' ($f.days_elapsed -eq 10 -and $f.days_left_in_cycle -eq 21 -and $f.reset_date -eq '2026-08-10')
    Check 'F4 run-rate 101.8, exhaustion 4.73d' ([double]$f.run_rate -eq 101.8 -and [double]$f.days_to_exhaustion -eq 4.73)
    Check 'F5 warn false at 68% vs 80' ($f.warn -eq $false)

    $fw = Get-CopilotCreditForecast -FleetPath $fleetWarn -Now $T0 -Fetcher $fx
    Check 'F6 warn true at 85% vs 80' ($fw.warn -eq $true -and [int]$fw.pct -eq 85)

    $fBefore = Get-CopilotCreditForecast -FleetPath $fleetFull -Now ([datetime]::Parse('2026-07-05T00:00:00Z').ToUniversalTime()) -Fetcher $fx
    Check 'F7 before reset day: prior-month anchor (elapsed 25, left 5, resets 2026-07-10)' ($fBefore.days_elapsed -eq 25 -and $fBefore.days_left_in_cycle -eq 5 -and $fBefore.reset_date -eq '2026-07-10')

    $fEdge = Get-CopilotCreditForecast -FleetPath $fleetFull -Now ([datetime]::Parse('2026-07-10T00:00:00Z').ToUniversalTime()) -Fetcher $fx
    Check 'F8 at reset instant: days_elapsed clamped to 1' ($fEdge.days_elapsed -eq 1)

    $fZero = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher { param($login) '{"usageItems":[]}' }
    Check 'F9 zero usage: run_rate 0 -> exhaustion null' ([double]$fZero.run_rate -eq 0 -and $null -eq $fZero.days_to_exhaustion)

    $fNoB = Get-CopilotCreditForecast -FleetPath $fleetBare -Now $T0 -Fetcher $fx
    Check 'F10 no budget -> status no_budget, used still reported' ($fNoB.status -eq 'no_budget' -and [double]$fNoB.used -eq 1018)

    $fNoR = Get-CopilotCreditForecast -FleetPath $fleetNoRst -Now $T0 -Fetcher $fx
    Check 'F11 no reset anchor -> used/budget/pct only' ($fNoR.status -eq 'no_reset_anchor' -and [int]$fNoR.pct -eq 68 -and $null -eq $fNoR.run_rate)

    $fUn = Get-CopilotCreditForecast -FleetPath $fleetFull -Now $T0 -Fetcher { param($login) throw 'connection refused' }
    Check 'F12 fetch failure -> unavailable + reason' ($fUn.status -eq 'unavailable' -and $fUn.reason -eq 'fetch-failed')

    # ---- panel render (capture via Out-String on a child scope) ----
    $pOk = (Write-CopilotCreditPanel -Forecast $f) *>&1 | Out-String
    Check 'P1 ok panel shows used/budget/pct + run-rate + models' ($pOk -match '1018 / 1500' -and $pOk -match '68%' -and $pOk -match 'run-rate 101.8/day' -and $pOk -match 'GPT-5 612')
    Check 'P1b ok panel body is ASCII-only (console-encoding safety)' ($pOk -notmatch '[^\x00-\x7F]')
    $pWarn = (Write-CopilotCreditPanel -Forecast $fw) *>&1 | Out-String
    Check 'P2 warn line at threshold' ($pWarn -match 'WARNING: over 80%')
    $scope = [ordered]@{ status='unavailable'; reason='insufficient-scope' }
    $pScope = (Write-CopilotCreditPanel -Forecast $scope) *>&1 | Out-String
    Check 'P3 insufficient-scope shows the exact fix hint' ($pScope -match 'gh auth refresh -h github.com -s user')
    $pUn = (Write-CopilotCreditPanel -Forecast $fUn) *>&1 | Out-String
    Check 'P4 unavailable is one honest line' ($pUn -match 'unavailable \(fetch-failed\)')

    # ---- R-series: /baton:usage runner integration (child process, hermetic) ----
    $runner = Join-Path $PSScriptRoot 'fleet-usage.ps1'

    $outBare = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetBare 2>&1 | Out-String
    Check 'R1 no budget -> no panel, no fetch' ($outBare -notmatch 'Copilot Credits')

    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $outFull = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    Check 'R2 budget configured -> panel renders numbers' ($outFull -match 'Copilot Credits' -and $outFull -match '1018 / 1500')

    $outJson = & pwsh -NoProfile -File $runner status -Json -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    $j = $null; try { $j = $outJson | ConvertFrom-Json } catch { }
    Check 'R3 --json carries copilot_credits' ($null -ne $j -and $null -ne $j.copilot_credits -and [double]$j.copilot_credits.used -eq 1018)

    $outJsonBare = & pwsh -NoProfile -File $runner status -Json -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetBare 2>&1 | Out-String
    $jb = $null; try { $jb = $outJsonBare | ConvertFrom-Json } catch { }
    Check 'R4 --json without budget has NO copilot_credits key' ($null -ne $jb -and -not ($jb.PSObject.Properties.Name -contains 'copilot_credits'))

    $badFix = Join-Path $tmp 'bad-fixture.json'
    Set-Content -Path $badFix -Value 'not json at all' -Encoding utf8NoBOM
    $env:BATON_COPILOT_TEST_USAGE = $badFix
    $outBad = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetFull 2>&1 | Out-String
    Check 'R5 fetch failure -> honest one-liner, runner exit 0' ($outBad -match 'unavailable \(fetch-failed\)' -and $LASTEXITCODE -eq 0)

    $outNoR = $null
    $env:BATON_COPILOT_TEST_USAGE = $fixturePath
    $outNoR = & pwsh -NoProfile -File $runner status -UsagePath (Join-Path $tmp 'empty.jsonl') -FleetPath $fleetNoRst 2>&1 | Out-String
    Check 'R6 no reset anchor -> numbers without run-rate line' ($outNoR -match '1018 / 1500' -and $outNoR -notmatch 'run-rate')
    $env:BATON_COPILOT_TEST_USAGE = $null
} finally {
    $env:BATON_HOME = $savedHome
    $env:BATON_COPILOT_TEST_USAGE = $savedSeam
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) failure(s)"; exit 1 }
Write-Host "`nALL PASS"; exit 0
