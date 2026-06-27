#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$noUsage = Join-Path $tmp 'no-usage.jsonl'   # Sprint 2: keep Select-Capability usage filter a no-op
$nopath = Join-Path ([System.IO.Path]::GetTempPath()) ("rl-none-" + [guid]::NewGuid().ToString('N'))

try {
    # --- Fixtures ---
    $toolsYaml = @"
tools:
  - name: docling
    kind: python
    enabled: true
    cost_tier: local
    capability: pdf-extract
    module: docling.document_converter
  - name: git-commit-message
    kind: cli
    enabled: true
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run tavernari/git-commit-message'
    stdin: true
  - name: paid-ocr
    kind: cli
    enabled: true
    cost_tier: paid
    capability: ocr
    command_template: 'cloudocr {{prompt}}'
  - name: local-ocr
    kind: cli
    enabled: true
    cost_tier: local
    capability: ocr
    command_template: 'ollama run deepseek-ocr'
  - name: off-tool
    kind: cli
    enabled: false
    cost_tier: local
    capability: commit-msg
    command_template: 'ollama run something'
"@
    $toolsPath = Join-Path $tmp 'tools.yaml'
    Set-Content -Path $toolsPath -Value $toolsYaml -Encoding utf8

    $fleetYaml = @"
research_default: [claude-cli, codex]
general_capabilities: [code-gen, reasoning, summarize]

providers:
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
  - name: ollama-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'ollama run devstral:24b "{{prompt}}"'
  - name: off-model
    kind: cli
    enabled: false
    cost_tier: local
    command_template: 'ollama run x "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    # --- Task 1: Read-Tools ---
    $tools = Read-Tools -Path $toolsPath
    Check 'reads 5 tools'              ($tools.Count -eq 5)
    $gcm = $tools | Where-Object { $_.name -eq 'git-commit-message' }
    Check 'capability parsed'          ($gcm.capability -eq 'commit-msg')
    Check 'cost_tier parsed'           ($gcm.cost_tier -eq 'local')
    Check 'kind parsed'                ($gcm.kind -eq 'cli')
    Check 'stdin parsed bool'          ($gcm.stdin -eq $true)
    Check 'command_template parsed'    ($gcm.command_template -eq 'ollama run tavernari/git-commit-message')
    Check 'enabled bool'              (($tools | Where-Object { $_.name -eq 'off-tool' }).enabled -eq $false)

    # --- Task 3: capability vocab ---
    $gc = Get-GeneralCapabilities -FleetPath $fleetPath
    Check 'general caps count'         ($gc.Count -eq 3)
    Check 'general caps has code-gen'  ($gc -contains 'code-gen')
    Check 'general caps absent = empty' ((Get-GeneralCapabilities -FleetPath $toolsPath).Count -eq 0)

    $known = Get-KnownCapabilities -ToolsPath $toolsPath -FleetPath $fleetPath
    Check 'known has tool cap'         ($known -contains 'commit-msg')
    Check 'known has general cap'      ($known -contains 'reasoning')
    Check 'known is deduped'           (($known | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0)

    # --- Task 4: Select-Capability ---
    $common = @{ ToolsPath = $toolsPath; FleetPath = $fleetPath }

    # specialized capability → the one enabled tool, source=tools
    $cm = Select-Capability -Capability 'commit-msg' @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'commit-msg one candidate'   ($cm.Count -eq 1)
    Check 'commit-msg picks tool'      ($cm[0].name -eq 'git-commit-message')
    Check 'commit-msg source tools'    ($cm[0].source -eq 'tools')
    Check 'commit-msg has why'         ([bool]$cm[0].why)
    Check 'disabled tool excluded'     (-not ($cm | Where-Object { $_.name -eq 'off-tool' }))

    # cheapest-tier-first: ocr has a local and a paid tool → local first
    $ocr = Select-Capability -Capability 'ocr' @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'ocr two candidates'         ($ocr.Count -eq 2)
    Check 'ocr local ranks first'      ($ocr[0].name -eq 'local-ocr')
    Check 'ocr paid ranks last'        ($ocr[1].name -eq 'paid-ocr')

    # general capability → enabled fleet providers, source=fleet, cheapest first
    $cg = Select-Capability -Capability 'code-gen' @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'code-gen from fleet'        ($cg[0].source -eq 'fleet')
    Check 'code-gen local first'       ($cg[0].name -eq 'ollama-local')
    Check 'code-gen excludes disabled' (-not ($cg | Where-Object { $_.name -eq 'off-model' }))

    # constraints
    $cgLocal = Select-Capability -Capability 'code-gen' -RequireLocal @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'RequireLocal drops paid'    (-not ($cgLocal | Where-Object { $_.cost_tier -eq 'paid' }))
    $ocrFree = Select-Capability -Capability 'ocr' -MaxCostTier 'free' @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'MaxCostTier free drops paid' (-not ($ocrFree | Where-Object { $_.cost_tier -eq 'paid' }))

    # unknown capability → empty
    $none = Select-Capability -Capability 'nonexistent' @common -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'unknown cap empty'          ($none.Count -eq 0)
}
finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }

# ===== Slice B: role/platform passthrough =====
$tmpB = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-roleb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpB | Out-Null
try {
    $toolsB = @"
tools:
  - name: anno-tool
    kind: cli
    enabled: true
    cost_tier: local
    capability: cap-b
    role: draft
    platform: local
    command_template: 'x'
"@
    $fleetB = @"
general_capabilities: [cap-b]

providers:
  - name: anno-paid
    kind: cli
    enabled: true
    cost_tier: paid
    role: finisher
    platform: codex
    command_template: 'x "{{prompt}}"'
  - name: bare-local
    kind: cli
    enabled: true
    cost_tier: local
    command_template: 'x "{{prompt}}"'
"@
    $tpB = Join-Path $tmpB 'tools.yaml';  Set-Content -Path $tpB -Value $toolsB -Encoding utf8
    $fpB = Join-Path $tmpB 'fleet.yaml';  Set-Content -Path $fpB -Value $fleetB -Encoding utf8
    $jpB = Join-Path $tmpB 'j.jsonl'

    $cB = Select-Capability -Capability 'cap-b' -ToolsPath $tpB -FleetPath $fpB -JournalPath $jpB -RatingsPath $nopath -UsagePath $noUsage
    $annoTool = @($cB | Where-Object { $_.name -eq 'anno-tool' })[0]
    $annoPaid = @($cB | Where-Object { $_.name -eq 'anno-paid' })[0]
    $bare     = @($cB | Where-Object { $_.name -eq 'bare-local' })[0]
    Check 'tools candidate exposes role'      ($annoTool.role -eq 'draft')
    Check 'tools candidate exposes platform'  ($annoTool.platform -eq 'local')
    Check 'fleet candidate exposes role'      ($annoPaid.role -eq 'finisher')
    Check 'fleet candidate exposes platform'  ($annoPaid.platform -eq 'codex')
    Check 'unannotated role is null'          ($null -eq $bare.role)
    Check 'unannotated platform is null'      ($null -eq $bare.platform)
    Check 'role fields do not affect ranking' ($cB[-1].name -eq 'anno-paid')
}
finally { Remove-Item -Recurse -Force $tmpB -ErrorAction SilentlyContinue }

