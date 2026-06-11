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

    # --- Task 2: New-IdeaConceptDoc ---
    $cdir = Join-Path $root 'concept-test'
    New-Item -ItemType Directory -Force -Path $cdir | Out-Null
    $cpath = Join-Path $cdir 'concept.md'
    New-IdeaConceptDoc -Path $cpath -Title 'Better Front Door' -Idea 'a better front door' -Date '2026-06-07'
    Check 'concept.md written'         (Test-Path $cpath)
    $c = Get-Content $cpath -Raw
    Check 'frontmatter title'          ($c -match '(?m)^title: Better Front Door\r?$')
    Check 'frontmatter status draft'   ($c -match '(?m)^status: draft\r?$')
    Check 'frontmatter source /idea'   ($c -match '(?m)^source: /idea\r?$')
    Check 'has Problem header'         ($c -match '(?m)^## Problem\r?$')
    Check 'has Viability header'       ($c -match '(?m)^## Viability verdict\r?$')
    Check 'has Approach header'        ($c -match '(?m)^## Proposed approach\r?$')
    Check 'has Risks header'           ($c -match '(?m)^## Risks & open questions\r?$')
    Check 'has Decomposition header'   ($c -match '(?m)^## Decomposition\r?$')
    Check 'has Out of scope header'    ($c -match '(?m)^## Out of scope\r?$')

    # --- Task 3: Build-IdeaIssues (pure) ---
    $tasks = @(
        [pscustomobject]@{ title='Wire the bridge'; description='Connect A to B.'; acceptance='Tests pass.'; tier='Tier-1' },
        [pscustomobject]@{ title='Add the view';    description='New panel.' }
    )
    $issues = Build-IdeaIssues -Tasks $tasks -ConceptPath '/x/concept.md' -ExtraLabels @('sp3')
    Check 'two issues built'           ($issues.Count -eq 2)
    Check 'title carried'              ($issues[0].title -eq 'Wire the bridge')
    Check 'desc in body'              ($issues[0].body -like '*Connect A to B.*')
    Check 'acceptance block present'   ($issues[0].body -like '*## Acceptance criteria*')
    Check 'backlink present'           ($issues[0].body -like '*From concept: /x/concept.md*')
    Check 'from:idea label always'     ($issues[0].labels -contains 'from:idea')
    Check 'tier label carried'         ($issues[0].labels -contains 'Tier-1')
    Check 'extra label carried'        ($issues[0].labels -contains 'sp3')
    Check 'no acceptance -> no block'  ($issues[1].body -notlike '*## Acceptance criteria*')
    Check 'labels de-duplicated'       (($issues[0].labels | Where-Object { $_ -eq 'from:idea' }).Count -eq 1)

    $none = Build-IdeaIssues -Tasks @() -ConceptPath '/x/concept.md'
    Check 'empty tasks -> empty'       ($none.Count -eq 0)

    $bad = Build-IdeaIssues -Tasks @([pscustomobject]@{ description='no title here' }) -ConceptPath '/x/concept.md' -WarningAction SilentlyContinue
    Check 'titleless task skipped'     ($bad.Count -eq 0)

    $special = Build-IdeaIssues -Tasks @([pscustomobject]@{ title='Fix "quotes" & <tags>'; description='100% done' }) -ConceptPath '/x/concept.md'
    Check 'special chars survive'      ($special[0].title -eq 'Fix "quotes" & <tags>')

    # --- Task 4: Publish-IdeaIssues (stubbed gh) ---
    # Stub: 'auth status' honours $script:authExit; 'issue create' fails for title 'FAILME'.
    $script:authExit = 0
    $script:createdLabels = @()
    function gh {
        if ($args[0] -eq 'auth') { $global:LASTEXITCODE = $script:authExit; return 'ok' }
        if ($args[0] -eq 'label' -and $args[1] -eq 'list') { $global:LASTEXITCODE = 0; return 'bug' }
        if ($args[0] -eq 'label' -and $args[1] -eq 'create') { $global:LASTEXITCODE = 0; $script:createdLabels += $args[2]; return 'created' }
        $ti = [array]::IndexOf([object[]]$args, '--title')
        $title = if ($ti -ge 0) { $args[$ti + 1] } else { '' }
        if ($title -eq 'FAILME') { $global:LASTEXITCODE = 1; return 'boom' }
        $global:LASTEXITCODE = 0
        return 'https://github.com/Ryfter/baton/issues/123'
    }

    # happy path: two issues created
    $okIssues = @(
        [pscustomobject]@{ title='Alpha'; body='a'; labels=@('from:idea') },
        [pscustomobject]@{ title='Beta';  body='b'; labels=@('from:idea','Tier-2') }
    )
    $res = Publish-IdeaIssues -Issues $okIssues
    Check 'two results returned'       ($res.Count -eq 2)
    Check 'first ok'                   ($res[0].ok -eq $true)
    Check 'number parsed'              ($res[0].number -eq 123)
    Check 'from:idea label ensured'    ($script:createdLabels -contains 'from:idea')
    Check 'tier label ensured'         ($script:createdLabels -contains 'Tier-2')

    # per-issue isolation: middle one fails, others still created
    $mixed = @(
        [pscustomobject]@{ title='Alpha';  body='a'; labels=@('from:idea') },
        [pscustomobject]@{ title='FAILME'; body='x'; labels=@('from:idea') },
        [pscustomobject]@{ title='Gamma';  body='g'; labels=@('from:idea') }
    )
    $res2 = Publish-IdeaIssues -Issues $mixed
    Check 'three results returned'     ($res2.Count -eq 3)
    Check 'failing one flagged'        ($res2[1].ok -eq $false -and $res2[1].error)
    Check 'after-failure one still ok' ($res2[2].ok -eq $true)

    # unauth pre-flight: nothing created, single preflight error
    $script:authExit = 1
    $res3 = Publish-IdeaIssues -Issues $okIssues
    Check 'unauth -> one preflight row'($res3.Count -eq 1)
    Check 'unauth row not ok'          ($res3[0].ok -eq $false)
    Check 'unauth error mentions auth' ($res3[0].error -like '*auth*')
    $script:authExit = 0

    Remove-Item Function:gh
}
finally {
    if (Test-Path $root) { Remove-Item -Recurse -Force $root }
}

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
