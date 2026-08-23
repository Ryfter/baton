#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Factory officers (baton-d133): Scheduler, Efficiency, VRAM, Systems.
.DESCRIPTION
  Deterministic sidecars. Scheduler injects eligibility (does not admit).
  Efficiency Officer never blocks labor. VRAM officer may briefly deny local
  dispatch. Systems agent inventories hardware and recommends placement.
  No new LM agents — these are code.
#>
. (Join-Path $PSScriptRoot 'efficiency-lib.ps1')

function Get-OfficerBatonHome {
    param([string]$BatonHome)
    if (-not [string]::IsNullOrWhiteSpace($BatonHome)) { return $BatonHome }
    if ($env:BATON_HOME) { return $env:BATON_HOME }
    return (Join-Path $HOME '.baton')
}

function ConvertTo-OfficerUtc {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [DateTimeKind]::Utc) { return $dt }
        if ($dt.Kind -eq [DateTimeKind]::Local) { return $dt.ToUniversalTime() }
        return [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc)
    }
    try {
        return [datetime]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    } catch { return $null }
}

function ConvertTo-OfficerFsKey {
    param([string]$Name = '')
    $s = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'local' }
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
    return $s
}

function Get-OfficerRegistry {
    <# Canonical four-officer table. Matches docs/officer-registry.schema.json. #>
    return [ordered]@{
        schema_version = 1
        decision       = 'baton-d133'
        officers       = @(
            [ordered]@{
                id           = 'scheduler'
                role         = 'Scheduler'
                level        = 'maestro-sidecar'
                blocks_labor = 'eligibility-only'
                job          = 'Nested 5h vs week/month windows, Fable <=1/h, excess_capacity tags. Does not admit.'
                enabled      = $true
            }
            [ordered]@{
                id           = 'efficiency'
                role         = 'Efficiency Officer'
                level        = 'conductor-sidecar'
                blocks_labor = 'never'
                job          = 'Token/process optimize, prompt reuse, lean language profiles, anti-overengineering.'
                enabled      = $true
            }
            [ordered]@{
                id           = 'vram'
                role         = 'VRAM officer'
                level        = 'maestro-adjacent'
                blocks_labor = 'briefly'
                job          = 'Inventory loaded models; exclusive 1x large vs shared Nx small; serialize; prefer warm; TTL unload.'
                enabled      = $true
            }
            [ordered]@{
                id           = 'systems'
                role         = 'Systems agent'
                level        = 'factory-inventory'
                blocks_labor = 'no'
                job          = 'Catalog GPU/NPU/CPU/RAM/Pi/edge; recommend placement; feed health canary. Discovery is not a mutex.'
                enabled      = $true
            }
        )
    }
}

function Test-OfficerRegistry {
    param($Registry = (Get-OfficerRegistry))
    $out = [ordered]@{ ok = $false; reason = '' }
    if ($null -eq $Registry) { $out.reason = 'missing'; return $out }
    if ([int]$Registry.schema_version -ne 1) { $out.reason = 'schema_version'; return $out }
    $ids = @($Registry.officers | ForEach-Object { [string]$_.id })
    $want = @('scheduler', 'efficiency', 'vram', 'systems')
    if (@($ids).Count -ne 4) { $out.reason = 'count'; return $out }
    foreach ($w in $want) {
        if ($ids -notcontains $w) { $out.reason = "missing:$w"; return $out }
    }
    if (@($ids | Select-Object -Unique).Count -ne 4) { $out.reason = 'duplicate-id'; return $out }
    $eff = @($Registry.officers | Where-Object { $_.id -eq 'efficiency' })[0]
    if ([string]$eff.blocks_labor -ne 'never') { $out.reason = 'efficiency-must-never-block'; return $out }
    $vram = @($Registry.officers | Where-Object { $_.id -eq 'vram' })[0]
    if ([string]$vram.blocks_labor -ne 'briefly') { $out.reason = 'vram-must-briefly-block'; return $out }
    $out.ok = $true
    return $out
}

# ---------- Scheduler ----------

