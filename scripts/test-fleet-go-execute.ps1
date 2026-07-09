#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "go-exec-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$saved = @{}
foreach ($k in 'BATON_HOME','BATON_GO_TEST_PLAN','BATON_GO_TEST_GATE','BATON_GO_TEST_SPAWN','BATON_GO_TEST_EXEC_DISPATCHER') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
try {
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $env:BATON_GO_TEST_SPAWN = $null

    # target repo
    $repo = Join-Path $tmpRoot 'repo'
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'test@test.local'
    & git -C $repo config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m 'init' 2>$null | Out-Null

    # temp fleet with one fake agentic provider
    Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'fleet.yaml') -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
'@

    # canned single-task plan + canned gate verdict
    $env:BATON_GO_TEST_PLAN = '{"run_id":"x","goal":"g","budget_cap":null,"tasks":[{"id":"t1","desc":"write feature","capability":"code-gen","depends_on":[],"est_cost_tier":"free","reversible":true}]}'
    $env:BATON_GO_TEST_GATE = 'accept'

    # fake instrument: writes a file into its cwd (must be the worktree)
    $dispFile = Join-Path $tmpRoot 'disp.ps1'
    Set-Content -LiteralPath $dispFile -Encoding utf8NoBOM -Value @'
function Invoke-TestExecDispatcher {
    param($Pick, $Prompt)
    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'feature.txt') -Value 'made by instrument' -Encoding utf8NoBOM
    return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
}
'@
    $env:BATON_GO_TEST_EXEC_DISPATCHER = $dispFile

    # ---- happy path ----
    $raw = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $repo -Json | Out-String
    $res = $raw | ConvertFrom-Json
    Check 'E1 run completed' ($res.status -eq 'completed')
    Check 'E2 result names a baton/run- branch' ($res.branch -like 'baton/run-*')
    Check 'E3 files_changed counted' ([int]$res.files_changed -ge 1)
    Check 'E4 changes.diff exists in run dir' (Test-Path (Join-Path $res.run_dir 'changes.diff'))
    Check 'E5 changes.diff carries the NEW file' ((Get-Content -Raw (Join-Path $res.run_dir 'changes.diff')) -match 'feature\.txt')
    Check 'E6 acceptance verdict landed' ($res.acceptance.verdict -eq 'accept')
    Check 'E7 user repo tree untouched' (-not (Test-Path (Join-Path $repo 'feature.txt')))
    Check 'E8 worktree has the instrument edit' (Test-Path (Join-Path ([string]$res.worktree) 'feature.txt'))
    $branches = [string](& git -C $repo branch --list 'baton/run-*')
    Check 'E9 run branch exists in the target repo' ($branches -match 'baton/run-')

    # ---- non-repo -> exit 2, no partial state ----
    $plain = Join-Path $tmpRoot 'plain'
    New-Item -ItemType Directory -Force -Path $plain | Out-Null
    & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Execute -RepoPath $plain -Json 2>$null | Out-Null
    Check 'E10 non-repo exits 2' ($LASTEXITCODE -eq 2)

    # ---- without -Execute the run is unchanged (route-and-discard; no worktree) ----
    $env:BATON_GO_TEST_SPAWN = '1'
    $raw2 = & pwsh -NoProfile -File "$PSScriptRoot/fleet-go.ps1" -Goal 'g' -Json | Out-String
    $res2 = $raw2 | ConvertFrom-Json
    Check 'E11 non-execute run still completes' ($res2.status -eq 'completed')
    Check 'E12 non-execute result has no branch key' ($null -eq $res2.PSObject.Properties['branch'])
} finally {
    foreach ($k in $saved.Keys) {
        if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
