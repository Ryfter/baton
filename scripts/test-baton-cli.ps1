# scripts/test-baton-cli.ps1
# Hermetic tests for the baton CLI dispatcher (Phase 1).
# Never touches the real ~/.baton, ~/.claude, or any real project tree.
$ErrorActionPreference = 'Stop'
$script:Fail = 0
function Assert($label, [bool]$cond) {
    if ($cond) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:Fail++ }
}

$here = $PSScriptRoot
$baton = Join-Path $here 'baton.ps1'
$resolveLib = Join-Path $here 'baton-resolve.ps1'
$verbsYaml = Join-Path $here 'verbs.yaml'

$root = Join-Path ([IO.Path]::GetTempPath()) ("bcli-" + [guid]::NewGuid().ToString('N'))
$home2 = Join-Path $root 'home'
$claude2 = Join-Path $root 'claude'
$repo2 = Join-Path $root 'repo'
New-Item -ItemType Directory -Force -Path $home2, $claude2, (Join-Path $repo2 'scripts') | Out-Null

$oldHome = $env:BATON_HOME
$oldRepo = $env:BATON_REPO_ROOT
$oldClaude = $env:BATON_CLAUDE_DIR

$env:BATON_HOME = $home2
$env:BATON_CLAUDE_DIR = $claude2
# Clear repo root unless a test sets it — keeps resolution off the real tree
# when we intentionally exercise override / legacy paths.
Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue

try {
    # ------------------------------------------------------------------
    # 1. baton --help exits 0 and lists at least 10 verbs
    # ------------------------------------------------------------------
    $helpOut = & pwsh -NoProfile -File $baton --help 2>&1 | Out-String
    Assert 'H1 baton --help exit 0' ($LASTEXITCODE -eq 0)
    $verbLines = @($helpOut -split "`n" | Where-Object { $_ -match '^\s{2}\S' })
    Assert 'H2 baton --help lists >= 10 verbs' ($verbLines.Count -ge 10)
    Assert 'H3 baton --help mentions go' ($helpOut -match '\bgo\b')

    $helpOut2 = 'quit' | & pwsh -NoProfile -File $baton 2>&1 | Out-String
    Assert 'H4 bare baton exit 0' ($LASTEXITCODE -eq 0)
    Assert 'H5 bare baton is the room (not a verb list)' (
        $helpOut2 -match '(?i)status' -and $helpOut2 -notmatch '(?m)^\s+fleet\s'
    )

    # ------------------------------------------------------------------
    # 2. baton verbs --json — valid JSON, required fields
    # ------------------------------------------------------------------
    $jsonOut = & pwsh -NoProfile -File $baton verbs --json 2>&1 | Out-String
    Assert 'J1 verbs --json exit 0' ($LASTEXITCODE -eq 0)
    $parsed = $null
    $jsonOk = $false
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        $jsonOk = $true
    } catch {
        $jsonOk = $false
    }
    Assert 'J2 verbs --json is valid JSON' $jsonOk
    $entries = @($parsed)
    Assert 'J3 verbs --json has entries' ($entries.Count -ge 10)
    $allFields = $true
    foreach ($e in $entries) {
        if (-not $e.name -or -not $e.summary -or -not $e.class -or -not $e.runner) {
            $allFields = $false
            break
        }
    }
    Assert 'J4 every entry has name/summary/class/runner' $allFields

    # ------------------------------------------------------------------
    # 3. Unknown verb exits 2 and names the verb on stderr
    # ------------------------------------------------------------------
    $unkCombined = & pwsh -NoProfile -File $baton totally-not-a-verb 2>&1
    $unkCode = $LASTEXITCODE
    $unkText = "$unkCombined"
    Assert 'U1 unknown verb exit 2' ($unkCode -eq 2)
    Assert 'U2 unknown verb names the verb' ($unkText -match 'totally-not-a-verb')

    # close match should hint
    $nearCombined = & pwsh -NoProfile -File $baton ggo 2>&1
    $nearText = "$nearCombined"
    Assert 'U3 near miss suggests go' ($nearText -match "Did you mean 'go'")

    # ------------------------------------------------------------------
    # 4. Resolution order: BATON_REPO_ROOT fake runner wins
    # ------------------------------------------------------------------
    $fakeScripts = Join-Path $repo2 'scripts'
    $fakeRunner = Join-Path $fakeScripts 'fleet-go.ps1'
    @'
