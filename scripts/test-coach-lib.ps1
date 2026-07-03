#!/usr/bin/env pwsh
# Hermetic tests for the guided-use coach engine (d074). Never touches real
# ~/.baton or ~/.claude: temp BATON_HOME, try/finally restore.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    . (Join-Path $here 'coach-lib.ps1')

    $coachDir = Get-CoachDir -BatonHome $env:BATON_HOME
    $seenPath = Join-Path $coachDir 'seen.json'

    # --- Level ---
    Assert "C1 level defaults to quiet when config absent" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    Assert "C2 level teach parses" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'teach')
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    Assert "C3 level off parses" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'off')
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"LOUD"}' -Encoding utf8NoBOM
    Assert "C4 unknown level falls back to quiet" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    Set-Content (Join-Path $coachDir 'config.json') 'not json {' -Encoding utf8NoBOM
    Assert "C5 malformed config falls back to quiet" ((Get-CoachLevel -BatonHome $env:BATON_HOME) -eq 'quiet')
    Remove-Item (Join-Path $coachDir 'config.json') -Force

    # --- Seen store ---
    Set-CoachSeen -SeenPath $seenPath -Key 'k1'
    $seen = Read-CoachSeen -SeenPath $seenPath
    Assert "C6 seen stamp round-trips" ($seen.ContainsKey('k1'))
    Set-Content $seenPath 'garbage {{' -Encoding utf8NoBOM
    Assert "C7 malformed seen.json reads as empty" ((Read-CoachSeen -SeenPath $seenPath).Count -eq 0)
    Set-CoachSeen -SeenPath $seenPath -Key 'k2'
    Assert "C8 stamp after malformed rewrites the store" ((Read-CoachSeen -SeenPath $seenPath).ContainsKey('k2'))
    Remove-Item $seenPath -Force

    # --- Empty context: nothing readable, nothing thrown ---
    $bare = Join-Path $tmp 'bare-dir'
    New-Item -ItemType Directory -Force -Path $bare | Out-Null
    $ctx0 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $bare
    Assert "C9 empty context: no project" ($null -eq $ctx0.project)
    Assert "C10 empty context: not a git repo" (-not $ctx0.is_git_repo)
    Assert "C11 empty context: pool not ok" (-not $ctx0.pool_ok)
    Assert "C12 empty context: no budget risk" (-not $ctx0.budget_at_risk)
    Assert "C13 empty context: zero failure runs" ($ctx0.failure_runs -eq 0)
    Assert "C14 empty context yields no suggestions" (@(Get-CoachSuggestions -Context $ctx0 -SeenPath $seenPath).Count -eq 0)

    # --- Onboard: git repo without a project record ---
    $repoDir = Join-Path $tmp 'proj-alpha'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoDir '.git') | Out-Null
    $ctx1 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C15 detects git repo" ($ctx1.is_git_repo)
    Assert "C16 project id from folder slug" ($ctx1.project_id -eq 'proj-alpha')
    $s1 = @(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath)
    Assert "C17 onboard rule fires" ((@($s1).Count -eq 1) -and ($s1[0].id -eq 'onboard') -and ($s1[0].command -eq '/baton:start'))
    Assert "C18 onboard dedup key carries normalized dir" ($s1[0].dedup_key -eq "onboard:$($ctx1.project_dir_normalized)")
    Set-CoachSeen -SeenPath $seenPath -Key $s1[0].dedup_key
    Assert "C19 stamped onboard is filtered" (@(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath).Count -eq 0)
    Assert "C20 -IncludeSeen bypasses the stamp" (@(Get-CoachSuggestions -Context $ctx1 -SeenPath $seenPath -IncludeSeen).Count -eq 1)

    # --- Registered project: next-command orientation ---
    $projDir = Join-Path (Join-Path $env:BATON_HOME 'projects') 'proj-alpha'
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    Set-Content (Join-Path $projDir 'project.json') '{"id":"proj-alpha","last_run":{"status":"completed"}}' -Encoding utf8NoBOM
    $ctx2 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C21 project record loads" ($null -ne $ctx2.project)
    $s2 = @(Get-CoachSuggestions -Context $ctx2 -SeenPath $seenPath -IncludeSeen)
    Assert "C22 next-command rule fires for last_run.status" ((@($s2).Count -ge 1) -and ($s2[0].id -eq 'next-command'))
    Assert "C23 next-command is digest-only (null dedup_key)" ($null -eq $s2[0].dedup_key)
    Assert "C24 registered project suppresses onboard" (@($s2 | Where-Object { $_.id -eq 'onboard' }).Count -eq 0)

    # --- Gate failure runs ---
    $runsRoot = Join-Path $env:BATON_HOME 'runs'
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-fail-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-fail-1/acceptance.json') '{"verdict":"polish","reason":"needs polish"}' -Encoding utf8NoBOM
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-ok-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-ok-1/acceptance.json') '{"verdict":"accept","reason":"fine"}' -Encoding utf8NoBOM
    $ctx3 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C25 failure run counted" ($ctx3.failure_runs -eq 1)
    Assert "C26 latest failure run id captured" ($ctx3.latest_failure_run_id -eq 'run-fail-1')
    $s3 = @(Get-CoachSuggestions -Context $ctx3 -SeenPath $seenPath)
    $gf = @($s3 | Where-Object { $_.id -eq 'gate-failure' })
    Assert "C27 gate-failure rule fires" ((@($gf).Count -eq 1) -and ($gf[0].command -eq '/baton:optimize-prompt'))
    Assert "C28 gate-failure dedup key names the run" ($gf[0].dedup_key -eq 'gate-failure:run-fail-1')

    # --- Pool: promote-pending + pool-verdict ---
    $poolDir = Join-Path $env:BATON_HOME 'prompts/pool'
    New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
    $poolJson = @'
{
  "schema": 1, "champion": "p001",
  "candidates": [
    { "id": "p001", "file": "p001.txt", "status": "champion",
      "offline": { "minibatch": { "win_rate_vs_champion": null } },
      "live": { "runs": 6, "accept": 4, "polish": 1, "reject": 1, "realized_cost_usd": 4.0, "rework_cost_usd": 0.0 },
      "promote_recommended_at": null, "retired_at": null, "retired_by": null },
    { "id": "p002", "file": "p002.txt", "status": "candidate",
      "offline": { "minibatch": { "win_rate_vs_champion": 0.8 } },
      "live": { "runs": 6, "accept": 5, "polish": 1, "reject": 0, "realized_cost_usd": 2.5, "rework_cost_usd": 0.0 },
      "promote_recommended_at": "2026-07-03T00:00:00Z", "retired_at": null, "retired_by": null }
  ]
}
'@
    Set-Content (Join-Path $poolDir 'pool.json') $poolJson -Encoding utf8NoBOM
    $ctx4 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C29 pool loads" ($ctx4.pool_ok)
    Assert "C30 champion id read" ($ctx4.pool_champion_id -eq 'p001')
    Assert "C31 challenger id read" ($ctx4.pool_challenger_id -eq 'p002')
    Assert "C32 verdict ready at threshold" ($ctx4.pool_verdict_ready)
    Assert "C33 promote pending detected" (@($ctx4.promote_pending) -contains 'p002')
    $s4 = @(Get-CoachSuggestions -Context $ctx4 -SeenPath $seenPath)
    $pp = @($s4 | Where-Object { $_.id -eq 'promote-pending' })
    $pv = @($s4 | Where-Object { $_.id -eq 'pool-verdict' })
    Assert "C34 promote-pending rule fires with --apply" ((@($pp).Count -eq 1) -and ($pp[0].command -eq '/baton:optimize-prompt --apply') -and ($pp[0].dedup_key -eq 'promote:p002'))
    Assert "C35 pool-verdict rule fires with --pool" ((@($pv).Count -eq 1) -and ($pv[0].command -eq '/baton:optimize-prompt --pool') -and ($pv[0].dedup_key -eq 'pool-verdict:p001:p002'))
    # Registered project => next-command (digest-only) leads; then the trio.
    Assert "C36 ordering: next-command, gate-failure, promote-pending, pool-verdict" (($s4[0].id -eq 'next-command') -and ($s4[1].id -eq 'gate-failure') -and ($s4[2].id -eq 'promote-pending') -and ($s4[3].id -eq 'pool-verdict'))
    $sEx = @(Get-CoachSuggestions -Context $ctx4 -SeenPath $seenPath -ExcludeIds @('gate-failure','promote-pending','pool-verdict'))
    Assert "C37 -ExcludeIds drops the optimizer trio (next-command remains)" ((@($sEx).Count -eq 1) -and ($sEx[0].id -eq 'next-command'))

    # --- Budget: conserve mode ---
    Set-ConserveMode -On $true -UsagePath (Join-Path $env:BATON_HOME 'usage-journal.jsonl')
    $ctx5 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C38 conserve mode read" ($ctx5.conserve)
    Assert "C39 budget at risk under conserve" ($ctx5.budget_at_risk)
    $bg = @(Get-CoachSuggestions -Context $ctx5 -SeenPath $seenPath | Where-Object { $_.id -eq 'budget' })
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    Assert "C40 budget rule fires daily-keyed" ((@($bg).Count -eq 1) -and ($bg[0].command -eq '/baton:usage') -and ($bg[0].dedup_key -eq "budget:$today"))

    # --- Poisoned pool: context still gathers, no throw ---
    Set-Content (Join-Path $poolDir 'pool.json') 'not a pool {{' -Encoding utf8NoBOM
    $ctx6 = Get-CoachContext -BatonHome $env:BATON_HOME -ProjectDir $repoDir
    Assert "C41 poisoned pool degrades to pool_ok=false" (-not $ctx6.pool_ok)
    Assert "C42 other signals survive a poisoned pool" ($ctx6.conserve -and ($ctx6.failure_runs -eq 1))

    # --- Write-CoachFooter (restore healthy pool first) ---
    Set-Content (Join-Path $poolDir 'pool.json') $poolJson -Encoding utf8NoBOM
    Remove-Item $seenPath -Force -ErrorAction SilentlyContinue
    $f1 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C43 footer prints one Next: line at quiet" ((@($f1).Count -eq 1) -and ($f1[0] -like 'Next: /baton:optimize-prompt*') -and ($f1[0] -notlike '*—*'))
    $f2 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C44 footer suggestion was stamped (next call moves on)" ((@($f2).Count -eq 1) -and ($f2[0] -ne $f1[0]))
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    $f3 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C45 teach footer includes the why" ((@($f3).Count -eq 1) -and ($f3[0] -like 'Next: *—*'))
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $f4 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C46 off level prints nothing" (@($f4).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM
    # Exhaust remaining stampable suggestions, then verify silence.
    $null = Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1
    $null = Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1
    $f5 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C47 all stamped -> no footer" (@($f5).Count -eq 0)
    # Digest-only entries never reach footers: context with ONLY next-command.
    Remove-Item (Join-Path $poolDir 'pool.json') -Force
    Remove-Item (Join-Path $runsRoot 'run-fail-1') -Recurse -Force
    Set-ConserveMode -On $false -UsagePath (Join-Path $env:BATON_HOME 'usage-journal.jsonl')
    $f6 = @(Write-CoachFooter -BatonHome $env:BATON_HOME -ProjectDir $repoDir 6>&1 | ForEach-Object { "$_" })
    Assert "C48 digest-only next-command never appears as a footer" (@($f6).Count -eq 0)
} finally {
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