function Get-SchedulerStatePath {
    param([string]$BatonHome = (Get-OfficerBatonHome))
    return (Join-Path $BatonHome 'officers/scheduler-state.json')
}

function Read-SchedulerState {
    param([string]$BatonHome = (Get-OfficerBatonHome))
    $path = Get-SchedulerStatePath -BatonHome $BatonHome
    $empty = [ordered]@{ last_fable_at = $null; last_hint = $null }
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [ordered]@{
            last_fable_at = $(if ($doc.last_fable_at) { [string]$doc.last_fable_at } else { $null })
            last_hint     = $(if ($doc.last_hint) { [string]$doc.last_hint } else { $null })
        }
    } catch { return $empty }
}

function Write-SchedulerState {
    param(
        [Parameter(Mandatory)]$State,
        [string]$BatonHome = (Get-OfficerBatonHome)
    )
    $dir = Split-Path (Get-SchedulerStatePath -BatonHome $BatonHome) -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($State | ConvertTo-Json -Compress) | Set-Content -LiteralPath (Get-SchedulerStatePath -BatonHome $BatonHome) -Encoding utf8NoBOM
}

function Record-SchedulerFableFire {
    param(
        [datetime]$Now = [datetime]::UtcNow,
        [string]$BatonHome = (Get-OfficerBatonHome)
    )
    $st = Read-SchedulerState -BatonHome $BatonHome
    $utc = ConvertTo-OfficerUtc -Value $Now
    if ($null -eq $utc) { $utc = [datetime]::UtcNow }
    $st.last_fable_at = $utc.ToUniversalTime().ToString('o')
    Write-SchedulerState -State $st -BatonHome $BatonHome
}

function Test-JobWantsFable {
    param($Job)
    if ($null -eq $Job) { return $false }
    if ($Job.wants_fable -eq $true) { return $true }
    foreach ($t in @($Job.tags)) {
        if ([string]$t -eq 'fable') { return $true }
    }
    foreach ($field in @('seat', 'provider', 'model_pick', 'model')) {
        $v = [string]($Job.$field)
        if ($v -match '(?i)fable') { return $true }
    }
    return $false
}

function Test-JobExcessCapacity {
    param($Job)
    if ($null -eq $Job) { return $false }
    if ([string]$Job.class -eq 'excess_capacity') { return $true }
    foreach ($t in @($Job.tags)) {
        if ([string]$t -eq 'excess_capacity') { return $true }
    }
    return $false
}

function Get-SchedulerWindowSnapshot {
    <# Live window snapshot. Unknown meters do not block ordinary jobs.
       Excess-capacity release requires an explicit residue=$true. #>
    param(
        [string]$BatonHome = (Get-OfficerBatonHome),
        $Now,
        $Override
    )
    if ($null -ne $Override) { return $Override }
    $snap = [ordered]@{
        window_5h_used_pct = $null
        window_7d_used_pct = $null
        window_5h_hard     = $false
        residue            = $false
    }
    if (-not (Get-Command Get-WindowBudgetStatus -ErrorAction SilentlyContinue)) { return $snap }
    try {
        $st = Get-WindowBudgetStatus -Window both -Now $Now -BatonHome $BatonHome
        $used5 = $null
        $used7 = $null
        foreach ($row in @($st.models)) {
            if ($null -ne $row.used_pct -and $row.used_pct.'5h' -ne $null) {
                $u = [double]$row.used_pct.'5h'
                if ($null -eq $used5 -or $u -gt $used5) { $used5 = $u }
            }
            if ($null -ne $row.used_pct -and $row.used_pct.'7d' -ne $null) {
                $u = [double]$row.used_pct.'7d'
                if ($null -eq $used7 -or $u -gt $used7) { $used7 = $u }
            }
        }
        $snap.window_5h_used_pct = $used5
        $snap.window_7d_used_pct = $used7
        if ($null -ne $used5 -and $used5 -ge 100) { $snap.window_5h_hard = $true }
        # Residue: weekly still has room AND the 5h window can still burn.
        if ($null -ne $used7 -and $used7 -lt 95 -and -not $snap.window_5h_hard) {
            $snap.residue = $true
        }
    } catch { }
    return $snap
}

