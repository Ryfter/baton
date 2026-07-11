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
} finally {
    if ($null -eq $savedPresetsEnv) { Remove-Item env:BATON_VERIFY_PRESETS -ErrorAction SilentlyContinue }
    else { $env:BATON_VERIFY_PRESETS = $savedPresetsEnv }
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
