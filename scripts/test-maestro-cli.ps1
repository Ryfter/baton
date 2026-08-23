# scripts/test-maestro-cli.ps1
# Hermetic tests: `baton` is the room. Type English. status lists worktrees.
# Never touches the real ~/.baton jobs, never fires fleet-go.
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$here = $PSScriptRoot
$baton = Join-Path $here 'baton.ps1'
$maestro = Join-Path $here 'maestro.ps1'
$lib = Join-Path $here 'maestro-lib.ps1'

Assert 'T0 maestro.ps1 exists' (Test-Path -LiteralPath $maestro)

$helpOut = & pwsh -NoProfile -File $baton --help 2>&1 | Out-String
Assert 'V1 baton --help still lists go' ($helpOut -match '\bgo\b')
Assert 'V2 baton --help does not teach maestro start' ($helpOut -notmatch 'maestro start')

$root = Join-Path ([IO.Path]::GetTempPath()) ("bmaestro-" + [guid]::NewGuid().ToString('N'))
$home2 = Join-Path $root 'home'
$bin2 = Join-Path $root 'bin'
$wt2 = Join-Path $root 'wtrees'
New-Item -ItemType Directory -Force -Path $home2, $bin2, $wt2 | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $wt2 'ct-install-easy'), (Join-Path $wt2 'td-playable') | Out-Null

function Write-Proj($Id, $Name, $Folder) {
    $d = Join-Path $home2 'projects' $Id
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    @{ id = $Id; name = $Name; folder = $Folder } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $d 'project.json') -Encoding utf8
}
Write-Proj 'baton' 'Baton' '/tmp/fake-baton'
Write-Proj 'canvas-toolchain' 'Canvas Toolchain' '/tmp/fake-ct'

$oldHome = $env:BATON_HOME
$oldRepo = $env:BATON_REPO_ROOT
$oldWt = $env:BATON_WORKTREE_ROOT
$env:BATON_HOME = $home2
$env:BATON_REPO_ROOT = (Split-Path $here -Parent)
$env:BATON_WORKTREE_ROOT = $wt2

