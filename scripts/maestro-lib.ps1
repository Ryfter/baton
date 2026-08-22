# Shared helpers for maestro-admit.ps1, maestro-fire.ps1, maestro-tick.ps1.

$script:MaestroDefaultUsable = @(
    'openrouter-ox-alpha',
    'grok-cli',
    'cursor-agent',
    'codex',
    'kiro',
    'lm-studio'
)

function Import-MaestroEnv {
    <# Load overnight secrets into the current runspace (and parallel workers).
       Bash maestro-watch sources .openrouter.env but Start-Job / ForEach-Object -Parallel do not. #>
    $envFile = Join-Path (Join-Path $HOME '.baton/overnight') '.openrouter.env'
    if (-not (Test-Path -LiteralPath $envFile)) { return $false }
    foreach ($line in Get-Content -LiteralPath $envFile -Encoding utf8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $val = $Matches[2].Trim()
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            Set-Item -Path "Env:$name" -Value $val
        }
    }
    return $true
}

function Test-MaestroInstrumentReady {
    param([Parameter(Mandatory)][string]$Name)
    switch -Regex ($Name) {
        '^openrouter' {
            return -not [string]::IsNullOrWhiteSpace($env:OPENROUTER_API_KEY)
        }
        '^cursor-' {
            return [bool](Get-Command cursor-agent -ErrorAction SilentlyContinue)
        }
        '^grok-cli$' {
            return [bool](Get-Command grok -ErrorAction SilentlyContinue)
        }
        '^codex$' {
            return [bool](Get-Command codex -ErrorAction SilentlyContinue)
        }
        '^kiro$' {
            return [bool](Get-Command kiro-cli -ErrorAction SilentlyContinue)
        }
        '^lm-studio$' {
            return $true
        }
        default { return $true }
    }
}

function Set-MaestroJobStatus {
    param(
        [Parameter(Mandatory)]$Job,
        [Parameter(Mandatory)][string]$Status,
        [string]$StatusLine
    )
    $Job.status = $Status
    if ($StatusLine) {
        $Job | Add-Member -NotePropertyName status_line -NotePropertyValue $StatusLine -Force
    }
}

function Get-MaestroJobsDir {
    param([Parameter(Mandatory)][string]$BatonHome)
    return (Join-Path $BatonHome 'maestro/jobs')
}

function Get-MaestroJobRecords {
    param([Parameter(Mandatory)][string]$JobsDir)
    if (-not (Test-Path -LiteralPath $JobsDir)) { return @() }
    $out = @()
    foreach ($f in Get-ChildItem -LiteralPath $JobsDir -Filter 'mj-*.json' -File) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $out += [pscustomobject]@{
                Path    = $f.FullName
                Job     = $j
                Created = [string]$j.created_at
            }
        } catch { }
    }
    return $out
}

function Get-MaestroUsableInstruments {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string[]]$Prefer = $script:MaestroDefaultUsable
    )
    $usable = [System.Collections.Generic.List[string]]::new()
    $budgetLib = Join-Path $PSScriptRoot 'window-budget-lib.ps1'
    if (Test-Path -LiteralPath $budgetLib) {
        try {
            . $budgetLib
            $status = Get-WindowBudgetStatus -Window '5h' -BatonHome $BatonHome
            foreach ($row in @($status.models)) {
                if ($row.lockout) { continue }
                $p = [string]$row.pressure
                if ($p -eq 'hard') { continue }
                $m = [string]$row.model
                if ($m -and -not $usable.Contains($m)) { [void]$usable.Add($m) }
            }
        } catch { }
    }
    foreach ($name in $Prefer) {
        if (-not (Test-MaestroInstrumentReady -Name $name)) { continue }
        if (-not $usable.Contains($name)) { [void]$usable.Add($name) }
    }
    return @($usable)
}

function Test-MaestroJobConsumesParallelSlot {
    param([Parameter(Mandatory)]$Job)
    if ([string]$Job.status -ne 'running') { return $false }
    if ([string]$Job.source -eq 'ensure-conductors') { return $false }
    if ([string]$Job.goal -match 'Conductor auto-admitted') { return $false }
    return $true
}

