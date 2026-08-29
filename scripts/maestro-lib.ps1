# Shared helpers for maestro-admit.ps1, maestro-fire.ps1, maestro-tick.ps1.

. (Join-Path $PSScriptRoot 'maestro-session-lib.ps1')

$script:MaestroDefaultUsable = @(
    'openrouter-ox-alpha',
    'opencode',
    'opencode-free',
    'grok-cli',
    'cursor-agent',
    'codex',
    'kiro',
    'lm-studio'
)

$script:MaestroFreeSeats = @(
    'openrouter-ox-alpha',
    'opencode',
    'opencode-free'
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
        '^opencode' {
            return [bool](Get-Command opencode -ErrorAction SilentlyContinue)
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

function Resolve-BatonProjectFromCwd {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string]$Cwd = $(Get-Location).Path
    )
    $path = try { [IO.Path]::GetFullPath($Cwd) } catch { [string]$Cwd }
    . (Join-Path $PSScriptRoot 'registry-lib.ps1')
    $slug = Get-ProjectId -Folder $path
    $choices = @(Get-MaestroRoomChoices -BatonHome $BatonHome)
    # Exact project folder match via registry records
    foreach ($c in @($choices | Where-Object { $_.Kind -eq 'project' })) {
        $recPath = Join-Path $BatonHome 'projects' ([string]$c.Id) 'project.json'
        if (Test-Path -LiteralPath $recPath) {
            $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json
            $folder = [string]$rec.folder
            if ($folder) {
                try {
                    $full = [IO.Path]::GetFullPath($folder)
                    if ($path.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
                        return [pscustomobject]@{ Id = [string]$c.Id; Path = $path; Registered = $true }
                    }
                } catch { }
            }
        }
        if ([string]$c.Id -eq $slug) {
            return [pscustomobject]@{ Id = [string]$c.Id; Path = $path; Registered = $true }
        }
    }
    # Worktree match
    foreach ($c in @($choices | Where-Object { $_.Kind -eq 'worktree' })) {
        if ($path -match [regex]::Escape([string]$c.Label) -or [string]$c.Id -eq $slug) {
            foreach ($p in @($choices | Where-Object { $_.Kind -eq 'project' })) {
                if (Test-MaestroChoiceMatchesProject -Choice $c -ProjectId ([string]$p.Id)) {
                    return [pscustomobject]@{ Id = [string]$p.Id; Path = $path; Registered = $true }
                }
            }
        }
    }
    return [pscustomobject]@{ Id = $slug; Path = $path; Registered = $false }
}

function Get-BatonJobCounts {
    param([string]$BatonHome)
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $active = 0; $held = 0; $wq = 0
    $terminal = @('done', 'rejected', 'cancelled')
    foreach ($rec in @(Get-MaestroJobRecords -JobsDir $jobsDir)) {
        $st = [string]$rec.Job.status
        if ($terminal -contains $st) { continue }
        switch -Regex ($st) {
            '^held$' { $held++ }
            '^waiting-quota$' { $wq++ }
            '^(running|admitted)$' { $active++ }
            default { $active++ }
        }
    }
    return [pscustomobject]@{ Active = $active; Held = $held; WaitingQuota = $wq }
}

function Format-BatonPassiveStatus {
    param(
        [string]$BatonHome,
        [string]$Cwd = $(Get-Location).Path
    )
    $ctx = Resolve-BatonProjectFromCwd -BatonHome $BatonHome -Cwd $Cwd
    $projLabel = if ($ctx.Registered) { [string]$ctx.Id } else { '(unregistered)' }
    $line1 = ('project  {0} · {1}' -f $projLabel, $ctx.Path)

    . (Join-Path $PSScriptRoot 'cursor-quota-lib.ps1')
    $cfg = Get-CursorQuotaConfig -BatonHome $BatonHome
    $claude = Read-ClaudeQuotaCache -BatonHome $BatonHome
    $cursor = Read-CursorQuotaCache -BatonHome $BatonHome
    $parts = [System.Collections.Generic.List[string]]::new()
    $cl = Format-ClaudeQuotaStatusLine -Cache $claude -Format detail -Config $cfg
    if ($cl) { [void]$parts.Add(($cl -replace '^\s+', '')) }
    $cu = Format-CursorQuotaStatusLine -Cache $cursor -Format detail -Config $cfg
    if ($cu) { [void]$parts.Add(($cu -replace '^\s+Cursor', 'Cursor')) }
    $line2 = if ($parts.Count -gt 0) {
        ('quota    ' + ($parts -join ' · '))
    } else {
        'quota    (no snapshot — run Claude Code or baton quota)'
    }

    $c = Get-BatonJobCounts -BatonHome $BatonHome
    $wqTxt = if ($c.WaitingQuota -gt 0) { " · $($c.WaitingQuota) waiting quota" } else { '' }
    $line3 = ('jobs     {0} active · {1} held{2}' -f $c.Active, $c.Held, $wqTxt)

    return @($line1, $line2, $line3)
}

