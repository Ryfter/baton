#!/usr/bin/env pwsh
<# Hermetic tests for scripts/officers-lib.ps1 (baton-d133 officers).
   The inner battery runs several times — officers must be stable, not flaky. #>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/officers-lib.ps1"

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

function Invoke-OfficerBattery {
    param([int]$Pass)
    $tag = "p$Pass"

    $reg = Get-OfficerRegistry
    $vr = Test-OfficerRegistry -Registry $reg
    Check "$tag registry ok" ($vr.ok -eq $true)
    Check "$tag four officers" (@($reg.officers).Count -eq 4)
    Check "$tag efficiency never blocks" ((@($reg.officers | Where-Object id -eq 'efficiency')[0].blocks_labor) -eq 'never')
    Check "$tag vram briefly blocks" ((@($reg.officers | Where-Object id -eq 'vram')[0].blocks_labor) -eq 'briefly')
    Check "$tag scheduler eligibility-only" ((@($reg.officers | Where-Object id -eq 'scheduler')[0].blocks_labor) -eq 'eligibility-only')
    Check "$tag systems does not mutex" ((@($reg.officers | Where-Object id -eq 'systems')[0].blocks_labor) -eq 'no')

    $now = [datetime]'2026-08-23T12:00:00Z'
    $box = Join-Path ([System.IO.Path]::GetTempPath()) ("officers-$tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $box | Out-Null
    try {
        $plain = [pscustomobject]@{ id = 'mj-1'; project = 'baton'; tags = @(); goal = 'ship docs' }
        $e0 = Get-SchedulerEligibility -Job $plain -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 10; window_7d_used_pct = 20; window_5h_hard = $false; residue = $false
        }
        Check "$tag ordinary job eligible" ($e0.eligible -eq $true -and $e0.state -eq 'queued')

        $fableJob = [pscustomobject]@{ id = 'mj-f'; tags = @('fable'); wants_fable = $true }
        Record-SchedulerFableFire -Now $now.AddHours(-0.2) -BatonHome $box
        $eF = Get-SchedulerEligibility -Job $fableJob -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 10; window_7d_used_pct = 20; window_5h_hard = $false; residue = $false
        }
        Check "$tag fable within 1h waits" ($eF.eligible -eq $false -and $eF.state -eq 'waiting-quota' -and $eF.reason -match 'fable')

        Record-SchedulerFableFire -Now $now.AddHours(-2) -BatonHome $box
        $eF2 = Get-SchedulerEligibility -Job $fableJob -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 10; window_7d_used_pct = 20; window_5h_hard = $false; residue = $false
        }
        Check "$tag fable after 1h eligible" ($eF2.eligible -eq $true)

        $hard = Get-SchedulerEligibility -Job $plain -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 100; window_7d_used_pct = 40; window_5h_hard = $true; residue = $false
        }
        Check "$tag 5h hard waits" ($hard.eligible -eq $false -and $hard.state -eq 'waiting-quota')
        Check "$tag nested residue hints pull-earlier" ($hard.hint -eq 'pull-earlier')

        $xc = [pscustomobject]@{ id = 'mj-x'; tags = @('excess_capacity'); class = 'excess_capacity' }
        $xcHold = Get-SchedulerEligibility -Job $xc -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 100; window_7d_used_pct = 40; window_5h_hard = $true; residue = $false
        }
        Check "$tag excess held without residue" ($xcHold.eligible -eq $false -and $xcHold.state -eq 'excess_capacity')
        Check "$tag excess does not dump into saturated 5h" ($xcHold.hint -eq 'pull-earlier')

        $xcGo = Get-SchedulerEligibility -Job $xc -Now $now -BatonHome $box -Windows @{
            window_5h_used_pct = 20; window_7d_used_pct = 40; window_5h_hard = $false; residue = $true
        }
        Check "$tag excess released when residue" ($xcGo.eligible -eq $true)

        $unknown = Get-SchedulerEligibility -Job $plain -Now $now -BatonHome $box
        Check "$tag unknown windows do not block ordinary jobs" ($unknown.eligible -eq $true)

        $lean = Invoke-EfficiencyAdvise -Task ([pscustomobject]@{ desc = 'fix typo'; capability = 'summarize'; est_cost_tier = 'paid' })
        Check "$tag efficiency never blocked" ($lean.blocked -eq $false)
        Check "$tag paid summarize suggests free" ($lean.cheaper_tier -eq 'free')
        Check "$tag tiny task stays lean" ($lean.reason -in @('already-lean', 'cheaper-seat'))
        Check "$tag prompt always starts Task:" ($lean.prompt -match '^Task:')

        $codeTask = [pscustomobject]@{
            desc           = 'Rewrite the conductor plan parser so allowed_paths become worktree-relative and add regression tests covering tilde and origin-checkout paths'
            capability     = 'code-gen'
            est_cost_tier  = 'free'
            allowed_paths  = @('scripts/conductor-lib.ps1')
        }
        $repo = Split-Path -Parent $PSScriptRoot
        $code = Invoke-EfficiencyAdvise -Task $codeTask -RepoRoot $repo
        Check "$tag code-gen appends pwsh profile" ($code.applied -eq $true -and $code.prompt -match 'pwsh')
        Check "$tag code-gen still not blocked" ($code.blocked -eq $false)
        Check "$tag worth-it rejects tiny+huge extra" (-not (Test-EfficiencyWorthIt -TaskDesc 'x' -ExtraBytes 5000))
        Check "$tag worth-it accepts real task + modest extra" (Test-EfficiencyWorthIt -TaskDesc ('rewrite the parser ' * 8) -ExtraBytes 200)

        $alive = { param($p) $p -eq 4242 }
        $c1 = Request-VramClaim -HostKey 'gpu-a' -Profile 'exclusive-large' -Model 'model-30b' -RunId 'r1' `
            -HolderPid 4242 -Now $now -BatonHome $box -TtlSeconds 60 -IsPidAlive $alive
        Check "$tag vram exclusive claimed" ($c1.ok -eq $true -and $c1.claim.profile -eq 'exclusive-large')
        $c2 = Request-VramClaim -HostKey 'gpu-a' -Profile 'exclusive-large' -Model 'model-30b' -RunId 'r2' `
            -HolderPid 4242 -Now $now -BatonHome $box -TtlSeconds 60 -IsPidAlive $alive
        Check "$tag second exclusive denied" ($c2.ok -eq $false -and $c2.reason -match 'serialize')
        $c3 = Request-VramClaim -HostKey 'gpu-a' -Profile 'shared-small' -Model 'model-9b' -RunId 'r3' `
            -HolderPid 4242 -Now $now -BatonHome $box -IsPidAlive $alive
        Check "$tag small denied while exclusive holds" ($c3.ok -eq $false -and $c3.reason -match 'exclusive-large')
        Check "$tag release exclusive" (Release-VramClaim -ClaimId $c1.claim.claim_id -HostKey 'gpu-a' -BatonHome $box)

        $s1 = Request-VramClaim -HostKey 'gpu-a' -Profile 'shared-small' -Model 'model-9b' -RunId 's1' `
            -HolderPid 4242 -Now $now -BatonHome $box -MaxShared 2 -IsPidAlive $alive
        $s2 = Request-VramClaim -HostKey 'gpu-a' -Profile 'shared-small' -Model 'model-9b' -RunId 's2' `
            -HolderPid 4242 -Now $now -BatonHome $box -MaxShared 2 -IsPidAlive $alive
        $s3 = Request-VramClaim -HostKey 'gpu-a' -Profile 'shared-small' -Model 'model-4b' -RunId 's3' `
            -HolderPid 4242 -Now $now -BatonHome $box -MaxShared 2 -IsPidAlive $alive
        Check "$tag two small ok" ($s1.ok -eq $true -and $s2.ok -eq $true)
        Check "$tag warm when same model loaded" ($s2.warm -eq $true)
        Check "$tag third small denied at cap" ($s3.ok -eq $false -and $s3.reason -match 'max')
        $exVsSmall = Request-VramClaim -HostKey 'gpu-a' -Profile 'exclusive-large' -Model 'model-30b' -RunId 'x' `
            -HolderPid 4242 -Now $now -BatonHome $box -IsPidAlive $alive
        Check "$tag exclusive denied while smalls live" ($exVsSmall.ok -eq $false)

        $dead = Request-VramClaim -HostKey 'gpu-b' -Profile 'exclusive-large' -Model 'm' -RunId 'd' `
            -HolderPid 99 -Now $now -BatonHome $box -IsPidAlive { param($p) $false }
        $reap = Request-VramClaim -HostKey 'gpu-b' -Profile 'exclusive-large' -Model 'm' -RunId 'd2' `
            -HolderPid 4242 -Now $now -BatonHome $box -IsPidAlive $alive
        Check "$tag dead-pid claim is written" ($dead.ok -eq $true)
        Check "$tag dead pid reclaimed" ($reap.ok -eq $true)

        $ttl1 = Request-VramClaim -HostKey 'gpu-c' -Profile 'exclusive-large' -Model 'm' -RunId 't' `
            -HolderPid 4242 -Now $now -BatonHome $box -TtlSeconds 30 -IsPidAlive $alive
        $later = $now.AddSeconds(31)
        $ttl2 = Request-VramClaim -HostKey 'gpu-c' -Profile 'exclusive-large' -Model 'm' -RunId 't2' `
            -HolderPid 4242 -Now $later -BatonHome $box -TtlSeconds 30 -IsPidAlive $alive
        Check "$tag ttl claim ok" ($ttl1.ok -eq $true)
        Check "$tag expired exclusive reclaimed" ($ttl2.ok -eq $true)

        Check "$tag 30b -> exclusive" ((Resolve-VramProfileForProvider -Provider @{ name = 'baton-workhorse'; model_default = 'qwen3-coder-30b' }) -eq 'exclusive-large')
        Check "$tag small -> shared" ((Resolve-VramProfileForProvider -Provider @{ name = 'lm-studio-small'; model_default = '9b' }) -eq 'shared-small')

        $facts = @{ os = 'Unix'; cpu_count = 8; gpu_gb = 32; npu = $true }
        $inv = Get-SystemsInventory -Facts $facts
        Check "$tag systems uses injected facts" ($inv.gpu_gb -eq 32 -and $inv.npu -eq $true)
        $stt = Get-SystemsPlacementAdvice -Kind stt -Inventory $inv
        Check "$tag STT prefers NPU" ($stt.target -eq 'npu' -and $stt.blocks -eq $false)
        $cg = Get-SystemsPlacementAdvice -Kind codegen -Inventory $inv
        Check "$tag codegen prefers GPU when 32GB" ($cg.target -eq 'gpu')
        $smallGpu = Get-SystemsPlacementAdvice -Kind codegen -Inventory @{ gpu_gb = 8; npu = $false }
        Check "$tag small GPU codegen -> cloud" ($smallGpu.target -eq 'cloud')
        $emb = Get-SystemsPlacementAdvice -Kind embed -Inventory @{ gpu_gb = 8; npu = $false }
        Check "$tag embed on small GPU" ($emb.target -eq 'gpu-small')
        $path = Save-SystemsInventory -Inventory $inv -BatonHome $box
        Check "$tag inventory persisted" ((Test-Path -LiteralPath $path) -and ((Get-Content $path -Raw) -match 'gpu_gb'))
        $lines = Get-OfficersDoctorLines -BatonHome $box
        Check "$tag doctor lines mention officers" (($lines -join "`n") -match 'officers: registry=ok')
    } finally {
        Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$repeats = 5
for ($i = 1; $i -le $repeats; $i++) {
    Write-Host "---- officer battery pass $i/$repeats ----"
    Invoke-OfficerBattery -Pass $i
}

if ($script:fail -gt 0) {
    Write-Host "$script:fail CHECK(S) FAILED across $repeats passes"
    exit 1
}
Write-Host "ALL CHECKS PASS ($repeats repeats)"
exit 0