function Get-SchedulerEligibility {
    <# Eligibility only. Never admits. Returns { eligible; state; reason; hint }.
       state is queued | waiting-quota | excess_capacity. #>
    param(
        [Parameter(Mandatory)]$Job,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$BatonHome = (Get-OfficerBatonHome),
        $State,
        $Windows,
        [double]$FableMinHours = 1.0
    )
    $out = [ordered]@{
        eligible = $true
        state    = 'queued'
        reason   = ''
        hint     = $null
        officer  = 'scheduler'
    }
    if ($null -eq $State) { $State = Read-SchedulerState -BatonHome $BatonHome }
    $win = Get-SchedulerWindowSnapshot -BatonHome $BatonHome -Now $Now -Override $Windows
    $excess = Test-JobExcessCapacity -Job $Job
    $fable = Test-JobWantsFable -Job $Job

    if ($fable -and $State.last_fable_at) {
        $last = ConvertTo-OfficerUtc -Value $State.last_fable_at
        $nowUtc = ConvertTo-OfficerUtc -Value $Now
        if ($null -ne $last -and $null -ne $nowUtc) {
            $hours = ($nowUtc - $last).TotalHours
            if ($hours -ge 0 -and $hours -lt $FableMinHours) {
                $out.eligible = $false
                $out.state = 'waiting-quota'
                $out.reason = "fable<=1/h: last fire $([math]::Round($hours, 2))h ago"
                return $out
            }
        }
    }

    if ($win.window_5h_hard -and -not $excess) {
        $out.eligible = $false
        $out.state = 'waiting-quota'
        $out.reason = '5h window exhausted'
        if ($null -ne $win.window_7d_used_pct -and [double]$win.window_7d_used_pct -lt 95) {
            $out.hint = 'pull-earlier'
        }
        return $out
    }

    if ($excess) {
        if (-not [bool]$win.residue) {
            $out.eligible = $false
            $out.state = 'excess_capacity'
            $out.reason = 'excess_capacity held: no residue (or 5h cannot burn it)'
            if ($null -ne $win.window_7d_used_pct -and [double]$win.window_7d_used_pct -lt 95 -and [bool]$win.window_5h_hard) {
                $out.hint = 'pull-earlier'
            }
            return $out
        }
        $out.reason = 'excess_capacity released: residue available'
        return $out
    }

    $out.reason = 'eligible'
    return $out
}

# ---------- Efficiency Officer ----------

function Test-EfficiencyWorthIt {
    <# Anti-overengineering: a "save" that costs more coordination than it saves is skipped. #>
    param(
        [string]$TaskDesc = '',
        [int]$ExtraBytes = 0,
        [int]$LeanCeiling = 240
    )
    $n = [Text.Encoding]::UTF8.GetByteCount([string]$TaskDesc)
    if ($n -lt 40) { return $false }
    if ($ExtraBytes -gt 2000) { return $false }
    if ($n -lt $LeanCeiling -and $ExtraBytes -gt (4 * [math]::Max($n, 1))) { return $false }
    return $true
}

