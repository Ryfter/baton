#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
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
    $cm = Select-Capability -Capability 'commit-msg' @common -RatingsPath $nopath -JournalPath $nopath
    Check 'commit-msg one candidate'   ($cm.Count -eq 1)
    Check 'commit-msg picks tool'      ($cm[0].name -eq 'git-commit-message')
    Check 'commit-msg source tools'    ($cm[0].source -eq 'tools')
    Check 'commit-msg has why'         ([bool]$cm[0].why)
    Check 'disabled tool excluded'     (-not ($cm | Where-Object { $_.name -eq 'off-tool' }))

    # cheapest-tier-first: ocr has a local and a paid tool → local first
    $ocr = Select-Capability -Capability 'ocr' @common -RatingsPath $nopath -JournalPath $nopath
    Check 'ocr two candidates'         ($ocr.Count -eq 2)
    Check 'ocr local ranks first'      ($ocr[0].name -eq 'local-ocr')
    Check 'ocr paid ranks last'        ($ocr[1].name -eq 'paid-ocr')

    # general capability → enabled fleet providers, source=fleet, cheapest first
    $cg = Select-Capability -Capability 'code-gen' @common -RatingsPath $nopath -JournalPath $nopath
    Check 'code-gen from fleet'        ($cg[0].source -eq 'fleet')
    Check 'code-gen local first'       ($cg[0].name -eq 'ollama-local')
    Check 'code-gen excludes disabled' (-not ($cg | Where-Object { $_.name -eq 'off-model' }))

    # constraints
    $cgLocal = Select-Capability -Capability 'code-gen' -RequireLocal @common -RatingsPath $nopath -JournalPath $nopath
    Check 'RequireLocal drops paid'    (-not ($cgLocal | Where-Object { $_.cost_tier -eq 'paid' }))
    $ocrFree = Select-Capability -Capability 'ocr' -MaxCostTier 'free' @common -RatingsPath $nopath -JournalPath $nopath
    Check 'MaxCostTier free drops paid' (-not ($ocrFree | Where-Object { $_.cost_tier -eq 'paid' }))

    # unknown capability → empty
    $none = Select-Capability -Capability 'nonexistent' @common -RatingsPath $nopath -JournalPath $nopath
    Check 'unknown cap empty'          ($none.Count -eq 0)
}
finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