function Resolve-MaestroFleetPath {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' })
    )
    foreach ($rel in @('overnight/fleet.yaml', 'fleet.yaml')) {
        $p = Join-Path $BatonHome $rel
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $seed = Join-Path (Split-Path $PSScriptRoot -Parent) 'references/fleet.yaml'
    if (Test-Path -LiteralPath $seed) { return $seed }
    return (Join-Path $BatonHome 'fleet.yaml')
}

function Select-MaestroRankedProviders {
    <# Rank providers the same way fleet-go does: Select-Capability + usage route-around.
       economy (standard): cheapest eligible tier, then quality + learned cost.
       champion (high): best quality first. No hardcoded failover list. #>
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string]$Capability = 'code-gen',
        [ValidateSet('local', 'free', 'paid')][string]$MaxCostTier = 'paid',
        [ValidateSet('economy', 'champion')][string]$SelectionMode = 'economy',
        [string]$FleetPath = ''
    )
    $routingLib = Join-Path $PSScriptRoot 'routing-lib.ps1'
    if (-not (Test-Path -LiteralPath $routingLib)) { return @() }
    . $routingLib
    if ([string]::IsNullOrWhiteSpace($FleetPath)) {
        $FleetPath = Resolve-MaestroFleetPath -BatonHome $BatonHome
    }
    if (-not (Test-Path -LiteralPath $FleetPath)) { return @() }
    $toolsPath = Join-Path $BatonHome 'tools.yaml'
    if (-not (Test-Path -LiteralPath $toolsPath)) {
        $toolsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'references/tools.yaml'
    }
    $ranked = Select-Capability -Capability $Capability -MaxCostTier $MaxCostTier `
        -SelectionMode $SelectionMode -FleetPath $FleetPath -ToolsPath $toolsPath `
        -UsagePath (Join-Path $BatonHome 'usage-journal.jsonl') `
        -JournalPath (Join-Path $BatonHome 'routing-journal.jsonl') `
        -RunsRoot (Join-Path $BatonHome 'runs')
    return @($ranked | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.name) -and
        (Test-MaestroInstrumentReady -Name ([string]$_.name))
    })
}