try {
    . $lib

    $tierPaid = Get-MaestroFireMaxCostTier -Job ([pscustomobject]@{ status = 'admitted' })
    Assert 'L1 missing max_cost_tier defaults paid' ($tierPaid -eq 'paid')
    $tierFree = Get-MaestroFireMaxCostTier -Job ([pscustomobject]@{ max_cost_tier = 'free' })
    Assert 'L2 job max_cost_tier=free honored' ($tierFree -eq 'free')

    $seat = Get-MaestroConductorSeat
    Assert 'L3 conductor seat is a non-empty name' (-not [string]::IsNullOrWhiteSpace([string]$seat.Name))
    Assert 'L4 default seat cost_tier is free' ([string]$seat.CostTier -eq 'free')

    $choices = @(Get-MaestroRoomChoices -BatonHome $home2)
    $ids = @($choices | ForEach-Object { [string]$_.Id })
    $labels = @($choices | ForEach-Object { [string]$_.Label })
    Assert 'W1 choices include registered baton' ($ids -contains 'baton')
    Assert 'W2 choices include canvas-toolchain' ($ids -contains 'canvas-toolchain')
    Assert 'W3 choices include worktree ct-install-easy' ($labels -contains 'ct-install-easy' -or $ids -contains 'ct-install-easy')
    Assert 'W4 choices include worktree td-playable' ($labels -contains 'td-playable' -or $ids -contains 'td-playable')

    $parsed = Resolve-MaestroUtterance -Text 'in canvas-toolchain, simplify install' -Choices $choices
    Assert 'U1 utterance project' ([string]$parsed.Project -eq 'canvas-toolchain')
    Assert 'U2 utterance goal keeps the work' ([string]$parsed.Goal -match 'simplify install')

    $job = New-MaestroJob -BatonHome $home2 -Project 'baton' -Goal 'ship the front door' -MaxCostTier free -Source cli
    Assert 'J1 New-MaestroJob returns mj- id' ([string]$job.id -match '^mj-[0-9a-f]{12}$')
    Assert 'J2 source is cli' ([string]$job.source -eq 'cli')
    Assert 'J3 max_cost_tier is free' ([string]$job.max_cost_tier -eq 'free')

    $roomOut = "worktrees`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'R1 room worktrees+quit exit 0' ($LASTEXITCODE -eq 0)
    Assert 'R2 room worktrees lists a project' ($roomOut -match 'canvas-toolchain')
    Assert 'R3 room worktrees lists a worktree' ($roomOut -match 'ct-install-easy')
    Assert 'R4 room does not teach maestro start' ($roomOut -notmatch 'maestro start')

    $talkOut = "in canvas-toolchain, simplify install`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'R5 room English exit 0' ($LASTEXITCODE -eq 0)
    $jobsDir = Join-Path $home2 'maestro/jobs'
    $written = @(Get-ChildItem -LiteralPath $jobsDir -Filter 'mj-*.json' -ErrorAction SilentlyContinue)
    $foundTalk = $false
    foreach ($f in $written) {
        $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ([string]$j.project -eq 'canvas-toolchain' -and [string]$j.goal -match 'simplify install') {
            $foundTalk = $true
        }
    }
    Assert 'R6 room English admitted a job' $foundTalk

    $pickOut = "projects`n2`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'R7 picking a number from projects exit 0' ($LASTEXITCODE -eq 0)
    Assert 'R8 pick acknowledges a choice' ($pickOut -match '(?i)(working on|picked|selected|on )')

    $projOut = "projects`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'R9 projects lists a registered project' ($projOut -match '(?m)^\s+\d+\s+canvas-toolchain\b')
    Assert 'R10 projects does not list worktrees' ($projOut -notmatch '(?m)^\s+\d+\s+ct-install-easy\b')

    $keys = @(Get-MaestroRoomKeywords)
    $keyNames = @($keys | ForEach-Object { [string]$_.Name })
    Assert 'K1 keywords include status' ($keyNames -contains 'status')
    Assert 'K1b keywords include projects' ($keyNames -contains 'projects')
    Assert 'K2 keywords include help' ($keyNames -contains 'help')
    Assert 'K3 keywords include quit' ($keyNames -contains 'quit')
    $sheet = Format-MaestroRoomKeywords
    Assert 'K4 keyword sheet names status' ($sheet -match '(?m)^\s+.*\bstatus\b')

    $quotaOut = "quota`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'Q1 room quota exit 0' ($LASTEXITCODE -eq 0)
    Assert 'Q2 room quota mentions Cursor cycle' ($quotaOut -match 'Cursor cycle|cursor cycle')

    $helpOut = "help`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'K5 help reprints the sheet' ($helpOut -match '\bstatus\b' -and $helpOut -match '\bquit\b')

    $items = @(Get-MaestroRoomScrollItems -Choices $choices)
    $runs = @($items | ForEach-Object { [string]$_.Run })
    Assert 'G1 scroll lists every registered project' (
        ($runs -contains 'baton') -and ($runs -contains 'canvas-toolchain')
    )
    Assert 'G2 scroll has runnables, not fake example slices' (
        ($runs -contains 'worktrees') -and ($runs -contains 'jobs') -and
        ($runs -contains 'status') -and ($runs -contains 'quota') -and
        (($items | ForEach-Object { $_.Label }) -join ' ') -notmatch 'ship the next slice'
    )
    $afterPick = @(Get-MaestroRoomScrollItems -Choices $choices -CurrentProject 'canvas-toolchain')
    Assert 'G3 after pick, status is a runnable' (
        @($afterPick | ForEach-Object { [string]$_.Run }) -contains 'status'
    )
    $onlyProj = @(Get-MaestroRoomScrollItems -Choices $choices -Mode 'projects')
    Assert 'G4 projects mode is only projects' (
        @($onlyProj | ForEach-Object { [string]$_.Kind } | Select-Object -Unique) -eq @('project') -and
        $onlyProj.Count -ge 2
    )
    $idx = Move-MaestroScrollIndex -Count $items.Count -Index 0 -Delta -1
    Assert 'G5 up from first stays on first' ($idx -eq 0)
    $last = Move-MaestroScrollIndex -Count $items.Count -Index ($items.Count - 1) -Delta 1
    Assert 'G5b down from last stays on last' ($last -eq ($items.Count - 1))
    $win = @(Get-MaestroScrollWindow -Items $items -Index 0 -Size 5)
    Assert 'G6 window marks the selected row' ([bool]($win | Where-Object { $_.Selected -and $_.Run -eq $items[0].Run }))
    $card0 = Format-MaestroRoomBanner -SeatName 'test' -Choices $choices -ScrollIndex 0
    $card1 = Format-MaestroRoomBanner -SeatName 'test' -Choices $choices -ScrollIndex 1
    Assert 'G8 down moves ▸ off the first project' (
        ($card0 -match '(?m)▸\s+baton\b') -and ($card1 -notmatch '(?m)▸\s+baton\b')
    )
    $redraw = Format-MaestroRoomRedraw -Banner $card1 -PreviousLineCount 12
    Assert 'G9 redraw goes back up the card instead of dumping another list' (
        $redraw.StartsWith([char]27 + '[12F') -and ($redraw -match '▸')
    )
    $listed = Format-MaestroRoomBanner -SeatName 'test' -Choices $choices -LastList 'projects'
    Assert 'G10 card keeps the full roster after a projects list' (
        $listed -match 'quit' -and $listed -match 'canvas-toolchain' -and $listed -match '── run'
    )
    $tall = Get-MaestroRoomPaintHeight -Text ('x' * 64) -Width 32
    Assert 'G11 paint height counts wrapped terminal rows' ($tall -eq 2)
    $in1 = Format-MaestroInputRedraw -Prefix 'baton › ' -Buffer ('a' * 30) -PreviousRowCount 1 -Width 40
    Assert 'G18 input redraw stays on one row before wrap' ([int]$in1.Rows -eq 1)
    $clearSeq = [char]27 + '[J'
    Assert 'G18b input redraw clears from cursor' ($in1.Text.IndexOf($clearSeq) -ge 0)
    $in2 = Format-MaestroInputRedraw -Prefix 'baton › ' -Buffer ('b' * 80) -PreviousRowCount 2 -Width 40
    Assert 'G19 wrapped input moves up before rewrite' (
        ([int]$in2.Rows -ge 2) -and $in2.Text.StartsWith([char]27 + '[1A')
    )
    $in3 = Format-MaestroInputRedraw -Prefix 'baton › ' -Buffer 'x' -PreviousRowCount 3 -Width 40
    Assert 'G20 backspace after wrap still climbs prior rows' (
        ([int]$in3.Rows -eq 1) -and $in3.Text.StartsWith([char]27 + '[2A')
    )
    $idxNow = Find-MaestroScrollIndex -Items $afterPick -Run 'canvas-toolchain'
    Assert 'G12 pick lands ▸ on that project' (
        $idxNow -ge 0 -and [string]$afterPick[$idxNow].Run -eq 'canvas-toolchain'
    )
    Assert 'G13 emoji display width is two cells' ((Get-MaestroDisplayWidth '📁') -eq 2)
    $box = Format-MaestroBoxLine -Text 'hi' -Inner 62
    Assert 'G14 box line is 64 cells wide' ((Get-MaestroDisplayWidth $box) -eq 64)
    Assert 'G15 card has no █░ meter' ($card0 -notmatch '[█░]')
    Assert 'G16 run rows keep the useful icons' ($card0 -match '🌳' -and $card0 -match '📊')
    Assert 'G17 seat label drops the openrouter- prefix' ((Format-MaestroSeatLabel -Name 'openrouter-ox-alpha') -eq 'ox-alpha')

    $usagePath = Join-Path $root 'usage-journal.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'lockout'; worker = 'grok-cli'; reason = 'cap'; reset_at = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $usagePath -Encoding utf8NoBOM
    Assert 'RA1 grok lockout is unavailable' (-not (Test-MaestroInstrumentAvailable -Name 'grok-cli' -BatonHome $root))
    Assert 'RA2 ox-alpha stays available when grok is out' (Test-MaestroInstrumentAvailable -Name 'openrouter-ox-alpha' -BatonHome $root)
    $seat = Get-MaestroConductorSeat -Provider 'grok-cli' -BatonHome $root
    Assert 'RA3 seat skips locked-out grok for ox-alpha' ([string]$seat.Name -eq 'openrouter-ox-alpha')

    $lonely = "status`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'ST1 status without a project asks to pick' ($lonely -match '(?i)pick a project|no project')
    $scoped = "in canvas-toolchain, simplify install`nstatus`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'ST2 status names the current project' ($scoped -match 'canvas-toolchain')
    Assert 'ST3 status is not a full project picker' ($scoped -notmatch '(?m)^\s+1\s+baton\s+project')

    $bare = "quit" | & pwsh -NoProfile -File $baton 2>&1 | Out-String
    Assert 'B1 bare baton is the room' ($LASTEXITCODE -eq 0 -and $bare -match '(?i)status')
    Assert 'B2 room shows keywords on entry' ($bare -match '\bstatus\b' -and $bare -match '\bhelp\b')
    Assert 'B3 room shows a type-here cue' ($bare -match '(?i)type here')
    Assert 'B4 room scroll lists all seeded projects' ($bare -match 'canvas-toolchain' -and $bare -match '\bbaton\b')
    Assert 'B5 room says enter runs' ($bare -match '(?i)enter runs|↑')

    $namePick = "canvas-toolchain`nquit" | & pwsh -NoProfile -File $maestro 2>&1 | Out-String
    Assert 'B6 typing a project name picks it' ($namePick -match '(?i)working on canvas-toolchain')
    $nameJobs = @(Get-ChildItem -LiteralPath $jobsDir -Filter 'mj-*.json' -ErrorAction SilentlyContinue)
    $nameAdmitted = $false
    foreach ($f in $nameJobs) {
        $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ([string]$j.goal -eq 'canvas-toolchain') { $nameAdmitted = $true }
    }
    Assert 'B7 typing a project name does not admit a job' (-not $nameAdmitted)

    $exact = Find-MaestroRoomExactPick -Choices $choices -Text 'canvas-toolchain'
    Assert 'G7 exact pick resolves a registered project' ([string]$exact.Id -eq 'canvas-toolchain')

    $jsonOut = & pwsh -NoProfile -File $maestro -NoWatch -Json 2>&1 | Out-String
    Assert 'P1 seat --json exit 0' ($LASTEXITCODE -eq 0)
    $startObj = $null
    try { $startObj = $jsonOut | ConvertFrom-Json } catch { $startObj = $null }
    Assert 'P2 seat is JSON' ($null -ne $startObj)
    Assert 'P3 seat cost_tier free' ([string]$startObj.cost_tier -eq 'free')

    $instOut = & pwsh -NoProfile -File $maestro install --bin-dir $bin2 --json 2>&1 | Out-String
    Assert 'I1 install --json exit 0' ($LASTEXITCODE -eq 0)
    $instObj = $null
    try { $instObj = $instOut | ConvertFrom-Json } catch { $instObj = $null }
    Assert 'I2 install wrote wrapper' ($instObj -and (Test-Path -LiteralPath ([string]$instObj.path)))
} finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRepo) { Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue }
    else { $env:BATON_REPO_ROOT = $oldRepo }
    if ($null -eq $oldWt) { Remove-Item Env:BATON_WORKTREE_ROOT -ErrorAction SilentlyContinue }
    else { $env:BATON_WORKTREE_ROOT = $oldWt }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -gt 0) {
    Write-Host "test-maestro-cli: $script:Fail FAILED"
    exit 1
}
Write-Host 'test-maestro-cli: OK'
exit 0
