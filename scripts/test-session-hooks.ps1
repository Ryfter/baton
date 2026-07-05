$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}
$here = $PSScriptRoot
$startHook = Join-Path $here 'hooks/baton-session-start.ps1'
$stopHook  = Join-Path $here 'hooks/baton-session-stop.ps1'

$home2 = Join-Path ([IO.Path]::GetTempPath()) ("bhk-" + [guid]::NewGuid().ToString('N'))
$proj  = Join-Path $home2 'proj'; New-Item -ItemType Directory -Force -Path (Join-Path $proj '.git') | Out-Null
$oldHome = $env:BATON_HOME
$env:BATON_HOME = $home2
try {
    $payload = @{ session_id='hook-sess'; cwd=$proj } | ConvertTo-Json -Compress

    # SessionStart → marker written, exit 0
    $payload | & pwsh -NoProfile -File $startHook
    Assert 'H1 start hook exits 0' ($LASTEXITCODE -eq 0)
    . "$here/session-markers-lib.ps1"
    Assert 'H2 marker present after start' (@(Get-ActiveSessions -BatonHome $home2 | Where-Object { $_.cwd -eq $proj }).Count -eq 1)

    # SessionEnd → marker cleared + resume pointer written, exit 0
    $payload | & pwsh -NoProfile -File $stopHook
    Assert 'H3 stop hook exits 0' ($LASTEXITCODE -eq 0)
    Assert 'H4 marker cleared after stop' (@(Get-ActiveSessions -BatonHome $home2).Count -eq 0)

    . "$here/registry-lib.ps1"
    $pid2 = Get-ProjectId -Folder $proj
    $rec = Read-ProjectRecord -ProjectId $pid2 -ProjectsRoot (Join-Path $home2 'projects')
    Assert 'H5 resume pointer captured' ($null -ne $rec -and $rec.last_session_id -eq 'hook-sess' -and $rec.agent -eq 'claude')

    # malformed JSON → still exit 0 (fail-open)
    'not json' | & pwsh -NoProfile -File $startHook
    Assert 'H6 malformed stdin still exits 0' ($LASTEXITCODE -eq 0)
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