function Get-MaestroUsableInstruments {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string[]]$Prefer = $script:MaestroDefaultUsable
    )
    $usable = [System.Collections.Generic.List[string]]::new()
    foreach ($c in (Select-MaestroRankedProviders -BatonHome $BatonHome)) {
        $n = [string]$c.name
        if ($n -and -not $usable.Contains($n)) { [void]$usable.Add($n) }
    }
    $instLib = Join-Path $PSScriptRoot 'instruments-lib.ps1'
    if (Test-Path -LiteralPath $instLib) {
        try {
            . $instLib
            foreach ($seat in @(Get-UsableInstrumentSeats -BatonHome $BatonHome)) {
                if ($seat -and -not $usable.Contains($seat)) { [void]$usable.Add($seat) }
            }
        } catch { }
    }
    if ($usable.Count -eq 0) {
        foreach ($name in $Prefer) {
            if (-not (Test-MaestroInstrumentReady -Name $name)) { continue }
            if (-not $usable.Contains($name)) { [void]$usable.Add($name) }
        }
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

function Get-MaestroFireMaxCostTier {
    param($Job)
    $t = ''
    if ($Job -and $Job.PSObject.Properties['max_cost_tier']) {
        $t = ([string]$Job.max_cost_tier).Trim().ToLowerInvariant()
    }
    if ($t -in @('local', 'free', 'paid')) { return $t }
    return 'paid'
}

function Get-MaestroConductorSeat {
    param(
        [string]$Provider,
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [ValidateSet('local', 'free', 'paid')][string]$MaxCostTier = 'paid'
    )
    $ranked = Select-MaestroRankedProviders -BatonHome $BatonHome -MaxCostTier $MaxCostTier
    $hint = if ($Provider) { $Provider.Trim() } else { '' }
    if ($hint) {
        $match = @($ranked | Where-Object { [string]$_.name -eq $hint } | Select-Object -First 1)
        if ($match.Count -gt 0) {
            return [pscustomobject]@{
                Name     = $hint
                CostTier = [string]$match[0].cost_tier
                Ready    = $true
            }
        }
    }
    if ($ranked.Count -gt 0) {
        $best = $ranked[0]
        return [pscustomobject]@{
            Name     = [string]$best.name
            CostTier = [string]$best.cost_tier
            Ready    = $true
        }
    }
    return [pscustomobject]@{
        Name     = if ($hint) { $hint } else { 'none' }
        CostTier = 'paid'
        Ready    = $false
    }
}

$script:MaestroProjectAliases = [ordered]@{
    'canvas toolchain'  = 'canvas-toolchain'
    'canvas-toolchain'  = 'canvas-toolchain'
    'tower defense'     = 'towerdefensegame'
    'towerdefense'      = 'towerdefensegame'
    'towerdefensegame'  = 'towerdefensegame'
    'atomic forge'      = 'atomicforge'
    'atomicforge'       = 'atomicforge'
    'answer bot'        = 'answerbot'
    'answerbot'         = 'answerbot'
    'bench gauntlet'    = 'bench-gauntlet'
    'bench-gauntlet'    = 'bench-gauntlet'
    'book profile'      = 'bookprofile'
    'bookprofile'       = 'bookprofile'
    'grim lore'         = 'grimlore'
    'grimlore'          = 'grimlore'
}

function Get-MaestroRoomKeywords {
    return @(
        [pscustomobject]@{ Name = 'projects';  Hint = 'registered projects — type a number to pick one' }
        [pscustomobject]@{ Name = 'new project'; Hint = 'create folder + private GitHub + Grimdex/Grimlore — new project Foo — what it is' }
        [pscustomobject]@{ Name = 'worktrees'; Hint = 'all worktrees — type a number to pick one' }
        [pscustomobject]@{ Name = 'status';    Hint = "this project's jobs and worktrees" }
        [pscustomobject]@{ Name = 'quota';     Hint = 'Claude 5h + Cursor billing cycle' }
        [pscustomobject]@{ Name = 'jobs';      Hint = 'everything running' }
        [pscustomobject]@{ Name = 'help';   Hint = 'this list' }
        [pscustomobject]@{ Name = 'quit';   Hint = 'leave' }
    )
}

function Test-MaestroRoomColor {
    return -not (
        $env:NO_COLOR -or $env:BATON_NO_COLOR -or
        ($env:TERM -eq 'dumb')
    )
}

function Get-MaestroAnsi {
    param([string]$Name)
    if (-not (Test-MaestroRoomColor)) { return '' }
    switch ($Name) {
        'dim'    { return ([char]27 + '[90m') }
        'cyan'   { return ([char]27 + '[36m') }
        'green'  { return ([char]27 + '[32m') }
        'yellow' { return ([char]27 + '[33m') }
        'red'    { return ([char]27 + '[31m') }
        'bold'   { return ([char]27 + '[1m') }
        'reset'  { return ([char]27 + '[0m') }
        default  { return '' }
    }
}

function Test-MaestroWideRune {
    param([int]$Rune)
    if ($Rune -lt 0x1100) { return $false }
    return (
        ($Rune -ge 0x1100 -and $Rune -le 0x115F) -or
        $Rune -eq 0x2329 -or $Rune -eq 0x232A -or
        ($Rune -ge 0x2E80 -and $Rune -le 0xA4CF) -or
        ($Rune -ge 0xAC00 -and $Rune -le 0xD7A3) -or
        ($Rune -ge 0xF900 -and $Rune -le 0xFAFF) -or
        ($Rune -ge 0xFE10 -and $Rune -le 0xFE19) -or
        ($Rune -ge 0xFE30 -and $Rune -le 0xFE6F) -or
        ($Rune -ge 0xFF00 -and $Rune -le 0xFF60) -or
        ($Rune -ge 0xFFE0 -and $Rune -le 0xFFE6) -or
        ($Rune -ge 0x1F300 -and $Rune -le 0x1FAFF)
    )
}

function Get-MaestroDisplayWidth {
    param([string]$Text)
    $t = if ($null -eq $Text) { '' } else { [regex]::Replace($Text, [char]27 + '\[[0-9;]*[A-Za-z]', '') }
    $w = 0
    $enum = [System.Globalization.StringInfo]::GetTextElementEnumerator($t)
    while ($enum.MoveNext()) {
        $el = [string]$enum.GetTextElement()
        if ([string]::IsNullOrEmpty($el)) { continue }
        $rune = if ($el.Length -ge 2 -and [char]::IsHighSurrogate($el[0])) {
            [char]::ConvertToUtf32($el, 0)
        } else {
            [int][char]$el[0]
        }
        if (Test-MaestroWideRune $rune) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Format-MaestroRoomKeywords {
    $icon = @{
        projects  = '📁'
        worktrees = '🌳'
        status    = '📊'
        quota     = '⏱️'
        jobs      = '📋'
        help      = '❓'
        quit      = '👋'
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('  keywords')
    foreach ($k in @(Get-MaestroRoomKeywords)) {
        $pre = if ($icon.ContainsKey($k.Name)) { $icon[$k.Name] + ' ' } else { '' }
        $lines.Add(('    {0}{1,-10} {2}' -f $pre, $k.Name, $k.Hint))
    }
    return ($lines -join [Environment]::NewLine)
}

function Find-MaestroRoomExactPick {
    param(
        $Choices,
        [string]$Text
    )
    $t = if ($null -eq $Text) { '' } else { $Text.Trim() }
    if (-not $t) { return $null }
    $rows = @($Choices)
    $projects = @($rows | Where-Object { $_.Kind -eq 'project' })
    foreach ($c in $projects) {
        if ($t -eq [string]$c.Id -or $t -eq [string]$c.Label -or $t -eq [string]$c.Name) { return $c }
    }
    foreach ($k in @($script:MaestroProjectAliases.Keys)) {
        if ($t -eq [string]$k) {
            $id = [string]$script:MaestroProjectAliases[$k]
            $hit = @($projects | Where-Object { [string]$_.Id -eq $id } | Select-Object -First 1)
            if ($hit) { return $hit }
        }
    }
    foreach ($c in @($rows | Where-Object { $_.Kind -eq 'worktree' })) {
        if ($t -ne [string]$c.Id -and $t -ne [string]$c.Label) { continue }
        foreach ($p in $projects) {
            if (Test-MaestroChoiceMatchesProject -Choice $c -ProjectId ([string]$p.Id)) { return $p }
        }
        return $c
    }
    return $null
}

function Resolve-MaestroRoomCurrent {
    param($Pick, $Choices)
    if (-not $Pick) { return $null }
    if ([string]$Pick.Kind -eq 'project') { return [string]$Pick.Id }
    foreach ($p in @($Choices | Where-Object { $_.Kind -eq 'project' })) {
        if (Test-MaestroChoiceMatchesProject -Choice $Pick -ProjectId ([string]$p.Id)) {
            return [string]$p.Id
        }
    }
    return [string]$Pick.Id
}

function Get-MaestroRoomScrollItems {
    param(
        $Choices,
        [string]$CurrentProject,
        [ValidateSet('all', 'projects', 'worktrees')][string]$Mode = 'all'
    )
    $items = [System.Collections.Generic.List[object]]::new()
    if ($Mode -eq 'worktrees') {
        foreach ($c in @($Choices | Where-Object { $_.Kind -eq 'worktree' })) {
            $items.Add([pscustomobject]@{ Kind = 'worktree'; Run = [string]$c.Id; Label = [string]$c.Label })
        }
        return @($items)
    }
    if ($Mode -eq 'projects') {
        foreach ($c in @($Choices | Where-Object { $_.Kind -eq 'project' })) {
            $items.Add([pscustomobject]@{ Kind = 'project'; Run = [string]$c.Id; Label = [string]$c.Id })
        }
        return @($items)
    }
    foreach ($c in @($Choices | Where-Object { $_.Kind -eq 'project' })) {
        $items.Add([pscustomobject]@{
            Kind    = 'project'
            Group   = 'project'
            Run     = [string]$c.Id
            Label   = [string]$c.Id
            Current = [bool]($CurrentProject -and $c.Id -eq $CurrentProject)
        })
    }
    foreach ($a in @('status', 'quota', 'worktrees', 'jobs', 'help', 'quit')) {
        $items.Add([pscustomobject]@{
            Kind    = 'action'
            Group   = 'run'
            Run     = $a
            Label   = $a
            Current = $false
        })
    }
    return @($items)
}

function Find-MaestroScrollIndex {
    param(
        $Items,
        [string]$Run
    )
    $arr = @($Items)
    if (-not $Run) { return 0 }
    for ($i = 0; $i -lt $arr.Count; $i++) {
        if ([string]$arr[$i].Run -eq $Run) { return $i }
    }
    return 0
}

function Get-MaestroRoomPaintWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -ge 20) { return $w }
    } catch { }
    return 80
}

function Get-MaestroRoomPaintHeight {
    param(
        [string]$Text,
        [int]$Width = 0
    )
    if ($Width -lt 1) { $Width = Get-MaestroRoomPaintWidth }
    $n = 0
    foreach ($ln in @($(if ($null -eq $Text) { @('') } else { $Text -split '\r?\n' }))) {
        $len = Get-MaestroDisplayWidth $ln
        if ($len -lt 1) { $n += 1; continue }
        $n += [int][Math]::Ceiling($len / [double]$Width)
    }
    return $n
}

function Move-MaestroScrollIndex {
    param(
        [int]$Count,
        [int]$Index,
        [int]$Delta
    )
    if ($Count -lt 1) { return 0 }
    $n = $Index + $Delta
    if ($n -lt 0) { return 0 }
    if ($n -ge $Count) { return ($Count - 1) }
    return $n
}

function Format-MaestroRoomRedraw {
    param(
        [string]$Banner,
        [int]$PreviousLineCount = 0
    )
    $esc = [char]27
    $lines = @(if ($null -eq $Banner) { @() } else { $Banner -split '\r?\n' })
    $sb = [System.Text.StringBuilder]::new()
    if ($PreviousLineCount -gt 0) {
        [void]$sb.Append($esc)
        [void]$sb.Append('[')
        [void]$sb.Append($PreviousLineCount)
        [void]$sb.Append('F')
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -gt 0) { [void]$sb.Append("`n") }
        [void]$sb.Append($lines[$i])
        [void]$sb.Append($esc)
        [void]$sb.Append('[K')
    }
    [void]$sb.Append("`n")
    [void]$sb.Append($esc)
    [void]$sb.Append('[J')
    return $sb.ToString()
}

