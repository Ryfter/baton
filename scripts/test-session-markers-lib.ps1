# scripts/test-session-markers-lib.ps1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/session-markers-lib.ps1"

$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" }
    else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("bmk-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # write → read back active
    Write-SessionMarker -Agent 'claude' -SessionId 'sess-1' -Cwd 'D:\dev\Whittle' -BatonHome $tmp
    $act = @(Get-ActiveSessions -BatonHome $tmp)
    Assert 'M1 one active marker after write' (@($act).Count -eq 1)
    Assert 'M2 marker carries agent+cwd' ($act[0].agent -eq 'claude' -and $act[0].cwd -eq 'D:\dev\Whittle')
    Assert 'M3 Test-FolderActive matches case-insensitively' (Test-FolderActive -Folder 'd:\dev\whittle' -Sessions $act)
    Assert 'M4 Test-FolderActive no false match' (-not (Test-FolderActive -Folder 'D:\dev\Other' -Sessions $act))

    # clear → returns record, no longer active
    $rec = Clear-SessionMarker -SessionId 'sess-1' -BatonHome $tmp
    Assert 'M5 Clear returns the removed record' ($null -ne $rec -and $rec.session_id -eq 'sess-1')
    Assert 'M6 no active markers after clear' (@(Get-ActiveSessions -BatonHome $tmp).Count -eq 0)

    # TTL age-out: hand-write a stale marker
    $sdir = Get-SessionsDir -BatonHome $tmp
    $stale = @{ agent='claude'; session_id='old'; cwd='D:\dev\Old'; started_at=(Get-Date).AddHours(-48).ToString('o') }
    $stale | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sdir 'old.json') -Encoding utf8NoBOM
    Assert 'M7 stale marker aged out' (@(Get-ActiveSessions -TtlHours 24 -BatonHome $tmp).Count -eq 0)

    # fail-open: no sessions dir
    $empty = Join-Path ([IO.Path]::GetTempPath()) ("bmk2-" + [guid]::NewGuid().ToString('N'))
    Assert 'M8 missing dir → empty' (@(Get-ActiveSessions -BatonHome $empty).Count -eq 0)
    Assert 'M9 clear missing marker → null' ($null -eq (Clear-SessionMarker -SessionId 'nope' -BatonHome $tmp))
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
