#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/security-researcher-lib.ps1"

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$box = Join-Path ([System.IO.Path]::GetTempPath()) ("sec-res-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $box 'projects/demo') | Out-Null
[ordered]@{
    id = 'demo'
    last_touched_at = ([datetime]::UtcNow.AddHours(-2)).ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $box 'projects/demo/project.json') -Encoding utf8NoBOM

try {
    $now = [datetime]::UtcNow
    $state = Read-SecurityResearcherState -BatonHome $box
    Check 'empty state schema' ($state.schema_version -eq 1)

    $heat = Get-SecurityProjectHeat -ProjectId 'demo' -State $state -Now $now -BatonHome $box
    Check 'recent touch is hot or warm' ($heat -in @('hot', 'warm'))

    $due = @(Get-SecurityResearcherDueProjects -BatonHome $box -Now $now)
    Check 'never-run project is due' (@($due | Where-Object project -eq 'demo').Count -eq 1)

    $tick = Invoke-SecurityResearcherTick -BatonHome $box -Now $now -WriteState
    Check 'tick records instrument' ([string]$tick.instrument -eq 'security-researcher')
    Check 'tick marks due count' ($tick.count -ge 1)

    $state2 = Read-SecurityResearcherState -BatonHome $box
    Check 'tick writes last_run' ($state2.projects.demo.last_run)
} finally {
    Remove-Item -Recurse -Force $box -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { exit 1 }
Write-Host 'security-researcher-lib: all checks passed'
exit 0