function Invoke-EfficiencyAdvise {
    <# Never blocks. Fail-open. Returns a possibly-reshaped prompt and optional cheaper seat. #>
    param(
        $Task,
        [string]$RepoRoot,
        [string]$RepoPath,
        [string]$RunDir,
        [string]$Language
    )
    $out = [ordered]@{
        blocked      = $false
        applied      = $false
        prompt       = ''
        cheaper_tier = $null
        reason       = 'identity'
        officer      = 'efficiency'
    }
    try {
        $desc = if ($null -ne $Task -and $Task.desc) { [string]$Task.desc } else { '' }
        $cap = if ($null -ne $Task) { [string]$Task.capability } else { '' }
        $tier = if ($null -ne $Task) { [string]$Task.est_cost_tier } else { '' }
        $root = $RepoRoot
        if (-not $root) { $root = $RepoPath }
        $basePrompt = "Task: $desc"
        $out.prompt = $basePrompt

        if ($root -or $RunDir) {
            $built = Build-EfficiencyTaskPrompt -TaskDesc $desc -RepoPath $root -RunDir $RunDir
            if ($built -and $built -ne $basePrompt) {
                $out.prompt = $built
                $out.applied = $true
                $out.reason = 'context-select'
            }
        }

        if ($tier -eq 'paid' -and $cap -in @('summarize', 'research', 'triage')) {
            $out.cheaper_tier = 'free'
            $out.applied = $true
            if ($out.reason -eq 'identity') { $out.reason = 'cheaper-seat' }
        }

        $lang = $Language
        if (-not $lang -and $cap -in @('code-gen', 'code-transform')) {
            $lang = 'python'
            $joined = (@($Task.allowed_paths) -join ' ')
            if ($joined -match '\.ps1\b') { $lang = 'pwsh' }
            elseif ($joined -match '\.tsx?\b') { $lang = 'typescript' }
            elseif ($joined -match '\.jsx?\b') { $lang = 'javascript' }
        }
        $profile = ''
        if ($lang) { $profile = Get-CodingProfile -Language $lang -RepoRoot $root }
        $extra = if ($profile) { [Text.Encoding]::UTF8.GetByteCount($profile) } else { 0 }
        if ($profile -and (Test-EfficiencyWorthIt -TaskDesc $desc -ExtraBytes $extra)) {
            $out.prompt = "$($out.prompt)`n`nCoding profile ($lang):`n$profile".Trim()
            $out.applied = $true
            if ($out.reason -eq 'identity') { $out.reason = 'appended-profile' }
        } elseif (-not $out.applied) {
            $out.reason = 'already-lean'
        }
    } catch {
        $out.prompt = if ($out.prompt) { $out.prompt } else { 'Task: ' }
        $out.reason = 'fail-open'
    }
    $out.blocked = $false
    return $out
}

# ---------- VRAM officer ----------

function Get-VramStoreDir {
    param([string]$BatonHome = (Get-OfficerBatonHome))
    return (Join-Path $BatonHome 'local-resource')
}

function Get-VramLockPath {
    param(
        [string]$HostKey = 'local',
        [string]$BatonHome = (Get-OfficerBatonHome)
    )
    $dir = Join-Path (Get-VramStoreDir -BatonHome $BatonHome) 'locks'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return (Join-Path $dir ((ConvertTo-OfficerFsKey $HostKey) + '__stack.lock'))
}

function Get-VramClaimsDir {
    param([string]$BatonHome = (Get-OfficerBatonHome))
    $dir = Join-Path (Get-VramStoreDir -BatonHome $BatonHome) 'claims'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Test-OfficerPidAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Read-VramLiveClaims {
    param(
        [string]$HostKey = 'local',
        [string]$BatonHome = (Get-OfficerBatonHome),
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$IsPidAlive
    )
    if (-not $IsPidAlive) { $IsPidAlive = { param($p) Test-OfficerPidAlive -ProcessId $p } }
    $prefix = (ConvertTo-OfficerFsKey $HostKey) + '__'
    $live = [System.Collections.Generic.List[object]]::new()
    $dir = Get-VramClaimsDir -BatonHome $BatonHome
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter ($prefix + '*.json') -File -ErrorAction SilentlyContinue)) {
        try {
            $c = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        } catch { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        $exp = $null
        try { $exp = [datetime]$c.expires_at } catch { }
        $pidOk = $true
        if ($null -ne $c.pid) {
            try { $pidOk = [bool](& $IsPidAlive ([int]$c.pid)) } catch { $pidOk = $false }
        }
        if (($null -ne $exp -and $exp.ToUniversalTime() -le $Now.ToUniversalTime()) -or -not $pidOk) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $c | Add-Member -NotePropertyName path -NotePropertyValue $f.FullName -Force
        $live.Add($c)
    }
    return @($live)
}

