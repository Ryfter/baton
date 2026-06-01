#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Concurrent fan-out of one prompt to a roster of fleet members.

.DESCRIPTION
  One Start-Job (separate PowerShell process) per provider — process isolation
  prevents env-var collision and contains crashes/hangs. Each job dot-sources
  fleet-lib.ps1 and runs Invoke-Fleet -NoJournal, writing its response to
  <OutputDir>/<provider>.md. The parent waits (with timeout), then writes all
  journal lines SERIALLY (avoiding concurrent-append corruption). Returns a
  manifest. Synthesis is done by the caller (Claude), not here.

  LIVE STATUS (Plan 10 cockpit): the parent writes <OutputDir>/_ensemble.json
  at launch (state=running, one entry per task) and rewrites it at completion
  (state=done + per-task outcome). Each child writes <OutputDir>/<label>.live.json
  the instant it starts ({state:running,started}) and overwrites it on finish
  ({state:done|error,started,ended,duration_s,exit}). The dashboard polls these
  files to render every model running concurrently in real time.
#>

. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

# Child-side scriptblock shared by both ensemble functions. Emits a <label>.live.json
# heartbeat at start and a terminal record at finish, alongside the <label>.md output.
$script:EnsembleWorker = {
    param($libPath, $provider, $prompt, $outDir, $fleetPath, $label)
    . $libPath
    $outFile  = Join-Path $outDir "$label.md"
    $liveFile = Join-Path $outDir "$label.live.json"
    $started  = (Get-Date).ToString('o')
    # Heartbeat: mark running the instant this process is alive.
    Set-JsonFileAtomic -Path $liveFile -Json (@{ label = $label; provider = $provider; state = 'running'; started = $started } | ConvertTo-Json -Compress)
    try {
        $r = Invoke-Fleet -Name $provider -Prompt $prompt -Path $fleetPath -NoJournal
        if ($r.exit_code -eq 0) {
            Set-Content -Path $outFile -Value ($r.stdout | Out-String).Trim() -Encoding utf8NoBOM
            $state = 'done'
        } else {
            Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] exit:$($r.exit_code) $($r.stderr)" -Encoding utf8NoBOM
            $state = 'error'
        }
        Set-JsonFileAtomic -Path $liveFile -Json (@{ label = $label; provider = $provider; state = $state; started = $started;
           ended = (Get-Date).ToString('o'); duration_s = [int]$r.duration_s; exit = [int]$r.exit_code } | ConvertTo-Json -Compress)
        [pscustomobject]@{ exit_code = $r.exit_code; duration_s = $r.duration_s }
    } catch {
        Set-Content -Path $outFile -Value "[ENSEMBLE ERROR] $($_.Exception.Message)" -Encoding utf8NoBOM
        Set-JsonFileAtomic -Path $liveFile -Json (@{ label = $label; provider = $provider; state = 'error'; started = $started;
           ended = (Get-Date).ToString('o'); duration_s = 0; exit = -1 } | ConvertTo-Json -Compress)
        [pscustomobject]@{ exit_code = -1; duration_s = 0 }
    }
}

# Write/refresh the run-level manifest the dashboard reads to discover live runs.
function Write-EnsembleRunMeta {
    param(
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][array]$Tasks,      # @( @{label;provider} )
        [Parameter(Mandatory)][string]$State,     # running | done
        [string]$Started,
        [int]$TimeoutS = 300,
        [array]$Manifest                          # terminal manifest (optional)
    )
    $promptSnip = if ($Prompt) { $Prompt.Substring(0, [Math]::Min(280, $Prompt.Length)) } else { '' }
    $meta = [ordered]@{
        run_id    = (Split-Path $OutputDir -Leaf)
        kind      = $Kind
        prompt    = $promptSnip
        state     = $State
        started   = $Started
        timeout_s = $TimeoutS
        tasks     = @($Tasks | ForEach-Object { @{ label = $_.label; provider = $_.provider } })
    }
    if ($State -eq 'done') { $meta['ended'] = (Get-Date).ToString('o') }
    if ($Manifest)         { $meta['manifest'] = $Manifest }
    Set-JsonFileAtomic -Path (Join-Path $OutputDir '_ensemble.json') -Json ($meta | ConvertTo-Json -Depth 6)
}