function Get-MaestroProjectBlocks {
    param([Parameter(Mandatory)]$JobRecords)
    $held = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $running = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rec in @($JobRecords)) {
        $proj = [string]$rec.Job.project
        if (-not $proj) { continue }
        $st = [string]$rec.Job.status
        if ($st -eq 'held') { [void]$held.Add($proj) }
        if ($st -eq 'admitted') { [void]$running.Add($proj) }
        if ($st -eq 'running' -and (Test-MaestroJobConsumesParallelSlot -Job $rec.Job)) {
            [void]$running.Add($proj)
        }
    }
    return [pscustomobject]@{ Held = $held; Running = $running }
}

function Test-MaestroProjectAdmittable {
    param(
        [Parameter(Mandatory)][string]$Project,
        $Blocks
    )
    if ($Blocks.Held.Contains($Project)) { return $false }
    if ($Blocks.Running.Contains($Project)) { return $false }
    return $true
}

function Resolve-MaestroRepoPath {
    param(
        [Parameter(Mandatory)][string]$BatonHome,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$DefaultRepo
    )
    $projectId = ($ProjectId -replace '[\\/]', '').Trim()
    if (-not $projectId) { return $DefaultRepo }
    $recPath = Join-Path $BatonHome "projects/$projectId/project.json"
    if (-not (Test-Path -LiteralPath $recPath)) { return $DefaultRepo }
    try {
        $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json
        $folder = [string]$rec.folder
        if (-not [string]::IsNullOrWhiteSpace($folder) -and (Test-Path -LiteralPath $folder)) {
            return $folder
        }
    } catch { }
    return $DefaultRepo
}

function Get-GoProvider {
    param($Out)
    if ($null -eq $Out) { return $null }
    if ($Out.PSObject.Properties['provider'] -and -not [string]::IsNullOrWhiteSpace([string]$Out.provider)) {
        return [string]$Out.provider
    }
    if ($Out.effective_cost -and $Out.effective_cost.workers -and @($Out.effective_cost.workers).Count -gt 0) {
        return [string]$Out.effective_cost.workers[0].worker
    }
    $runDir = [string]$Out.run_dir
    if ($runDir -and (Test-Path -LiteralPath (Join-Path $runDir 'decisions.jsonl'))) {
        $line = Get-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') -TotalCount 1 -ErrorAction SilentlyContinue
        if ($line) {
            try {
                $d = $line | ConvertFrom-Json
                if ($d.chose) { return [string]$d.chose }
            } catch { }
        }
    }
    return $null
}

function Resolve-MaestroStatusFromGo {
    param(
        [string]$GoStatus,
        [string]$GoWhy = ''
    )
    $s = ($GoStatus -as [string]).Trim().ToLowerInvariant()
    $why = ($GoWhy -as [string]).ToLowerInvariant()
    if ($s -eq 'labor-unavailable') { return 'waiting-quota' }
    if ($s -match 'quota|rate.?limit|limited') { return 'waiting-quota' }
    if ($why -match 'quota|rate.?limit|no candidate|labor-unavailable|usage limit') { return 'waiting-quota' }
    if ($s -like 'interrupted-*') { return 'running' }
    if ($s -in @('completed', 'accepted', 'failed', 'done')) { return 'done' }
    if ($s -eq 'waiting-quota' -or $s -eq 'labor-unavailable') { return 'waiting-quota' }
    return 'done'
}

function Update-MaestroJobFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Patch
    )
    $job = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($Patch.ContainsKey('status') -and $Patch.status) { $job.status = $Patch.status }
    if ($Patch.ContainsKey('run_id') -and $Patch.run_id) { $job.run_id = $Patch.run_id }
    if ($Patch.ContainsKey('provider') -and $Patch.provider) { $job.provider = $Patch.provider }
    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Test-MaestroJobId {
    param([Parameter(Mandatory)][string]$JobId)
    return ($JobId -match '^mj-[0-9a-f]{12}$')
}

function Invoke-MaestroHoldJob {
    param(
        [Parameter(Mandatory)][string]$JobsDir,
        [Parameter(Mandatory)][string]$JobId
    )
    if (-not (Test-MaestroJobId -JobId $JobId)) {
        throw "invalid job id: $JobId"
    }
    $path = Join-Path $JobsDir "$JobId.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "no such job: $JobId"
    }
    $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $prev = [string]$job.status
    $job | Add-Member -NotePropertyName held_from -NotePropertyValue $prev -Force
    $job.status = 'held'
    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-MaestroEvent -Root $JobsDir -JobId $JobId -Kind 'hold' -Status 'held'
    return $job
}