function Request-VramClaim {
    <# May briefly deny. Exclusive-large vs shared-small. Prefer warm same-model. #>
    param(
        [string]$HostKey = 'local',
        [ValidateSet('exclusive-large', 'shared-small')][string]$Profile = 'shared-small',
        [string]$Model = '',
        [string]$RunId = '',
        [int]$TtlSeconds = 120,
        [int]$MaxShared = 3,
        [int]$HolderPid = $PID,
        [datetime]$Now = [datetime]::UtcNow,
        [string]$BatonHome = (Get-OfficerBatonHome),
        [scriptblock]$IsPidAlive
    )
    $out = [ordered]@{
        ok      = $false
        reason  = ''
        claim   = $null
        warm    = $false
        officer = 'vram'
    }
    $lockPath = Get-VramLockPath -HostKey $HostKey -BatonHome $BatonHome
    $stream = $null
    $gotLock = $false
    try {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            $gotLock = $true
        } catch {
            # Stale lock: if older than 8s, steal once.
            $age = 999
            try { $age = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc).TotalSeconds } catch { }
            if ($age -gt 8) {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                try {
                    $stream = [System.IO.File]::Open(
                        $lockPath,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None
                    )
                    $gotLock = $true
                } catch {
                    $out.reason = 'admission-lock-busy'
                    return $out
                }
            } else {
                $out.reason = 'admission-lock-busy'
                return $out
            }
        }
        $live = @(Read-VramLiveClaims -HostKey $HostKey -BatonHome $BatonHome -Now $Now -IsPidAlive $IsPidAlive)
        $hasExclusive = @($live | Where-Object { [string]$_.profile -eq 'exclusive-large' }).Count -gt 0
        $sharedCount = @($live | Where-Object { [string]$_.profile -eq 'shared-small' }).Count
        $sameModel = @($live | Where-Object { [string]$_.model -eq [string]$Model -and $Model })
        if ($sameModel.Count -gt 0) { $out.warm = $true }

        if ($Profile -eq 'exclusive-large') {
            if ($live.Count -gt 0) {
                $out.reason = 'exclusive-large denied: GPU already claimed (serialize or fail over)'
                return $out
            }
        } else {
            if ($hasExclusive) {
                $out.reason = 'shared-small denied: exclusive-large holds the GPU'
                return $out
            }
            if ($sharedCount -ge $MaxShared) {
                $out.reason = "shared-small denied: $sharedCount >= max $MaxShared"
                return $out
            }
        }

        $id = ([guid]::NewGuid().ToString('N').Substring(0, 12))
        $claim = [ordered]@{
            claim_id   = $id
            host       = (ConvertTo-OfficerFsKey $HostKey)
            profile    = $Profile
            model      = [string]$Model
            run_id     = [string]$RunId
            pid        = [int]$HolderPid
            claimed_at = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            expires_at = $Now.ToUniversalTime().AddSeconds($TtlSeconds).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $path = Join-Path (Get-VramClaimsDir -BatonHome $BatonHome) ("$(ConvertTo-OfficerFsKey $HostKey)__$id.json")
        ($claim | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        $out.ok = $true
        $out.claim = $claim
        $out.reason = $(if ($out.warm) { 'warm-reuse-model' } else { 'claimed' })
        return $out
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($gotLock -and (Test-Path -LiteralPath $lockPath)) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Release-VramClaim {
    param(
        [Parameter(Mandatory)][string]$ClaimId,
        [string]$HostKey = 'local',
        [string]$BatonHome = (Get-OfficerBatonHome)
    )
    $path = Join-Path (Get-VramClaimsDir -BatonHome $BatonHome) ("$(ConvertTo-OfficerFsKey $HostKey)__$ClaimId.json")
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $true
    }
    return $false
}

function Test-OfficerNoProbe {
    return [string]$env:BATON_OFFICERS_NOPROBE -in @('1', 'true', 'TRUE', 'yes')
}

function ConvertFrom-OfficerLmStudioModels {
    <# Loaded rows from LM Studio native GET /api/v1/models (or v0 /api/v0/models).
       size_bytes is on-disk GGUF size, not a VRAM occupancy meter. #>
    param([Parameter(Mandatory)][string]$RawJson)
    $o = $RawJson | ConvertFrom-Json -ErrorAction Stop
    $list = if ($null -ne $o.models) { @($o.models) } else { @($o.data) }
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $list) {
        $id = if ($m.key) { [string]$m.key } elseif ($m.id) { [string]$m.id } else { '' }
        $inst = @()
        if ($null -ne $m.loaded_instances) { $inst = @($m.loaded_instances) }
        $isLoaded = ($inst.Count -gt 0) -or ([string]$m.state -eq 'loaded')
        if (-not $isLoaded) { continue }
        $bytes = $null
        if ($m.size_bytes) { $bytes = [long]$m.size_bytes }
        $ttl = $null
        if ($inst.Count -gt 0 -and $null -ne $inst[0].remaining_ttl_seconds) {
            $ttl = [int]$inst[0].remaining_ttl_seconds
        }
        $loaded.Add([ordered]@{
            id         = $id
            size_bytes = $bytes
            size_gb    = $(if ($null -ne $bytes) { [math]::Round($bytes / 1GB, 2) } else { $null })
            ttl_s      = $ttl
            format     = $(if ($m.format) { [string]$m.format } elseif ($m.compatibility_type) { [string]$m.compatibility_type } else { '' })
        })
    }
    return @($loaded)
}

