#!/usr/bin/env pwsh
# End-to-end footer checks via the cheapest real CLI (fleet-usage status):
# footer prints, one-shots, respects off, excludes self, never pollutes -Json.
# fleet-gate/go/optimize-prompt use the identical guarded call — wiring parity
# is checked by grep here and behavior by the opus final review.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$usageCli = Join-Path $here 'fleet-usage.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-footer-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $up = Join-Path $env:BATON_HOME 'usage-journal.jsonl'

    # Fixture: one polish-verdict run -> the gate-failure suggestion is live.
    $runsRoot = Join-Path $env:BATON_HOME 'runs'
    New-Item -ItemType Directory -Force -Path (Join-Path $runsRoot 'run-fail-1') | Out-Null
    Set-Content (Join-Path $runsRoot 'run-fail-1/acceptance.json') '{"verdict":"polish","reason":"x"}' -Encoding utf8NoBOM

    # Run the CLIs from a NON-git cwd: otherwise the repo cwd makes the
    # onboard rule fire (temp BATON_HOME has no project record for the repo)
    # and pollutes the one-shot assertions with a second live suggestion.
    $workDir = Join-Path $tmp 'work'
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Push-Location $workDir

    # F1: footer appears once...
    $o1 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F1 usage status exits 0" ($LASTEXITCODE -eq 0)
    Assert "F1 footer suggests optimize-prompt" (@($o1 | Where-Object { $_ -like 'Next: /baton:optimize-prompt*' }).Count -eq 1)

    # F2: ...and is one-shot.
    $o2 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F2 footer one-shot (stamped)" (@($o2 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)

    # F3: -Json stays pure even with a fresh (unstamped) suggestion.
    Remove-Item (Join-Path (Join-Path $env:BATON_HOME 'coach') 'seen.json') -Force -ErrorAction SilentlyContinue
    $o3 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up -Json 2>$null | ForEach-Object { "$_" })
    Assert "F3 -Json output has no footer" (@($o3 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)
    Assert "F3 -Json output parses" ($null -ne (($o3 -join "`n") | ConvertFrom-Json))

    # F4: level off -> no footer.
    $coachDir = Join-Path $env:BATON_HOME 'coach'
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $o4 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F4 off level: no footer" (@($o4 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM

    # F5: self-suggestion excluded — only the budget signal, run /baton:usage.
    Remove-Item (Join-Path $runsRoot 'run-fail-1') -Recurse -Force
    Remove-Item (Join-Path $coachDir 'seen.json') -Force -ErrorAction SilentlyContinue
    . (Join-Path $here 'usage-lib.ps1')
    Set-ConserveMode -On $true -UsagePath $up
    $o5 = @(& pwsh -NoProfile -File $usageCli status -UsagePath $up 2>$null | ForEach-Object { "$_" })
    Assert "F5 usage never suggests itself" (@($o5 | Where-Object { $_ -like 'Next:*' }).Count -eq 0)

    # F6: wiring parity — all four CLIs carry the guarded footer call.
    foreach ($cli in 'fleet-usage.ps1', 'fleet-gate.ps1', 'fleet-go.ps1', 'fleet-optimize-prompt.ps1') {
        $src = Get-Content -Raw (Join-Path $here $cli)
        Assert "F6 $cli sources coach-lib" ($src -like '*coach-lib.ps1*')
        Assert "F6 $cli calls Write-CoachFooter" ($src -like '*Write-CoachFooter*')
    }
    $opSrc = Get-Content -Raw (Join-Path $here 'fleet-optimize-prompt.ps1')
    Assert "F6 optimize-prompt excludes its own rules" ($opSrc -like "*'gate-failure'*" -and $opSrc -like "*'promote-pending'*" -and $opSrc -like "*'pool-verdict'*")
} finally {
    Pop-Location -ErrorAction SilentlyContinue
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
