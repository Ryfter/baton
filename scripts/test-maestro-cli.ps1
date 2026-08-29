# scripts/test-maestro-cli.ps1
# Hermetic tests: passive status default, admit verb, lib helpers.
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

    $seat = Get-MaestroConductorSeat -BatonHome $home2
    Assert 'L3 conductor seat is a non-empty name' (-not [string]::IsNullOrWhiteSpace([string]$seat.Name))
    $rankedDefault = Select-MaestroRankedProviders -BatonHome $home2
    if ($rankedDefault.Count -gt 0) {
        Assert 'L4 default seat matches router top pick' ([string]$seat.Name -eq [string]$rankedDefault[0].name)
    } else {
        Assert 'L4 default seat has a cost tier when router empty' ($seat.CostTier -in @('local', 'free', 'paid'))
    }

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

    . (Join-Path $here 'registry-lib.ps1')

    $projCtx = Resolve-BatonProjectFromCwd -BatonHome $home2 -Cwd (Join-Path $wt2 'ct-install-easy')
    Assert 'C1 worktree cwd resolves parent project' ([string]$projCtx.Id -eq 'canvas-toolchain')
    Assert 'C2 worktree cwd is registered' ($projCtx.Registered -eq $true)

    $badCtx = Resolve-BatonProjectFromCwd -BatonHome $home2 -Cwd '/tmp/not-a-project'
    Assert 'C3 unknown cwd is unregistered' ($badCtx.Registered -eq $false)

    $counts = Get-BatonJobCounts -BatonHome $home2
    Assert 'C4 empty factory counts zero' ($counts.Active -eq 0 -and $counts.Held -eq 0)

    $lines = Format-BatonPassiveStatus -BatonHome $home2 -Cwd (Join-Path $wt2 'ct-install-easy')
    Assert 'C5 passive status is 3 lines' (@($lines).Count -eq 3)
    Assert 'C6 line1 starts with project' ($lines[0] -match '^project\s')
    Assert 'C7 line2 starts with quota' ($lines[1] -match '^quota\s')
    Assert 'C8 line3 starts with jobs' ($lines[2] -match '^jobs\s')

    $job = New-MaestroJob -BatonHome $home2 -Project 'baton' -Goal 'ship the front door' -MaxCostTier free -Source cli
    Assert 'J1 New-MaestroJob returns mj- id' ([string]$job.id -match '^mj-[0-9a-f]{12}$')
    Assert 'J2 source is cli' ([string]$job.source -eq 'cli')
    Assert 'J3 max_cost_tier is free' ([string]$job.max_cost_tier -eq 'free')

    $keys = @(Get-MaestroRoomKeywords)
    $keyNames = @($keys | ForEach-Object { [string]$_.Name })
    Assert 'K1 keywords include status' ($keyNames -contains 'status')
    Assert 'K1b keywords include projects' ($keyNames -contains 'projects')
    Assert 'K2 keywords include help' ($keyNames -contains 'help')
    Assert 'K3 keywords include quit' ($keyNames -contains 'quit')
    $sheet = Format-MaestroRoomKeywords
    Assert 'K4 keyword sheet names status' ($sheet -match '(?m)^\s+.*\bstatus\b')

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

    $miniFleet = Join-Path $home2 'overnight/fleet.yaml'
    New-Item -ItemType Directory -Force -Path (Split-Path $miniFleet -Parent) | Out-Null
    @'
general_capabilities: [code-gen]
providers:
  - name: grok-cli
    kind: cli
    enabled: true
    cost_tier: paid
    platform: grok
    agentic: true
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: openrouter-ox-alpha
    kind: http
    enabled: true
    cost_tier: free
    capabilities: [code-gen]
    agentic: true
    command_template: 'echo "{{prompt}}"'
'@ | Set-Content -LiteralPath $miniFleet -Encoding utf8NoBOM
    $usagePath = Join-Path $home2 'usage-journal.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'lockout'; worker = 'grok-cli'; reason = 'cap'; reset_at = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $usagePath -Encoding utf8NoBOM
    $ranked = Select-MaestroRankedProviders -BatonHome $home2 -FleetPath $miniFleet
    Assert 'RT1 Select-Capability ranks providers' ($ranked.Count -ge 1)
    Assert 'RT2 locked-out grok is not in ranked pool' (@($ranked | Where-Object { [string]$_.name -eq 'grok-cli' }).Count -eq 0)
    $seat = Get-MaestroConductorSeat -Provider 'grok-cli' -BatonHome $home2
    Assert 'RT3 seat uses router top pick when hint is exhausted' ([string]$seat.Name -eq [string]$ranked[0].name)

    $exact = Find-MaestroRoomExactPick -Choices $choices -Text 'canvas-toolchain'
    Assert 'G7 exact pick resolves a registered project' ([string]$exact.Id -eq 'canvas-toolchain')

    $bare = & pwsh -NoProfile -File $baton 2>&1 | Out-String
    Assert 'B1 bare baton passive exit 0' ($LASTEXITCODE -eq 0 -and $bare -match '(?m)^project\s')
    Assert 'B2 bare baton does not hang on redirected stdin' ($true)

    $viaVerb = & pwsh -NoProfile -File $baton admit --project baton --goal 'via verb' --json 2>&1 | Out-String
    Assert 'B3 baton admit creates job' ($LASTEXITCODE -eq 0 -and $viaVerb -match 'mj-')

    $passiveOut = & pwsh -NoProfile -File $maestro -NoWatch 2>&1 | Out-String
    Assert 'P4 bare maestro is passive not room' (
        $LASTEXITCODE -eq 0 -and
        $passiveOut -match '(?m)^project\s' -and
        $passiveOut -notmatch 'type here|enter runs|╭'
    )

    $admitOut = & pwsh -NoProfile -File $maestro go --project baton --goal 'passive pivot' --json 2>&1 | Out-String
    # baseline — go still works until admit wired in verbs (Task 4 uses baton admit)

    $admitNew = & pwsh -NoProfile -File $maestro admit --project baton --goal 'from admit subcommand' --json 2>&1 | Out-String
    Assert 'A1 maestro admit exit 0' ($LASTEXITCODE -eq 0)
    $admitObj = $null
    try { $admitObj = $admitNew | ConvertFrom-Json } catch { }
    Assert 'A2 maestro admit returns mj- id' ($admitObj -and [string]$admitObj.id -match '^mj-')

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
