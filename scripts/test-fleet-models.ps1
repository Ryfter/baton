#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-models.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fm-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    # --- Fixtures: registry with two providers on one LM Studio box + one ollama box ---
    $fleetYaml = @"
keep_list: ['*heretic*']

providers:
  - name: lm-studio
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'qwen/qwen3-coder-30b'
    capabilities: [code-gen]
    usage_class: broad
  - name: lm-studio-small
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'phi-4'
    capabilities: [judge, extract-json]
    usage_class: tight
  - name: lm-studio-auto
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    model_default: 'auto'
    capabilities: [summarize-short]
    usage_class: tight
  - name: ollama-box2
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://100.115.71.9:11434'
    model_default: 'dolphin3:8b'
  - name: claude-cli
    kind: cli
    enabled: true
    cost_tier: paid
    command_template: 'claude -p "{{prompt}}"'
"@
    $fleetPath = Join-Path $tmp 'fleet.yaml'
    Set-Content -Path $fleetPath -Value $fleetYaml -Encoding utf8

    # REAL LM Studio 0.3.x native shape (verified live 2026-06-11): top key `models`,
    # id in `key`, `architecture`, quantization OBJECT, capabilities OBJECT of bools,
    # loadedness via loaded_instances[].
    $lmJson = @'
{"models":[
  {"key":"qwen/qwen3-coder-30b","type":"llm","architecture":"qwen3","quantization":{"name":"Q4_K_M","bits_per_weight":4.5},"loaded_instances":[{"id":"x"}],"max_context_length":262144,"capabilities":{"trained_for_tool_use":true,"vision":false}},
  {"key":"phi-4","type":"llm","architecture":"phi","quantization":{"name":"Q4_K_M","bits_per_weight":4.5},"loaded_instances":[],"max_context_length":16384,"capabilities":{"trained_for_tool_use":false,"reasoning":true}},
  {"key":"gemma-heretic-9b","type":"llm","architecture":"gemma","quantization":{"name":"Q4_K_M","bits_per_weight":4.5},"loaded_instances":[],"max_context_length":8192,"capabilities":{}},
  {"key":"qwen3-embedding-8b","type":"embedding","architecture":"qwen3","quantization":{"name":"Q8_0","bits_per_weight":8},"loaded_instances":[],"max_context_length":32768,"capabilities":{}},
  {"key":"llama-twin-a-7b","type":"llm","architecture":"llama","quantization":{"name":"Q4_K_M","bits_per_weight":4.5},"loaded_instances":[],"max_context_length":8192,"capabilities":{},"size_bytes":4200000000},
  {"key":"llama-twin-b-7b","type":"llm","architecture":"llama","quantization":{"name":"Q5_K_M","bits_per_weight":5.5},"loaded_instances":[],"max_context_length":8192,"capabilities":{},"size_bytes":4500000000}
]}
'@
    # Legacy/OpenAI-ish variant stays accepted (older LM Studio builds).
    $lmJsonLegacy = @'
{"data":[
  {"id":"old-model","type":"llm","arch":"llama","quantization":"Q4_K_M","state":"loaded","max_context_length":8192,"capabilities":["reasoning"]}
]}
'@
    $olJson = @'
{"models":[
  {"name":"dolphin3:8b","size":4900000000,"details":{"family":"llama","quantization_level":"Q4_K_M","parameter_size":"8.0B"}}
]}
'@

    # --- Normalizers ---
    $lmRows = @(ConvertFrom-LmStudioModels -RawJson $lmJson)
    Check 'lm: row count'        ($lmRows.Count -eq 6)
    Check 'lm: fields mapped'    ($lmRows[0].id -eq 'qwen/qwen3-coder-30b' -and $lmRows[0].max_context -eq 262144 -and $lmRows[0].loaded -eq $true)
    Check 'lm: reasoning flag'   ($lmRows[1].flags -contains 'reasoning')
    Check 'lm: embedding type'   ($lmRows[3].type -eq 'embedding')
    Check 'lm: quant object name' ($lmRows[0].quant -eq 'Q4_K_M')
    Check 'lm: family from architecture' ($lmRows[0].family -eq 'qwen3')
    $lmLegacy = @(ConvertFrom-LmStudioModels -RawJson $lmJsonLegacy)
    Check 'lm: legacy shape accepted' ($lmLegacy[0].id -eq 'old-model' -and $lmLegacy[0].loaded -eq $true -and ($lmLegacy[0].flags -contains 'reasoning') -and $lmLegacy[0].quant -eq 'Q4_K_M')
    $olRows = @(ConvertFrom-OllamaTags -RawJson $olJson)
    Check 'ol: fields mapped'    ($olRows[0].id -eq 'dolphin3:8b' -and $olRows[0].size_bytes -eq 4900000000 -and $olRows[0].family -eq 'llama')

    # --- Inventory: dedupe by base_url, prober injected, offline box survives ---
    $script:probed = [System.Collections.ArrayList]@()
    $prober = {
        param($url)
        [void]$script:probed.Add($url)
        if ($url -like 'http://localhost:1234*') { return $lmJson }
        throw "connection refused"
    }.GetNewClosure()
    $inv = Get-ModelInventory -FleetPath $fleetPath -Prober $prober
    Check 'inv: one probe per box'      (@($script:probed).Count -eq 2)
    Check 'inv: lm box reachable'       (@($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0].reachable -eq $true)
    Check 'inv: providers grouped'      (@(@($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0].providers).Count -eq 3)
    Check 'inv: offline box marked'     (@($inv.boxes | Where-Object { $_.base_url -like '*11434*' })[0].reachable -eq $false)
    Check 'inv: cli providers ignored'  (@($inv.boxes | Where-Object { $_.providers -contains 'claude-cli' }).Count -eq 0)

    # --- Tags ---
    $inv = Add-InventoryTags -Inventory $inv -FleetPath $fleetPath
    $lmBox = @($inv.boxes | Where-Object { $_.base_url -eq 'http://localhost:1234' })[0]
    $phi = @($lmBox.models | Where-Object { $_.id -eq 'phi-4' })[0]
    Check 'tag: pinned_by'       ($phi.pinned_by -contains 'lm-studio-small')
    Check 'tag: claims'          ($phi.claims -contains 'judge')
    Check 'tag: keep glob'       (@($lmBox.models | Where-Object { $_.id -eq 'gemma-heretic-9b' })[0].keep -eq $true)
    Check 'tag: unregistered'    (@($lmBox.models | Where-Object { $_.id -eq 'qwen3-embedding-8b' })[0].unregistered -eq $true)

    # --- Recommendations ---
    $recs = @(Get-InventoryRecommendations -Inventory $inv -FleetPath $fleetPath)
    Check 'rec: judge risk (reasoning flag)'  (@($recs | Where-Object { $_ -match 'JUDGE RISK.*phi-4' }).Count -eq 1)
    Check 'rec: near-dup pair'                (@($recs | Where-Object { $_ -match 'NEAR-DUP.*llama-twin' }).Count -eq 1)
    Check 'rec: unregistered specialist'      (@($recs | Where-Object { $_ -match 'UNREGISTERED SPECIALIST.*qwen3-embedding-8b' }).Count -eq 1)
    Check 'rec: offline box noted'            (@($recs | Where-Object { $_ -match 'offline.*ollama-box2' }).Count -eq 1)
    Check 'rec: keep never culled'            (@($recs | Where-Object { $_ -match 'heretic' }).Count -eq 0)
    Check 'rec: auto sentinel not flagged'    (@($recs | Where-Object { $_ -match 'MISSING PIN.*auto' }).Count -eq 0)

    # --- Missing pin: registry pins a model the box doesn't have ---
    $fleet2 = $fleetYaml.Replace("model_default: 'phi-4'", "model_default: 'phi-9-imaginary'")
    $fleet2Path = Join-Path $tmp 'fleet2.yaml'
    Set-Content -Path $fleet2Path -Value $fleet2 -Encoding utf8
    $inv2 = Add-InventoryTags -Inventory (Get-ModelInventory -FleetPath $fleet2Path -Prober $prober) -FleetPath $fleet2Path
    $recs2 = @(Get-InventoryRecommendations -Inventory $inv2 -FleetPath $fleet2Path)
    Check 'rec: missing pin'     (@($recs2 | Where-Object { $_ -match 'MISSING PIN.*phi-9-imaginary' }).Count -eq 1)
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "`n$($script:fail) FAILURES" -ForegroundColor Red; exit 1 }
Write-Host "`nALL PASS" -ForegroundColor Green; exit 0