function Format-MaestroInputRedraw {
    <# Rebuild the baton › input line after a keystroke.

       Single-line wipe (`\r` + spaces) breaks once prefix+buffer wraps the
       terminal width: each character then reprints on a new row. Move to the
       first paint row, clear to end of screen, then rewrite. #>
    param(
        [string]$Prefix,
        [string]$Buffer = '',
        [int]$PreviousRowCount = 1,
        [int]$Width = 0
    )
    if ($Width -lt 1) { $Width = Get-MaestroRoomPaintWidth }
    $esc = [char]27
    $rows = Get-MaestroRoomPaintHeight -Text ($Prefix + $Buffer) -Width $Width
    if ($rows -lt 1) { $rows = 1 }
    $sb = [System.Text.StringBuilder]::new()
    $prev = [Math]::Max(1, $PreviousRowCount)
    if ($prev -gt 1) {
        [void]$sb.Append($esc)
        [void]$sb.Append('[')
        [void]$sb.Append($prev - 1)
        [void]$sb.Append('A')
    }
    [void]$sb.Append("`r")
    [void]$sb.Append($esc)
    [void]$sb.Append('[J')
    [void]$sb.Append($Prefix)
    [void]$sb.Append($Buffer)
    return [pscustomobject]@{
        Text = $sb.ToString()
        Rows = $rows
    }
}

