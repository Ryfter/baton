# scripts/test-registry-lib.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/registry-lib.ps1"

$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("breg-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    # project via .git
    $p1 = Join-Path $root 'WhimsicalCarving'; New-Item -ItemType Directory -Force -Path (Join-Path $p1 '.git') | Out-Null
    # project via CHARTER.md, with a blurb
    $p2 = Join-Path $root 'Whittle'; New-Item -ItemType Directory -Force -Path $p2 | Out-Null
    Set-Content -LiteralPath (Join-Path $p2 'CHARTER.md') -Value "# Whittle — Project Charter`n`n## What we're building`nA CLI wood-carving planner`n" -Encoding utf8NoBOM
    # NOT a project (plain folder)
    $p3 = Join-Path $root 'notes'; New-Item -ItemType Directory -Force -Path $p3 | Out-Null

    Assert 'R1 .git folder is a project' (Test-IsProjectFolder -Folder $p1)
    Assert 'R2 CHARTER folder is a project' (Test-IsProjectFolder -Folder $p2)
    Assert 'R3 plain folder is not a project' (-not (Test-IsProjectFolder -Folder $p3))

    Assert 'R4 folder slug lowercases' ((Get-FolderSlug -Folder $p1) -eq 'whimsicalcarving')
    Assert 'R5 blurb from CHARTER section' ((Get-ProjectBlurb -Folder $p2) -eq 'A CLI wood-carving planner')
    Assert 'R6 blurb fallback when none' ((Get-ProjectBlurb -Folder $p1) -eq '(no description)')

    $found = @(Find-ProjectFolders -Root $root)
    Assert 'R7 scan finds exactly the two projects' (@($found).Count -eq 2)
    Assert 'R8 scan skips the plain folder' (-not ($found.slug -contains 'notes'))
    Assert 'R9 scan carries folder+blurb' (($found | Where-Object { $_.slug -eq 'whittle' }).blurb -eq 'A CLI wood-carving planner')

    Assert 'R10 missing root → empty' (@(Find-ProjectFolders -Root (Join-Path $root 'nope')).Count -eq 0)
}
finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
