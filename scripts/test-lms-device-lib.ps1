#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lms-device-lib.ps1')

$script:fail = 0
function Check($n, $c) { if ($c) { Write-Host "PASS: $n" } else { Write-Host "FAIL: $n"; $script:fail++ } }

# Sample mirrors real `lms link status` output (placeholder hosts/ids).
$sample = @'
This device: BoxA
Status: Online

Found 3 devices:

  - BoxB
    Status: connected
    Identifier: aaaa1111
    Loaded Models Instances:
      - some-model@q5_k_m
  - BoxC
    Status: connected
    Identifier: bbbb2222
  - BoxD
    Status: disconnected
    Identifier: cccc3333
'@

$map = Convert-LmsLinkStatus -Text $sample
Check 'link status: local device name'    ($map.local -eq 'BoxA')
Check 'link status: three devices parsed' ($map.devices.Count -eq 3)
Check 'link status: identifier bound'     (($map.devices | Where-Object { $_.name -eq 'BoxB' }).identifier -eq 'aaaa1111')
Check 'link status: last device kept'     (($map.devices | Where-Object { $_.name -eq 'BoxD' }).identifier -eq 'cccc3333')
Check 'link status: disconnected status'  (($map.devices | Where-Object { $_.name -eq 'BoxD' }).status -eq 'disconnected')
Check 'link status: loaded-model line not a device' (-not ($map.devices | Where-Object { $_.name -like 'some-model*' }))
Check 'link status: empty input safe'     ((Convert-LmsLinkStatus -Text '').devices.Count -eq 0)

Check 'busy: generating'       (Test-LmsStatusBusy -Status 'generating')
Check 'busy: processingPrompt' (Test-LmsStatusBusy -Status 'processingPrompt')
Check 'busy: loaded is idle'   (-not (Test-LmsStatusBusy -Status 'loaded'))
Check 'busy: empty is idle'    (-not (Test-LmsStatusBusy -Status ''))

$rows = @(
    [pscustomobject]@{ deviceIdentifier = 'aaaa1111'; identifier = 'm1'; status = 'generating'; sizeBytes = 2GB },
    [pscustomobject]@{ deviceIdentifier = 'aaaa1111'; identifier = 'm2'; status = 'loaded';     sizeBytes = 1GB },
    [pscustomobject]@{ deviceIdentifier = 'bbbb2222'; identifier = 'm3'; status = 'loaded';     sizeBytes = 3GB }
)
$act = Resolve-LmsBoxActivity -LoadedRows $rows -DeviceMap $map
$boxB = $act | Where-Object { $_.name -eq 'BoxB' }
$boxC = $act | Where-Object { $_.name -eq 'BoxC' }
$boxD = $act | Where-Object { $_.name -eq 'BoxD' }
$boxA = $act | Where-Object { $_.name -eq 'BoxA' }
Check 'activity: local box included even with nothing loaded' ($null -ne $boxA -and -not $boxA.busy)
Check 'activity: busy when any model generating'   ($boxB.busy)
Check 'activity: vram summed across models'        ($boxB.vram_bytes -eq 3GB)
Check 'activity: two models attributed to box'     ($boxB.models.Count -eq 2)
Check 'activity: loaded-only box is not busy'      (-not $boxC.busy -and $boxC.vram_bytes -eq 3GB)
Check 'activity: idle box reported, not omitted'   ($null -ne $boxD -and $boxD.models.Count -eq 0)
Check 'activity: disconnected box unreachable'     (-not $boxD.reachable)
Check 'activity: no rows still lists every box'    ((Resolve-LmsBoxActivity -LoadedRows @() -DeviceMap $map).Count -eq 4)
Check 'activity: null rows safe'                   ((Resolve-LmsBoxActivity -LoadedRows $null -DeviceMap $map).Count -eq 4)

$orphan = Resolve-LmsBoxActivity -LoadedRows @([pscustomobject]@{ deviceIdentifier = 'zzzz9999'; identifier = 'mX'; status = 'generating'; sizeBytes = 1GB }) -DeviceMap $map
Check 'activity: unknown device still surfaces busy' (($orphan | Where-Object { $_.identifier -eq 'zzzz9999' }).busy)

if ($script:fail -gt 0) { Write-Host "`n$script:fail failure(s)"; exit 1 }
Write-Host "`nAll lms-device-lib tests passed."