function Get-MaestroScrollWindow {
    param(
        $Items,
        [int]$Index = 0,
        [int]$Size = 0
    )
    $arr = @($Items)
    if ($arr.Count -eq 0) { return @() }
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $arr.Count) { $Index = $arr.Count - 1 }
    if ($Size -lt 1) {
        $Size = if ($arr.Count -le 40) { $arr.Count } else { 12 }
    }
    $start = [Math]::Max(0, $Index - [int][Math]::Floor(($Size - 1) / 2.0))
    if (($start + $Size) -gt $arr.Count) { $start = [Math]::Max(0, $arr.Count - $Size) }
    $end = [Math]::Min($arr.Count, $start + $Size) - 1
    $out = [System.Collections.Generic.List[object]]::new()
    for ($i = $start; $i -le $end; $i++) {
        $row = $arr[$i]
        $out.Add([pscustomobject]@{
            Kind      = $row.Kind
            Group     = $row.Group
            Run       = $row.Run
            Label     = $row.Label
            Current   = [bool]$row.Current
            Selected  = ($i -eq $Index)
            Index     = $i
            MoreAbove = ($start -gt 0)
            MoreBelow = ($end -lt ($arr.Count - 1))
        })
    }
    return @($out)
}

function Format-MaestroRoomScroll {
    param(
        $Items,
        [int]$Index = 0,
        [int]$Size = 0
    )
    $arr = @($Items)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($arr.Count -eq 0) {
        $lines.Add('  ↑↓ scroll · enter runs')
        $lines.Add('    (nothing to scroll)')
        return ($lines -join [Environment]::NewLine)
    }
    $win = @(Get-MaestroScrollWindow -Items $arr -Index $Index -Size $Size)
    if ($win.Count -gt 0 -and $win[0].MoreAbove) { $lines.Add('    ↑ more') }
    $seenRun = $false
    $runIcon = @{
        status    = '📊'
        quota     = '⏱️'
        worktrees = '🌳'
        jobs      = '📋'
        help      = '❓'
        quit      = '👋'
    }
    foreach ($row in $win) {
        if (([string]$row.Group -eq 'run' -or [string]$row.Kind -eq 'action') -and -not $seenRun) {
            $lines.Add(('    {0}── run ──{1}' -f (Get-MaestroAnsi dim), (Get-MaestroAnsi reset)))
            $seenRun = $true
        }
        $mark = if ($row.Selected) { '▸' } else { ' ' }
        $label = [string]$row.Label
        $icon = ''
        if ($runIcon.ContainsKey([string]$row.Run)) { $icon = $runIcon[[string]$row.Run] + ' ' }
        $body = $icon + $label
        if ($row.Selected) {
            $body = (Get-MaestroAnsi cyan) + (Get-MaestroAnsi bold) + $mark + ' ' + $body + (Get-MaestroAnsi reset)
        } elseif ($row.Current) {
            $body = (Get-MaestroAnsi green) + $mark + ' ' + $body + (Get-MaestroAnsi reset)
        } else {
            $body = $mark + ' ' + $body
        }
        $lines.Add('    ' + $body)
    }
    if ($win.Count -gt 0 -and $win[-1].MoreBelow) { $lines.Add('    ↓ more') }
    return ($lines -join [Environment]::NewLine)
}

