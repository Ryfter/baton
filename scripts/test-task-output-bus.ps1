#!/usr/bin/env pwsh
<# Hermetic tests for the task-output bus (#115 slice 1). Fake-spawner / fixture
   pattern mirrors test-fleet-executor-lib.ps1. #>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

function New-TempRepo {
    param([string]$Root)
    $p = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q
    & git -C $p config user.email 'test@test.local'
    & git -C $p config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $p 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m 'init' 2>$null | Out-Null
    return $p
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "task-output-bus-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedBatonHome = $env:BATON_HOME
try {
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'
    Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    command_template: 'echo "{{prompt}}"'
'@
    $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'
    $repo = New-TempRepo -Root $tmpRoot
    $wt = New-RunWorktree -RepoPath $repo -RunId 'bus-t1'
    $runDir = Join-Path $tmpRoot 'run-bus'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $enc = [System.Text.Encoding]::UTF8

    # ---- Pure helpers: extract + write + inject ----

    # (a) worker output containing the block -> output.md with exactly the block content
    $withBlock = @"
Some preamble chatter from the worker.
## Task output
path: src/foo.ps1
fact: bar uses Baz
"@
    $resA = Get-TaskOutputResidue -Stdout $withBlock
    Check 'A1 residue starts at ## Task output heading' ($resA.StartsWith('## Task output'))
    Check 'A1b residue carries facts, not preamble' (
        ($resA -match 'path: src/foo.ps1') -and ($resA -match 'fact: bar uses Baz') -and
        ($resA -notmatch 'preamble chatter'))
    $dirA = Join-Path $tmpRoot 'a-run'
    Write-TaskBusOutput -RunDir $dirA -TaskId 't1' -Stdout $withBlock
    $outA = Get-Content -LiteralPath (Join-Path $dirA 'tasks/t1/output.md') -Raw
    Check 'A2 output.md written under tasks/<id>/' (Test-Path -LiteralPath (Join-Path $dirA 'tasks/t1/output.md'))
    Check 'A3 output.md equals extracted block' ($outA.TrimEnd("`r", "`n") -eq $resA.TrimEnd("`r", "`n"))

    # last occurrence wins
    $double = "first`n## Task output`nold`n## Task output`nnew only"
    $resLast = Get-TaskOutputResidue -Stdout $double
    Check 'A4 last ## Task output wins' (
        ($resLast -match 'new only') -and ($resLast -notmatch 'old'))

    # (b) no block -> tail captured + file still written
    $noBlock = "plain worker chatter`nline two`nline three"
    $resB = Get-TaskOutputResidue -Stdout $noBlock
    Check 'B1 no-block residue is the full stdout tail' ($resB.TrimEnd("`r", "`n") -eq $noBlock.TrimEnd("`r", "`n"))
    $dirB = Join-Path $tmpRoot 'b-run'
    Write-TaskBusOutput -RunDir $dirB -TaskId 't2' -Stdout $noBlock
    Check 'B2 output.md still written without block' (Test-Path -LiteralPath (Join-Path $dirB 'tasks/t2/output.md'))
    $outB = Get-Content -LiteralPath (Join-Path $dirB 'tasks/t2/output.md') -Raw
    Check 'B3 no-block file content is the tail' ($outB.TrimEnd("`r", "`n") -eq $noBlock.TrimEnd("`r", "`n"))

    # (c) >8KB block -> truncated with marker
    $bigBody = 'X' * 10000
    $big = "## Task output`n$bigBody"
    $resC = Get-TaskOutputResidue -Stdout $big -MaxBytes 8192
    Check 'C1 oversize residue capped at ~8192 UTF-8 bytes' ($enc.GetByteCount($resC) -le 8192 + 32)
    Check 'C2 oversize residue carries explicit (truncated) marker' ($resC -match '\(truncated\)')
    Check 'C3 truncated content still starts at heading' ($resC.StartsWith('## Task output'))
    $dirC = Join-Path $tmpRoot 'c-run'
    Write-TaskBusOutput -RunDir $dirC -TaskId 'big' -Stdout $big
    $outC = Get-Content -LiteralPath (Join-Path $dirC 'tasks/big/output.md') -Raw
    Check 'C4 written file also carries (truncated)' ($outC -match '\(truncated\)')

    # (d) dependent task prompt contains ## Inputs from t1 (and t0) in depends_on order
    $seenPrompt = [ref]''
    $capDisp = {
        param($pick, $prompt)
        $seenPrompt.Value = [string]$prompt
        Set-Content -LiteralPath (Join-Path (Get-Location).Path 'made.txt') -Value 'x' -Encoding utf8NoBOM
        @{ stdout = "## Task output`nfrom-t2"; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $depRun = Join-Path $tmpRoot 'dep-run'
    New-Item -ItemType Directory -Force -Path $depRun | Out-Null
    Write-TaskBusOutput -RunDir $depRun -TaskId 't0' -Stdout "## Task output`noutput-of-t0"
    Write-TaskBusOutput -RunDir $depRun -TaskId 't1' -Stdout "## Task output`noutput-of-t1"
    $spD = New-AgenticSpawner -Worktree $wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
        -RunDir $depRun -Dispatcher $capDisp
    $taskD = [pscustomobject]@{
        id = 't2'; desc = 'consume upstream'; capability = 'code-gen'
        depends_on = @('t0', 't1'); est_cost_tier = 'free'
        stakes = 'standard'; stakes_basis = 'ordinary bounded feature'
    }
    $rd = & $spD $taskD
    Check 'D1 dependent task ok' ($rd.ok -eq $true)
    $pD = $seenPrompt.Value
    Check 'D2 prompt has Inputs from t0' ($pD -match '## Inputs from t0')
    Check 'D3 prompt has Inputs from t1' ($pD -match '## Inputs from t1')
    Check 'D4 t0 content present' ($pD -match 'output-of-t0')
    Check 'D5 t1 content present' ($pD -match 'output-of-t1')
    # order: t0 section before t1 section
    $i0 = $pD.IndexOf('## Inputs from t0')
    $i1 = $pD.IndexOf('## Inputs from t1')
    Check 'D6 deps injected in depends_on order' (($i0 -ge 0) -and ($i1 -gt $i0))
    Check 'D7 Task: desc still present' ($pD -match 'Task: consume upstream')
    # Instruction block must SURVIVE dependency injection (residue headings alone
    # must not trip the idempotency guard — #115 review finding #1).
    $instrD = Get-TaskOutputInstructionBlock
    Check 'D8 instruction block survives dep injection' ($pD.IndexOf($instrD) -ge 0)
    Check 'D8b instruction unique second line present after Inputs' (
        ($pD -match 'End your reply with a ## Task output section') -and
        ($pD.IndexOf('## Inputs from t0') -ge 0) -and
        ($pD.LastIndexOf('End your reply with a ## Task output section') -gt $pD.IndexOf('## Inputs from t0')))

    # (d2) path containment: hostile TaskId must not write outside run dir
    $escRun = Join-Path $tmpRoot 'escape-run'
    New-Item -ItemType Directory -Force -Path $escRun | Out-Null
    $naiveWrite = [System.IO.Path]::GetFullPath((Join-Path $escRun 'tasks/../../x/output.md'))
    if (Test-Path -LiteralPath $naiveWrite) {
        Remove-Item -LiteralPath $naiveWrite -Force -ErrorAction SilentlyContinue
    }
    $warnsWrite = $null
    Write-TaskBusOutput -RunDir $escRun -TaskId '../../x' -Stdout 'LEAKED' `
        -WarningVariable warnsWrite -WarningAction SilentlyContinue
    Check 'D9 hostile TaskId does not write outside run dir' (
        -not (Test-Path -LiteralPath $naiveWrite))
    Check 'D9b no tasks tree created for hostile id' (
        -not (Test-Path -LiteralPath (Join-Path $escRun 'tasks')))
    Check 'D9c write warning path taken' (
        (@($warnsWrite).Count -gt 0) -and
        ((@($warnsWrite | ForEach-Object { [string]$_ }) -join ' ') -match 'unsafe TaskId'))

    # (d3) path containment: hostile depId must not read outside run dir
    # Bait file at the path a naive Join-Path would open for depId '../..'
    $naiveRead = [System.IO.Path]::GetFullPath((Join-Path $escRun 'tasks/../../output.md'))
    $naiveReadDir = Split-Path -Parent $naiveRead
    if (-not (Test-Path -LiteralPath $naiveReadDir)) {
        New-Item -ItemType Directory -Force -Path $naiveReadDir | Out-Null
    }
    Set-Content -LiteralPath $naiveRead -Value 'SECRET-PAYLOAD-DO-NOT-LEAK' -Encoding utf8NoBOM
    $hostileInj = Get-TaskBusInputBlock -RunDir $escRun -DependsOn @('../..')
    Check 'D10 hostile depId injects placeholder' ($hostileInj -match '\(no output was produced\)')
    Check 'D10b hostile depId does not leak external content' (
        $hostileInj -notmatch 'SECRET-PAYLOAD-DO-NOT-LEAK')
    $naiveReadX = [System.IO.Path]::GetFullPath((Join-Path $escRun 'tasks/../../x/output.md'))
    $naiveReadXDir = Split-Path -Parent $naiveReadX
    if (-not (Test-Path -LiteralPath $naiveReadXDir)) {
        New-Item -ItemType Directory -Force -Path $naiveReadXDir | Out-Null
    }
    Set-Content -LiteralPath $naiveReadX -Value 'SECRET-X-PAYLOAD' -Encoding utf8NoBOM
    $hostileInjX = Get-TaskBusInputBlock -RunDir $escRun -DependsOn @('../../x')
    Check 'D10c hostile ../../x dep injects placeholder' ($hostileInjX -match '\(no output was produced\)')
    Check 'D10d hostile ../../x does not leak' ($hostileInjX -notmatch 'SECRET-X-PAYLOAD')

    # (d4) duplicate depends_on ids: first wins, single section
    $dedupeRun = Join-Path $tmpRoot 'dedupe-run'
    New-Item -ItemType Directory -Force -Path $dedupeRun | Out-Null
    Write-TaskBusOutput -RunDir $dedupeRun -TaskId 't1' -Stdout "## Task output`nonce"
    $deduped = Get-TaskBusInputBlock -RunDir $dedupeRun -DependsOn @('t1', 't1')
    $t1Count = ([regex]::Matches($deduped, '(?m)^## Inputs from t1\s*$')).Count
    Check 'D11 duplicate depends_on injects one section' ($t1Count -eq 1)
    Check 'D11b duplicate depends_on still has content' ($deduped -match 'once')

    # (e) missing dep output -> placeholder, no throw
    $seenE = [ref]''
    $dispE = {
        param($pick, $prompt)
        $seenE.Value = [string]$prompt
        @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $missRun = Join-Path $tmpRoot 'miss-run'
    New-Item -ItemType Directory -Force -Path $missRun | Out-Null
    # t1 present, t-missing absent
    Write-TaskBusOutput -RunDir $missRun -TaskId 't1' -Stdout "## Task output`nhere"
    $spE = New-AgenticSpawner -Worktree $wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
        -RunDir $missRun -Dispatcher $dispE
    $threwE = $false
    try {
        $null = & $spE ([pscustomobject]@{
            id = 't3'; desc = 'needs missing'; capability = 'code-gen'
            depends_on = @('t1', 't-missing'); est_cost_tier = 'free'
            stakes = 'standard'; stakes_basis = 'ordinary bounded feature'
        })
    } catch { $threwE = $true }
    Check 'E1 missing dep does not throw' (-not $threwE)
    Check 'E2 placeholder for missing dep' ($seenE.Value -match '## Inputs from t-missing[\s\S]*\(no output was produced\)')
    Check 'E3 present dep still injected' ($seenE.Value -match '## Inputs from t1')

    # pure helper for missing with no RunDir
    $ph = Get-TaskBusInputBlock -RunDir '' -DependsOn @('ghost')
    Check 'E4 empty RunDir yields placeholder not throw' ($ph -match '\(no output was produced\)')

    # (f) total-inputs cap enforced with dropped-ids line
    $capRun = Join-Path $tmpRoot 'cap-run'
    New-Item -ItemType Directory -Force -Path $capRun | Out-Null
    # three deps each ~4KB -> total > 8192*2.5; with total cap 24576 still OK.
    # Force a low TotalCapBytes so oldest drop.
    $chunk = 'Y' * 3000
    Write-TaskBusOutput -RunDir $capRun -TaskId 'old1' -Stdout "## Task output`n$chunk"
    Write-TaskBusOutput -RunDir $capRun -TaskId 'old2' -Stdout "## Task output`n$chunk"
    Write-TaskBusOutput -RunDir $capRun -TaskId 'new3' -Stdout "## Task output`n$chunk"
    # Per-cap keeps each ~3KB; total cap 5000 forces drop of oldest.
    $inj = Get-TaskBusInputBlock -RunDir $capRun -DependsOn @('old1', 'old2', 'new3') `
        -PerCapBytes 8192 -TotalCapBytes 5000
    Check 'F1 dropped-ids line present' ($inj -match '\(inputs truncated:')
    Check 'F2 oldest dep dropped first' ($inj -match 'old1')
    Check 'F3 newest kept when possible' (
        ($inj -match '## Inputs from new3') -or ($inj -match '## Inputs from old2'))
    Check 'F4 dropped section not fully present as Inputs heading for first-dropped' (
        # After drop, either old1 is only named in the truncated line, not as a full section —
        # or if multiple dropped, the line lists them. Assert the marker format at minimum.
        ($inj -match '\(inputs truncated: [^)]+\)'))
    # tighter: with total 5000 and ~3KB sections, at most one section fits; first two dropped
    Check 'F5 old1 not a full Inputs section when dropped' (
        -not ($inj -match '(?m)^## Inputs from old1\s*$'))

    # (g) failed attempt still writes output.md
    # Isolate usage journal so a hard_failover classification does not lock the
    # single test provider out of later cases (H).
    $failRun = Join-Path $tmpRoot 'fail-run'
    New-Item -ItemType Directory -Force -Path $failRun | Out-Null
    $failUsage = Join-Path $tmpRoot 'fail-usage.jsonl'
    $failDisp = {
        param($pick, $prompt)
        @{ stdout = "## Task output`nfailed-but-useful`nfix: 42"; stderr = 'boom'; exit_code = 1; duration_s = 0 }
    }
    $spG = New-AgenticSpawner -Worktree $wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
        -RunDir $failRun -UsagePath $failUsage -Dispatcher $failDisp
    $rg = & $spG ([pscustomobject]@{
        id = 't-fail'; desc = 'will fail'; capability = 'code-gen'
        depends_on = @(); est_cost_tier = 'free'
        stakes = 'standard'; stakes_basis = 'ordinary bounded feature'
    })
    Check 'G1 attempt reported not ok' ($rg.ok -eq $false)
    $failOutPath = Join-Path $failRun 'tasks/t-fail/output.md'
    Check 'G2 failed attempt still wrote output.md' (Test-Path -LiteralPath $failOutPath)
    $failBody = Get-Content -LiteralPath $failOutPath -Raw
    Check 'G3 failed residue captured' (
        ($failBody -match 'failed-but-useful') -and ($failBody -match 'fix: 42'))

    # (h) prompt instruction block present in BOTH prompt seams
    $instr = Get-TaskOutputInstructionBlock
    Check 'H0 instruction block is short (3-4 lines)' (
        (@($instr -split "`n").Count -ge 3) -and (@($instr -split "`n").Count -le 5))

    $seenH = @{ prompt = '' }
    $dispH = {
        param($pick, $prompt)
        $seenH.prompt = [string]$prompt
        @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
    }.GetNewClosure()
    $spH = New-AgenticSpawner -Worktree $wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
        -RunDir $runDir -Dispatcher $dispH
    $rh = & $spH ([pscustomobject]@{
        id = 't-h'; desc = 'instruction check'; capability = 'code-gen'
        depends_on = @(); est_cost_tier = 'free'
        stakes = 'standard'; stakes_basis = 'ordinary bounded feature'
    })
    Check 'H1 seam1 dispatched (provider available)' ($rh.ok -eq $true -or $rh.chose -eq 'fake-agentic')
    Check 'H1b seam1 (New-AgenticSpawner) carries instruction block' (
        $seenH.prompt.IndexOf($instr) -ge 0)
    Check 'H1c seam1 has ## Task output instruction heading' (
        $seenH.prompt -match '(?m)^## Task output\s*$')

    $vsOut = Join-Path $tmpRoot 'vs-out.txt'
    Set-Content -LiteralPath $vsOut -Value 'check failed output' -Encoding utf8NoBOM
    $evidence = Format-VerifyEvidencePrompt -TaskDesc 'Original task text' `
        -Verification @{ failure_category = 'check-failed' } -OutputPath $vsOut
    Check 'H2 seam2 (Format-VerifyEvidencePrompt) carries instruction block' (
        $evidence.IndexOf($instr) -ge 0)
    Check 'H2b seam2 has ## Task output instruction heading' (
        $evidence -match '(?m)^## Task output\s*$')
    Check 'H2c seam2 still carries failure category' ($evidence -match 'check-failed')
    Check 'H2d seam2 still <=965 UTF-8 bytes (default MaxBytes path)' (
        $enc.GetByteCount($evidence) -le 965)

    # Build-AgenticWorkerPrompt unit: instruction + optional inputs
    $built = Build-AgenticWorkerPrompt -TaskDesc 'do the thing' -InputBlock "## Inputs from t1`nhello"
    Check 'H3 Build-AgenticWorkerPrompt joins inputs + Task + instruction' (
        ($built -match '## Inputs from t1') -and ($built -match 'Task: do the thing') -and
        ($built.IndexOf($instr) -ge 0))
    $built2 = Add-TaskOutputInstruction -Prompt (Add-TaskOutputInstruction -Prompt 'x')
    Check 'H4 Add-TaskOutputInstruction is idempotent' (
        (([regex]::Matches($built2, [regex]::Escape($instr))).Count -eq 1))

    # Authority comment present at injection site (source-level guard)
    $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fleet-executor-lib.ps1') -Raw
    Check 'H5 authority comment present (ADVISORY DATA, NOT AUTHORITY)' (
        $src -match 'ADVISORY DATA, NOT AUTHORITY')
    Check 'H5b authority comment mentions allowed_paths / oracle' (
        ($src -match 'allowed_paths') -and ($src -match 'oracle'))

    if ($script:fail -eq 0) {
        Write-Host "`nALL CHECKS PASS"
        exit 0
    } else {
        Write-Host "`n$script:fail CHECK(S) FAILED"
        exit 1
    }
} finally {
    $env:BATON_HOME = $savedBatonHome
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}
