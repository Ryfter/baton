#!/usr/bin/env pwsh
# Hermetic tests for coordination-lib.ps1 (Coordination Layer v1 — resource facet).
# Never touches the real ~/.baton, ~/.claude, or any project tree: BATON_HOME is a
# throwaway temp dir, restored in the finally. The process table is faked through
# $script:CoordProcessProbe, so no test ever depends on a real pid being alive or dead.
# No real hostnames, model ids, or endpoints appear anywhere — host-a / stack-a /
# model-large only.
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("coordination-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prevHome = $env:BATON_HOME
$env:BATON_HOME = (Join-Path $tmp 'default-home')
New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null

try {
    . "$PSScriptRoot/coordination-lib.ps1"

    # ---- fake process table -------------------------------------------------
    # Contract mirrors the real probe: $null => not running; @{started_at=$null} =>
    # running but the OS will not say when (the never-early-steal case).
    $script:selfStart = '2026-08-01T00:00:00.0000000Z'
    $script:fakeProcs = @{}
    $script:CoordProcessProbe = {
        param($ProbePid)
        if ($script:fakeProcs.ContainsKey([int]$ProbePid)) { return $script:fakeProcs[[int]$ProbePid] }
        if ([int]$ProbePid -eq $PID) { return @{ started_at = $script:selfStart } }
        return $null
    }

    # ---- helpers ------------------------------------------------------------
    $stdConfig = @'
{
  "schema": 1,
  "hosts": { "host-a": { "vram_gb": 32 } },
  "profiles": {
    "model-large": { "vram_gb": 17, "class": "broad", "max_inflight": 1 },
    "model-small": { "vram_gb": 8,  "class": "tight", "max_inflight": 2 },
    "model-mid":   { "vram_gb": 8,  "class": "broad", "max_inflight": 1 }
  }
}
'@
    # Declared 32 GB * 0.90 safety factor => 28.8 GB admissible.

    function New-TestHome {
        param([Parameter(Mandatory)][string]$Name, [string]$ConfigJson)
        $dir = Join-Path $tmp $Name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $root = Get-CoordinationRoot -BatonHome $dir
        if ($PSBoundParameters.ContainsKey('ConfigJson') -and $null -ne $ConfigJson) {
            Set-Content -LiteralPath (Join-Path $root 'config.json') -Value $ConfigJson -Encoding utf8NoBOM
        }
        return $dir
    }

    function Write-TestClaim {
        <# Seed a claim row straight into the store (bypasses admission on purpose:
           these fixtures model claims left behind by OTHER processes). #>
        param(
            [Parameter(Mandatory)][string]$HomeDir,
            [Parameter(Mandatory)][string]$ClaimId,
            [string]$ClaimHost = 'host-a',
            [string]$Stack = 'stack-a',
            [string]$LoadProfile = 'model-large',
            [double]$VramGb = 17,
            [string]$Class = 'broad',
            [int]$HolderPid = 0,
            [string]$HolderStartedAt = $script:selfStart,
            [double]$ExpiresInSec = 60,
            [int]$Weight = 100
        )
        if ($HolderPid -le 0) { $HolderPid = $PID }
        $now = [datetimeoffset]::UtcNow
        $row = [ordered]@{
            claim_id          = $ClaimId
            host              = $ClaimHost
            stack             = $Stack
            load_profile      = $LoadProfile
            vram_gb           = $VramGb
            class             = $Class
            run_id            = 'run-fixture'
            project           = 'proj-fixture'
            weight            = $Weight
            holder_pid        = $HolderPid
            holder_started_at = $HolderStartedAt
            acquired_at       = $now.ToString('o')
            renewed_at        = $now.ToString('o')
            expires_at        = $now.AddSeconds($ExpiresInSec).ToString('o')
            ttl_sec           = 60
        }
        Set-Content -LiteralPath (Get-CoordClaimPath -ClaimId $ClaimId -BatonHome $HomeDir) `
            -Value ($row | ConvertTo-Json -Depth 4) -Encoding utf8NoBOM
        return $row
    }

    function Write-TestLock {
        param(
            [Parameter(Mandatory)][string]$HomeDir,
            [Parameter(Mandatory)][string]$Key,
            [double]$ExpiresInSec = 5,
            [int]$HolderPid = 0
        )
        if ($HolderPid -le 0) { $HolderPid = $PID }
        $now = [datetimeoffset]::UtcNow
        $payload = ([ordered]@{
            schema            = 1
            key               = $Key
            holder_pid        = $HolderPid
            holder_started_at = $script:selfStart
            acquired_at       = $now.ToString('o')
            expires_at        = $now.AddSeconds($ExpiresInSec).ToString('o')
            ttl_sec           = 5
        } | ConvertTo-Json -Compress)
        $path = Get-CoordLockPath -Key $Key -BatonHome $HomeDir
        Set-Content -LiteralPath $path -Value $payload -Encoding utf8NoBOM
        return $path
    }

    # =====================================================================
    # ST — store layout
    # =====================================================================
    $h0 = New-TestHome -Name 'home-layout' -ConfigJson $stdConfig
    $root0 = Get-CoordinationRoot -BatonHome $h0
    Check 'ST1 root is <BATON_HOME>/coordination' ($root0 -eq (Join-Path $h0 'coordination'))
    Check 'ST2 locks/ created' (Test-Path -LiteralPath (Join-Path $root0 'locks') -PathType Container)
    Check 'ST3 live/claims/ created' (Test-Path -LiteralPath (Join-Path (Join-Path $root0 'live') 'claims') -PathType Container)
    Check 'ST4 journal/ created' (Test-Path -LiteralPath (Join-Path $root0 'journal') -PathType Container)
    Check 'ST5 lock key is admit__resource__<host>__<stack>' (
        (Get-CoordResourceLockKey -HostName 'host-a' -Stack 'stack-a') -eq 'admit__resource__host-a__stack-a')

    # =====================================================================
    # G — grant / capacity  (RULE: capacity is declared, and it is a ceiling)
    # =====================================================================
    $hG = New-TestHome -Name 'home-grant' -ConfigJson $stdConfig

    $g1 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -Class 'broad' -RunId 'run-1' -Project 'proj-a' -BatonHome $hG
    Check 'G1 grant when declared capacity allows' ($g1.granted -eq $true -and $g1.reason -eq 'granted')

    $expectedFields = @(
        'claim_id', 'host', 'stack', 'load_profile', 'vram_gb', 'class', 'run_id', 'project',
        'weight', 'holder_pid', 'holder_started_at', 'acquired_at', 'renewed_at', 'expires_at', 'ttl_sec')
    $actualFields = @($g1.claim.Keys)
    Check 'G2 claim row has exactly the 15 spec fields, in order' (
        (@(Compare-Object -ReferenceObject $expectedFields -DifferenceObject $actualFields -SyncWindow 0).Count -eq 0) -and
        $actualFields.Count -eq 15)
    Check 'G3 claim row values populated' (
        $g1.claim.host -eq 'host-a' -and $g1.claim.stack -eq 'stack-a' -and
        $g1.claim.load_profile -eq 'model-large' -and [double]$g1.claim.vram_gb -eq 17 -and
        $g1.claim.run_id -eq 'run-1' -and $g1.claim.project -eq 'proj-a' -and
        [int]$g1.claim.ttl_sec -eq 60 -and [int]$g1.claim.holder_pid -eq $PID)
    Check 'G4 claim file landed under live/claims' (
        Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId $g1.claim.claim_id -BatonHome $hG))
    Check 'G5 live claim is visible lock-free' (
        @(Get-ResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hG).Count -eq 1)

    # Same stack, different profile, still inside the declared budget => allowed.
    $g2 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-small' `
        -VramGb 8 -Class 'tight' -RunId 'run-2' -Project 'proj-a' -BatonHome $hG
    Check 'G6 same stack granted while capacity remains (17+8 <= 28.8)' ($g2.granted -eq $true)

    # 17 + 8 + 8 = 33 > 28.8 => denied on capacity.
    $g3 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-mid' `
        -VramGb 8 -Class 'broad' -RunId 'run-3' -Project 'proj-a' -BatonHome $hG
    Check 'G7 deny when sum + requested exceeds declared capacity' (
        $g3.granted -eq $false -and $g3.reason -eq 'capacity')
    Check 'G8 denied request writes no claim file' (
        @(Get-ResourceClaims -HostName 'host-a' -BatonHome $hG).Count -eq 2)

    # Same profile again: weights already loaded, but the inflight cap is 1 for broad.
    $g4 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -Class 'broad' -RunId 'run-4' -Project 'proj-a' -BatonHome $hG
    Check 'G9 deny a second broad claim on an already-loaded profile (max_inflight 1)' (
        $g4.granted -eq $false -and $g4.reason -eq 'profile_inflight')

    # RULE 3 — stack exclusivity: one model server per box.
    $x1 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-mid' `
        -VramGb 4 -Class 'broad' -RunId 'run-5' -Project 'proj-a' -BatonHome $hG
    Check 'X1 deny a second stack on the same host while one is live (stack exclusivity)' (
        $x1.granted -eq $false -and $x1.reason -eq 'stack_exclusive')
    Check 'X2 stack exclusivity denies even when the box has spare declared VRAM' (
        $x1.granted -eq $false)
    Check 'X3 a different HOST is unaffected by host-a exclusivity' (
        @(Get-ResourceClaims -HostName 'host-b' -BatonHome $hG).Count -eq 0)

    # Release frees capacity for the previously-denied request.
    $rel = Remove-ResourceClaim -ClaimId $g2.claim.claim_id -BatonHome $hG
    Check 'R1 release reports ok' ($rel.ok -eq $true -and $rel.reason -eq 'released')
    Check 'R2 released claim is gone from the live set' (
        @(Get-ResourceClaims -HostName 'host-a' -BatonHome $hG).Count -eq 1)
    $g5 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-mid' `
        -VramGb 8 -Class 'broad' -RunId 'run-6' -Project 'proj-a' -BatonHome $hG
    Check 'R3 release frees capacity for a subsequent grant' ($g5.granted -eq $true)
    Check 'R4 releasing an unknown claim id is not_found (no throw)' (
        (Remove-ResourceClaim -ClaimId 'no-such-claim' -BatonHome $hG).reason -eq 'not_found')

    # =====================================================================
    # C — RULE 2: unknown declared capacity means DENY, not "infinite"
    # =====================================================================
    $hC1 = New-TestHome -Name 'home-nocfg'
    $c1 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hC1
    Check 'C1 deny when config.json is absent entirely (capacity unknown)' (
        $c1.granted -eq $false -and $c1.reason -eq 'capacity_unknown')

    $hC2 = New-TestHome -Name 'home-zerovram' -ConfigJson '{ "schema": 1, "hosts": { "host-a": { "vram_gb": 0 } } }'
    $c2 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hC2
    Check 'C2 deny when declared vram_gb is 0 (0 = unknown, never infinite)' (
        $c2.granted -eq $false -and $c2.reason -eq 'capacity_unknown')

    $hC3 = New-TestHome -Name 'home-nokey' -ConfigJson '{ "schema": 1, "hosts": { "host-a": { } } }'
    $c3 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hC3
    Check 'C3 deny when the host entry omits vram_gb' (
        $c3.granted -eq $false -and $c3.reason -eq 'capacity_unknown')

    $hC4 = New-TestHome -Name 'home-otherhost' -ConfigJson $stdConfig
    $c4 = Request-ResourceClaim -HostName 'host-b' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hC4
    Check 'C4 deny for a host absent from the declared hosts map' (
        $c4.granted -eq $false -and $c4.reason -eq 'capacity_unknown')

    $hC5 = New-TestHome -Name 'home-noprofilevram' -ConfigJson '{ "schema": 1, "hosts": { "host-a": { "vram_gb": 32 } } }'
    $c5 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' -BatonHome $hC5
    Check 'C5 deny when the REQUEST footprint is unknown (no -VramGb, no profile)' (
        $c5.granted -eq $false -and $c5.reason -eq 'profile_vram_unknown')

    $hC6 = New-TestHome -Name 'home-profilevram' -ConfigJson $stdConfig
    $c6 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' -BatonHome $hC6
    Check 'C6 footprint may come from the declared profile instead of -VramGb' (
        $c6.granted -eq $true -and [double]$c6.claim.vram_gb -eq 17 -and $c6.claim.class -eq 'broad')

    # =====================================================================
    # F — RULE 1: fail CLOSED (store / config / lock unavailable)
    # =====================================================================
    $badParent = Join-Path $tmp 'not-a-directory.txt'
    Set-Content -LiteralPath $badParent -Value 'this is a file, not a BATON_HOME' -Encoding utf8NoBOM
    $threw = $false
    $f1 = $null
    try {
        $f1 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
            -VramGb 17 -BatonHome $badParent
    } catch {
        $threw = $true
    }
    Check 'F1 store unwritable => granted=$false (never an implicit grant)' (
        $null -ne $f1 -and $f1.granted -eq $false)
    Check 'F2 store unwritable => no throw escapes to the caller' (-not $threw)
    Check 'F3 store unwritable => reason names the store' ($f1.reason -eq 'store_unavailable')

    $hF = New-TestHome -Name 'home-badcfg' -ConfigJson '{ this is not json'
    $f4 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hF
    Check 'F4 unreadable config => granted=$false' ($f4.granted -eq $false -and $f4.reason -eq 'config_unreadable')

    # A live, unexpired lock held by this (alive) process cannot be stolen => deny.
    $hF2 = New-TestHome -Name 'home-lockheld' -ConfigJson $stdConfig
    [void](Write-TestLock -HomeDir $hF2 -Key (Get-CoordResourceLockKey -HostName 'host-a') -ExpiresInSec 120)
    $f5 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -TimeoutSec 0 -BatonHome $hF2
    Check 'F5 admission lock unavailable => granted=$false' (
        $f5.granted -eq $false -and $f5.reason -eq 'lock_unavailable')
    # Same lock file also blocks a DIFFERENT stack: the host-level lock is what makes
    # stack exclusivity race-free (two stacks would otherwise take two different locks).
    $f6 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-mid' `
        -VramGb 8 -TimeoutSec 0 -BatonHome $hF2
    Check 'F6 host-level lock serializes DIFFERENT stacks on the same host' (
        $f6.granted -eq $false -and $f6.reason -eq 'lock_unavailable')
    Remove-Item -LiteralPath (Get-CoordLockPath -Key (Get-CoordResourceLockKey -HostName 'host-a') -BatonHome $hF2) -Force
    $f7 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hF2
    Check 'F7 once the lock clears, the same request is granted' ($f7.granted -eq $true)

    # =====================================================================
    # L — admission lock mechanics
    # =====================================================================
    $hL = New-TestHome -Name 'home-lock' -ConfigJson $stdConfig
    $lockA = Get-CoordLockPath -Key 'admit-test-a' -BatonHome $hL
    $ret = Invoke-WithAdmissionLock -Key 'admit-test-a' -BatonHome $hL -Script { 'payload-value' }
    Check 'L1 Invoke-WithAdmissionLock returns the scriptblock result' ($ret -eq 'payload-value')
    Check 'L2 lock released after the scriptblock' (-not (Test-Path -LiteralPath $lockA))

    $lockB = Get-CoordLockPath -Key 'admit-test-b' -BatonHome $hL
    $threwB = $false
    try {
        Invoke-WithAdmissionLock -Key 'admit-test-b' -BatonHome $hL -Script { throw 'boom' }
    } catch {
        $threwB = $true
    }
    Check 'L3 a throwing scriptblock still propagates' ($threwB)
    Check 'L4 lock released even when the scriptblock throws' (-not (Test-Path -LiteralPath $lockB))

    # Two sequential acquire attempts of the same key: the second must NOT also hold it.
    # $script: scope on purpose — a scriptblock assigns into its own child scope.
    $script:bothHeld = 'not-attempted'
    $script:innerBlocked = $false
    Invoke-WithAdmissionLock -Key 'admit-test-c' -BatonHome $hL -Script {
        try {
            $script:bothHeld = Invoke-WithAdmissionLock -Key 'admit-test-c' -TimeoutSec 0 -BatonHome $hL -Script { 'second-holder' }
        } catch {
            $script:innerBlocked = $true
            $script:bothHeld = $null
        }
    }
    Check 'L5 two sequential acquires do not both hold the lock' (
        $script:innerBlocked -eq $true -and $null -eq $script:bothHeld)
    Check 'L6 lock released after the nested attempt' (
        -not (Test-Path -LiteralPath (Get-CoordLockPath -Key 'admit-test-c' -BatonHome $hL)))

    # Stale lock (expired payload) => reclaimed, retry succeeds.
    [void](Write-TestLock -HomeDir $hL -Key 'admit-test-d' -ExpiresInSec -30)
    $staleRet = Invoke-WithAdmissionLock -Key 'admit-test-d' -TimeoutSec 0 -BatonHome $hL -Script { 'after-stale' }
    Check 'L7 expired lock payload is reclaimed and the retry succeeds' ($staleRet -eq 'after-stale')

    # Lock whose holder is provably dead => reclaimed too.
    $script:fakeProcs[7777] = $null
    [void](Write-TestLock -HomeDir $hL -Key 'admit-test-e' -ExpiresInSec 120 -HolderPid 7777)
    $deadRet = Invoke-WithAdmissionLock -Key 'admit-test-e' -TimeoutSec 0 -BatonHome $hL -Script { 'after-dead' }
    Check 'L8 lock held by a provably dead pid is reclaimed' ($deadRet -eq 'after-dead')

    # =====================================================================
    # S — stale claim reclaim
    # =====================================================================
    $hS = New-TestHome -Name 'home-stale' -ConfigJson $stdConfig
    [void](Write-TestClaim -HomeDir $hS -ClaimId 'claim-expired' -ExpiresInSec -30)
    Check 'S1 an expired claim is not live' (
        @(Get-ResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hS).Count -eq 0)
    $s2 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -BatonHome $hS
    Check 'S2 an expired claim stops counting toward capacity' ($s2.granted -eq $true)
    Check 'S3 the expired claim file was reclaimed' (
        -not (Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId 'claim-expired' -BatonHome $hS)))

    $hS2 = New-TestHome -Name 'home-deadholder' -ConfigJson $stdConfig
    $script:fakeProcs[4242] = $null   # not running at all
    [void](Write-TestClaim -HomeDir $hS2 -ClaimId 'claim-dead' -HolderPid 4242 -ExpiresInSec 600)
    Check 'S4 dead-holder claim is still TTL-live before reclaim' (
        @(Get-ResourceClaims -HostName 'host-a' -BatonHome $hS2).Count -eq 1)
    $reclaimed = @(Remove-StaleResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hS2)
    Check 'S5 a claim whose holder pid is dead is reclaimed' (
        $reclaimed.Count -eq 1 -and $reclaimed[0].claim_id -eq 'claim-dead')
    Check 'S6 reclaim removed the file' (
        -not (Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId 'claim-dead' -BatonHome $hS2)))

    # Pid reuse: running, start time KNOWN and contradicting the record => dead.
    $hS3 = New-TestHome -Name 'home-pidreuse' -ConfigJson $stdConfig
    $script:fakeProcs[4444] = @{ started_at = '2026-08-02T12:00:00.0000000Z' }
    [void](Write-TestClaim -HomeDir $hS3 -ClaimId 'claim-reused' -HolderPid 4444 `
        -HolderStartedAt '2020-01-01T00:00:00.0000000Z' -ExpiresInSec 600)
    Check 'S7 start-time mismatch (pid reuse) is provably dead => reclaimed' (
        @(Remove-StaleResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hS3).Count -eq 1)

    # RULE 5 — unknown start time: running, but the OS will not say when it started.
    $hS4 = New-TestHome -Name 'home-unknownstart' -ConfigJson $stdConfig
    $script:fakeProcs[4343] = @{ started_at = $null }
    [void](Write-TestClaim -HomeDir $hS4 -ClaimId 'claim-unknownstart' -HolderPid 4343 `
        -HolderStartedAt '2020-01-01T00:00:00.0000000Z' -ExpiresInSec 600)
    $u1 = @(Remove-StaleResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hS4)
    Check 'U1 unknown start-time does NOT early-steal a live claim (TTL-only reclaim)' ($u1.Count -eq 0)
    Check 'U2 the un-stealable claim file survives' (
        Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId 'claim-unknownstart' -BatonHome $hS4))
    Check 'U3 the un-stealable claim still counts as live' (
        @(Get-ResourceClaims -HostName 'host-a' -BatonHome $hS4).Count -eq 1)
    $u4 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-mid' `
        -VramGb 8 -BatonHome $hS4
    Check 'U4 the un-stealable claim still enforces stack exclusivity' (
        $u4.granted -eq $false -and $u4.reason -eq 'stack_exclusive')
    # Same claim, now past its TTL: TTL alone is enough to reclaim it.
    [void](Write-TestClaim -HomeDir $hS4 -ClaimId 'claim-unknownstart' -HolderPid 4343 `
        -HolderStartedAt '2020-01-01T00:00:00.0000000Z' -ExpiresInSec -5)
    Check 'U5 the same unknown-start claim IS reclaimed once its TTL expires' (
        @(Remove-StaleResourceClaims -HostName 'host-a' -Stack 'stack-a' -BatonHome $hS4).Count -eq 1)

    # =====================================================================
    # N — renew
    # =====================================================================
    $hN = New-TestHome -Name 'home-renew' -ConfigJson $stdConfig
    $n0 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -RunId 'run-n' -Project 'proj-a' -TtlSec 30 -BatonHome $hN
    Check 'N1 seed claim granted' ($n0.granted -eq $true)
    $beforeExp = ConvertFrom-CoordTimestamp $n0.claim.expires_at
    Start-Sleep -Milliseconds 1100
    $n1 = Update-ResourceClaim -ClaimId $n0.claim.claim_id -BatonHome $hN
    $afterExp = ConvertFrom-CoordTimestamp $n1.claim.expires_at
    Check 'N2 renew succeeds for the holder' ($n1.ok -eq $true -and $n1.reason -eq 'renewed')
    Check 'N3 renew extends expires_at' ($afterExp -gt $beforeExp)
    Check 'N4 renew stamps renewed_at' (
        (ConvertFrom-CoordTimestamp $n1.claim.renewed_at) -gt (ConvertFrom-CoordTimestamp $n0.claim.renewed_at))
    Check 'N5 renew persisted to disk' (
        (ConvertFrom-CoordTimestamp ((Get-Content -LiteralPath (Get-CoordClaimPath -ClaimId $n0.claim.claim_id -BatonHome $hN) -Raw | ConvertFrom-Json).expires_at)) -eq $afterExp)

    # Non-holder: rewrite the row so a different (live) pid owns it.
    $script:fakeProcs[5555] = @{ started_at = $script:selfStart }
    [void](Write-TestClaim -HomeDir $hN -ClaimId 'claim-foreign' -HolderPid 5555 -ExpiresInSec 600 -LoadProfile 'model-small' -VramGb 8)
    $n6 = Update-ResourceClaim -ClaimId 'claim-foreign' -BatonHome $hN
    Check 'N6 renew by a non-holder fails' ($n6.ok -eq $false -and $n6.reason -eq 'not_holder')
    Check 'N7 a failed renew leaves the claim untouched' (
        Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId 'claim-foreign' -BatonHome $hN))
    $n8 = Update-ResourceClaim -ClaimId 'no-such-claim' -BatonHome $hN
    Check 'N8 renewing an unknown claim id is not_found (no throw)' ($n8.ok -eq $false -and $n8.reason -eq 'not_found')
    [void](Write-TestClaim -HomeDir $hN -ClaimId 'claim-gone' -ExpiresInSec -10 -LoadProfile 'model-mid' -VramGb 8)
    $n9 = Update-ResourceClaim -ClaimId 'claim-gone' -BatonHome $hN
    Check 'N9 an expired claim cannot be renewed back to life' ($n9.ok -eq $false -and $n9.reason -eq 'expired')

    # =====================================================================
    # W — weights: precedence, and RULE 4 (no preemption)
    # =====================================================================
    $hW = New-TestHome -Name 'home-weights' -ConfigJson $stdConfig
    Set-Content -LiteralPath (Join-Path (Get-CoordinationRoot -BatonHome $hW) 'weights.json') `
        -Value '{ "schema": 1, "default": 100, "projects": { "proj-heavy": 200, "proj-night": 50 } }' -Encoding utf8NoBOM
    Check 'W1 explicit weight wins over everything' (
        (Get-ProjectWeight -Project 'proj-heavy' -Explicit 777 -BatonHome $hW) -eq 777)
    Check 'W2 project entry wins over default' (
        (Get-ProjectWeight -Project 'proj-heavy' -BatonHome $hW) -eq 200)
    Check 'W3 second project entry resolves independently' (
        (Get-ProjectWeight -Project 'proj-night' -BatonHome $hW) -eq 50)
    Check 'W4 unknown project falls back to default' (
        (Get-ProjectWeight -Project 'proj-unknown' -BatonHome $hW) -eq 100)
    $hW2 = New-TestHome -Name 'home-noweights' -ConfigJson $stdConfig
    Check 'W5 missing weights.json falls back to default 100' (
        (Get-ProjectWeight -Project 'proj-any' -BatonHome $hW2) -eq 100)

    $wGrant = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-large' `
        -VramGb 17 -Project 'proj-night' -RunId 'run-low' -BatonHome $hW
    Check 'W6 weight is resolved onto the claim row (annotation)' (
        $wGrant.granted -eq $true -and [int]$wGrant.claim.weight -eq 50)

    # RULE 4: a far heavier request must NOT evict or outrank the live low-weight claim.
    $p1 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-mid' `
        -VramGb 8 -Project 'proj-heavy' -Weight 9000 -RunId 'run-high' -BatonHome $hW
    Check 'P1 a heavier-weight claim does NOT preempt a live claim (stack exclusivity holds)' (
        $p1.granted -eq $false -and $p1.reason -eq 'stack_exclusive')
    Check 'P2 the low-weight claim survives the heavy request' (
        Test-Path -LiteralPath (Get-CoordClaimPath -ClaimId $wGrant.claim.claim_id -BatonHome $hW))
    $p3 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-mid' `
        -VramGb 20 -Project 'proj-heavy' -Weight 9000 -RunId 'run-high2' -BatonHome $hW
    Check 'P3 weight never buys capacity that is not there' (
        $p3.granted -eq $false -and $p3.reason -eq 'capacity')
    Check 'P4 the live set is unchanged after both heavy denials (no eviction)' (
        @(Get-ResourceClaims -HostName 'host-a' -BatonHome $hW).Count -eq 1)
    $p5 = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-a' -LoadProfile 'model-small' `
        -VramGb 8 -Project 'proj-night' -Weight 1 -RunId 'run-tiny' -BatonHome $hW
    Check 'P5 a minimum-weight request is granted when capacity allows (weight orders nothing)' (
        $p5.granted -eq $true)

    # =====================================================================
    # J — journal
    # =====================================================================
    $jrn = @(Get-CoordJournal -BatonHome $hW)
    Check 'J1 journal recorded a grant' (@($jrn | Where-Object { $_.event -eq 'grant' }).Count -ge 1)
    Check 'J2 journal recorded a deny with its reason' (
        @($jrn | Where-Object { $_.event -eq 'deny' -and $_.reason -eq 'stack_exclusive' }).Count -ge 1)
    Add-Content -LiteralPath (Get-CoordJournalPath -BatonHome $hW) -Value '{ torn line' -Encoding utf8NoBOM
    Check 'J3 malformed journal lines are skipped by the reader' (
        @(Get-CoordJournal -BatonHome $hW).Count -eq $jrn.Count)
}
catch {
    Write-Host "FAIL: suite threw — $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $script:fail++
}
finally {
    if ($null -eq $prevHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue } else { $env:BATON_HOME = $prevHome }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail CHECK(S) FAILED"; exit 1 }
Write-Host 'ALL CHECKS PASS'