function Test-MaestroChoiceMatchesProject {
    param($Choice, [string]$ProjectId)
    if (-not $Choice -or [string]::IsNullOrWhiteSpace($ProjectId)) { return $false }
    $projId = $ProjectId.Trim().ToLowerInvariant()
    $label = ([string]$Choice.Label).ToLowerInvariant()
    $id = ([string]$Choice.Id).ToLowerInvariant()
    $path = ([string]$Choice.Path).ToLowerInvariant()
    if ($id -eq $projId -or $label -eq $projId) { return $true }
    if ($projId.Length -ge 3) {
        if ($label.Contains($projId) -or $id.Contains($projId) -or $path.Contains($projId)) { return $true }
    }
    $prefixes = @{
        'canvas-toolchain' = @('ct-')
        'atomicforge'      = @('af-')
        'answerbot'        = @('ab-')
        'towerdefensegame' = @('td-')
        'bench-gauntlet'   = @('bg-')
        'bookprofile'      = @('bp-')
        'grimlore'         = @('gl-')
        'baton'            = @('maestro', 'wt-front', 'wt-factory')
    }
    foreach ($pre in @($prefixes[$projId])) {
        if ($label.StartsWith($pre) -or $id.StartsWith($pre)) { return $true }
    }
    return $false
}

