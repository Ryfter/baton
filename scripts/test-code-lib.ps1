#!/usr/bin/env pwsh
# Tests for scripts/code-lib.ps1 — subtasks IO, topo sort, worktree status,
# parallel manifest IO, journal append, files_touched conflict detection.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'code-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- T1: subtasks round-trip ---
$tmp1 = Join-Path $env:TEMP "code-st-$(Get-Random).json"
$tasks1 = @(
    @{ id='t1'; title='Backend'; description='api+tests'; files_touched=@('src/api.ts'); depends_on=@() },
    @{ id='t2'; title='Frontend'; description='component+tests'; files_touched=@('src/ui.tsx'); depends_on=@('t1') }
)
New-CodeSubtasksFile -Path $tmp1 -Feature 'Profile page' -SpecPath 'docs/spec.md' `
    -Tasks $tasks1 -JobId 'j042-profile' -Sprint 'code.sprint-1'
$rd = Read-CodeSubtasksFile -Path $tmp1
Assert "T1 version=1"      ($rd.version -eq 1)
Assert "T1 feature roundtrip" ($rd.feature -eq 'Profile page')
Assert "T1 job_id roundtrip"  ($rd.job_id -eq 'j042-profile')
Assert "T1 two tasks"        ($rd.tasks.Count -eq 2)
Assert "T1 t1 has empty deps" (-not @($rd.tasks[0].depends_on))
Assert "T1 t2 depends on t1"  (($rd.tasks[1].depends_on -join ',') -eq 't1')
Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue

# --- T2: duplicate ids rejected ---
$tmp2 = Join-Path $env:TEMP "code-st2-$(Get-Random).json"
$dup = @(
    @{ id='t1'; title='A'; depends_on=@() },
    @{ id='t1'; title='B'; depends_on=@() }
)
$threw = $false
try {
    New-CodeSubtasksFile -Path $tmp2 -Feature 'F' -SpecPath 'x' -Tasks $dup -JobId 'j' -Sprint 'code.sprint-1'
} catch { $threw = $true }
Assert "T2 duplicate ids throws" $threw
Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue

# --- T3: topo sort — independent first, then dependent ---
$linear = @(
    [pscustomobject]@{ id='t2'; depends_on=@('t1') },
    [pscustomobject]@{ id='t1'; depends_on=@() },
    [pscustomobject]@{ id='t3'; depends_on=@('t2') }
)
$ord = Resolve-CodeTaskOrder -Tasks $linear
Assert "T3 t1 first" ($ord[0].id -eq 't1')
Assert "T3 t2 second" ($ord[1].id -eq 't2')
Assert "T3 t3 third" ($ord[2].id -eq 't3')

# --- T4: topo sort — multiple independents preserve relative order ---
$multi = @(
    [pscustomobject]@{ id='a'; depends_on=@() },
    [pscustomobject]@{ id='b'; depends_on=@() },
    [pscustomobject]@{ id='c'; depends_on=@('a','b') }
)
$ord4 = Resolve-CodeTaskOrder -Tasks $multi
Assert "T4 a before c" ((($ord4 | ForEach-Object { $_.id }).IndexOf('a')) -lt (($ord4 | ForEach-Object { $_.id }).IndexOf('c')))
Assert "T4 b before c" ((($ord4 | ForEach-Object { $_.id }).IndexOf('b')) -lt (($ord4 | ForEach-Object { $_.id }).IndexOf('c')))

# --- T5: cycle detection ---
$cyc = @(
    [pscustomobject]@{ id='a'; depends_on=@('b') },
    [pscustomobject]@{ id='b'; depends_on=@('a') }
)
$threw = $false
try { Resolve-CodeTaskOrder -Tasks $cyc | Out-Null } catch { $threw = $true }
Assert "T5 cycle throws" $threw

# --- T6: unknown dep rejected ---
$bad = @( [pscustomobject]@{ id='a'; depends_on=@('nope') } )
$threw = $false
try { Resolve-CodeTaskOrder -Tasks $bad | Out-Null } catch { $threw = $true }
Assert "T6 unknown dep throws" $threw

# --- T7: output dir shape ---
$od = Get-CodeOutputDir -JobId 'j042' -Sprint 'code.sprint-1' -Stamp '2026-05-30T05-30-00'
Assert "T7 output dir shape" ($od -like "*$([IO.Path]::DirectorySeparatorChar).claude$([IO.Path]::DirectorySeparatorChar)jobs$([IO.Path]::DirectorySeparatorChar)j042$([IO.Path]::DirectorySeparatorChar)phases$([IO.Path]::DirectorySeparatorChar)code.sprint-1$([IO.Path]::DirectorySeparatorChar)parallel-2026-05-30T05-30-00")

# --- T8: parallel manifest round-trip ---
$mp = Join-Path $env:TEMP "code-mf-$(Get-Random).json"
$results = @(
    @{ task_id='t1'; worktree='/tmp/wt1'; branch='j042/t1'; summary='did api'; status='ok'; commits_ahead=3; files_changed=4 },
    @{ task_id='t2'; worktree='/tmp/wt2'; branch='j042/t2'; summary='did ui'; status='ok'; commits_ahead=2; files_changed=2 }
)
Write-CodeParallelManifest -Path $mp -Results $results
$rmf = Read-CodeParallelManifest -Path $mp
Assert "T8 version 1" ($rmf.version -eq 1)
Assert "T8 two results" ($rmf.results.Count -eq 2)
Assert "T8 t1 status ok" ($rmf.results[0].status -eq 'ok')
Remove-Item $mp -Force -ErrorAction SilentlyContinue

# --- T9: worktree status against a temp git repo ---
$repo = Join-Path $env:TEMP "code-repo-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $repo | Out-Null
& git -C $repo init -b master 2>&1 | Out-Null
& git -C $repo config user.email test@example.com 2>&1 | Out-Null
& git -C $repo config user.name test 2>&1 | Out-Null
Set-Content -Path (Join-Path $repo 'a.txt') -Value 'a' -Encoding utf8NoBOM
& git -C $repo add a.txt 2>&1 | Out-Null
& git -C $repo commit -m 'base' 2>&1 | Out-Null
& git -C $repo checkout -b feat 2>&1 | Out-Null
Set-Content -Path (Join-Path $repo 'b.txt') -Value 'b' -Encoding utf8NoBOM
Set-Content -Path (Join-Path $repo 'c.txt') -Value 'c' -Encoding utf8NoBOM
& git -C $repo add b.txt c.txt 2>&1 | Out-Null
& git -C $repo commit -m 'feat1' 2>&1 | Out-Null
Set-Content -Path (Join-Path $repo 'b.txt') -Value 'b-edited' -Encoding utf8NoBOM
& git -C $repo add b.txt 2>&1 | Out-Null
& git -C $repo commit -m 'feat2' 2>&1 | Out-Null
$st = Get-CodeWorktreeStatus -WorktreePath $repo -BaseBranch 'master'
Assert "T9 commits_ahead = 2" ($st.commits_ahead -eq 2)
Assert "T9 files_changed = 2" ($st.files_changed -eq 2)
Assert "T9 clean (no porcelain)" (-not $st.dirty)
Set-Content -Path (Join-Path $repo 'd.txt') -Value 'd' -Encoding utf8NoBOM
$st2 = Get-CodeWorktreeStatus -WorktreePath $repo -BaseBranch 'master'
Assert "T9 dirty after untracked" ($st2.dirty)
Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue

# --- T10: journal append ---
$jrn = Join-Path $env:TEMP "code-jrn-$(Get-Random).md"
$noState = Join-Path $env:TEMP "code-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState
Write-CodeJournalLine -JobId 'j042' -Sprint 'code.sprint-1' -TaskCount 3 -OkCount 2 -ErrCount 1 -JournalPath $jrn
$lines = @(Get-Content $jrn | Where-Object { $_ -match '\| code \|' })
Assert "T10 one code line" ($lines.Count -eq 1)
Assert "T10 line shape" ($lines[0] -match '\| code \| parallel \| j042 \| sprint:code\.sprint-1 \| tasks:3 \| ok:2 \| err:1')
Remove-Item $jrn -Force -ErrorAction SilentlyContinue
Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue

# --- T11: files_touched conflict detection ---
$ordTasks = @(
    [pscustomobject]@{ id='t1'; files_touched=@('src/api.ts','src/api.test.ts') },
    [pscustomobject]@{ id='t2'; files_touched=@('src/ui.tsx') },
    [pscustomobject]@{ id='t3'; files_touched=@('src/api.ts','src/utils.ts') }
)
$cf = Get-CodeFilesTouchedConflicts -OrderedTasks $ordTasks
Assert "T11 one conflict (t1 vs t3)" ($cf.Count -eq 1)
Assert "T11 conflict pairs t1 -> t3" ($cf[0].earlier_task -eq 't1' -and $cf[0].later_task -eq 't3')
Assert "T11 overlap is api.ts" ($cf[0].overlap -contains 'src/api.ts')

# --- T12: no conflicts when files don't overlap ---
$ordTasks2 = @(
    [pscustomobject]@{ id='t1'; files_touched=@('a') },
    [pscustomobject]@{ id='t2'; files_touched=@('b') }
)
$cf2 = Get-CodeFilesTouchedConflicts -OrderedTasks $ordTasks2
Assert "T12 zero conflicts" ($cf2.Count -eq 0)

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