function Invoke-MaestroReleaseJob {
    param(
        [Parameter(Mandatory)][string]$JobsDir,
        [Parameter(Mandatory)][string]$JobId
    )
    if (-not (Test-MaestroJobId -JobId $JobId)) {
        throw "invalid job id: $JobId"
    }
    $path = Join-Path $JobsDir "$JobId.json"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "no such job: $JobId"
    }
    $job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([string]$job.status -ne 'held') {
        throw "job is not held: $($job.status)"
    }
    $restore = 'admitted'
    if ($job.PSObject.Properties['held_from'] -and -not [string]::IsNullOrWhiteSpace([string]$job.held_from)) {
        $restore = ([string]$job.held_from).Trim().ToLowerInvariant()
    }
    $valid = @('queued', 'admitted', 'running', 'waiting-quota', 'done')
    if ($restore -notin $valid -or $restore -eq 'held') { $restore = 'admitted' }
    if ($job.PSObject.Properties['held_from']) { $job.PSObject.Properties.Remove('held_from') }
    $job.status = $restore
    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-MaestroEvent -Root $JobsDir -JobId $JobId -Kind 'release' -Status $restore
    return $job
}

function Write-MaestroEvent {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Status,
        [string]$RunId,
        [string]$Provider
    )
    $row = @{
        ts     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        job_id = $JobId
        kind   = $Kind
    }
    if ($Status) { $row.status = $Status }
    if ($RunId) { $row.run_id = $RunId }
    if ($Provider) { $row.provider = $Provider }
    $eventsPath = Join-Path $Root 'events.jsonl'
    ($row | ConvertTo-Json -Compress) + "`n" | Add-Content -LiteralPath $eventsPath -Encoding utf8NoBOM
}

function Invoke-MaestroFireOne {
    param(
        [Parameter(Mandatory)]$Pick,
        [Parameter(Mandatory)][string]$JobsDir,
        [Parameter(Mandatory)][string]$BatonHome,
        [Parameter(Mandatory)][string]$FleetGo,
        [Parameter(Mandatory)][string]$DefaultRepo,
        [Parameter(Mandatory)][string]$FleetPath
    )
    $job = $Pick.Job
    $jobPath = $Pick.Path
    $job.status = 'running'
    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jobPath -Encoding utf8NoBOM
    Write-MaestroEvent -Root $JobsDir -JobId ([string]$job.id) -Kind 'firing'

    $repoPath = Resolve-MaestroRepoPath -BatonHome $BatonHome -ProjectId ([string]$job.project) -DefaultRepo $DefaultRepo
    $stakes = if ($job.stakes) { [string]$job.stakes } else { 'standard' }

    $goArgs = @{
        Goal       = [string]$job.goal
        RepoPath   = $repoPath
        FleetPath  = $FleetPath
        Execute    = $true
        NoPlanGate = $true
        NoVerify   = $true
        Stakes     = $stakes
        Json       = $true
    }

    $raw = ''
    $exit = 0
    try {
        $raw = (& pwsh -NoProfile -File $FleetGo @goArgs | Out-String).Trim()
        $exit = $LASTEXITCODE
    } catch {
        $raw = $_.Exception.Message
        $exit = 1
    }

    $patch = @{
        run_id   = $null
        provider = $null
        status   = 'done'
    }

    if ($raw) {
        try {
            $out = $raw | ConvertFrom-Json
            if ($out.run_id) { $patch.run_id = [string]$out.run_id }
            $prov = Get-GoProvider -Out $out
            if ($prov) { $patch.provider = $prov }
            $patch.status = Resolve-MaestroStatusFromGo -GoStatus ([string]$out.status) -GoWhy ([string]$out.report)
        } catch {
            if ($raw -match 'quota|rate.?limit|labor-unavailable|no candidate') {
                $patch.status = 'waiting-quota'
            } else {
                $patch.status = 'done'
            }
        }
    } elseif ($exit -ne 0) {
        if ($raw -match 'quota|rate.?limit|labor-unavailable|no candidate') {
            $patch.status = 'waiting-quota'
        } else {
            $patch.status = 'done'
        }
    }

    Update-MaestroJobFile -Path $jobPath -Patch $patch
    Write-MaestroEvent -Root $JobsDir -JobId ([string]$job.id) -Kind 'fired' -Status $patch.status -RunId $patch.run_id -Provider $patch.provider

    return [pscustomobject]@{
        id       = [string]$job.id
        status   = $patch.status
        run_id   = $patch.run_id
        provider = $patch.provider
        exit     = $exit
    }
}
