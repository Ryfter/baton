#!/usr/bin/env pwsh
# Child-process smoke of scripts/fleet-ask.ps1 against the stub fixture.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runner  = Join-Path $here 'fleet-ask.ps1'
$fixture = Join-Path $here 'fixtures\fleet-sample.yaml'

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# stub-cli echoes 'hello-<prompt>'; isolate state so no job/phase tags leak.
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "ask-nostate-$(Get-Random).json")
$env:CAO_FLEET_HOST = 'testbox'
try {
    $out = & pwsh -NoProfile -File $runner -Provider 'stub-cli' -Prompt 'world' -FleetPath $fixture 2>&1 | Out-String
    Assert "prints provider stdout"     ($out -match 'hello-world')
    Assert "prints ASCII footer w/ tok" ($out -match '-- stub-cli \| \d+s \| exit:0 \| tok:\d+\((exact|estimate)\)')

    # unknown provider -> stderr + exit 2
    & pwsh -NoProfile -File $runner -Provider 'does-not-exist' -Prompt 'x' -FleetPath $fixture 2>$null | Out-Null
    Assert "unknown provider exits 2" ($LASTEXITCODE -eq 2)

    # missing prompt -> exit 2
    & pwsh -NoProfile -File $runner -Provider 'stub-cli' -FleetPath $fixture 2>$null | Out-Null
    Assert "missing prompt exits 2" ($LASTEXITCODE -eq 2)

    # -PromptFile is read (965-byte escape hatch)
    $pf = Join-Path $env:TEMP "ask-prompt-$(Get-Random).txt"
    Set-Content -Path $pf -Value 'fromfile' -Encoding utf8NoBOM
    $out2 = & pwsh -NoProfile -File $runner -Provider 'stub-cli' -PromptFile $pf -FleetPath $fixture 2>&1 | Out-String
    Assert "-PromptFile is honored" ($out2 -match 'hello-fromfile')
    Remove-Item $pf -ErrorAction SilentlyContinue
} finally {
    Remove-Item env:CAO_STATE_PATH, env:CAO_FLEET_HOST -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "`n$failures failed" -ForegroundColor Red; exit 1 }
else { Write-Host "`nAll tests passed" -ForegroundColor Green; exit 0 }
