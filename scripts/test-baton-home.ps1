#!/usr/bin/env pwsh
# Tests for baton-home.ps1: Get-BatonHome, Initialize-BatonHome, Move-BatonState.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'baton-home.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$savedHome = $env:BATON_HOME
$savedClaude = $env:BATON_CLAUDE_DIR
try {
    # --- Get-BatonHome ---
    $env:BATON_HOME = 'X:\custom\baton'
    Assert "Get-BatonHome honors env var" ((Get-BatonHome) -eq 'X:\custom\baton')
    $env:BATON_HOME = $null
    Assert "Get-BatonHome defaults to ~/.baton" ((Get-BatonHome) -eq (Join-Path $HOME '.baton'))

    # --- Initialize-BatonHome ---
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "baton-home-test-$([guid]::NewGuid().ToString('N'))"
    $env:BATON_HOME = Join-Path $tmp 'baton'
    $refs = Join-Path $tmp 'references'
    New-Item -ItemType Directory -Force -Path $refs | Out-Null
    foreach ($f in @('fleet.yaml','tools.yaml','prime-hours.yaml')) {
        Set-Content (Join-Path $refs $f) "seed: $f" -Encoding utf8NoBOM
    }
    $seeded = Initialize-BatonHome -ReferencesDir $refs
    Assert "creates BATON_HOME root"   (Test-Path $env:BATON_HOME)
    Assert "creates jobs dir"          (Test-Path (Join-Path $env:BATON_HOME 'jobs'))
    Assert "creates runs dir"          (Test-Path (Join-Path $env:BATON_HOME 'runs'))
    Assert "creates logs dir"          (Test-Path (Join-Path $env:BATON_HOME 'logs'))
    Assert "seeds all three configs"   (@($seeded).Count -eq 3)
    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'user: edited' -Encoding utf8NoBOM
    $seeded2 = Initialize-BatonHome -ReferencesDir $refs
    Assert "second run seeds nothing"  (@($seeded2).Count -eq 0)
    Assert "never overwrites existing config" ((Get-Content (Join-Path $env:BATON_HOME 'fleet.yaml') -Raw).Trim() -eq 'user: edited')

    # --- Move-BatonState ---
    $fakeClaude = Join-Path $tmp 'claude'
    $env:BATON_CLAUDE_DIR = $fakeClaude
    $env:BATON_HOME = Join-Path $tmp 'baton2'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'jobs/j1') | Out-Null
    Set-Content (Join-Path $fakeClaude 'current-job.json') '{"job_id":"j1"}' -Encoding utf8NoBOM
    Set-Content (Join-Path $fakeClaude 'routing-journal.jsonl') '{"x":1}' -Encoding utf8NoBOM
    # knowledge must NOT be in the move set
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'knowledge') | Out-Null
    $r = Move-BatonState
    Assert "moves jobs dir"            (Test-Path (Join-Path $env:BATON_HOME 'jobs/j1'))
    Assert "moves current-job.json"    (Test-Path (Join-Path $env:BATON_HOME 'current-job.json'))
    Assert "moves routing journal"     (Test-Path (Join-Path $env:BATON_HOME 'routing-journal.jsonl'))
    Assert "source jobs gone"          (-not (Test-Path (Join-Path $fakeClaude 'jobs')))
    Assert "knowledge left in place"   (Test-Path (Join-Path $fakeClaude 'knowledge'))
    Assert "writes marker"             (Test-Path (Join-Path $env:BATON_HOME '.migrated-from-claude.json'))
    Assert "reports migrated items"    (@($r.migrated) -contains 'jobs')

    # idempotent: marker gates a second run
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeClaude 'jobs/j2') | Out-Null
    $r2 = Move-BatonState
    Assert "marker gates re-run"       ((-not (Test-Path (Join-Path $env:BATON_HOME 'jobs/j2'))) -and (Test-Path (Join-Path $fakeClaude 'jobs/j2')))

    # conflict: both exist -> source untouched, listed
    $env:BATON_HOME = Join-Path $tmp 'baton3'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    Set-Content (Join-Path $env:BATON_HOME 'fleet.yaml') 'dest' -Encoding utf8NoBOM
    Set-Content (Join-Path $fakeClaude 'fleet.yaml') 'src' -Encoding utf8NoBOM
    $r3 = Move-BatonState
    Assert "conflict leaves source"    ((Get-Content (Join-Path $fakeClaude 'fleet.yaml') -Raw).Trim() -eq 'src')
    Assert "conflict reported"         (@($r3.conflicts) -contains 'fleet.yaml')
} finally {
    $env:BATON_HOME = $savedHome
    $env:BATON_CLAUDE_DIR = $savedClaude
    if ($tmp -and (Test-Path $tmp)) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# --- Stale-literal regression guard: no script may still default state to ~/.claude ---
$stalePattern = '\.claude[/\\](jobs|runs|ideas|ensembles|current-job\.json|routing-journal|model-routing-log|fleet\.yaml|tools\.yaml|prime-hours\.yaml)'
$allowed = @('baton-home.ps1', 'bootstrap.ps1')   # migration source list lives here by design
$stale = @()
foreach ($f in (Get-ChildItem $here -Recurse -Filter *.ps1 | Where-Object { $_.Name -notlike 'test-*' -and ($allowed -notcontains $_.Name) })) {
    if ((Get-Content $f.FullName -Raw) -match $stalePattern) { $stale += $f.Name }
}
Assert "no stale ~/.claude state literals in scripts ($($stale -join ', '))" ($stale.Count -eq 0)

if ($failures -gt 0) { exit 1 } else { exit 0 }
