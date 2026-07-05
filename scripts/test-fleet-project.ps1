$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$cli = Join-Path $here 'fleet-project.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("bfp-" + [guid]::NewGuid().ToString('N'))
$proj = Join-Path $root 'Gadget'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$home2 = Join-Path $root 'home'; New-Item -ItemType Directory -Force -Path $home2 | Out-Null
$oldHome = $env:BATON_HOME; $oldRoot = $env:BATON_PROJECTS_ROOT
$env:BATON_HOME = $home2; $env:BATON_PROJECTS_ROOT = $root
try {
    $j = & pwsh -NoProfile -File $cli list --json 2>&1
    Assert 'P1 list --json is valid JSON' ($null -ne ($j | ConvertFrom-Json))
    Assert 'P2 gadget starts inactive' (("$j" | ConvertFrom-Json).inactive.slug -contains 'gadget')

    & pwsh -NoProfile -File $cli set-blurb gadget "A tiny gadget" | Out-Null
    Assert 'P3 set-blurb exit 0' ($LASTEXITCODE -eq 0)
    & pwsh -NoProfile -File $cli archive gadget | Out-Null
    $j2 = (& pwsh -NoProfile -File $cli list --json 2>&1) | ConvertFrom-Json
    Assert 'P4 archived after archive' ($j2.archived.slug -contains 'gadget')
    Assert 'P5 blurb persisted' (($j2.archived | Where-Object { $_.slug -eq 'gadget' }).blurb -eq 'A tiny gadget')

    & pwsh -NoProfile -File $cli unarchive gadget | Out-Null
    $j3 = (& pwsh -NoProfile -File $cli list --json 2>&1) | ConvertFrom-Json
    Assert 'P6 back to inactive after unarchive' ($j3.inactive.slug -contains 'gadget')

    & pwsh -NoProfile -File $cli 2>&1 | Out-Null
    Assert 'P7 no subcommand → exit 2' ($LASTEXITCODE -eq 2)
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRoot) { Remove-Item Env:BATON_PROJECTS_ROOT -EA SilentlyContinue } else { $env:BATON_PROJECTS_ROOT = $oldRoot }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
