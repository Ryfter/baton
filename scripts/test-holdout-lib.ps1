#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'holdout-lib.ps1')

$fail = 0
function Assert($l, $c) { if ($c) { Write-Host "PASS $l" } else { Write-Host "FAIL $l"; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-holdout-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.baton/holdout') | Out-Null
Set-Content -LiteralPath (Join-Path $tmp '.baton/holdout/manifest.json') -Encoding utf8NoBOM -Value @'
{
  "schema_version": 1,
  "scenarios": [
    { "id": "ok-echo", "title": "echo pass", "argv": ["pwsh", "-NoProfile", "-Command", "exit 0"] },
    { "id": "bad-echo", "title": "echo fail", "argv": ["pwsh", "-NoProfile", "-Command", "exit 3"] }
  ]
}
'@
Push-Location $tmp
try {
    & git init -q
    & git add -A
    & git -c user.email='t@t.com' -c user.name='t' commit -q -m 'holdout test'
    $base = (& git rev-parse HEAD).Trim()

    $skip = Invoke-HoldoutSuite -RepoPath $tmp -BaseSha $base -WorktreeRoot $tmp
    Assert 'H1 suite runs' (-not $skip.skipped)
    Assert 'H2 one failure' ($skip.ok -eq $false -and $skip.results.Count -eq 2)

    $noManifest = Get-FrozenHoldoutManifest -RepoPath $tmp -BaseSha '0000000000000000000000000000000000000000'
    Assert 'H3 missing manifest' ($noManifest.ok -eq $false)
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { exit 1 }
Write-Host 'ALL PASS'
exit 0
