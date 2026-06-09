#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-dispatch.ps1"   # loads routing-lib -> routing-learn -> fleet-lib

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-learn-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # ===== Task 1: ratings store =====
    $ratings = Join-Path $tmp 'routing-ratings.jsonl'

    # Missing file -> empty, no throw.
    Check 'ratings missing -> empty' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 0)

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'good' -Note 'clean subject' -RatingsPath $ratings `
        -Timestamp '2026-06-08T00:00:00.0000000-06:00'
    $rs = @(Get-CapabilityRatings -RatingsPath $ratings)
    Check 'rating appended'        ($rs.Count -eq 1)
    Check 'rating capability'      ($rs[0].capability -eq 'commit-msg')
    Check 'rating candidate'       ($rs[0].candidate -eq 'devstral')
    Check 'rating value'           ($rs[0].rating -eq 'good')
    Check 'rating note'            ($rs[0].note -eq 'clean subject')
    Check 'rating ts injected'     ($rs[0].ts -eq '2026-06-08T00:00:00.0000000-06:00')

    Add-CapabilityRating -Capability 'commit-msg' -Candidate 'devstral' -Source 'fleet' `
        -Rating 'bad' -RatingsPath $ratings -Timestamp '2026-06-08T00:00:01.0000000-06:00'
    Check 'rating appends second'  (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)

    # Creates nested dir if absent.
    $nested = Join-Path $tmp 'knowledge/universal/routing-ratings.jsonl'
    Add-CapabilityRating -Capability 'x' -Candidate 'y' -Source 'tools' -Rating 'good' -RatingsPath $nested
    Check 'rating creates nested dir' (Test-Path $nested)

    # Malformed line skipped on read.
    Add-Content -LiteralPath $ratings -Value 'not json{{' -Encoding utf8NoBOM
    Check 'malformed ratings line skipped' (@(Get-CapabilityRatings -RatingsPath $ratings).Count -eq 2)
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$script:fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host "`nALL PASS" -ForegroundColor Green; exit 0 }