function Get-OfficerLmStudioSnapshot {
    <# Fail-soft probe of one LM Studio (or OpenAI-compat) base URL. #>
    param(
        [string]$BaseUrl = 'http://localhost:1234',
        [scriptblock]$Prober,
        [int]$TimeoutSec = 3
    )
    $empty = [ordered]@{ ok = $false; reason = ''; loaded = @(); loaded_disk_gb = $null; base_url = $BaseUrl }
    if ((Test-OfficerNoProbe) -and -not $Prober) { $empty.reason = 'noprobe'; return $empty }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $empty.reason = 'no-url'; return $empty }
    $url = $BaseUrl.TrimEnd('/') + '/api/v1/models'
    try {
        $raw = $null
        if ($Prober) {
            $raw = [string](& $Prober $url)
        } else {
            $raw = [string](Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing).Content
        }
        if ([string]::IsNullOrWhiteSpace($raw)) { $empty.reason = 'empty-body'; return $empty }
        $rows = @(ConvertFrom-OfficerLmStudioModels -RawJson $raw)
        $disk = [double]0
        foreach ($r in $rows) {
            if ($null -ne $r.size_gb) { $disk += [double]$r.size_gb }
        }
        return [ordered]@{
            ok             = $true
            reason         = 'ok'
            loaded         = $rows
            loaded_disk_gb = $(if ($null -ne $disk) { [math]::Round([double]$disk, 2) } else { $null })
            base_url       = $BaseUrl
        }
    } catch {
        $empty.reason = $_.Exception.Message
        return $empty
    }
}

function Get-HostGpuFacts {
    <# nvidia-smi when present; else Apple unified memory (ANE = NPU). Injectable. #>
    param([scriptblock]$Prober)
    if ($Prober) { return & $Prober }
    $out = [ordered]@{
        gpu_gb      = $null
        gpu_used_gb = $null
        gpu_name    = $null
        npu         = $false
        source      = 'none'
    }
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $line = & nvidia-smi --query-gpu=memory.total,memory.used,name --format=csv,noheader,nounits 2>$null |
                Select-Object -First 1
            if ($line) {
                $parts = @($line -split ',' | ForEach-Object { $_.Trim() })
                if ($parts.Count -ge 2) {
                    $out.gpu_gb = [math]::Round(([double]$parts[0]) / 1024.0, 1)
                    $out.gpu_used_gb = [math]::Round(([double]$parts[1]) / 1024.0, 1)
                    if ($parts.Count -ge 3) { $out.gpu_name = $parts[2] }
                    $out.source = 'nvidia-smi'
                    return $out
                }
            }
        } catch { }
    }
    if ($IsMacOS -or [string][Environment]::OSVersion.Platform -eq 'Unix') {
        try {
            $brand = [string](& sysctl -n machdep.cpu.brand_string 2>$null)
            $bytes = [string](& sysctl -n hw.memsize 2>$null)
            if ($brand -match 'Apple M') {
                $out.npu = $true
                $out.gpu_name = $brand.Trim()
                $out.source = 'apple-unified'
                if ($bytes -match '^\d+$') {
                    $out.gpu_gb = [math]::Round(([double]$bytes) / 1GB, 1)
                }
                return $out
            }
        } catch { }
    }
    return $out
}

