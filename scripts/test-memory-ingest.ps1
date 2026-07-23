#!/usr/bin/env pwsh
# Hermetic tests for memory-ingest-lib.ps1 + fleet-memory.ps1 ingest.
# Fixture run dirs under $env:TEMP; BATON_HOME redirected. NO live models,
# no real provider names (placeholders: worker-a only).
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("mem-ingest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prevBatonHome = $env:BATON_HOME
$env:BATON_HOME = $tmp
$cli = Join-Path $PSScriptRoot 'fleet-memory.ps1'

try {
    . "$PSScriptRoot/memory-ingest-lib.ps1"

    $runsRoot = Join-Path $tmp 'runs'
    $memPath = Join-Path $tmp 'memory-journal.jsonl'
    New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null

    # ---- helper: write a minimal run fixture ----
    function New-FixtureRun {
        param(
            [Parameter(Mandatory)][string]$RunId,
            [Parameter(Mandatory)][string]$Goal,
            [Parameter(Mandatory)][string]$Status,
            [string]$Verdict = '',
            [object[]]$Tasks = @(),
            [object[]]$Events = @(),
            [object[]]$Decisions = @(),
            [switch]$CorruptPlan,
            [switch]$NoPlan
        )
        $dir = Join-Path $runsRoot $RunId
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (-not $NoPlan) {
            if ($CorruptPlan) {
                Set-Content -LiteralPath (Join-Path $dir 'plan.json') -Value '{not-json' -Encoding utf8NoBOM
            } else {
                $plan = [ordered]@{
                    run_id     = $RunId
                    goal       = $Goal
                    budget_cap = $null
                    tasks      = @($Tasks)
                }
                ($plan | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dir 'plan.json') -Encoding utf8NoBOM
            }
        }
        $report = @"
# Conductor run — $RunId

**Goal:** $Goal
**Status:** $Status
**Spend:** 0.00

## Tasks
"@
        Set-Content -LiteralPath (Join-Path $dir 'report.md') -Value $report -Encoding utf8NoBOM

        if (@($Events).Count -gt 0) {
            $elines = @($Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
            Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Value ($elines -join "`n") -Encoding utf8NoBOM
        }
        if (@($Decisions).Count -gt 0) {
            $dlines = @($Decisions | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
            Set-Content -LiteralPath (Join-Path $dir 'decisions.jsonl') -Value ($dlines -join "`n") -Encoding utf8NoBOM
        }
        if ($Verdict) {
            $acc = [ordered]@{ verdict = $Verdict; reason = 'fixture gate' }
            ($acc | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Join-Path $dir 'acceptance.json') -Encoding utf8NoBOM
        }
        return $dir
    }

    # ---- pure helpers ----
    Check 'M1 failed status -> fail' ((ConvertTo-MemoryOutcomeFromRun -Status 'failed') -eq 'fail')
    Check 'M2 verification-failed -> fail' ((ConvertTo-MemoryOutcomeFromRun -Status 'verification-failed') -eq 'fail')
    Check 'M3 rejected -> fail' ((ConvertTo-MemoryOutcomeFromRun -Status 'rejected') -eq 'fail')
    Check 'M4 completed + accept -> pass' ((ConvertTo-MemoryOutcomeFromRun -Status 'completed' -Acceptance ([pscustomobject]@{ verdict = 'accept' })) -eq 'pass')
    Check 'M5 needs-polish -> partial' ((ConvertTo-MemoryOutcomeFromRun -Status 'needs-polish') -eq 'partial')
    Check 'M6 polish acceptance -> partial' ((ConvertTo-MemoryOutcomeFromRun -Status 'completed' -Acceptance ([pscustomobject]@{ verdict = 'polish' })) -eq 'partial')

    # ---- (1) reject-gate fixture -> >=1 failed row with expected signature tokens ----
    $rejectId = 'go-reject-gate-1'
    $rejectDir = New-FixtureRun -RunId $rejectId -Goal 'auth login flaky under ci' -Status 'rejected' -Verdict 'reject' `
        -Tasks @(
            [ordered]@{ id = 't1'; desc = 'patch the auth login retry path'; capability = 'code-gen'; est_cost_tier = 'paid'; reversible = $true }
        ) `
        -Events @(
            [ordered]@{ ts = '2026-07-18T10:00:00Z'; level = 'info'; task_id = ''; kind = 'started'; message = 'plan: 1 tasks' }
            [ordered]@{ ts = '2026-07-18T10:01:00Z'; level = 'info'; task_id = 't1'; kind = 'started'; message = 'patch the auth login retry path' }
            [ordered]@{ ts = '2026-07-18T10:02:00Z'; level = 'info'; task_id = 't1'; kind = 'spent'; message = '0.00' }
            [ordered]@{ ts = '2026-07-18T10:03:00Z'; level = 'info'; task_id = 't1'; kind = 'finished'; message = 'patch the auth login retry path' }
            [ordered]@{ ts = '2026-07-18T10:04:00Z'; level = 'info'; task_id = ''; kind = 'gate'; message = 'acceptance verdict: reject — critical auth hole' }
        ) `
        -Decisions @(
            [ordered]@{
                ts = '2026-07-18T10:01:30Z'; task_id = 't1'; chose = 'worker-a'
                alternatives = @('worker-b'); why = 'routed code-gen -> worker-a'
                cost_tier = 'paid'; stakes = 'high'; stakes_basis = 'operator'
                depth_tier = 'high'; depth_applied = $true; selection_mode = 'champion'
            }
        )

    $folded = @(ConvertFrom-RunLedger -RunDir $rejectDir)
    Check 'R1 reject fold yields >=1 row' ($folded.Count -ge 1)
    $failRows = @($folded | Where-Object { $_.outcome -eq 'fail' })
    Check 'R2 reject fold yields fail outcome' ($failRows.Count -ge 1)
    $runLevel = @($failRows | Where-Object { $_.problem -eq 'auth login flaky under ci' }) | Select-Object -First 1
    Check 'R3 run-level problem is the goal' ($null -ne $runLevel)
    $sig = Get-MemorySignature -Text $runLevel.problem
    Check 'R4 signature carries auth/login/flaky tokens' (
        ($sig -match 'auth') -and ($sig -match 'login' -or $sig -match 'flaky' -or $sig -match 'ci')
    )
    Check 'R5 refs.run set' ([string](Get-MemoryIngestRefValue -Refs $runLevel.refs -Key 'run') -eq $rejectId)
    Check 'R6 stakes_basis preserved in refs' ([string](Get-MemoryIngestRefValue -Refs $runLevel.refs -Key 'stakes_basis') -eq 'operator')
    Check 'R7 task_id preserved in refs' ([string](Get-MemoryIngestRefValue -Refs $runLevel.refs -Key 'task_id') -eq 't1')
    Check 'R8 source is conductor-ledger' ([string]$runLevel.source -eq 'conductor-ledger')
    # Routing noise (spent/started) must not become their own rows.
    $noiseProblems = @($folded | Where-Object { $_.problem -match '^(plan:|0\.00)' })
    Check 'R9 routing noise skipped' ($noiseProblems.Count -eq 0)

    $ing1 = Invoke-MemoryIngest -Run $rejectDir -BatonHome $tmp -MemoryPath $memPath
    Check 'R10 first ingest writes >=1' ($ing1.written -ge 1)
    $journal1 = @(Read-MemoryJournal -Path $memPath)
    Check 'R11 journal has fail row' (@($journal1 | Where-Object { $_.outcome -eq 'fail' }).Count -ge 1)
    $jFail = @($journal1 | Where-Object { $_.outcome -eq 'fail' -and $_.problem -eq 'auth login flaky under ci' }) | Select-Object -First 1
    Check 'R12 journal signature tokens' (
        $null -ne $jFail -and
        ([string]$jFail.signature -match 'auth') -and
        ([string]$jFail.source -eq 'conductor-ledger')
    )

    # ---- (2) re-ingest -> zero new rows ----
    $ing2 = Invoke-MemoryIngest -Run $rejectDir -BatonHome $tmp -MemoryPath $memPath
    Check 'I1 re-ingest writes zero' ($ing2.written -eq 0)
    Check 'I2 re-ingest skips duplicates' ($ing2.skipped_duplicate -ge 1)
    $journal2 = @(Read-MemoryJournal -Path $memPath)
    Check 'I3 journal row count unchanged' ($journal2.Count -eq $journal1.Count)

    # Also via run-id resolution under $BATON_HOME/runs/
    $ing2b = Invoke-MemoryIngest -Run $rejectId -BatonHome $tmp -MemoryPath $memPath
    Check 'I4 run-id resolve + re-ingest still zero writes' ($ing2b.written -eq 0 -and $ing2b.run_id -eq $rejectId)

    # ---- (3) --dry-run writes nothing ----
    $dryId = 'go-dry-run-1'
    $dryDir = New-FixtureRun -RunId $dryId -Goal 'docker build is slow on ci' -Status 'failed' `
        -Tasks @([ordered]@{ id = 't1'; desc = 'speed up docker build'; capability = 'code-gen'; est_cost_tier = 'local'; reversible = $true }) `
        -Events @(
            [ordered]@{ ts = '2026-07-18T11:00:00Z'; level = 'error'; task_id = 't1'; kind = 'error'; message = 'speed up docker build' }
        ) `
        -Decisions @(
            [ordered]@{ ts = '2026-07-18T11:00:00Z'; task_id = 't1'; chose = 'worker-a'; why = 'local'; stakes_basis = 'heuristic' }
        )
    $beforeDry = if (Test-Path $memPath) { @(Get-Content -LiteralPath $memPath) } else { @() }
    $dryRes = Invoke-MemoryIngest -Run $dryDir -BatonHome $tmp -MemoryPath $memPath -DryRun
    $afterDry = if (Test-Path $memPath) { @(Get-Content -LiteralPath $memPath) } else { @() }
    Check 'D1 dry-run written count is 0' ($dryRes.written -eq 0)
    Check 'D2 dry-run flag set' ($dryRes.dry_run -eq $true)
    Check 'D3 dry-run previews >=1 row' (@($dryRes.rows).Count -ge 1)
    Check 'D4 dry-run leaves journal bytes unchanged' ($beforeDry.Count -eq $afterDry.Count)

    # ---- (4) corrupt/missing ledger -> fail-soft warning, never throws ----
    $script:threw = $false
    $warnBag = @()
    try {
        $bad = Invoke-MemoryIngest -Run (Join-Path $runsRoot 'does-not-exist') -BatonHome $tmp -MemoryPath $memPath -WarningVariable warnBag -WarningAction SilentlyContinue
    } catch {
        $script:threw = $true
        $bad = $null
    }
    Check 'F1 missing run never throws' (-not $script:threw)
    Check 'F2 missing run writes nothing' ($null -ne $bad -and $bad.written -eq 0)
    Check 'F3 missing run surfaces warning' (@($bad.warnings).Count -ge 1 -or @($warnBag).Count -ge 1)

    $corruptId = 'go-corrupt-plan'
    $corruptDir = New-FixtureRun -RunId $corruptId -Goal 'whatever' -Status 'failed' -CorruptPlan
    $script:threw2 = $false
    $warnBag2 = @()
    try {
        $cor = Invoke-MemoryIngest -Run $corruptDir -BatonHome $tmp -MemoryPath $memPath -WarningVariable warnBag2 -WarningAction SilentlyContinue
    } catch {
        $script:threw2 = $true
        $cor = $null
    }
    Check 'F4 corrupt plan never throws' (-not $script:threw2)
    Check 'F5 corrupt plan writes nothing' ($null -ne $cor -and $cor.written -eq 0)
    Check 'F6 corrupt plan warns' (@($cor.warnings).Count -ge 1 -or @($warnBag2).Count -ge 1)

    $noPlanId = 'go-no-plan'
    $noPlanDir = New-FixtureRun -RunId $noPlanId -Goal 'x' -Status 'failed' -NoPlan
    $script:threw3 = $false
    try {
        $np = Invoke-MemoryIngest -Run $noPlanDir -BatonHome $tmp -MemoryPath $memPath -WarningAction SilentlyContinue
    } catch {
        $script:threw3 = $true
        $np = $null
    }
    Check 'F7 missing plan never throws' (-not $script:threw3)
    Check 'F8 missing plan writes nothing' ($null -ne $np -and $np.written -eq 0)

    # Malformed events/decisions lines are skipped, run still folds from plan+status.
    $malId = 'go-malformed-lines'
    $malDir = New-FixtureRun -RunId $malId -Goal 'cache invalidation is hard' -Status 'completed' -Verdict 'accept' `
        -Tasks @([ordered]@{ id = 't1'; desc = 'fix cache'; capability = 'code-gen'; est_cost_tier = 'free'; reversible = $true })
    Add-Content -LiteralPath (Join-Path $malDir 'events.jsonl') -Value 'NOT JSON' -Encoding utf8NoBOM
    Add-Content -LiteralPath (Join-Path $malDir 'decisions.jsonl') -Value '{bad' -Encoding utf8NoBOM
    $script:threw4 = $false
    try {
        $mal = Invoke-MemoryIngest -Run $malDir -BatonHome $tmp -MemoryPath $memPath
    } catch {
        $script:threw4 = $true
        $mal = $null
    }
    Check 'F9 malformed jsonl never throws' (-not $script:threw4)
    Check 'F10 malformed jsonl still can write run-level row' ($null -ne $mal -and $mal.written -ge 1)
    $malRow = @($mal.rows | Where-Object { $_.outcome -eq 'pass' }) | Select-Object -First 1
    Check 'F11 completed+accept -> pass' ($null -ne $malRow)

    # ---- task-level verification-failed produces fail row ----
    $vfId = 'go-verify-fail-1'
    $vfDir = New-FixtureRun -RunId $vfId -Goal 'ship feature x' -Status 'verification-failed' `
        -Tasks @([ordered]@{ id = 't1'; desc = 'unit tests for feature x'; capability = 'code-gen'; est_cost_tier = 'local'; reversible = $true }) `
        -Events @(
            [ordered]@{ ts = '2026-07-18T12:00:00Z'; level = 'warn'; task_id = 't1'; kind = 'task-verification-failed'; message = 'verification failed (oracle)' }
            [ordered]@{ ts = '2026-07-18T12:00:01Z'; level = 'error'; task_id = 't1'; kind = 'error'; message = 'unit tests for feature x' }
        ) `
        -Decisions @(
            [ordered]@{ ts = '2026-07-18T12:00:00Z'; task_id = 't1'; chose = 'worker-a'; stakes_basis = 'heuristic' }
        )
    $vfFold = @(ConvertFrom-RunLedger -RunDir $vfDir)
    $vfTask = @($vfFold | Where-Object { $_.outcome -eq 'fail' -and $_.problem -eq 'unit tests for feature x' }) | Select-Object -First 1
    Check 'V1 verification-failed emits task fail row' ($null -ne $vfTask)
    Check 'V2 verification-failed refs.task_id' ([string](Get-MemoryIngestRefValue -Refs $vfTask.refs -Key 'task_id') -eq 't1')

    # ---- needs-polish -> partial ----
    $np2Id = 'go-needs-polish-1'
    $np2Dir = New-FixtureRun -RunId $np2Id -Goal 'polish the dashboard styles' -Status 'needs-polish' -Verdict 'polish' `
        -Tasks @([ordered]@{ id = 't1'; desc = 'restyle dashboard'; capability = 'code-gen'; est_cost_tier = 'paid'; reversible = $true }) `
        -Events @(
            [ordered]@{ ts = '2026-07-18T13:00:00Z'; level = 'info'; task_id = 't1'; kind = 'finished'; message = 'restyle dashboard' }
        ) `
        -Decisions @(
            [ordered]@{ ts = '2026-07-18T13:00:00Z'; task_id = 't1'; chose = 'worker-a'; stakes_basis = 'operator' }
        )
    $np2Fold = @(ConvertFrom-RunLedger -RunDir $np2Dir)
    $np2Row = @($np2Fold | Where-Object { $_.outcome -eq 'partial' }) | Select-Object -First 1
    Check 'P1 needs-polish -> partial' ($null -ne $np2Row)

    # ---- CLI surface: ingest --json / --dry-run ----
    $cliReject = & pwsh -NoProfile -File $cli ingest -Run $rejectId -MemoryPath $memPath -Json 2>&1 | Out-String
    $cliObj = $null
    try { $cliObj = $cliReject | ConvertFrom-Json } catch { }
    Check 'C1 CLI re-ingest --json parses' ($null -ne $cliObj)
    Check 'C2 CLI re-ingest written=0' ($null -ne $cliObj -and [int]$cliObj.written -eq 0)
    Check 'C3 CLI re-ingest skipped_duplicate >=1' ($null -ne $cliObj -and [int]$cliObj.skipped_duplicate -ge 1)

    $beforeCliDry = @(Get-Content -LiteralPath $memPath)
    $cliDry = & pwsh -NoProfile -File $cli ingest -Run $dryId -MemoryPath $memPath -DryRun -Json 2>&1 | Out-String
    $cliDryObj = $null
    try { $cliDryObj = $cliDry | ConvertFrom-Json } catch { }
    $afterCliDry = @(Get-Content -LiteralPath $memPath)
    Check 'C4 CLI --dry-run --json parses' ($null -ne $cliDryObj -and $cliDryObj.dry_run -eq $true)
    Check 'C5 CLI --dry-run writes nothing' ($beforeCliDry.Count -eq $afterCliDry.Count)

    # Missing -Run exits 2
    $null = & pwsh -NoProfile -File $cli ingest -MemoryPath $memPath 2>&1
    Check 'C6 ingest without -Run exits 2' ($LASTEXITCODE -eq 2)
}
finally {
    if ($null -ne $prevBatonHome) { $env:BATON_HOME = $prevBatonHome }
    else { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
    Write-Host "`n$($script:fail) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
exit 0