# ===== models-as-tools: claims, floors, champion mode =====
$tmpC = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-claims-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpC | Out-Null
try {
    $claimsYaml = @"
general_capabilities: [code-gen, reasoning, summarize]
capability_floors:
  summarize-long: 65536
  judge: 4096

providers:
  - name: frontier
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
  - name: big-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [code-gen, summarize-long]
    context: 32768
  - name: small-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [judge, commit-msg, summarize-long]
    context: 131072
    quality: 0.4
"@
    $claimsFleet = Join-Path $tmpC 'claims-fleet.yaml'
    Set-Content -Path $claimsFleet -Value $claimsYaml -Encoding utf8
    $noRatings = Join-Path $tmpC 'no-ratings.jsonl'; $noJournal = Join-Path $tmpC 'no-journal.jsonl'
    # A minimal tools.yaml with no entries — avoids throw on missing file for these fleet-only tests
    $claimsToolsYaml = "tools:`n"
    $toolsPath = Join-Path $tmpC 'tools.yaml'
    Set-Content -Path $toolsPath -Value $claimsToolsYaml -Encoding utf8

    Check 'floors reader' ((Get-CapabilityFloors -FleetPath $claimsFleet)['summarize-long'] -eq 65536)
    Check 'floors absent -> empty' ((Get-CapabilityFloors -FleetPath (Join-Path $tmpC 'no-such.yaml')).Count -eq 0)

    # Claims GRANT beyond the general list: judge is not a general capability.
    $cJudge = @(Select-Capability -Capability 'judge' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -UsagePath $noUsage)
    Check 'claim grants non-general cap' (@($cJudge | Where-Object { $_.name -eq 'small-local' }).Count -eq 1)
    # Claims RESTRICT: big-local declares a list without 'reasoning', so it is out;
    # field-less frontier keeps the blanket grant.
    $cReason = @(Select-Capability -Capability 'reasoning' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -UsagePath $noUsage)
    Check 'claim list restricts'   (@($cReason | Where-Object { $_.name -eq 'big-local' }).Count -eq 0)
    Check 'no-field keeps blanket' (@($cReason | Where-Object { $_.name -eq 'frontier' }).Count -eq 1)
    # Context floor: big-local claims summarize-long but 32768 < 65536 -> filtered;
    # small-local (131072) survives.
    $cLong = @(Select-Capability -Capability 'summarize-long' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -UsagePath $noUsage)
    Check 'floor filters short context' (@($cLong | Where-Object { $_.name -eq 'big-local' }).Count -eq 0)
    Check 'floor passes long context'   (@($cLong | Where-Object { $_.name -eq 'small-local' }).Count -eq 1)
    # Economy ranking unchanged: local outranks paid for code-gen.
    $cEco = @(Select-Capability -Capability 'code-gen' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -UsagePath $noUsage)
    Check 'economy: local outranks paid' ($cEco[0].cost_tier -eq 'local')
    $cChamp = @(Select-Capability -Capability 'judge' -ToolsPath $toolsPath -FleetPath $claimsFleet -RatingsPath $noRatings -JournalPath $noJournal -SelectionMode champion -UsagePath $noUsage)
    Check 'champion mode returns ranked' (@($cChamp).Count -eq 1 -and $cChamp[0].name -eq 'small-local')

    # Champion vs economy with a real quality gap:
    $champYaml = @"
general_capabilities: []

providers:
  - name: cheap-ok
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://x'
    capabilities: [extract-json]
    quality: 0.55
  - name: paid-great
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'x "{{prompt}}"'
    capabilities: [extract-json]
    quality: 0.95
"@
    $champFleet = Join-Path $tmpC 'champ-fleet.yaml'
    Set-Content -Path $champFleet -Value $champYaml -Encoding utf8
    # empty-tools.yaml: a valid but empty tools list so Read-Tools does not throw
    $emptyTools = Join-Path $tmpC 'empty-tools.yaml'
    Set-Content -Path $emptyTools -Value "tools:`n" -Encoding utf8
    $e = @(Select-Capability -Capability 'extract-json' -ToolsPath $emptyTools -FleetPath $champFleet -RatingsPath $noRatings -JournalPath $noJournal -UsagePath $noUsage)
    $h = @(Select-Capability -Capability 'extract-json' -ToolsPath $emptyTools -FleetPath $champFleet -RatingsPath $noRatings -JournalPath $noJournal -SelectionMode champion -UsagePath $noUsage)
    Check 'economy: cheapest first'  ($e[0].name -eq 'cheap-ok')
    Check 'champion: best first'     ($h[0].name -eq 'paid-great')
}
finally { Remove-Item -Recurse -Force $tmpC -ErrorAction SilentlyContinue }

