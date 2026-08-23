#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$lib = Join-Path $PSScriptRoot 'cursor-quota-lib.ps1'
. $lib

$root = Join-Path ([IO.Path]::GetTempPath()) ("cquota-" + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $root 'cursor-quota.json'
$config = Join-Path $root 'cursor-quota.config.json'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$env:BATON_HOME = $root

try {
    Copy-Item (Join-Path $PSScriptRoot '..\references\cursor-quota.config.json') $config

    $summary = [pscustomobject]@{
        billingCycleStart = '2026-08-20T17:04:57.000Z'
        billingCycleEnd   = '2026-09-20T17:04:57.000Z'
        membershipType    = 'pro'
        individualUsage   = [pscustomobject]@{
            plan = [pscustomobject]@{
                totalPercentUsed = 68.9
                autoPercentUsed  = 64.0
                apiPercentUsed   = 100.0
            }
            onDemand = [pscustomobject]@{ enabled = $false }
        }
    }
    $rec = ConvertTo-CursorQuotaRecord -Summary $summary
    Assert 'R1 record has total_used_pct' ($rec.total_used_pct -eq 68.9)
    Assert 'R2 record has schema' ($rec.schema -eq 1)
    Assert 'R3 billing end stored as ISO' ($rec.billing_cycle_end -match '2026-09-20')
    Assert 'R4 remaining_pct computed' ($rec.remaining_pct -eq 31.1)

    $saved = Update-CursorQuotaCache -CachePath $cache -MaxAgeSeconds 300 -Summary $summary
    Assert 'R5 cache file written' (Test-Path -LiteralPath $cache)
    Assert 'R6 refresh returns cached when fresh' (
        ([string](Update-CursorQuotaCache -CachePath $cache -MaxAgeSeconds 300 -Summary $null).total_used_pct) -eq '68.9'
    )

    $line = Format-CursorQuotaStatusLine -Cache $saved -Format compact
    Assert 'R7 compact line has cursor label' ($line -match '^cursor ')
    Assert 'R8 compact line has bar chars' ($line -match '[█░]')
    Assert 'R9 compact line has percent' ($line -match '69%')

    $detail = Format-CursorQuotaStatusLine -Cache $saved -Format detail
    Assert 'R10 detail line shows auto/api' ($detail -match 'auto 64%' -and $detail -match 'API 100%')

    $cfg = Get-CursorQuotaConfig
    Assert 'R11 config loads yellow threshold' ($cfg.display.yellow_pct -eq 70)

    $claudePath = Join-Path $root 'claude-quota.json'
    @{
        schema      = 1
        observed_at = (Get-Date).ToUniversalTime().ToString('o')
        five_hour   = @{ used_pct = 42; resets_at_unix = 4102444800 }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $claudePath -Encoding utf8NoBOM
    $panel = Format-BatonQuotaPanel -BatonHome $root
    Assert 'R12 panel mentions Claude and Cursor' ($panel -match 'Claude 5h' -and $panel -match 'cursor cycle')
    Assert 'R13 panel mentions config path' ($panel -match 'cursor-quota.config.json')

    $cli = Join-Path $PSScriptRoot 'cursor-quota.ps1'
    $out = & pwsh -NoProfile -File $cli status -Format compact 2>&1 | Out-String
    Assert 'R14 cli status exit 0' ($LASTEXITCODE -eq 0)
    Assert 'R15 cli status mentions cursor' ($out -match 'cursor')

    $ansi = Format-CursorQuotaStatusLine -Cache $saved -Format ansi
    Assert 'R16 ansi format has escape or plain fallback' ($ansi -match 'cursor')

    $usSummary = [pscustomobject]@{
        billingCycleStart = [datetime]'2026-08-20T17:04:57Z'
        billingCycleEnd   = [datetime]'2026-09-20T17:04:57Z'
        membershipType    = 'pro'
        individualUsage   = $summary.individualUsage
    }
    $usRec = ConvertTo-CursorQuotaRecord -Summary $usSummary
    Assert 'R17 DateTime billing fields normalize to ISO' ($usRec.billing_cycle_end -match '2026-09-20')
} finally {
    Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Fail -gt 0) {
    Write-Host "test-cursor-quota: $script:Fail FAILED"
    exit 1
}
Write-Host 'test-cursor-quota: OK'
exit 0
