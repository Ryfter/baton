#!/usr/bin/env pwsh
# scripts/test-choices-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'baton-home.ps1')
. (Join-Path $PSScriptRoot 'choices-lib.ps1')

$script:failures = 0
function Assert([string]$label, [bool]$cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$prev = $env:BATON_HOME
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("baton-choices-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:BATON_HOME = $tmp
try {
    $dir = Get-ChoicesDir -BatonHome $tmp
    Assert 'T1 choices dir path ends with choices' ($dir -match '[\\/]choices$')
    Assert 'T1b dir created on Get-ChoicesDir' (Test-Path -LiteralPath $dir)

    $id = New-ChoiceId
    Assert 'T2 id prefix ch-' ($id -match '^ch-[0-9a-f]{12}$')

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $good = [ordered]@{
        schema_version = 1
        id             = $id
        status         = 'draft'
        project        = 'canvas-toolchain'
        title          = 'Publish v2.2.0?'
        question       = 'Unblock npm publish?'
        options        = @(
            @{ id = 'yes'; label = 'Publish'; summary = 'Tag and publish' }
            @{ id = 'no'; label = 'Defer'; summary = 'Wait' }
        )
        recommendation = @{ option_id = 'yes'; why = 'Professors blocked' }
        evidence       = @('docs/foo.md')
        created_at     = $now
        updated_at     = $now
    }
    $path = Write-Choice -Choice $good -BatonHome $tmp
    Assert 'T3 file written' (Test-Path -LiteralPath $path)
    $back = Read-Choice -Id $id -BatonHome $tmp
    Assert 'T4 round-trip id' ($back.id -eq $id)
    Assert 'T5 round-trip status' ($back.status -eq 'draft')
    Assert 'T5b created_at stays string' ($back.created_at -is [string])
    Assert 'T5c updated_at stays string' ($back.updated_at -is [string])

    $threw = $false
    try {
        $badHash = [ordered]@{}
        foreach ($p in $good.Keys) { $badHash[$p] = $good[$p] }
        $badHash.status = 'waiting'
        Test-ChoiceSchema -Choice $badHash
    } catch { $threw = $true }
    Assert 'T6 unknown status throws' $threw

    $threw2 = $false
    try {
        $badVer = [ordered]@{}
        foreach ($p in $good.Keys) { $badVer[$p] = $good[$p] }
        $badVer.schema_version = 99
        Test-ChoiceSchema -Choice $badVer
    } catch { $threw2 = $true }
    Assert 'T7 bad schema_version throws' $threw2

    $threw3 = $false
    try {
        $badVerFloat = [ordered]@{}
        foreach ($p in $good.Keys) { $badVerFloat[$p] = $good[$p] }
        $badVerFloat.schema_version = 1.1
        Test-ChoiceSchema -Choice $badVerFloat
    } catch { $threw3 = $true }
    Assert 'T8 coercible schema_version 1.1 throws' $threw3

    $threw4 = $false
    try {
        $badVerStr = [ordered]@{}
        foreach ($p in $good.Keys) { $badVerStr[$p] = $good[$p] }
        $badVerStr.schema_version = '1'
        Test-ChoiceSchema -Choice $badVerStr
    } catch { $threw4 = $true }
    Assert 'T9 string schema_version "1" throws' $threw4
}
finally {
    if ($null -eq $prev) { Remove-Item Env:\BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prev }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "FAILED: $failures"; exit 1 }
Write-Host 'ALL PASS'
exit 0