function Get-VramInventory {
    param(
        [string]$HostKey = 'local',
        [string]$BatonHome = (Get-OfficerBatonHome),
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$IsPidAlive,
        [string]$LmStudioUrl = 'http://localhost:1234',
        [scriptblock]$LmsProber
    )
    $live = @(Read-VramLiveClaims -HostKey $HostKey -BatonHome $BatonHome -Now $Now -IsPidAlive $IsPidAlive)
    $lms = Get-OfficerLmStudioSnapshot -BaseUrl $LmStudioUrl -Prober $LmsProber
    $loadedIds = @($lms.loaded | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    return [ordered]@{
        host           = (ConvertTo-OfficerFsKey $HostKey)
        count          = $live.Count
        exclusive      = @($live | Where-Object { $_.profile -eq 'exclusive-large' }).Count
        shared         = @($live | Where-Object { $_.profile -eq 'shared-small' }).Count
        models         = @($live | ForEach-Object { [string]$_.model } | Where-Object { $_ } | Select-Object -Unique)
        claims         = $live
        loaded         = @($lms.loaded)
        loaded_ids     = $loadedIds
        loaded_disk_gb = $lms.loaded_disk_gb
        lms_ok         = [bool]$lms.ok
        officer        = 'vram'
    }
}

function Resolve-VramProfileForProvider {
    param($Provider)
    $name = [string]$Provider.name
    $model = [string]$Provider.model_default
    $blob = "$name $model"
    if ($blob -match '(?i)(30b|32b|70b|72b|large|workhorse)') { return 'exclusive-large' }
    return 'shared-small'
}

# ---------- Systems agent ----------

function Get-SystemsInventory {
    param(
        $Facts,
        [scriptblock]$GpuProber,
        [scriptblock]$LmsProber,
        [string]$LmStudioUrl = 'http://localhost:1234',
        [switch]$NoProbe
    )
    if ($null -ne $Facts) {
        $inv = [ordered]@{}
        foreach ($k in @($Facts.Keys)) { $inv[$k] = $Facts[$k] }
        if (-not $inv.Contains('ts')) { $inv.ts = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $inv.officer = 'systems'
        return $inv
    }
    $ramMb = $null
    try { $ramMb = [int]([math]::Round([gc]::GetTotalMemory($false) / 1MB, 0)) } catch { }
    $gpu = [ordered]@{ gpu_gb = $null; gpu_used_gb = $null; gpu_name = $null; npu = $false; source = 'none' }
    $lms = [ordered]@{ ok = $false; loaded = @(); loaded_disk_gb = $null }
    $allowProbe = -not $NoProbe
    if ($allowProbe -and ($GpuProber -or -not (Test-OfficerNoProbe))) {
        $gpu = Get-HostGpuFacts -Prober $GpuProber
    }
    if ($allowProbe -and ($LmsProber -or -not (Test-OfficerNoProbe))) {
        $lms = Get-OfficerLmStudioSnapshot -BaseUrl $LmStudioUrl -Prober $LmsProber
    }
    $loadedIds = @($lms.loaded | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    return [ordered]@{
        ts             = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        os             = [string][Environment]::OSVersion.Platform
        cpu_count      = [int][Environment]::ProcessorCount
        working_mb     = $ramMb
        gpu_gb         = $gpu.gpu_gb
        gpu_used_gb    = $gpu.gpu_used_gb
        gpu_name       = $gpu.gpu_name
        gpu_source     = $gpu.source
        npu            = [bool]$gpu.npu
        loaded         = @($lms.loaded)
        loaded_ids     = $loadedIds
        loaded_disk_gb = $lms.loaded_disk_gb
        lms_ok         = [bool]$lms.ok
        officer        = 'systems'
        source         = $(if ($gpu.source -and $gpu.source -ne 'none') { [string]$gpu.source } else { 'runtime-probe' })
    }
}

function Get-SystemsPlacementAdvice {
    param(
        [ValidateSet('stt', 'codegen', 'embed', 'general')][string]$Kind = 'general',
        $Inventory
    )
    if ($null -eq $Inventory) { $Inventory = Get-SystemsInventory }
    $gpu = 0
    if ($null -ne $Inventory.gpu_gb) { $gpu = [double]$Inventory.gpu_gb }
    $npu = [bool]$Inventory.npu
    $place = [ordered]@{
        kind      = $Kind
        target    = 'cpu'
        reason    = ''
        blocks    = $false
        officer   = 'systems'
    }
    switch ($Kind) {
        'stt' {
            if ($npu) { $place.target = 'npu'; $place.reason = 'STT on NPU keeps GPU free for codegen' }
            else { $place.target = 'cpu'; $place.reason = 'no NPU declared — STT on CPU' }
        }
        'codegen' {
            $src = [string]$Inventory.gpu_source
            $loadedN = @($Inventory.loaded_ids).Count
            if ($gpu -ge 16) {
                $place.target = 'gpu'
                $how = if ($src -eq 'apple-unified') { 'unified' } else { 'GPU' }
                $place.reason = "$how ${gpu}GB enough for local codegen"
                if ($loadedN -gt 0) { $place.reason += " (LMS serving $loadedN)" }
            } else {
                $place.target = 'cloud'
                $place.reason = 'local GPU too small or unknown — prefer Ox/cloud for codegen'
            }
        }
        'embed' {
            if ($gpu -ge 4 -and $gpu -lt 16) { $place.target = 'gpu-small'; $place.reason = 'small GPU for embeddings' }
            else { $place.target = 'cpu'; $place.reason = 'embeddings on CPU' }
        }
        default {
            $place.target = 'cpu'
            $place.reason = 'general work: cheapest local'
        }
    }
    return $place
}

function Save-SystemsInventory {
    param(
        $Inventory,
        [string]$BatonHome = (Get-OfficerBatonHome)
    )
    if ($null -eq $Inventory) { $Inventory = Get-SystemsInventory }
    $dir = Join-Path $BatonHome 'systems'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $path = Join-Path $dir 'inventory.json'
    ($Inventory | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return $path
}

function Get-OfficersDoctorLines {
    param(
        [string]$BatonHome = (Get-OfficerBatonHome),
        $SystemsInventory,
        $VramInventory
    )
    $inv = if ($null -ne $SystemsInventory) { $SystemsInventory } else { Get-SystemsInventory }
    $vram = if ($null -ne $VramInventory) { $VramInventory } else { Get-VramInventory -BatonHome $BatonHome }
    $sched = Read-SchedulerState -BatonHome $BatonHome
    $reg = Test-OfficerRegistry
    $loaded = @($inv.loaded_ids)
    if ($loaded.Count -lt 1) { $loaded = @($vram.loaded_ids) }
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("officers: registry=$(if ($reg.ok) { 'ok' } else { 'bad:' + $reg.reason })")
    [void]$lines.Add("systems: os=$($inv.os) cpu=$($inv.cpu_count) npu=$($inv.npu) gpu_gb=$($inv.gpu_gb) source=$($inv.gpu_source)")
    $loadStr = if ($loaded.Count) { $loaded -join ',' } else { '-' }
    [void]$lines.Add("vram: host=$($vram.host) live=$($vram.count) exclusive=$($vram.exclusive) shared=$($vram.shared) loaded=$loadStr disk_gb=$($vram.loaded_disk_gb)")
    [void]$lines.Add("scheduler: last_fable=$($sched.last_fable_at)")
    return @($lines)
}
