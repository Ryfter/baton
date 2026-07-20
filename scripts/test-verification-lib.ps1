#!/usr/bin/env pwsh
# Hermetic suite for verification-lib (d082 V1). Zero network, zero model calls,
# temp dirs only — never real ~/.baton, ~/.claude, or any real project tree.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'verification-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpRoot = Join-Path $env:TEMP "verify-lib-test-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedPresetsEnv = $env:BATON_VERIFY_PRESETS
try {
    # Pin presets to the repo copy so the suite never reads a live BATON_HOME seed.
    $env:BATON_VERIFY_PRESETS = Join-Path (Split-Path $PSScriptRoot -Parent) 'references/verify-presets.json'
    $wt = Join-Path $tmpRoot 'wt'
    New-Item -ItemType Directory -Force -Path $wt | Out-Null

    # --- P: presets ---
    $presets = Get-VerifyPresets
    Assert "P1 presets file parses and exposes pytest" ($null -ne $presets['pytest'])
    Assert "P2 file-exists-nonempty carries weak ceiling" ($presets['file-exists-nonempty'].grade_ceiling -eq 'weak')
    $noneP = Get-VerifyPresets -PresetsPath (Join-Path $tmpRoot 'absent.json')
    Assert "P3 absent presets file -> empty map (fail-soft)" ($noneP.Count -eq 0)

    # --- S: argv safety ---
    Assert "S1 plain argv ok" ((Test-VerifyArgvSafe -Argv @('python', '-m', 'pytest')).ok)
    Assert "S2 sh -c rejected" (-not (Test-VerifyArgvSafe -Argv @('sh', '-c', 'echo hi')).ok)
    Assert "S3 cmd /c rejected (case-insensitive)" (-not (Test-VerifyArgvSafe -Argv @('CMD', '/C', 'dir')).ok)
    Assert "S4 pwsh -Command rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-Command', '1')).ok)
    Assert "S5 pwsh -EncodedCommand abbreviation rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-enc', 'AAA')).ok)
    Assert "S6 python -c rejected" (-not (Test-VerifyArgvSafe -Argv @('python', '-c', 'print(1)')).ok)
    Assert "S7 node --eval rejected" (-not (Test-VerifyArgvSafe -Argv @('node', '--eval', '1')).ok)
    Assert "S8 powershell.exe path form rejected" (-not (Test-VerifyArgvSafe -Argv @('C:\wp\powershell.exe', '-command', '1')).ok)
    Assert "S9 pwsh -File allowed" ((Test-VerifyArgvSafe -Argv @('pwsh', '-NoProfile', '-File', 'x.ps1')).ok)
    Assert "S10 empty element rejected" (-not (Test-VerifyArgvSafe -Argv @('git', '')).ok)
    # C1: pwsh parameter-prefix abbreviations execute -Command/-EncodedCommand and must be rejected.
    Assert "S11 pwsh -com (Command prefix) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-com', 'Write-Output X')).ok)
    Assert "S12 pwsh -comm (Command prefix) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-comm', 'Write-Output X')).ok)
    Assert "S13 pwsh -comma (Command prefix) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-comma', 'Write-Output X')).ok)
    Assert "S14 pwsh -comman (Command prefix) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-comman', 'Write-Output X')).ok)
    Assert "S15 pwsh -en (EncodedCommand prefix) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-en', 'AAA=')).ok)
    Assert "S16 pwsh -cwa (CommandWithArgs alias) rejected" (-not (Test-VerifyArgvSafe -Argv @('pwsh', '-cwa', 'x')).ok)
    Assert "S17 python -cCODE (attached) rejected" (-not (Test-VerifyArgvSafe -Argv @('python', '-cprint(1)')).ok)
    Assert "S18 python3 -cCODE (attached) rejected" (-not (Test-VerifyArgvSafe -Argv @('python3', '-cimport os')).ok)
    Assert "S19 node --eval=CODE (attached) rejected" (-not (Test-VerifyArgvSafe -Argv @('node', '--eval=1')).ok)
    Assert "S20 env python -c rejected (env-wrapper shift)" (-not (Test-VerifyArgvSafe -Argv @('env', 'python', '-c', 'print(1)')).ok)
    Assert "S21 /usr/bin/env node -e rejected (env path shift)" (-not (Test-VerifyArgvSafe -Argv @('/usr/bin/env', 'node', '-e', '1')).ok)
    Assert "S22 pwsh.cmd -com rejected (.cmd wrapper stripped)" (-not (Test-VerifyArgvSafe -Argv @('C:\wp\pwsh.cmd', '-com', 'x')).ok)
    Assert "S23 perl -eCODE (attached) rejected" (-not (Test-VerifyArgvSafe -Argv @('perl', '-eprint 1')).ok)
    Assert "S24 deno -e rejected" (-not (Test-VerifyArgvSafe -Argv @('deno', '-e', '1')).ok)
    # C1 regressions: legitimate commands must NOT be over-blocked.
    Assert "S25 real pytest invocation allowed" ((Test-VerifyArgvSafe -Argv @('python', '-m', 'pytest', 'tests/', '-q')).ok)
    Assert "S26 gcc -c foo.c allowed (gcc is not an interpreter)" ((Test-VerifyArgvSafe -Argv @('gcc', '-c', 'foo.c')).ok)
    Assert "S27 pwsh -NoProfile -File allowed (real script run)" ((Test-VerifyArgvSafe -Argv @('pwsh', '-NoProfile', '-File', 'scripts/x.ps1')).ok)
    Assert "S28 node script.js allowed (no eval flag)" ((Test-VerifyArgvSafe -Argv @('node', 'server.js', '--port', '3000')).ok)
    Assert "S29 python -C (uppercase, not -c) allowed" ((Test-VerifyArgvSafe -Argv @('python', '-C', 'foo')).ok)
    # C-carry: env-wrapper hardening — assignments/flags before the interpreter must not
    # let a shell/eval escape slip past the one-token shift (V1 review carry-forward).
    Assert "S30 env NAME=val python -c rejected" (-not (Test-VerifyArgvSafe -Argv @('env', 'FOO=bar', 'python', '-c', 'x')).ok)
    Assert "S31 env -i pwsh -Command rejected" (-not (Test-VerifyArgvSafe -Argv @('env', '-i', 'pwsh', '-Command', 'x')).ok)
    Assert "S32 env -u X node --eval= rejected" (-not (Test-VerifyArgvSafe -Argv @('env', '-u', 'X', 'node', '--eval=1')).ok)
    Assert "S33 env NAME=val pytest still allowed (no over-block)" ((Test-VerifyArgvSafe -Argv @('env', 'FOO=bar', 'pytest', 'tests/', '-q')).ok)
    Assert "S34 env -C dir sh -c rejected (flag-with-value + escape)" (-not (Test-VerifyArgvSafe -Argv @('env', '-C', '/tmp', 'sh', '-c', 'x')).ok)

    # --- C: containment ---
    Set-Content -LiteralPath (Join-Path $wt 'inside.txt') -Value 'x' -Encoding utf8NoBOM
    Assert "C1 relative inside resolves" ($null -ne (Test-VerifyPathContained -Root $wt -Relative 'inside.txt'))
    Assert "C2 '.' resolves to the root itself" ($null -ne (Test-VerifyPathContained -Root $wt -Relative '.'))
    Assert "C3 .. escape rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative '..\outside.txt'))
    Assert "C4 rooted path rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative $tmpRoot))
    Assert "C5 nested .. that stays inside is fine" ($null -ne (Test-VerifyPathContained -Root $wt -Relative 'a\..\inside.txt'))
    # Junction escape (no admin needed, unlike symlinks): link inside -> dir outside
    $outDir = Join-Path $tmpRoot 'outside-dir'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $junc = Join-Path $wt 'jlink'
    $null = New-Item -ItemType Junction -Path $junc -Target $outDir -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $junc) {
        Assert "C6 junction whose target escapes is rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative 'jlink'))
    } else {
        Assert "C6 junction whose target escapes is rejected (skipped: junction unavailable)" $true
    }
    # I2: a junction at an INTERMEDIATE component escapes containment (leaf is a real file).
    Set-Content -LiteralPath (Join-Path $outDir 'secret.txt') -Value 'top-secret' -Encoding utf8NoBOM
    $juncMid = Join-Path $wt 'linkdir'
    $null = New-Item -ItemType Junction -Path $juncMid -Target $outDir -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $juncMid) {
        Assert "C7 intermediate-component junction escape is rejected" ($null -eq (Test-VerifyPathContained -Root $wt -Relative 'linkdir\secret.txt'))
    } else {
        Assert "C7 intermediate-component junction escape is rejected (skipped: junction unavailable)" $true
    }
    # I2 regression: a legitimate deeply-nested REAL directory still resolves inside.
    $realDeep = Join-Path $wt 'realsub\deep'
    New-Item -ItemType Directory -Force -Path $realDeep | Out-Null
    Set-Content -LiteralPath (Join-Path $realDeep 'ok.txt') -Value 'y' -Encoding utf8NoBOM
    Assert "C8 legitimate nested real dir still resolves inside" ($null -ne (Test-VerifyPathContained -Root $wt -Relative 'realsub\deep\ok.txt'))

    # --- N: normalize + lint ---
    $rawOk = @{ argv = @('git', 'status'); proves = 'demo'; expect_files = @('inside.txt') }
    $n1 = Get-VerificationContract -Raw $rawOk -WorktreeRoot $wt
    Assert "N1 raw profile normalizes" ($n1.ok -and $n1.contract.timeout_s -eq 300 -and $n1.contract.grade_ceiling -eq 'strong')
    $n2 = Get-VerificationContract -Raw @{ argv = @('sh', '-c', 'x'); proves = 'p' } -WorktreeRoot $wt
    Assert "N2 shell escape fails lint" ((-not $n2.ok) -and $n2.reason -match 'escape')
    $n3 = Get-VerificationContract -Raw @{ argv = @('git', 'status') } -WorktreeRoot $wt
    Assert "N3 missing proves rejected" ((-not $n3.ok) -and $n3.reason -match 'proves')
    $n4 = Get-VerificationContract -Raw @{ argv = @('git', 'status'); proves = 'p'; timeout_s = 99999 } -WorktreeRoot $wt
    Assert "N4 timeout above cap rejected" ((-not $n4.ok) -and $n4.reason -match 'cap')
    $n5 = Get-VerificationContract -Raw @{ argv = @('git', 'status'); proves = 'p'; expect_files = @('..\x') } -WorktreeRoot $wt
    Assert "N5 escaping expect_files rejected" ((-not $n5.ok) -and $n5.reason -match 'escapes')
    $n6 = Get-VerificationContract -Raw @{ preset = 'pwsh-suite'; args = @('scripts/x.ps1'); proves = 'suite passes' } -WorktreeRoot $wt
    Assert "N6 preset expands with args appended" ($n6.ok -and $n6.contract.argv[-1] -eq 'scripts/x.ps1' -and $n6.contract.argv[0] -eq 'pwsh')
    $n7 = Get-VerificationContract -Raw @{ preset = 'no-such' } -WorktreeRoot $wt
    Assert "N7 unknown preset rejected" ((-not $n7.ok) -and $n7.reason -match 'unknown-preset')
    $n8 = Get-VerificationContract -Raw @{ preset = 'file-exists-nonempty'; expect_files = @('inside.txt') } -WorktreeRoot $wt
    Assert "N8 noop preset resolves {{lib_dir}} and keeps weak ceiling" ($n8.ok -and $n8.contract.grade_ceiling -eq 'weak' -and ($n8.contract.argv -join ' ') -match 'verify-noop')

    # --- helpers for part 2 ---
    function New-TestGitRepo([string]$Path) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        & git -C $Path init -q 2>$null | Out-Null
        & git -C $Path config user.email t@t 2>$null | Out-Null
        & git -C $Path config user.name t 2>$null | Out-Null
    }
    $repo = Join-Path $tmpRoot 'repo'
    New-TestGitRepo $repo
    $cfgDir = Join-Path $repo '.baton'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfg = @{ schema = 1; profiles = @{ demo = @{ argv = @('git', 'status'); proves = 'repo status readable'; protected_paths = @('oracle.txt') } } }
    ConvertTo-Json -InputObject $cfg -Depth 6 | Set-Content -LiteralPath (Join-Path $cfgDir 'verification.json') -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'oracle-v1' -Encoding utf8NoBOM
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m base 2>$null | Out-Null
    $baseSha = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $taskDir = Join-Path $tmpRoot 'run\tasks\t1'

    # --- F: frozen contract ---
    $f1 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F1 freeze resolves the profile from the base commit" ($f1.ok -and (Test-Path $f1.contract_path))
    $f2 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'nope' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F2 unknown profile fails closed" ((-not $f2.ok) -and $f2.reason -match 'unknown-profile')
    # Worker edits the WORKTREE copy after freeze -> frozen contract still governs
    $mut = @{ schema = 1; profiles = @{ demo = @{ argv = @('sh', '-c', 'evil'); proves = 'x' } } }
    ConvertTo-Json -InputObject $mut -Depth 6 | Set-Content -LiteralPath (Join-Path $cfgDir 'verification.json') -Encoding utf8NoBOM
    $f3 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha $baseSha -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\t1b')
    Assert "F3 frozen contract authority: worktree mutation is invisible" ($f3.ok -and ($f3.contract.argv[0] -eq 'git'))
    $f4 = Get-FrozenVerificationContract -RepoPath $repo -BaseSha '0000000000000000000000000000000000000000' -ProfileName 'demo' -WorktreeRoot $repo -RunTaskDir $taskDir
    Assert "F4 bad base sha -> no-verification-config" ((-not $f4.ok) -and $f4.reason -match 'no-verification-config')

    # --- R: runner ---
    $rOut = Join-Path $tmpRoot 'r1.txt'
    $r1 = Invoke-VerifyCommand -Argv @('git', '--version') -WorkingDir $repo -TimeoutS 60 -OutputPath $rOut
    Assert "R1 plain command exits 0 with captured output" ($r1.exit_code -eq 0 -and (Get-Content $rOut -Raw) -match 'git version')
    $r2 = Invoke-VerifyCommand -Argv @('git', 'definitely-not-a-verb') -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r2.txt')
    Assert "R2 failing command reports nonzero exit" ($r2.started -and $r2.exit_code -ne 0)
    $r3 = Invoke-VerifyCommand -Argv @("no-such-exe-$(Get-Random)") -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r3.txt')
    Assert "R3 missing executable -> started=false (spawn error)" (-not $r3.started)
    # Timeout + tree kill: pwsh -File on a sleeper script (argv-safe form)
    $sleeper = Join-Path $tmpRoot 'sleeper.ps1'
    Set-Content -LiteralPath $sleeper -Value 'Start-Sleep -Seconds 120' -Encoding utf8NoBOM
    $t0 = Get-Date
    $r4 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $sleeper) -WorkingDir $repo -TimeoutS 2 -OutputPath (Join-Path $tmpRoot 'r4.txt')
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    Assert "R4 timeout kills the tree quickly" ($r4.timed_out -and $elapsed -lt 30)
    # M1: prove the timeout kills the WHOLE tree (a grandchild), not just the direct child.
    $gcPidFile = Join-Path $tmpRoot 'gcpid.txt'
    $treeSleeper = Join-Path $tmpRoot 'tree-sleeper.ps1'
    $treeBody = @"
