#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'fleet-choices.ps1'
$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-ch-cli-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
$fail = 0
function Assert($l,$c){ if($c){Write-Host "PASS $l"} else {Write-Host "FAIL $l"; $script:fail++} }
try {
    $optsPath = Join-Path $tmp 'opts.json'
    Set-Content -LiteralPath $optsPath -Encoding utf8NoBOM -Value '[{"id":"a","label":"A","summary":"sa"},{"id":"b","label":"B","summary":"sb"}]'
    $draftOut = & pwsh -NoProfile -File $runner draft -Project demo -Title 'T' -Question 'Q' -OptionsJson $optsPath -Rec a -RecWhy 'because' -Json 2>&1 | Out-String
    $d = $draftOut | ConvertFrom-Json
    Assert 'C1 draft json id' ($d.id -match '^ch-')
    & pwsh -NoProfile -File $runner admit $d.id -Priority P0
    Assert 'C2 admit exit 0' ($LASTEXITCODE -eq 0)
    $brief = & pwsh -NoProfile -File $runner brief 2>&1 | Out-String
    Assert 'C3 brief mentions demo' ($brief -match 'demo')
    $next = & pwsh -NoProfile -File $runner next -Json 2>&1 | Out-String | ConvertFrom-Json
    Assert 'C4 next id' ($next.id -eq $d.id)
    & pwsh -NoProfile -File $runner answer $d.id a
    Assert 'C5 answer exit 0' ($LASTEXITCODE -eq 0)
    $next2 = & pwsh -NoProfile -File $runner next 2>&1 | Out-String
    Assert 'C6 empty next message' ($next2 -match 'none admitted')
}
finally {
    if ($null -eq $prev) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prev }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'; exit 0