function Invoke-FleetEnsemble {
    param(
        [Parameter(Mandatory)][string[]]$Providers,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$OutputDir,
        [int]$TimeoutS = 300,
        [string]$Kind = 'ensemble',
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md')
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $libPath = Join-Path $PSScriptRoot 'fleet-lib.ps1'
    $started = (Get-Date).ToString('o')

    # One label per provider here (label == provider).
    $tasks = @($Providers | ForEach-Object { @{ label = $_; provider = $_ } })
    Write-EnsembleRunMeta -OutputDir $OutputDir -Kind $Kind -Prompt $Prompt `
        -Tasks $tasks -State 'running' -Started $started -TimeoutS $TimeoutS

    # Spawn one process-isolated job per provider.
    $jobMap = @()
    foreach ($p in $Providers) {
        $job = Start-Job -ArgumentList $libPath, $p, $Prompt, $OutputDir, $FleetPath, $p -ScriptBlock $script:EnsembleWorker
        $jobMap += [pscustomobject]@{ provider = $p; job = $job }
    }

    # Wait for all jobs, bounded by TimeoutS.
    $null = Wait-Job -Job ($jobMap.job) -Timeout $TimeoutS

    $manifest = @()
    foreach ($entry in $jobMap) {
        $job = $entry.job
        $prov = $entry.provider
        $outFile = Join-Path $OutputDir "$prov.md"
        $liveFile = Join-Path $OutputDir "$prov.live.json"
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            Set-Content -Path $outFile -Value "[ENSEMBLE TIMEOUT] exceeded ${TimeoutS}s" -Encoding utf8NoBOM
            Set-JsonFileAtomic -Path $liveFile -Json (@{ label = $prov; provider = $prov; state = 'timeout'; duration_s = $TimeoutS } | ConvertTo-Json -Compress)
            $manifest += [pscustomobject]@{ provider = $prov; status = 'timeout'; file = $outFile; duration_s = $TimeoutS }
        } else {
            $ret = Receive-Job -Job $job
            $exit = if ($ret -and $null -ne $ret.exit_code) { [int]$ret.exit_code } else { -1 }
            $dur  = if ($ret -and $null -ne $ret.duration_s) { [int]$ret.duration_s } else { 0 }
            $status = if ($exit -eq 0) { 'ok' } else { 'error' }
            $manifest += [pscustomobject]@{ provider = $prov; status = $status; file = $outFile; duration_s = $dur }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    Write-EnsembleRunMeta -OutputDir $OutputDir -Kind $Kind -Prompt $Prompt `
        -Tasks $tasks -State 'done' -Started $started -TimeoutS $TimeoutS -Manifest $manifest

    # Parent writes journal lines SERIALLY (no concurrent appends).
    foreach ($m in $manifest) {
        $jexit = switch ($m.status) { 'ok' { 0 } 'timeout' { -2 } default { -1 } }
        Write-FleetJournalLine -Provider $m.provider -DurationS $m.duration_s `
            -ExitCode $jexit -Prompt $Prompt -JournalPath $JournalPath
    }

    return $manifest
}

function Invoke-FleetEnsembleTasks {
    <#
    .SYNOPSIS
      Heterogeneous-task fan-out: each task carries its own provider + prompt + label.

    .DESCRIPTION
      Sister of Invoke-FleetEnsemble. Where the latter fans ONE prompt out to N
      providers, this dispatches N TASKS where each task can target a different
      provider with a different prompt. Output files are named by label, not
      provider — labels can repeat providers (e.g. Six Hats with a 2-provider
      roster maps 6 labeled tasks onto 2 providers).

    .PARAMETER Tasks
      Array of hashtables: @{ label = string; provider = string; prompt = string }.
      Each becomes a Start-Job process running Invoke-Fleet -NoJournal.

    .PARAMETER OutputDir
      Created if missing. Files land at <OutputDir>/<label>.md.

    .OUTPUTS
      Manifest: @( @{ label; provider; status; file; duration_s } )
    #>
    param(
        [Parameter(Mandatory)][array]$Tasks,
        [Parameter(Mandatory)][string]$OutputDir,
        [int]$TimeoutS = 300,
        [string]$Kind = 'tasks',
        [string]$FleetPath = (Join-Path $HOME '.claude/fleet.yaml'),
        [string]$JournalPath = (Join-Path $HOME '.claude/model-routing-log.md')
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null }
    $libPath = Join-Path $PSScriptRoot 'fleet-lib.ps1'
    $started = (Get-Date).ToString('o')

    # Validate task shape
    foreach ($t in $Tasks) {
        if (-not $t.label)    { throw "Task missing 'label' field." }
        if (-not $t.provider) { throw "Task '$($t.label)' missing 'provider' field." }
        if (-not $t.prompt)   { throw "Task '$($t.label)' missing 'prompt' field." }
    }

    $promptForMeta = if ($Tasks.Count -gt 0) { [string]$Tasks[0].prompt } else { '' }
    Write-EnsembleRunMeta -OutputDir $OutputDir -Kind $Kind -Prompt $promptForMeta `
        -Tasks $Tasks -State 'running' -Started $started -TimeoutS $TimeoutS

    $jobMap = @()
    foreach ($t in $Tasks) {
        $job = Start-Job -ArgumentList $libPath, $t.provider, $t.prompt, $OutputDir, $FleetPath, $t.label -ScriptBlock $script:EnsembleWorker
        $jobMap += [pscustomobject]@{ label = $t.label; provider = $t.provider; prompt = $t.prompt; job = $job }
    }

    $null = Wait-Job -Job ($jobMap.job) -Timeout $TimeoutS

    $manifest = @()
    foreach ($entry in $jobMap) {
        $job = $entry.job
        $lbl = $entry.label
        $prv = $entry.provider
        $outFile = Join-Path $OutputDir "$lbl.md"
        $liveFile = Join-Path $OutputDir "$lbl.live.json"
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            Set-Content -Path $outFile -Value "[ENSEMBLE TIMEOUT] exceeded ${TimeoutS}s" -Encoding utf8NoBOM
            Set-JsonFileAtomic -Path $liveFile -Json (@{ label = $lbl; provider = $prv; state = 'timeout'; duration_s = $TimeoutS } | ConvertTo-Json -Compress)
            $manifest += [pscustomobject]@{ label = $lbl; provider = $prv; status = 'timeout'; file = $outFile; duration_s = $TimeoutS; prompt = $entry.prompt }
        } else {
            $ret = Receive-Job -Job $job
            $exit = if ($ret -and $null -ne $ret.exit_code) { [int]$ret.exit_code } else { -1 }
            $dur  = if ($ret -and $null -ne $ret.duration_s) { [int]$ret.duration_s } else { 0 }
            $status = if ($exit -eq 0) { 'ok' } else { 'error' }
            $manifest += [pscustomobject]@{ label = $lbl; provider = $prv; status = $status; file = $outFile; duration_s = $dur; prompt = $entry.prompt }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }

    Write-EnsembleRunMeta -OutputDir $OutputDir -Kind $Kind -Prompt $promptForMeta `
        -Tasks $Tasks -State 'done' -Started $started -TimeoutS $TimeoutS -Manifest $manifest

    # Parent writes journal lines SERIALLY — one line per task (so a provider
    # used by multiple tasks gets multiple journal entries).
    foreach ($m in $manifest) {
        $jexit = switch ($m.status) { 'ok' { 0 } 'timeout' { -2 } default { -1 } }
        Write-FleetJournalLine -Provider $m.provider -DurationS $m.duration_s `
            -ExitCode $jexit -Prompt $m.prompt -JournalPath $JournalPath
    }

    return $manifest
}