`$c = Start-Process pwsh -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru
Set-Content -LiteralPath '$gcPidFile' -Value `$c.Id -Encoding utf8NoBOM
Start-Sleep -Seconds 120
"@
    Set-Content -LiteralPath $treeSleeper -Value $treeBody -Encoding utf8NoBOM
    $t0b = Get-Date
    $r4b = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $treeSleeper) -WorkingDir $repo -TimeoutS 6 -OutputPath (Join-Path $tmpRoot 'r4b.txt')
    $elapsedB = ((Get-Date) - $t0b).TotalSeconds
    $gcPid = $null
    if (Test-Path -LiteralPath $gcPidFile) { $gcPid = ([string](Get-Content -LiteralPath $gcPidFile -Raw)).Trim() }
    $gcGone = $false
    if ($gcPid) {
        for ($i = 0; $i -lt 50; $i++) {
            if ($null -eq (Get-Process -Id ([int]$gcPid) -ErrorAction SilentlyContinue)) { $gcGone = $true; break }
            Start-Sleep -Milliseconds 100
        }
    }
    Assert "R4b timeout reaps the grandchild (whole-tree kill)" ($r4b.timed_out -and $elapsedB -lt 30 -and $gcPid -and $gcGone)
    # argv literality: spaces, quotes, $() reach the child untouched
    $echoer = Join-Path $tmpRoot 'echoer.ps1'
    Set-Content -LiteralPath $echoer -Value 'param($P) [Console]::Out.Write($P)' -Encoding utf8NoBOM
    $lit = 'a b "q" $(Get-Date) `tick'
    $r5out = Join-Path $tmpRoot 'r5.txt'
    $r5 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $echoer, $lit) -WorkingDir $repo -TimeoutS 60 -OutputPath $r5out
    Assert "R5 argv passes spaces/quotes/dollar literally (no reparse)" ($r5.exit_code -eq 0 -and (Get-Content $r5out -Raw).Contains($lit))
    # Output cap
    $blaster = Join-Path $tmpRoot 'blaster.ps1'
    Set-Content -LiteralPath $blaster -Value "[Console]::Out.Write(('x' * 400000))" -Encoding utf8NoBOM
    $r6 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $blaster) -WorkingDir $repo -TimeoutS 60 -OutputPath (Join-Path $tmpRoot 'r6.txt') -MaxOutputBytes 1000
    Assert "R6 output truncated at the byte cap" ($r6.output_truncated -and (Get-Item (Join-Path $tmpRoot 'r6.txt')).Length -lt 5000)
    # I3: a check that floods far beyond the cap is bounded — file <= cap+margin, flag set,
    #     exit code still captured, process completes cleanly (memory bounded by the cap).
    $flood = Join-Path $tmpRoot 'flood.ps1'
    Set-Content -LiteralPath $flood -Value "[Console]::Out.Write(('x' * 2000000)); exit 0" -Encoding utf8NoBOM
    $r7out = Join-Path $tmpRoot 'r7.txt'
    $r7 = Invoke-VerifyCommand -Argv @('pwsh', '-NoProfile', '-File', $flood) -WorkingDir $repo -TimeoutS 60 -OutputPath $r7out -MaxOutputBytes 1000
    Assert "R7 flooded output is bounded (truncated flag, file<=cap+margin, exit 0 captured)" ($r7.output_truncated -and (-not $r7.timed_out) -and $r7.exit_code -eq 0 -and (Get-Item $r7out).Length -le 1200)

    # --- E/G/V: façade end-to-end ---
    $demo = $f1.contract
    $protPre = Get-VerifyPathHashes -WorktreeRoot $repo -Paths @($demo.protected_paths)
    $v1 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v1') -ProtectedPreHashes $protPre
    Assert "V1 clean pass; protected intact; grade bounded (no scope enforcement)" ($v1.ok -and $v1.verdict -eq 'pass' -and $v1.grade -eq 'bounded')
    $v2 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v2') -ProtectedPreHashes $protPre -DiffFiles @('src/a.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V2 scope enforced + protected intact -> STRONG" ($v2.ok -and $v2.grade -eq 'strong')
    $v3 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3') -ProtectedPreHashes $protPre -DiffFiles @('src/a.ps1', 'other/b.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V3 diff outside allowed paths -> scope-violation, fail closed" ($v3.verdict -eq 'scope-violation' -and $v3.failure_category -eq 'scope-violation' -and -not $v3.ok)
    # #125: directory-prefix allowed_paths (trailing '/') + segment-boundary safety.
    # Exact entries keep prior semantics; empty AllowedPaths remains unenforced (V1).
    $v3p = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3p') -ProtectedPreHashes $protPre -DiffFiles @('app/urlnorm.py') -AllowedPaths @('app/')
    Assert "V3p directory prefix app/ allows app/urlnorm.py" ($v3p.scope_ok -and $v3p.ok -and $v3p.verdict -eq 'pass')
    $v3q = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3q') -ProtectedPreHashes $protPre -DiffFiles @('apple/x.py') -AllowedPaths @('app/')
    Assert "V3q directory prefix app/ does NOT allow apple/x.py (segment boundary)" ($v3q.verdict -eq 'scope-violation' -and $v3q.failure_category -eq 'scope-violation' -and -not $v3q.ok -and -not $v3q.scope_ok)
    $v3r = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3r') -ProtectedPreHashes $protPre -DiffFiles @('app/urlnorm.py', 'docs/readme.md') -AllowedPaths @('app/', 'docs/readme.md')
    Assert "V3r mixed exact+prefix list allows nested + exact" ($v3r.scope_ok -and $v3r.ok)
    $v3s = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3s') -ProtectedPreHashes $protPre -DiffFiles @('app/urlnorm.py', 'other/b.py') -AllowedPaths @('app/', 'docs/readme.md')
    Assert "V3s mixed list still blocks paths outside exact+prefix" ($v3s.verdict -eq 'scope-violation' -and -not $v3s.scope_ok)
    $v3t = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3t') -ProtectedPreHashes $protPre -DiffFiles @('src/a.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V3t exact entry still passes (unchanged semantics)" ($v3t.scope_ok -and $v3t.ok)
    $v3u = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v3u') -ProtectedPreHashes $protPre -DiffFiles @('app/other.py') -AllowedPaths @('app/urlnorm.py')
    Assert "V3u exact file entry still blocks sibling under same dir when not listed" ($v3u.verdict -eq 'scope-violation' -and -not $v3u.scope_ok)
    # Protected-oracle mutation
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'TAMPERED' -Encoding utf8NoBOM
    $v4 = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v4') -ProtectedPreHashes $protPre
    Assert "V4 mutated protected oracle -> scope-violation/protected-path-mutated" ($v4.verdict -eq 'scope-violation' -and $v4.failure_category -eq 'protected-path-mutated')
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'oracle-v1' -Encoding utf8NoBOM
    # I1: contract DECLARES a protected path but NO pre-hashes are supplied -> the oracle
    #     was never verified. A concurrent mutation goes undetected, so the library must NOT
    #     certify strong: protected_ok is false and the grade is capped below strong.
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'MUTATED-NO-PREHASH' -Encoding utf8NoBOM
    $v4b = Invoke-VerificationContract -Contract $demo -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v4b') -DiffFiles @('src/a.ps1') -AllowedPaths @('src/a.ps1')
    Assert "V4b declared-but-unverified protected oracle -> protected_ok false, grade NOT strong" ((-not $v4b.protected_ok) -and $v4b.grade -ne 'strong')
    Set-Content -LiteralPath (Join-Path $repo 'oracle.txt') -Value 'oracle-v1' -Encoding utf8NoBOM
    # Expected files: missing / empty / unchanged (A5) / changed
    $expC = [ordered]@{ argv = @('git', '--version'); cwd = '.'; timeout_s = 60; expect_files = @('out.txt'); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v5 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v5')
    Assert "V5 missing expected file fails" ($v5.failure_category -eq 'expected-file-missing')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value '' -NoNewline -Encoding utf8NoBOM
    $v6 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v6')
    Assert "V6 empty expected file fails" ($v6.failure_category -eq 'expected-file-empty')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value 'stale' -Encoding utf8NoBOM
    $prePre = Get-VerifyPathHashes -WorktreeRoot $repo -Paths @('out.txt')
    $v7 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v7') -ExpectPreHashes $prePre
    Assert "V7 pre-existing expected file UNCHANGED fails (A5 content bar)" ($v7.failure_category -eq 'expected-file-unchanged')
    Set-Content -LiteralPath (Join-Path $repo 'out.txt') -Value 'fresh content' -Encoding utf8NoBOM
    $v8 = Invoke-VerificationContract -Contract $expC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v8') -ExpectPreHashes $prePre
    Assert "V8 changed expected file passes" ($v8.ok -and $v8.expected_files_ok)
    # Check failure + weak ceiling + spawn failure verdicts
    $failC = [ordered]@{ argv = @('git', 'definitely-not-a-verb'); cwd = '.'; timeout_s = 60; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v9 = Invoke-VerificationContract -Contract $failC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v9')
    Assert "V9 failing check -> fail/check-failed, grade invalid" ($v9.verdict -eq 'fail' -and $v9.failure_category -eq 'check-failed' -and $v9.grade -eq 'invalid')
    $noopC = (Get-VerificationContract -Raw @{ preset = 'file-exists-nonempty'; expect_files = @('out.txt') } -WorktreeRoot $repo).contract
    $v10 = Invoke-VerificationContract -Contract $noopC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v10') -ExpectPreHashes $prePre
    Assert "V10 weak ceiling caps a passing existence check at WEAK" ($v10.ok -and $v10.grade -eq 'weak')
    $spawnC = [ordered]@{ argv = @("no-such-exe-$(Get-Random)"); cwd = '.'; timeout_s = 30; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }
    $v11 = Invoke-VerificationContract -Contract $spawnC -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v11')
    Assert "V11 missing verifier exe -> infrastructure-error, not model-quality fail" ($v11.verdict -eq 'infrastructure-error' -and $v11.failure_category -eq 'spawn-failed')
    $v12 = Invoke-VerificationContract -Contract ([ordered]@{ argv = @('pwsh', '-NoProfile', '-File', $sleeper); cwd = '.'; timeout_s = 2; expect_files = @(); protected_paths = @(); proves = 'p'; grade_ceiling = 'strong' }) -WorktreeRoot $repo -RunTaskDir (Join-Path $tmpRoot 'run\tasks\v12')
    Assert "V12 check timeout -> fail/check-timeout (retry-eligible category)" ($v12.verdict -eq 'fail' -and $v12.failure_category -eq 'check-timeout' -and $v12.timed_out)
} finally {
    if ($null -eq $savedPresetsEnv) { Remove-Item env:BATON_VERIFY_PRESETS -ErrorAction SilentlyContinue }
    else { $env:BATON_VERIFY_PRESETS = $savedPresetsEnv }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
