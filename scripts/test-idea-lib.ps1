#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/idea-lib.ps1"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("idea-test-" + [guid]::NewGuid().ToString('N'))
$fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name"; $script:fail++ }
}

try {
    # --- Task 1: New-IdeaWorkspace ---
    $ws = New-IdeaWorkspace -Idea 'A Better Front Door!' -IdeasRoot $root -Timestamp '2026-06-07T10-00-00'
    Check 'workspace slug sanitized'   ($ws.slug -eq 'a-better-front-door')
    Check 'workspace path uses slug+ts'($ws.path -eq (Join-Path $root 'a-better-front-door-2026-06-07T10-00-00'))
    Check 'workspace dir created'      (Test-Path $ws.path)
    Check 'research subdir created'    (Test-Path (Join-Path $ws.path 'research'))
    Check 'council subdir created'     (Test-Path (Join-Path $ws.path 'council'))

    $ws2 = New-IdeaWorkspace -Idea '!!!' -IdeasRoot $root -Timestamp '2026-06-07T10-00-01'
    Check 'degenerate idea -> idea slug'($ws2.slug -eq 'idea')

    $longIdea = ('x' * 100)
    $ws3 = New-IdeaWorkspace -Idea $longIdea -IdeasRoot $root -Timestamp '2026-06-07T10-00-02'
    Check 'slug capped at 60'          ($ws3.slug.Length -le 60)

    $env:IDEAS_ROOT = $root
    $ws4 = New-IdeaWorkspace -Idea 'env rooted' -Timestamp '2026-06-07T10-00-03'
    Check 'honours $env:IDEAS_ROOT'    ($ws4.path -like "$root*")
    Remove-Item Env:IDEAS_ROOT
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
