#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/routing-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("routing-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

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
}
finally { if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp } }
if ($fail -gt 0) { Write-Host "`n$fail FAILED"; exit 1 } else { Write-Host "`nALL PASS"; exit 0 }