param()
Write-Output 'FAKE_REPO_RUNNER'
exit 0
'@ | Set-Content -LiteralPath $fakeRunner -Encoding utf8NoBOM

    # Also need verbs.yaml in the fake tree so the dispatcher can load it if
    # we point the whole dispatcher at the fake — but we invoke the real
    # baton.ps1 and only override Resolve-BatonScript via env. The real
    # dispatcher loads verbs from its own $PSScriptRoot, then resolves the
    # runner via Resolve-BatonScript (which honors BATON_REPO_ROOT first).
    $env:BATON_REPO_ROOT = $repo2
    $goOut = & pwsh -NoProfile -File $baton go 2>&1 | Out-String
    Assert 'R1 BATON_REPO_ROOT fake runner chosen' ($goOut -match 'FAKE_REPO_RUNNER')
    Assert 'R2 fake runner exit 0' ($LASTEXITCODE -eq 0)
    Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------
    # 5. Legacy-path fallback warns once, not per call
    # ------------------------------------------------------------------
    # Isolate: no BATON_REPO_ROOT, empty BATON_HOME/scripts, entry root
    # overridden by testing resolve lib directly with a temp entry that
    # does not contain the target file; only legacy has it.
    $legacyScripts = Join-Path $claude2 'scripts'
    New-Item -ItemType Directory -Force -Path $legacyScripts | Out-Null
    $legacyFile = Join-Path $legacyScripts 'legacy-only-probe.ps1'
    Set-Content -LiteralPath $legacyFile -Value '# probe' -Encoding utf8NoBOM

    $emptyEntry = Join-Path $root 'empty-entry'
    New-Item -ItemType Directory -Force -Path $emptyEntry | Out-Null
    $env:BATON_HOME = (Join-Path $root 'home-no-scripts')
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue

    # Fresh process for warn-once semantics (script-scoped flag).
    $childProbe = Join-Path $root 'legacy-warn-child.ps1'
    $probeLines = @(
        '$ErrorActionPreference = ''Stop'''
        "`$env:BATON_HOME = '$($env:BATON_HOME -replace '''', '''''')'"
        "`$env:BATON_CLAUDE_DIR = '$($claude2 -replace '''', '''''')'"
        'Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue'
        ". '$($resolveLib -replace '''', '''''')'"
        "`$script:BatonEntryScriptRoot = '$($emptyEntry -replace '''', '''''')'"
        '$script:BatonLegacyPathWarned = $false'
        '$null = Resolve-BatonScript -Name ''legacy-only-probe.ps1'''
        '$null = Resolve-BatonScript -Name ''legacy-only-probe.ps1'''
    )
    Set-Content -LiteralPath $childProbe -Value ($probeLines -join [Environment]::NewLine) -Encoding utf8NoBOM

    $warnAll = & pwsh -NoProfile -File $childProbe 2>&1
    $warnText = ($warnAll | ForEach-Object { "$_" }) -join "`n"
    $warnCount = ([regex]::Matches($warnText, 'deprecated path')).Count
    Assert 'L1 legacy path warns at least once' ($warnCount -ge 1)
    Assert 'L2 legacy path warns exactly once' ($warnCount -eq 1)

    # restore hermetic home for remaining tests
    $env:BATON_HOME = $home2
    $env:BATON_CLAUDE_DIR = $claude2

    # ------------------------------------------------------------------
    # 6. Every runner in verbs.yaml resolves to an existing file
    # ------------------------------------------------------------------
    . $resolveLib
    $script:BatonEntryScriptRoot = $here
    $script:BatonLegacyPathWarned = $true  # silence during bulk resolve
    Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue
    # Use real scripts dir as entry so runners resolve from the checkout.
    $verbText = Get-Content -LiteralPath $verbsYaml -Raw
    $runnerNames = [regex]::Matches($verbText, '(?m)^\s+runner:\s*(\S+)\s*$') |
        ForEach-Object { $_.Groups[1].Value.Trim('"', "'") }
    Assert 'V1 verbs.yaml has runners' ($runnerNames.Count -ge 10)
    $allExist = $true
    $missing = @()
    foreach ($rn in $runnerNames) {
        try {
            $p = Resolve-BatonScript -Name $rn
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
                $allExist = $false
                $missing += $rn
            }
        } catch {
            $allExist = $false
            $missing += $rn
        }
    }
    Assert "V2 every runner file exists ($($runnerNames.Count))" $allExist
    if (-not $allExist) { Write-Host "    missing: $($missing -join ', ')" }

    # ------------------------------------------------------------------
    # 7. Arguments pass through unmodified (spaces + quote)
    # ------------------------------------------------------------------
    $stubScripts = Join-Path $root 'stub-scripts'
    New-Item -ItemType Directory -Force -Path $stubScripts | Out-Null
    $stubRunner = Join-Path $stubScripts 'fleet-go.ps1'
    @'