function Get-MaestroProjectStatus {
    param(
        [string]$BatonHome,
        [string]$Project,
        $Choices
    )
    if ([string]::IsNullOrWhiteSpace($Project)) {
        return [pscustomobject]@{
            Text      = 'No project yet. Type projects or name one.'
            Worktrees = @()
        }
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("  status · $Project")
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    $mine = @()
    if (Test-Path -LiteralPath $jobsDir) {
        $mine = @(
            Get-MaestroJobRecords -JobsDir $jobsDir |
                Where-Object { [string]$_.Job.project -eq $Project } |
                ForEach-Object { $_.Job } |
                Sort-Object created_at -Descending
        )
    }
    $lines.Add('  jobs')
    if ($mine.Count -eq 0) {
        $lines.Add('    (none)')
    } else {
        foreach ($j in ($mine | Select-Object -First 8)) {
            $goal = [string]$j.goal
            if ($goal.Length -gt 48) { $goal = $goal.Substring(0, 45) + '...' }
            $lines.Add(('    {0,-16} {1,-12} {2}' -f $j.id, $j.status, $goal))
        }
    }
    $wts = @($Choices | Where-Object {
        $_.Kind -eq 'worktree' -and (Test-MaestroChoiceMatchesProject -Choice $_ -ProjectId $Project)
    })
    $lines.Add('  worktrees')
    if ($wts.Count -eq 0) {
        $lines.Add('    (none)')
    } else {
        $n = 1
        foreach ($w in $wts) {
            $lines.Add(('    {0,2}  {1}' -f $n, $w.Label))
            $n++
        }
        $lines.Add('  Type a number to pick a worktree.')
    }
    return [pscustomobject]@{
        Text      = ($lines -join [Environment]::NewLine)
        Worktrees = $wts
    }
}

function Format-MaestroSeatLabel {
    param([string]$Name)
    $n = if ($null -eq $Name) { '' } else { $Name.Trim() }
    foreach ($pre in @('openrouter-', 'opencode-')) {
        if ($n.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) {
            return $n.Substring($pre.Length)
        }
    }
    return $n
}

function Format-MaestroBoxLine {
    param([string]$Text, [int]$Inner = 62)
    $t = if ($null -eq $Text) { '' } else { $Text }
    $w = Get-MaestroDisplayWidth $t
    if ($w -gt $Inner) {
        $plain = [regex]::Replace($t, [char]27 + '\[[0-9;]*[A-Za-z]', '')
        $cut = ''
        $enum = [System.Globalization.StringInfo]::GetTextElementEnumerator($plain)
        while ($enum.MoveNext()) {
            $el = [string]$enum.GetTextElement()
            $next = $cut + $el
            if ((Get-MaestroDisplayWidth $next) -gt $Inner) { break }
            $cut = $next
        }
        $t = $cut
        $w = Get-MaestroDisplayWidth $t
    }
    if ($w -lt $Inner) { $t = $t + (' ' * ($Inner - $w)) }
    $dim = Get-MaestroAnsi dim
    $rst = Get-MaestroAnsi reset
    return ($dim + '│' + $rst + $t + $dim + '│' + $rst)
}

function Format-MaestroRoomBanner {
    param(
        [string]$SeatName,
        $Choices,
        [string]$CurrentProject,
        [string]$LastList,
        [int]$ScrollIndex = 0,
        [string]$ScrollMode = 'all'
    )
    $inner = 62
    $rule = [string]::new([char]0x2500, $inner)
    $mode = if ($ScrollMode) { $ScrollMode } else { 'all' }
    $items = @(Get-MaestroRoomScrollItems -Choices $Choices -CurrentProject $CurrentProject -Mode $mode)
    $dim = Get-MaestroAnsi dim
    $cya = Get-MaestroAnsi cyan
    $yel = Get-MaestroAnsi yellow
    $grn = Get-MaestroAnsi green
    $rst = Get-MaestroAnsi reset
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($dim + '╭' + $rule + '╮' + $rst)
    $right = if ($CurrentProject) {
        ('{0}🟢 {1}{2}' -f $grn, $CurrentProject, $rst)
    } else {
        $seat = Format-MaestroSeatLabel -Name $SeatName
        ('{0}💺 {1}{2}' -f $yel, $seat, $rst)
    }
    $title = ('  {0}BATON{1} · {2}' -f $cya, $rst, $right)
    $lines.Add((Format-MaestroBoxLine -Text $title -Inner $inner))
    $hint = ('  {0}↑↓{1} move · {0}enter{1} runs · type here or English' -f $cya, $rst)
    $lines.Add((Format-MaestroBoxLine -Text $hint -Inner $inner))
    $lines.Add($dim + '├' + $rule + '┤' + $rst)
    foreach ($row in ((Format-MaestroRoomScroll -Items $items -Index $ScrollIndex) -split '\r?\n')) {
        $lines.Add((Format-MaestroBoxLine -Text $row -Inner $inner))
    }
    $lines.Add($dim + '╰' + $rule + '╯' + $rst)
    return ($lines -join [Environment]::NewLine)
}

function Get-MaestroRoomChoices {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [string[]]$WorktreeRoots
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $projRoot = Join-Path $BatonHome 'projects'
    if (Test-Path -LiteralPath $projRoot) {
        foreach ($dir in Get-ChildItem -LiteralPath $projRoot -Directory -ErrorAction SilentlyContinue) {
            $pj = Join-Path $dir.FullName 'project.json'
            if (-not (Test-Path -LiteralPath $pj)) { continue }
            try { $rec = Get-Content -LiteralPath $pj -Raw | ConvertFrom-Json } catch { continue }
            $id = if ($rec.id) { [string]$rec.id } else { $dir.Name }
            $name = if ($rec.name) { [string]$rec.name } else { $id }
            $path = [string]$rec.folder
            if ($seen.Add($id)) {
                $rows.Add([pscustomobject]@{
                    Id    = $id
                    Label = $id
                    Name  = $name
                    Path  = $path
                    Kind  = 'project'
                })
            }
        }
    }

    $roots = @($WorktreeRoots | Where-Object { $_ })
    if ($roots.Count -eq 0 -and $env:BATON_WORKTREE_ROOT) {
        $roots = @($env:BATON_WORKTREE_ROOT)
    }
    if ($roots.Count -eq 0) {
        $realHome = Join-Path $HOME '.baton'
        if ($BatonHome -eq $realHome) {
            $roots = @(
                (Join-Path $HOME '.herdr/worktrees'),
                '/Users/kev/Dev/.baton-worktrees'
            )
        }
    }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            if ($d.Name.StartsWith('.')) { continue }
            $nested = @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'worktree-*' })
            $targets = if ($nested.Count -gt 0) { $nested } else { @($d) }
            foreach ($t in $targets) {
                $leaf = $t.Name
                if ($leaf -match '^go-\d{4}-') { continue }
                if (-not $seen.Add($leaf)) { continue }
                $rows.Add([pscustomobject]@{
                    Id    = $leaf
                    Label = $leaf
                    Name  = $d.Name
                    Path  = $t.FullName
                    Kind  = 'worktree'
                })
            }
        }
    }

    return @(
        $rows | Sort-Object @{ Expression = { if ($_.Kind -eq 'project') { 0 } else { 1 } } }, Id
    )
}

function Resolve-MaestroUtterance {
    param(
        [Parameter(Mandatory)][string]$Text,
        $Choices,
        [string]$CurrentProject
    )
    $raw = $Text.Trim()
    $project = $null
    $goal = $raw
    $needles = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($Choices)) {
        if ($c.Id) { $needles.Add([pscustomobject]@{ Needle = [string]$c.Id; Id = [string]$c.Id }) }
        if ($c.Label -and $c.Label -ne $c.Id) {
            $needles.Add([pscustomobject]@{ Needle = [string]$c.Label; Id = [string]$c.Id })
        }
        if ($c.Name -and $c.Name -ne $c.Id) {
            $needles.Add([pscustomobject]@{ Needle = [string]$c.Name; Id = [string]$c.Id })
        }
    }
    foreach ($k in $script:MaestroProjectAliases.Keys) {
        $needles.Add([pscustomobject]@{ Needle = [string]$k; Id = [string]$script:MaestroProjectAliases[$k] })
    }
    $best = $null
    $bestLen = 0
    foreach ($n in $needles) {
        $needle = [string]$n.Needle
        if ($needle.Length -lt 2) { continue }
        if ($raw.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $needle.Length -gt $bestLen) {
            $best = $n
            $bestLen = $needle.Length
        }
    }
    if ($best) {
        $project = [string]$best.Id
        $stripped = [regex]::Replace($raw, [regex]::Escape([string]$best.Needle), '', 'IgnoreCase')
        $stripped = [regex]::Replace($stripped, '^\s*(in|on|for)\s+', '', 'IgnoreCase')
        $stripped = $stripped.Trim().TrimStart(',', ':', '-', ' ').Trim()
        $goal = if ($stripped) { $stripped } else { $raw }
    } elseif ($CurrentProject) {
        $project = $CurrentProject
        $goal = $raw
    }
    return [pscustomobject]@{ Project = $project; Goal = $goal }
}

