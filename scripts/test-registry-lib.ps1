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

    # --- Task 3: roster / resolution / resume ---
    $home2 = Join-Path ([IO.Path]::GetTempPath()) ("breg-home-" + [guid]::NewGuid().ToString('N'))
    $projRoot = Join-Path $home2 'projects'
    New-Item -ItemType Directory -Force -Path $projRoot | Out-Null

    # a record for Whittle marked archived; WhimsicalCarving has no record (→ inactive)
    $whittleId = Get-ProjectId -Folder $p2
    Write-ProjectRecord -Record @{ id=$whittleId; name='Whittle'; folder=$p2; archived=$true } -ProjectsRoot $projRoot

    # make WhimsicalCarving active via a live marker
    Write-SessionMarker -Agent 'claude' -SessionId 'live-1' -Cwd $p1 -BatonHome $home2

    $roster = Get-ProjectRoster -Root $root -BatonHome $home2
    Assert 'R11 active group holds the live project' (@($roster.active | Where-Object { $_.folder -eq $p1 }).Count -eq 1)
    Assert 'R12 archived group holds the archived record' (@($roster.archived | Where-Object { $_.folder -eq $p2 }).Count -eq 1)
    Assert 'R13 archived project not in inactive' (@($roster.inactive | Where-Object { $_.folder -eq $p2 }).Count -eq 0)

    # resolution precedence
    $byslug = Resolve-ProjectTarget -Slug 'whimsicalcarving' -Root $root -BatonHome $home2
    Assert 'R14 --slug resolves to its folder' ($byslug.status -eq 'resolved' -and $byslug.folder -eq $p1)
    $bad = Resolve-ProjectTarget -Slug 'ghost' -Root $root -BatonHome $home2
    Assert 'R15 unknown slug → unknown' ($bad.status -eq 'unknown')
    $cwd = Resolve-ProjectTarget -Cwd $p2 -Root $root -BatonHome $home2
    Assert 'R16 cwd-is-project resolves to cwd' ($cwd.status -eq 'resolved' -and $cwd.folder -eq $p2)
    $hb = Resolve-ProjectTarget -Cwd $root -Root $root -BatonHome $home2
    Assert 'R17 home base (not a project) → picker' ($hb.status -eq 'picker')

    # resume command is agent-tagged
    Assert 'R18 claude resume command' ((Get-ResumeCommand -Agent 'claude' -SessionId 'abc') -eq 'claude --resume abc')
    Assert 'R19 codex resume command' ((Get-ResumeCommand -Agent 'codex' -SessionId 'abc') -like 'codex*abc*')
    Assert 'R20 unknown agent → null' ($null -eq (Get-ResumeCommand -Agent 'mystery' -SessionId 'abc'))

    # slug vs id collision: slug must win
    $root3 = Join-Path ([IO.Path]::GetTempPath()) ("breg-collision-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root3 | Out-Null
    try {
        # Project 1: folder name 'foo' with .git → slug='foo', id='foo'
        $p_slug_foo = Join-Path $root3 'foo'
        New-Item -ItemType Directory -Force -Path (Join-Path $p_slug_foo '.git') | Out-Null

        # Project 2: folder name 'bar' with remote pointing to 'foo' → slug='bar', id='foo'
        $p_id_foo = Join-Path $root3 'bar'
        New-Item -ItemType Directory -Force -Path (Join-Path $p_id_foo '.git') | Out-Null
        # Simulate git remote by writing a minimal config
        $gitConfig = Join-Path $p_id_foo '.git/config'
        Set-Content -LiteralPath $gitConfig -Value @"
[remote "origin"]
	url = https://github.com/example/foo
"@ -Encoding utf8NoBOM

        # Resolving slug 'foo' should return the folder whose FOLDER slug is 'foo' (p_slug_foo)
        $resolved = Resolve-ProjectTarget -Slug 'foo' -Root $root3 -BatonHome (Join-Path ([IO.Path]::GetTempPath()) "breg-collision-home")
        Assert 'R21 slug collision: slug wins over id' ($resolved.status -eq 'resolved' -and $resolved.folder -eq $p_slug_foo)
    }
    finally { Remove-Item -Recurse -Force $root3 -ErrorAction SilentlyContinue }

    Remove-Item -Recurse -Force $home2 -ErrorAction SilentlyContinue
}
finally { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }

if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
