# Shared helpers for maestro-fire.ps1 (Slice 1 — no Go, no Fable).

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
    if ($s -in @('completed', 'accepted')) { return 'done' }
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