# Echo argv markers so the parent can assert fidelity.
# Use automatic $args only as a read (never assign to $args).
$i = 0
foreach ($a in $args) {
    Write-Output ("ARG{0}={1}" -f $i, $a)
    $i++
}
exit 0
'@ | Set-Content -LiteralPath $stubRunner -Encoding utf8NoBOM

    # Point BATON_REPO_ROOT so 'go' resolves to the stub.
    $stubRepo = Join-Path $root 'stub-repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $stubRepo 'scripts') | Out-Null
    Copy-Item $stubRunner (Join-Path $stubRepo 'scripts' 'fleet-go.ps1')
    $env:BATON_REPO_ROOT = $stubRepo

    $spaceArg = 'hello world'
    $quoteArg = 'say "hi"'
    $passOut = & pwsh -NoProfile -File $baton go --flag $spaceArg $quoteArg 2>&1 | Out-String
    Assert 'A1 arg passthrough exit 0' ($LASTEXITCODE -eq 0)
    Assert 'A2 first flag preserved' ($passOut -match 'ARG0=--flag')
    Assert 'A3 space arg preserved' ($passOut -match [regex]::Escape('ARG1=hello world'))
    Assert 'A4 quote arg preserved' ($passOut -match [regex]::Escape('ARG2=say "hi"'))

    # ------------------------------------------------------------------
    # 8. Runner exit code propagates (stub exits 3 → baton exits 3)
    # ------------------------------------------------------------------
    @'
exit 3
'@ | Set-Content -LiteralPath (Join-Path $stubRepo 'scripts' 'fleet-go.ps1') -Encoding utf8NoBOM
    $null = & pwsh -NoProfile -File $baton go 2>&1
    Assert 'E1 runner exit 3 propagates' ($LASTEXITCODE -eq 3)

    # --version discovers something from the real source checkout
    $verOut = & pwsh -NoProfile -File $baton --version 2>&1 | Out-String
    Assert 'Z1 --version exit 0' ($LASTEXITCODE -eq 0)
    Assert 'Z2 --version non-empty' (-not [string]::IsNullOrWhiteSpace($verOut.Trim()))
    Assert 'Z3 --version not unknown (source checkout)' ($verOut.Trim() -ne 'unknown')

    # ------------------------------------------------------------------
    # 9. Version resolution: BATON_REPO_ROOT / marker / unknown
    # ------------------------------------------------------------------
    # Isolated dispatcher copy so walk-up from $PSScriptRoot cannot reach the
    # real repo's .claude-plugin/plugin.json.
    $isoScripts = Join-Path $root 'iso-scripts'
    New-Item -ItemType Directory -Force -Path $isoScripts | Out-Null
    Copy-Item -LiteralPath $baton -Destination (Join-Path $isoScripts 'baton.ps1')
    Copy-Item -LiteralPath $resolveLib -Destination (Join-Path $isoScripts 'baton-resolve.ps1')
    Copy-Item -LiteralPath $verbsYaml -Destination (Join-Path $isoScripts 'verbs.yaml')
    $isoBaton = Join-Path $isoScripts 'baton.ps1'

    # V-REPO: BATON_REPO_ROOT points at a tree with plugin.json only.
    $verRepo = Join-Path $root 'ver-repo'
    $verPluginDir = Join-Path $verRepo '.claude-plugin'
    New-Item -ItemType Directory -Force -Path $verPluginDir | Out-Null
    Set-Content -LiteralPath (Join-Path $verPluginDir 'plugin.json') `
        -Value '{"name":"baton","version":"9.8.7-test"}' -Encoding utf8NoBOM
    $env:BATON_REPO_ROOT = $verRepo
    $verRepoOut = & pwsh -NoProfile -File $isoBaton --version 2>&1 | Out-String
    Assert 'VR1 --version via BATON_REPO_ROOT exit 0' ($LASTEXITCODE -eq 0)
    Assert 'VR2 --version via BATON_REPO_ROOT is non-unknown' (
        ($verRepoOut.Trim() -ne 'unknown') -and (-not [string]::IsNullOrWhiteSpace($verRepoOut.Trim()))
    )
    Assert 'VR3 --version reads plugin.json version' ($verRepoOut.Trim() -eq '9.8.7-test')
    Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue

    # V-MARK: deployed layout — version marker present, no plugin.json, no env.
    Set-Content -LiteralPath (Join-Path $isoScripts 'baton-version.txt') `
        -Value '4.5.6-deploy' -Encoding utf8NoBOM
    $verMarkOut = & pwsh -NoProfile -File $isoBaton --version 2>&1 | Out-String
    Assert 'VM1 --version via marker exit 0' ($LASTEXITCODE -eq 0)
    Assert 'VM2 --version via marker is non-unknown' (
        ($verMarkOut.Trim() -ne 'unknown') -and (-not [string]::IsNullOrWhiteSpace($verMarkOut.Trim()))
    )
    Assert 'VM3 --version reads baton-version.txt' ($verMarkOut.Trim() -eq '4.5.6-deploy')

    # V-UNK: neither plugin.json nor marker available → exactly "unknown".
    Remove-Item -LiteralPath (Join-Path $isoScripts 'baton-version.txt') -Force
    Remove-Item Env:BATON_REPO_ROOT -ErrorAction SilentlyContinue
    $verUnkOut = & pwsh -NoProfile -File $isoBaton --version 2>&1 | Out-String
    Assert 'VU1 --version with nothing exit 0' ($LASTEXITCODE -eq 0)
    Assert 'VU2 --version is exactly unknown' ($verUnkOut.Trim() -eq 'unknown')

    # ------------------------------------------------------------------
    # 10. Per-verb flag_aliases (go) + raw passthrough (no-map verbs)
    # ------------------------------------------------------------------
    # Fresh stub runner that echoes argv (re-use stub-repo layout).
    $echoRunner = @'
