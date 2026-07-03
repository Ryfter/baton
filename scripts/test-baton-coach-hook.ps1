#!/usr/bin/env pwsh
# Tests for the SessionStart baton-coach hook: orientation digest scaled by
# registration, one-shot onboard line, always exits 0. Hermetic BATON_HOME.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$hook = Join-Path $here 'hooks/baton-coach.ps1'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

function Invoke-CoachHook([string]$Cwd) {
    # Claude Code feeds hooks a JSON payload on stdin; cwd is what the coach reads.
    $payload = '{"cwd":' + (ConvertTo-Json $Cwd) + ',"hook_event_name":"SessionStart","source":"startup"}'
    $out = @($payload | & pwsh -NoProfile -File $hook 2>$null)
    return ,@($out | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
}

$savedHome = $env:BATON_HOME
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "coach-hook-test-$([guid]::NewGuid().ToString('N'))"
try {
    $env:BATON_HOME = Join-Path $tmp 'baton'

    # H1: BATON_HOME absent -> silent, exit 0.
    $plainDir = Join-Path $tmp 'plain'
    New-Item -ItemType Directory -Force -Path $plainDir | Out-Null
    $o1 = Invoke-CoachHook $plainDir
    Assert "H1 absent BATON_HOME: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H1 absent BATON_HOME: silent" (@($o1).Count -eq 0)

    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null

    # H2: non-git dir -> silent.
    $o2 = Invoke-CoachHook $plainDir
    Assert "H2 non-git dir: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H2 non-git dir: silent" (@($o2).Count -eq 0)

    # H3: unregistered git repo -> one onboard line, then one-shot silence.
    $repoDir = Join-Path $tmp 'proj-alpha'
    New-Item -ItemType Directory -Force -Path (Join-Path $repoDir '.git') | Out-Null
    $o3 = Invoke-CoachHook $repoDir
    Assert "H3 unregistered repo: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H3 unregistered repo: one onboard line" ((@($o3).Count -eq 1) -and ($o3[0] -like '*Baton available*') -and ($o3[0] -like '*/baton:start*'))
    $o3b = Invoke-CoachHook $repoDir
    Assert "H3b onboard is one-shot" (@($o3b).Count -eq 0)

    # H4: registered project -> digest with status + suggestion, never dedups.
    $projDir = Join-Path (Join-Path $env:BATON_HOME 'projects') 'proj-alpha'
    New-Item -ItemType Directory -Force -Path $projDir | Out-Null
    Set-Content (Join-Path $projDir 'project.json') '{"id":"proj-alpha","last_run":{"status":"completed"}}' -Encoding utf8NoBOM
    $o4 = Invoke-CoachHook $repoDir
    Assert "H4 registered project: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H4 digest headline names the project + status" ((@($o4).Count -ge 2) -and ($o4[0] -like "*proj-alpha*") -and ($o4[0] -like '*completed*'))
    Assert "H4 digest carries a suggested next command" (@($o4 | Where-Object { $_ -like 'Suggested next:*' }).Count -eq 1)
    $o4b = Invoke-CoachHook $repoDir
    Assert "H4b digest repeats on every start (status report, no dedup)" (@($o4b).Count -eq @($o4).Count)

    # H5: teach level appends the why.
    $coachDir = Join-Path $env:BATON_HOME 'coach'
    New-Item -ItemType Directory -Force -Path $coachDir | Out-Null
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"teach"}' -Encoding utf8NoBOM
    $o5 = Invoke-CoachHook $repoDir
    Assert "H5 teach digest includes why" (@($o5 | Where-Object { ($_ -like 'Suggested next:*') -and ($_ -like '*—*') }).Count -eq 1)

    # H6: off level -> silent even for a registered project.
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"off"}' -Encoding utf8NoBOM
    $o6 = Invoke-CoachHook $repoDir
    Assert "H6 off: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H6 off: silent" (@($o6).Count -eq 0)
    Set-Content (Join-Path $coachDir 'config.json') '{"level":"quiet"}' -Encoding utf8NoBOM

    # H7: poisoned pool must not break the digest or the exit code.
    $poolDir = Join-Path $env:BATON_HOME 'prompts/pool'
    New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
    Set-Content (Join-Path $poolDir 'pool.json') 'garbage {{' -Encoding utf8NoBOM
    $o7 = Invoke-CoachHook $repoDir
    Assert "H7 poisoned pool: exit 0" ($LASTEXITCODE -eq 0)
    Assert "H7 poisoned pool: digest still prints" (@($o7).Count -ge 2)
} finally {
    $env:BATON_HOME = $savedHome
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($failures -gt 0) { Write-Host "`n$failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
