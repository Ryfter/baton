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
    $env:BATON_OFFICERS_NOPROBE = '1'

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

        $lmsJson = '{"models":[{"key":"google/gemma-4-e2b","size_bytes":5954405243,"format":"gguf","loaded_instances":[{"id":"google/gemma-4-e2b","remaining_ttl_seconds":100}]},{"key":"qwen/qwen3-coder-30b","size_bytes":25104903500,"format":"gguf","loaded_instances":[{"id":"qwen/qwen3-coder-30b","remaining_ttl_seconds":200}]},{"key":"idle-7b","size_bytes":4000000000,"loaded_instances":[]}]}'
        $parsed = @(ConvertFrom-OfficerLmStudioModels -RawJson $lmsJson)
        Check "$tag lms parser only loaded" ($parsed.Count -eq 2 -and $parsed[0].id -eq 'google/gemma-4-e2b')
        Check "$tag lms size_gb rounded" ($parsed[0].size_gb -eq 5.55)
        $gpuStub = { [ordered]@{ gpu_gb = 24; gpu_used_gb = $null; gpu_name = 'Apple M4'; npu = $true; source = 'apple-unified' } }
        $lmsStub = { param($url) $lmsJson }
        $liveInv = Get-SystemsInventory -GpuProber $gpuStub -LmsProber $lmsStub
        Check "$tag live inventory gpu_gb 24" ($liveInv.gpu_gb -eq 24 -and $liveInv.npu -eq $true)
        Check "$tag live inventory source apple-unified" ($liveInv.gpu_source -eq 'apple-unified')
        Check "$tag live inventory sees two loaded" ($liveInv.loaded_ids.Count -eq 2 -and $liveInv.loaded_ids -contains 'qwen/qwen3-coder-30b')
        $livePlace = Get-SystemsPlacementAdvice -Kind codegen -Inventory $liveInv
        Check "$tag codegen uses unified 24GB as gpu" ($livePlace.target -eq 'gpu' -and $livePlace.reason -match 'unified')
        $liveStt = Get-SystemsPlacementAdvice -Kind stt -Inventory $liveInv
        Check "$tag apple ANE is npu for STT" ($liveStt.target -eq 'npu')
        $deadLms = Get-OfficerLmStudioSnapshot -BaseUrl 'http://127.0.0.1:1' -Prober { throw 'refused' }
        Check "$tag lms down is fail-soft" ($deadLms.ok -eq $false -and @($deadLms.loaded).Count -eq 0)
        $vramLive = Get-VramInventory -HostKey 'gpu-a' -BatonHome $box -Now $now -IsPidAlive $alive -LmsProber $lmsStub
        Check "$tag vram inventory lists LMS loaded" ($vramLive.loaded_ids -contains 'google/gemma-4-e2b')
        $docLive = Get-OfficersDoctorLines -BatonHome $box -SystemsInventory $liveInv -VramInventory $vramLive
        Check "$tag doctor names loaded 30b" (($docLive -join "`n") -match 'qwen/qwen3-coder-30b')
        Check "$tag doctor names gpu source" (($docLive -join "`n") -match 'source=apple-unified')

        Check "$tag fable seat forbidden" (Test-SecuritySeatForbidden -Seat 'cursor-fable')
        Check "$tag sol seat forbidden" (Test-SecuritySeatForbidden -Seat 'gpt-5.6-sol')
        Check "$tag ox seat allowed" (-not (Test-SecuritySeatForbidden -Seat 'openrouter-glm'))
        $nowS = [datetime]'2026-08-23T12:00:00Z'
        $hotRec = [pscustomobject]@{ last_touched = '2026-08-23T10:00:00Z'; last_run = '2026-08-22T10:00:00Z' }
        Check "$tag touched-since-run is hot" ((Get-SecurityBand -Record $hotRec -Now $nowS) -eq 'hot')
        $warmRec = [pscustomobject]@{ last_touched = '2026-08-16T12:00:00Z'; last_run = '2026-08-20T12:00:00Z' }
        Check "$tag recent-clean is warm" ((Get-SecurityBand -Record $warmRec -Now $nowS) -eq 'warm')
        $coldRec = [pscustomobject]@{ last_touched = '2026-07-01T12:00:00Z'; last_run = '2026-07-15T12:00:00Z'; last_clean = '2026-07-15T12:00:00Z' }
        Check "$tag stale+clean is cold" ((Get-SecurityBand -Record $coldRec -Now $nowS) -eq 'cold')
        $hotDue = Get-SecurityRecipe -Project 'baton' -Record $hotRec -Now $nowS
        Check "$tag hot recipe nightly ox" ($hotDue.due -eq $true -and $hotDue.cadence -eq 'nightly' -and $hotDue.seat -eq 'openrouter-glm')
        Check "$tag recipe denies fable" ($hotDue.deny_seats -contains 'fable' -and $hotDue.grimlore_to_ox -eq $false)
        $deep = Get-SecurityRecipe -Project 'baton' -Record $warmRec -Now $nowS -Deep
        Check "$tag deep seats opus not fable" ($deep.seat -eq 'opus' -and -not (Test-SecuritySeatForbidden -Seat $deep.seat))
        $coldR = Get-SecurityRecipe -Project 'old' -Record $coldRec -Now $nowS
        Check "$tag cold is monthly local" ($coldR.band -eq 'cold' -and $coldR.cadence -match 'monthly' -and $coldR.seat -eq 'local')
        [void](Update-SecurityScale -Project 'baton' -Now $nowS -Touched $nowS.AddHours(-2) -BatonHome $box)
        $scalePath = Get-SecurityScalePath -BatonHome $box
        Check "$tag security scale persisted" ((Test-Path -LiteralPath $scalePath) -and ((Get-Content $scalePath -Raw) -match 'last_run'))

        $rev = Invoke-EfficiencyProfileReview -RepoRoot (Split-Path -Parent $PSScriptRoot)
        Check "$tag profile review never blocks" ($rev.blocked -eq $false)
        Check "$tag shipped profiles are lean" ($rev.ok -eq $true)
        $fatDir = Join-Path $box 'references/coding-profiles'
        New-Item -ItemType Directory -Force -Path $fatDir | Out-Null
        foreach ($l in @('python','pwsh','typescript','javascript','nodejs','react','html-css')) {
            Set-Content -LiteralPath (Join-Path $fatDir "$l.md") -Value ("# $l`n" + ("leverage robustly`n" * 50)) -Encoding utf8NoBOM
        }
        $fat = Invoke-EfficiencyProfileReview -RepoRoot $box
        Check "$tag fat profiles fail review" ($fat.ok -eq $false -and $fat.blocked -eq $false)
        Check "$tag fat profile names bloat" (@($fat.findings | Where-Object { $_.reasons -contains 'promotional-language' }).Count -ge 1)

        $planAdv = Invoke-EfficiencyPlanAdvise -Plan ([pscustomobject]@{
            tasks = @([pscustomobject]@{ id = 't1'; desc = 'sum it'; capability = 'summarize'; est_cost_tier = 'paid' })
        })
        Check "$tag plan advise never blocks" ($planAdv.blocked -eq $false)
        Check "$tag plan advise cheapens summarize" ($planAdv.plan.tasks[0].est_cost_tier -eq 'free')

        $skipGl = Invoke-SecurityScannerSpine -RepoPath '/Users/kev/Dev/Grimlore'
        Check "$tag scanner skips grimlore" ($skipGl.ok -eq $false -and $skipGl.reason -eq 'grimlore-skipped')
        $scan = Invoke-SecurityScannerSpine -RepoPath $box `
            -GitLog { param($r,$s) @('abc123 fix todo') } `
            -GitDiff { param($r) 'scripts/officers-lib.ps1 | 2 +-' } `
            -Ripgrep { param($r) @("$r/foo.ps1:3: TODO secret-looking") }
        Check "$tag scanner ok from injectors" ($scan.ok -eq $true -and $scan.hit_n -eq 1)
        Check "$tag scanner keeps log" ($scan.log[0] -match 'abc123')

        $scaleDue = Read-SecurityScale -BatonHome $box
        $scaleDue.projects['due-proj'] = [ordered]@{
            last_touched = '2026-08-23T10:00:00Z'
            last_run     = '2026-08-22T10:00:00Z'
            last_clean   = $null
        }
        Write-SecurityScale -Scale $scaleDue -BatonHome $box
        $dueList = Get-SecurityDueProjects -Now $nowS -BatonHome $box
        Check "$tag due projects lists hot" (@($dueList | Where-Object { $_.project -eq 'due-proj' }).Count -eq 1)
        $scaleFresh = Read-SecurityScale -BatonHome $box
        $scaleFresh.projects['fresh'] = [ordered]@{
            last_touched = '2026-08-20T12:00:00Z'
            last_run     = '2026-08-23T11:00:00Z'
            last_clean   = $null
        }
        Write-SecurityScale -Scale $scaleFresh -BatonHome $box
        $skipScan2 = Invoke-SecurityProjectScan -Project 'fresh' -RepoPath $box -Now $nowS -BatonHome $box `
            -GitLog { param($r,$s) @() } -GitDiff { param($r) '' } -Ripgrep { param($r) @() }
        Check "$tag scan skips when not due" ($skipScan2.skipped -eq $true -and $skipScan2.reason -eq 'not-due')
        $forceScan = Invoke-SecurityProjectScan -Project 'fresh' -RepoPath $box -Now $nowS -BatonHome $box -Force `
            -GitLog { param($r,$s) @('forced') } -GitDiff { param($r) '' } -Ripgrep { param($r) @() }
        Check "$tag force scan runs anyway" ($forceScan.ok -eq $true -and (Test-Path -LiteralPath $forceScan.report))
        $batch = Invoke-SecurityDueScans -BatonHome $box -DefaultRepo $box -MaxScans 2 -Now $nowS `
            -ProjectRepos @{ 'due-proj' = $box }
        Check "$tag due batch caps scans" ($batch.scanned -le 2)
        Check "$tag due batch reports results" (@($batch.results).Count -ge 1)

        $coldHeld = Get-SecurityRecipe -Project 'old' -Record $coldRec -Now $nowS -Windows @{
            window_5h_used_pct = 100; window_7d_used_pct = 40; window_5h_hard = $true; residue = $false
        }
        Check "$tag cold held without residue" ($coldHeld.due_by_cadence -eq $true -and $coldHeld.due -eq $false -and $coldHeld.held_reason -match 'excess_capacity')
        $coldGo = Get-SecurityRecipe -Project 'old' -Record $coldRec -Now $nowS -Windows @{
            window_5h_used_pct = 20; window_7d_used_pct = 40; window_5h_hard = $false; residue = $true
        }
        Check "$tag cold runs on residue" ($coldGo.due -eq $true)

        $seedDue = Get-SecurityDueProjects -Now $nowS -BatonHome $box -RegistryProjects @(
            [ordered]@{ id = 'never-scanned'; folder = $box }
        )
        Check "$tag registry seed never-scanned due" (@($seedDue | Where-Object { $_.project -eq 'never-scanned' }).Count -eq 1)

        $prompt = Format-SecurityInterpretPrompt -Project 'baton' -Scan $scan
        Check "$tag interpret prompt cites project" ($prompt -match 'baton' -and $prompt -match 'abc123')
        $interp = Invoke-SecurityInterpret -Project 'baton' -Scan $scan -Recipe $hotDue -Dispatcher {
            param($prov, $p) [ordered]@{ stdout = 'high: TODO hit may hide secret'; exit_code = 0 }
        }
        Check "$tag interpret via injector" ($interp.ok -eq $true -and $interp.text -match 'high:')
        Check "$tag opus maps to cursor-opus" ((Resolve-SecurityFleetProvider -Seat 'opus') -eq 'cursor-opus')
        $withIx = Invoke-SecurityProjectScan -Project 'due-proj' -RepoPath $box -Now $nowS -BatonHome $box -Force `
            -DoInterpret -GitLog { param($r,$s) @('ix1') } -GitDiff { param($r) 'a | 1 +' } `
            -Ripgrep { param($r) @("$r/x:1: TODO") } -InterpretDispatcher {
                param($prov, $p) [ordered]@{ stdout = 'med: review TODO'; exit_code = 0 }
            }
        Check "$tag scan stores interpret" ($withIx.interpret.ok -eq $true -and (Test-Path -LiteralPath $withIx.report))
        $noSig = Invoke-SecurityProjectScan -Project 'due-proj' -RepoPath $box -Now $nowS -BatonHome $box -Force `
            -DoInterpret -InterpretOnlyOnSignal `
            -GitLog { param($r,$s) @() } -GitDiff { param($r) '' } -Ripgrep { param($r) @() }
        Check "$tag interpret skipped without signal" ($null -eq $noSig.interpret)

        Check "$tag med interpret needs deep" (Test-SecurityInterpretNeedsDeep -Interpret @{ ok = $true; text = 'med: check auth' })
        Check "$tag low interpret skips deep" (-not (Test-SecurityInterpretNeedsDeep -Interpret @{ ok = $true; text = 'low: style' }))
        Check "$tag high outcome is fail" ((Get-SecurityScanQualityOutcome -Scan $scan -Interpret @{ ok = $true; text = 'high: secret in TODO' }) -eq 'fail')
        $scaleDeepMq = Read-SecurityScale -BatonHome $box
        $scaleDeepMq.projects['deep-proj'] = [ordered]@{
            last_touched = '2026-08-23T10:00:00Z'
            last_run     = '2026-08-22T10:00:00Z'
            last_clean   = $null
        }
        Write-SecurityScale -Scale $scaleDeepMq -BatonHome $box
        $mqRows = [System.Collections.Generic.List[object]]::new()
        $batchMq = Invoke-SecurityDueScans -BatonHome $box -DefaultRepo $box -MaxScans 1 -MaxDeepScans 1 -Now $nowS `
            -ProjectRepos @{ 'deep-proj' = $box } -DoInterpret -DeepOnResidue -Windows @{
                window_5h_used_pct = 20; window_7d_used_pct = 40; window_5h_hard = $false; residue = $true
            } -InterpretDispatcher {
                param($prov, $p) [ordered]@{ stdout = 'med: review auth path'; exit_code = 0 }
            }
        [void](Record-SecurityScanQuality -BatchResult $batchMq -BatonHome $box -Writer {
            param($Provider, $Model, $TaskClass, $Outcome, $EvidenceRef, $Notes)
            $mqRows.Add([ordered]@{ provider = $Provider; task_class = $TaskClass; outcome = $Outcome })
        })
        Check "$tag quality records spine" (@($mqRows | Where-Object { $_.task_class -eq 'security.spine' }).Count -ge 1)
        Check "$tag deep on residue fires" ($batchMq.deep -eq 1)
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