$i = 0
foreach ($a in $args) {
    Write-Output ("ARG{0}={1}" -f $i, $a)
    $i++
}
exit 0
'@
    New-Item -ItemType Directory -Force -Path (Join-Path $stubRepo 'scripts') | Out-Null
    Set-Content -LiteralPath (Join-Path $stubRepo 'scripts' 'fleet-go.ps1') -Value $echoRunner -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $stubRepo 'scripts' 'fleet-doctor.ps1') -Value $echoRunner -Encoding utf8NoBOM
    $env:BATON_REPO_ROOT = $stubRepo

    # F1: baton go --project X --execute → -Project X -Execute
    $aliasOut = & pwsh -NoProfile -File $baton go --project X --execute 2>&1 | Out-String
    Assert 'F1 go alias translation exit 0' ($LASTEXITCODE -eq 0)
    Assert 'F2 --project → -Project' ($aliasOut -match 'ARG0=-Project')
    Assert 'F3 project value preserved' ($aliasOut -match 'ARG1=X')
    Assert 'F4 --execute → -Execute' ($aliasOut -match 'ARG2=-Execute')

    # F5: verb without flag_aliases (fleet) passes --project through unchanged.
    $fleetOut = & pwsh -NoProfile -File $baton fleet --project X 2>&1 | Out-String
    Assert 'F5 no-map verb exit 0' ($LASTEXITCODE -eq 0)
    Assert 'F6 no-map --project unchanged' ($fleetOut -match 'ARG0=--project')
    Assert 'F7 no-map value preserved' ($fleetOut -match 'ARG1=X')

    # F8/F9: value with space + value beginning with '-' survive byte-for-byte.
    $spaceVal = 'my project'
    $dashVal = '-weird'
    $valOut = & pwsh -NoProfile -File $baton go --project $spaceVal --budget $dashVal 2>&1 | Out-String
    Assert 'F8 space value byte-for-byte' ($valOut -match [regex]::Escape('ARG1=my project'))
    Assert 'F9 leading-dash value byte-for-byte' ($valOut -match [regex]::Escape('ARG3=-weird'))
    Assert 'F10 --budget → -Budget (flag only)' ($valOut -match 'ARG2=-Budget')

    # F11: bare "--" stops translation; following tokens are verbatim.
    $ddOut = & pwsh -NoProfile -File $baton go --project X -- --execute --project 2>&1 | Out-String
    Assert 'F11 pre-- --project translated' ($ddOut -match 'ARG0=-Project')
    Assert 'F12 bare -- preserved' ($ddOut -match 'ARG2=--')
    Assert 'F13 post-- --execute untranslated' ($ddOut -match 'ARG3=--execute')
    Assert 'F14 post-- --project untranslated' ($ddOut -match 'ARG4=--project')

    # F15: undeclared --flag on go passes through unchanged.
    $unkFlagOut = & pwsh -NoProfile -File $baton go --not-a-real-flag 2>&1 | Out-String
    Assert 'F15 undeclared --flag passthrough' ($unkFlagOut -match 'ARG0=--not-a-real-flag')
}
finally {
    if ($null -eq $oldHome) { Remove-Item Env:BATON_HOME -EA SilentlyContinue } else { $env:BATON_HOME = $oldHome }
    if ($null -eq $oldRepo) { Remove-Item Env:BATON_REPO_ROOT -EA SilentlyContinue } else { $env:BATON_REPO_ROOT = $oldRepo }
    if ($null -eq $oldClaude) { Remove-Item Env:BATON_CLAUDE_DIR -EA SilentlyContinue } else { $env:BATON_CLAUDE_DIR = $oldClaude }
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}
if ($script:Fail -gt 0) { Write-Host "`n$script:Fail CHECK(S) FAILED"; exit 1 } else { Write-Host "`nALL CHECKS PASS" }