function New-MaestroJob {
    param(
        [string]$BatonHome = $(if ($env:BATON_HOME) { $env:BATON_HOME } else { Join-Path $HOME '.baton' }),
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$Goal,
        [string]$Stakes = 'standard',
        [string]$MissedFire = 'catch-up',
        [string]$Source = 'cli',
        [string]$Status = 'admitted',
        [ValidateSet('local', 'free', 'paid')][string]$MaxCostTier = 'free',
        [string]$Provider
    )
    $proj = $Project.Trim()
    $text = $Goal.Trim()
    if (-not $proj) { throw 'project is required' }
    if (-not $text) { throw 'goal is required' }
    $jobsDir = Get-MaestroJobsDir -BatonHome $BatonHome
    if (-not (Test-Path -LiteralPath $jobsDir)) {
        New-Item -ItemType Directory -Force -Path $jobsDir | Out-Null
    }
    $id = 'mj-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $job = [ordered]@{
        id            = $id
        project       = $proj
        goal          = $text
        stakes        = $Stakes
        missed_fire   = $MissedFire
        source        = $Source
        status        = $Status
        run_id        = $null
        provider      = $Provider
        max_cost_tier = $MaxCostTier
        created_at    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $path = Join-Path $jobsDir "$id.json"
    ($job | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-MaestroEvent -Root $jobsDir -JobId $id -Kind 'created' -Status $Status -Provider $Provider
    return [pscustomobject]$job
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
    $proj = [string]$job.project
    $goalText = Expand-MaestroGoalWithHandoff -Goal ([string]$job.goal) -JobId ([string]$job.id) -BatonHome $BatonHome

    $patch = @{
        run_id   = $null
        provider = $null
        status   = 'done'
    }
    $exit = 0

    if (Test-MaestroUseHerdr -Project $proj) {
        . (Join-Path $PSScriptRoot 'maestro-herdr.ps1')
        $prevTarget = $env:HERDR_TARGET
        try {
            $env:HERDR_TARGET = Resolve-MaestroHerdrTarget -Project $proj -BatonHome $BatonHome
            $hf = Invoke-MaestroHerdrFire -Goal $goalText -Target $env:HERDR_TARGET
            $patch.run_id = [string]$hf.run_id
            $patch.provider = [string]$hf.provider
            $patch.status = [string]$hf.status
            $exit = [int]$hf.exit
            Update-MaestroSessionAfterFire -Project $proj -Provider $patch.provider -BatonHome $BatonHome
        } catch {
            $patch.status = 'done'
            $patch.provider = 'herdr:error'
            $exit = 1
        } finally {
            if ($null -eq $prevTarget) { Remove-Item Env:\HERDR_TARGET -ErrorAction SilentlyContinue }
            else { $env:HERDR_TARGET = $prevTarget }
        }
    } else {
        $goArgs = @{
            Goal        = $goalText
            RepoPath    = $repoPath
            FleetPath   = $FleetPath
            Execute     = $true
            NoPlanGate  = $true
            NoVerify    = $true
            Stakes      = $stakes
            Json        = $true
            MaxCostTier = (Get-MaestroFireMaxCostTier -Job $job)
        }

        $raw = ''
        try {
            $raw = (& pwsh -NoProfile -File $FleetGo @goArgs | Out-String).Trim()
            $exit = $LASTEXITCODE
        } catch {
            $raw = $_.Exception.Message
            $exit = 1
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
    }

    Update-MaestroJobFile -Path $jobPath -Patch $patch
    Write-MaestroEvent -Root $JobsDir -JobId ([string]$job.id) -Kind 'fired' -Status $patch.status -RunId $patch.run_id -Provider $patch.provider
    if ([string]$patch.provider -match '(?i)fable') {
        try {
            . (Join-Path $PSScriptRoot 'officers-lib.ps1')
            Record-SchedulerFableFire -BatonHome $BatonHome
        } catch { }
    }

    return [pscustomobject]@{
        id       = [string]$job.id
        status   = $patch.status
        run_id   = $patch.run_id
        provider = $patch.provider
        exit     = $exit
    }
}