# ===== W: Learned-cost re-rank (d060) =====
$tmpW = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-learned-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpW | Out-Null
try {
    # Use providers: multi-line format so Read-Fleet's hand-rolled parser can handle it.
    $baseFleet = @"
general_capabilities: []

providers:
  - name: localw
    kind: cli
    enabled: true
    cost_tier: local
    capabilities: [code]
    command_template: 'echo x'
  - name: freew
    kind: cli
    enabled: true
    cost_tier: free
    capabilities: [code]
    command_template: 'echo x'
"@
    # Seed a box-private board FIRST (localw learned-terrible, freew learned-great), so the
    # OFF test proves the SWITCH gates the bias — not the mere absence of records.
    # 5 single-producer runs per worker so confidence reaches 1.0 (min(1,5/5)*(0.5+0.5*1.0)),
    # weight = (1.0-0.5)/0.5 = 1.0, full +/-1.0 adjust -> a decisive adjacent-tier flip.
    # Fewer runs (e.g. 3/worker -> conf 0.6 -> weight 0.2 -> +/-0.2) would NOT flip a full tier.
    $runs = Join-Path $tmpW 'learned-runs'
    $runDefs = 1..5 | ForEach-Object { @{ id="l$_"; w='localw'; e=50 } }
    $runDefs += 1..5 | ForEach-Object { @{ id="f$_"; w='freew'; e=1 } }
    foreach ($r in $runDefs) {
        $d = Join-Path $runs $r.id; New-Item -ItemType Directory -Force -Path $d | Out-Null
        (@{ run_id=$r.id; effective_cost=$r.e; workers=@(@{worker=$r.w; share=1.0}); single_producer=$true } | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath (Join-Path $d 'effective-cost.json') -Encoding utf8NoBOM
    }

    # OFF: no learned_routing key. Records ARE present (-RunsRoot $runs), but the switch is
    # off, so ranking must still be tier-ordinal: local before free, byte-for-byte unchanged.
    $ft = Join-Path $tmpW 'fleet-off.yaml'; $baseFleet | Set-Content -LiteralPath $ft -Encoding utf8NoBOM
    $off = Select-Capability -Capability code -FleetPath $ft -ToolsPath (Join-Path $tmpW 'none.yaml') -RunsRoot $runs -RatingsPath $nopath -JournalPath $nopath -UsagePath $noUsage
    Check 'W_off1 switch-off ranks local before free despite present records' (@($off)[0].name -eq 'localw' -and @($off)[1].name -eq 'freew')

    # ON: learned_routing true + the same seeded board -> localw yields, freew rises.
    $onFleet = "learned_routing: true`n" + $baseFleet
    $ft2 = Join-Path $tmpW 'fleet-on.yaml'; $onFleet | Set-Content -LiteralPath $ft2 -Encoding utf8NoBOM
    $onArgs = @{ Capability='code'; FleetPath=$ft2; ToolsPath=(Join-Path $tmpW 'none.yaml'); RunsRoot=$runs; RatingsPath=$nopath; JournalPath=$nopath; UsagePath=$noUsage }
    $on = Select-Capability @onArgs
    Check 'W_on1 learned-bad local yields to learned-good free' (@($on)[0].name -eq 'freew')

    # Champion ignores the board: with equal quality it ranks by tier ordinal (local first).
    # If the learned bias leaked into champion, localw (learned-terrible) would be pushed
    # DOWN like in W_on1 -> freew first. Asserting localw first proves champion never reads it.
    $champ = Select-Capability @onArgs -SelectionMode champion
    Check 'W_champ1 champion ignores learned board (localw still first, not yielded)' (@($champ).Count -eq 2 -and @($champ)[0].name -eq 'localw')
}
finally { Remove-Item -Recurse -Force $tmpW -ErrorAction SilentlyContinue }

if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
