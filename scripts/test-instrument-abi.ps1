#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-dispatch.ps1')
. (Join-Path $PSScriptRoot 'fleet-executor-lib.ps1')

$script:failures = 0
$script:passes = 0
function Check($Name, $Condition) {
    if ($Condition) { Write-Host "PASS  $Name" -ForegroundColor Green; $script:passes++ }
    else { Write-Host "FAIL  $Name" -ForegroundColor Red; $script:failures++ }
}

function Get-FreeTcpPort {
    $socket = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $socket.Start()
        return [int]$socket.LocalEndpoint.Port
    } finally { $socket.Stop() }
}

function Start-MockHttpServer {
    param(
        [Parameter(Mandatory)][string]$Mode,
        [int]$MaxRequests = 1,
        [int]$DelayMs = 0
    )
    $port = Get-FreeTcpPort
    $readyPath = Join-Path $script:tempRoot "ready-$([guid]::NewGuid().ToString('N')).txt"
    $capturePath = Join-Path $script:tempRoot "http-$([guid]::NewGuid().ToString('N')).jsonl"
    $fixturePath = Join-Path $PSScriptRoot 'fixtures/mock-http-server.ps1'
    $process = Start-Process -FilePath 'pwsh' -ArgumentList @(
        '-NoProfile', '-File', $fixturePath, '-Port', $port, '-Mode', $Mode,
        '-ReadyPath', $readyPath, '-CapturePath', $capturePath,
        '-MaxRequests', $MaxRequests, '-DelayMs', $DelayMs
    ) -PassThru -WindowStyle Hidden
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath) -and $watch.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $readyPath)) {
        try { $process.Kill($true) } catch { }
        throw "mock HTTP server failed to start for mode $Mode"
    }
    return @{ process = $process; base_url = "http://127.0.0.1:$port"; capture = $capturePath }
}

function Stop-MockHttpServer {
    param([Parameter(Mandatory)][hashtable]$Server)
    try {
        if (-not $Server.process.WaitForExit(5000)) { $Server.process.Kill($true) }
    } catch { }
    try { $Server.process.Dispose() } catch { }
}

function Get-HttpCaptureRows {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_ | ConvertFrom-Json })
}

$script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-instrument-abi-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:tempRoot | Out-Null
$savedBatonHome = $env:BATON_HOME
$env:BATON_HOME = Join-Path $script:tempRoot 'baton-home'
New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null

try {
    # Generic HTTP: exact usage, all model-resolution branches, missing-usage
    # fallback at Invoke-Fleet, errors, timeout, and custom tool endpoint.
    $server = Start-MockHttpServer -Mode usage-total
    try {
        $httpProvider = @{ base_url = $server.base_url; model_default = 'pinned-model'; timeout_s = 5 }
        $httpResult = Invoke-FleetHttpChat -Provider $httpProvider -Prompt 'hello' -Model 'explicit-model'
        Stop-MockHttpServer -Server $server
        $captureRows = Get-HttpCaptureRows -Path $server.capture
        $posted = $captureRows[0].body | ConvertFrom-Json
        Check 'H1 explicit model wins and total usage is exact' (
            $httpResult.exit_code -eq 0 -and $httpResult.tokens -eq 41 -and
            $httpResult.tokens_basis -eq 'exact' -and $posted.model -eq 'explicit-model')
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode usage-sum
    try {
        $httpProvider = @{ base_url = $server.base_url; model_default = 'pinned-model'; timeout_s = 5 }
        $httpResult = Invoke-FleetHttpChat -Provider $httpProvider -Prompt 'hello'
        Stop-MockHttpServer -Server $server
        $posted = (Get-HttpCaptureRows -Path $server.capture)[0].body | ConvertFrom-Json
        Check 'H2 pinned model wins and prompt plus completion usage is exact' (
            $httpResult.tokens -eq 20 -and $httpResult.tokens_basis -eq 'exact' -and
            $posted.model -eq 'pinned-model')
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode no-usage -MaxRequests 2
    try {
        $httpProvider = @{ base_url = $server.base_url; model_default = 'auto'; timeout_s = 5 }
        $httpResult = Invoke-FleetHttpChat -Provider $httpProvider -Prompt 'hello'
        Stop-MockHttpServer -Server $server
        $captureRows = Get-HttpCaptureRows -Path $server.capture
        $posted = $captureRows[1].body | ConvertFrom-Json
        Check 'H3 auto model resolves from first listed model' ($posted.model -eq 'listed-model')
        Check 'H3 helper omits tokens when native usage is absent' (-not $httpResult.ContainsKey('tokens'))
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode no-usage
    try {
        $fleetPath = Join-Path $script:tempRoot 'http-fleet.yaml'
        Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @"
providers:
  - name: generic-http-fixture
    kind: http
    enabled: true
    cost_tier: local
    base_url: '$($server.base_url)'
    model_default: fixture-model
    timeout_s: 5
"@
        $fleetResult = Invoke-Fleet -Name 'generic-http-fixture' -Prompt 'estimate me' `
            -Path $fleetPath -NoJournal -NoUsageJournal
        Check 'H4 Invoke-Fleet preserves estimate fallback when usage is absent' (
            $fleetResult.exit_code -eq 0 -and $fleetResult.tokens_basis -eq 'estimate' -and
            $fleetResult.tokens -gt 0)
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode non-200
    try {
        $httpResult = Invoke-FleetHttpChat -Provider @{ base_url = $server.base_url; model_default = 'fixture'; timeout_s = 5 } -Prompt 'fail'
        Check 'H5 non-200 returns an honest failure row' ($httpResult.exit_code -ne 0 -and $httpResult.stderr)
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode timeout -DelayMs 2500
    try {
        $started = Get-Date
        $httpResult = Invoke-FleetHttpChat -Provider @{ base_url = $server.base_url; model_default = 'fixture'; timeout_s = 1 } -Prompt 'slow'
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Check 'H6 timeout_s is honored' ($httpResult.exit_code -ne 0 -and $elapsed -lt 8)
    } finally { Stop-MockHttpServer -Server $server }

    $server = Start-MockHttpServer -Mode usage-total
    try {
        $toolResult = Invoke-Tool -Tool @{ kind = 'http'; base_url = $server.base_url; endpoint = '/custom/chat'; model_default = 'tool-model'; timeout_s = 5 } -Prompt 'tool http'
        Stop-MockHttpServer -Server $server
        $requestLine = (Get-HttpCaptureRows -Path $server.capture)[0].request_line
        Check 'H7 HTTP tool honors custom endpoint and exact usage' (
            $requestLine -match '^POST /custom/chat ' -and $toolResult.tokens_basis -eq 'exact')
    } finally { Stop-MockHttpServer -Server $server }

    $stubResult = Invoke-Fleet -Name 'stub-http' -Prompt 'override' `
        -Path (Join-Path $PSScriptRoot 'fixtures/fleet-sample.yaml') -NoJournal -NoUsageJournal
    Check 'H8 hatch file retains precedence over generic HTTP' ($stubResult.stdout -eq 'stub-http-response:override')

    # Stdio JSON: request-file contract, parsing, failures, stderr, timeout, bytes.
    $fakeChild = Join-Path $PSScriptRoot 'fixtures/fake-stdio-json.ps1'
    $stdioCapture = Join-Path $script:tempRoot 'stdio-request.json'
    $stdioProvider = @{
        kind = 'stdio-json'
        command_template = "pwsh -NoProfile -File $fakeChild -Mode happy -CapturePath $stdioCapture"
        model_default = 'child-model'
        tier_high = '--depth high'
        timeout_s = 5
    }
    $stdioResult = Invoke-FleetStdioJson -Instrument $stdioProvider -Prompt 'stdio hello' -Tier high
    $request = Get-Content -LiteralPath $stdioCapture -Raw | ConvertFrom-Json
    Check 'S1 stdio-json happy path normalizes exact usage' (
        $stdioResult.exit_code -eq 0 -and $stdioResult.tokens -eq 123 -and
        $stdioResult.tokens_basis -eq 'exact')
    Check 'S1 request carries prompt model and tier args through stdin file' (
        $request.prompt -eq 'stdio hello' -and $request.model -eq 'child-model' -and
        $request.tier_args -eq '--depth high')

    $malformedProvider = @{ kind = 'stdio-json'; command_template = "pwsh -NoProfile -File $fakeChild -Mode malformed"; timeout_s = 5 }
    $stdioResult = Invoke-FleetStdioJson -Instrument $malformedProvider -Prompt 'x'
    Check 'S2 malformed child JSON is an honest failure' ($stdioResult.exit_code -ne 0 -and $stdioResult.stderr -match 'malformed')

    $processFailureProvider = @{ kind = 'stdio-json'; command_template = "pwsh -NoProfile -File $fakeChild -Mode process-nonzero"; timeout_s = 5 }
    $stdioResult = Invoke-FleetStdioJson -Instrument $processFailureProvider -Prompt 'x'
    Check 'S3 process nonzero preserves stderr and exit code' ($stdioResult.exit_code -eq 7 -and $stdioResult.stderr -match 'process failure')

    $declaredFailureProvider = @{ kind = 'stdio-json'; command_template = "pwsh -NoProfile -File $fakeChild -Mode response-nonzero"; timeout_s = 5 }
    $stdioResult = Invoke-FleetStdioJson -Instrument $declaredFailureProvider -Prompt 'x'
    Check 'S4 response nonzero preserves declared failure' ($stdioResult.exit_code -eq 4 -and $stdioResult.stderr -match 'declared child failure')

    $stderrProvider = @{ kind = 'stdio-json'; command_template = "pwsh -NoProfile -File $fakeChild -Mode stderr"; timeout_s = 5 }
    $stdioResult = Invoke-FleetStdioJson -Instrument $stderrProvider -Prompt 'x'
    Check 'S5 successful child stderr is preserved' ($stdioResult.exit_code -eq 0 -and $stdioResult.stderr -match 'fake child warning')

    $timeoutProvider = @{ kind = 'stdio-json'; command_template = "pwsh -NoProfile -File $fakeChild -Mode timeout"; timeout_s = 1 }
    $started = Get-Date
    $stdioResult = Invoke-FleetStdioJson -Instrument $timeoutProvider -Prompt 'x'
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Check 'S6 stdio-json timeout kills and returns' ($stdioResult.exit_code -ne 0 -and $stdioResult.stderr -match 'timeout' -and $elapsed -lt 8)

    $oversizeCapture = Join-Path $script:tempRoot 'oversize-should-not-exist.json'
    $oversizeProvider = @{
        kind = 'stdio-json'; max_prompt_bytes = 3
        command_template = "pwsh -NoProfile -File $fakeChild -Mode happy -CapturePath $oversizeCapture"
    }
    $stdioResult = Invoke-FleetStdioJson -Instrument $oversizeProvider -Prompt 'éé'
    Check 'S7 max_prompt_bytes counts UTF-8 and skips before child call' (
        $stdioResult.reason -eq 'prompt_too_large' -and -not (Test-Path -LiteralPath $oversizeCapture))

    # cli/python share execution; http/stdio were exercised above.
    $echoTool = Join-Path $script:tempRoot 'echo-tool.ps1'
    Set-Content -LiteralPath $echoTool -Encoding utf8NoBOM -Value @'
param([string]$PromptText)
[Console]::Out.Write("tool:$PromptText")
'@
    $pythonResult = Invoke-Tool -Tool @{ kind = 'python'; command_template = "pwsh -NoProfile -File $echoTool" } -Prompt 'python prompt'
    $cliResult = Invoke-Tool -Tool @{ kind = 'cli'; command_template = "pwsh -NoProfile -File $echoTool" } -Prompt 'cli prompt'
    Check 'T1 python uses the same execution path as cli' (
        ([string]$pythonResult.stdout).Trim() -eq 'tool:python prompt' -and
        ([string]$cliResult.stdout).Trim() -eq 'tool:cli prompt' -and
        $pythonResult.tokens_basis -eq 'estimate' -and $cliResult.tokens_basis -eq 'estimate')

    $toolStdio = Invoke-Tool -Tool $stdioProvider -Prompt 'tool stdio'
    Check 'T2 stdio-json tools share the generic transport' ($toolStdio.exit_code -eq 0 -and $toolStdio.tokens -eq 123)

    # Routing gate: widened set, unknown loud skip, oversized loud skip.
    $routingJournal = Join-Path $script:tempRoot 'routing.jsonl'
    $dispatchState = @{ calls = 0 }
    $dispatcher = {
        param($candidate, $prompt)
        $dispatchState.calls++
        return @{ stdout = "ok:$($candidate.kind):$prompt"; stderr = ''; exit_code = 0; duration_s = 0; tokens = 1; tokens_basis = 'estimate' }
    }.GetNewClosure()
    foreach ($supportedKind in @('cli', 'python', 'http', 'stdio-json')) {
        $candidate = [pscustomobject]@{
            name = "candidate-$supportedKind"; source = 'tools'; kind = $supportedKind
            cost_tier = 'local'; max_prompt_bytes = $null
        }
        $dispatchResult = Invoke-RoutedCandidate -Capability summarize -Candidate $candidate `
            -Prompt 'route me' -Dispatcher $dispatcher -JournalPath $routingJournal
        Check "R1 supported kind $supportedKind reaches dispatcher" ($dispatchResult.attempt.passed -eq $true)
    }
    Check 'R1 every supported kind dispatched exactly once' ($dispatchState.calls -eq 4)

    $unknown = [pscustomobject]@{
        name = 'unknown-kind'; source = 'tools'; kind = 'carrier-pigeon'
        cost_tier = 'local'; max_prompt_bytes = $null
    }
    $beforeUnknown = $dispatchState.calls
    $unknownResult = Invoke-RoutedCandidate -Capability summarize -Candidate $unknown `
        -Prompt 'route me' -Dispatcher $dispatcher -JournalPath $routingJournal
    $unknownJournal = (Get-Content -LiteralPath $routingJournal | Select-Object -Last 1) | ConvertFrom-Json
    Check 'R2 unknown kind skips loudly without dispatch' (
        $dispatchState.calls -eq $beforeUnknown -and $unknownResult.attempt.reason -match 'unsupported kind' -and
        $unknownJournal.reason -match 'unsupported kind')

    $oversizeCandidate = [pscustomobject]@{
        name = 'small-context'; source = 'tools'; kind = 'stdio-json'
        cost_tier = 'local'; max_prompt_bytes = 3
    }
    $beforeOversize = $dispatchState.calls
    $oversizeResult = Invoke-RoutedCandidate -Capability summarize -Candidate $oversizeCandidate `
        -Prompt 'éé' -Dispatcher $dispatcher -JournalPath $routingJournal
    $oversizeJournal = (Get-Content -LiteralPath $routingJournal | Select-Object -Last 1) | ConvertFrom-Json
    Check 'R3 prompt_too_large skips and journals before dispatch' (
        $dispatchState.calls -eq $beforeOversize -and $oversizeResult.result.reason -eq 'prompt_too_large' -and
        $oversizeJournal.reason -match 'prompt_too_large')

    # Additive declaration slots survive both YAML readers.
    $toolsPath = Join-Path $script:tempRoot 'tools.yaml'
    Set-Content -LiteralPath $toolsPath -Encoding utf8NoBOM -Value @'
tools:
  - name: declared-tool
    kind: http
    enabled: true
    capability: summarize
    cost_tier: local
    base_url: 'http://127.0.0.1:1'
    endpoint: /custom
    max_prompt_bytes: 4096
    probe: placeholder-probe
    agentic: false
'@
    $toolRow = @(Read-Tools -Path $toolsPath)[0]
    Check 'D1 tools endpoint parses additively' ($toolRow.endpoint -eq '/custom')
    Check 'D1 tools max_prompt_bytes parses additively' ([string]$toolRow.max_prompt_bytes -eq '4096')
    Check 'D1 tools probe parses additively' ($toolRow.probe -eq 'placeholder-probe')
    Check 'D1 tools agentic parses additively' ($toolRow.agentic -eq $false)

    $fleetDeclarationPath = Join-Path $script:tempRoot 'declared-fleet.yaml'
    Set-Content -LiteralPath $fleetDeclarationPath -Encoding utf8NoBOM -Value @'
providers:
  - name: declared-fleet
    kind: stdio-json
    enabled: true
    cost_tier: local
    command_template: 'placeholder-child'
    max_prompt_bytes: 8192
    probe: placeholder-probe
    agentic: true
'@
    $fleetRow = @(Read-Fleet -Path $fleetDeclarationPath)[0]
    Check 'D2 fleet max_prompt_bytes parses additively' ([string]$fleetRow.max_prompt_bytes -eq '8192')
    Check 'D2 fleet probe parses additively' ($fleetRow.probe -eq 'placeholder-probe')
    Check 'D2 fleet agentic parses additively' ($fleetRow.agentic -eq $true)

    Check 'A1 agentic:true HTTP is refused at executor seam' (
        -not (Test-ProviderAgentic -Provider @{ kind = 'http'; agentic = $true; platform = 'codex' }))
    Check 'A2 agentic:true stdio-json is refused at executor seam' (
        -not (Test-ProviderAgentic -Provider @{ kind = 'stdio-json'; agentic = $true; platform = 'codex' }))
    Check 'A3 agentic:true CLI remains eligible' (
        Test-ProviderAgentic -Provider @{ kind = 'cli'; agentic = $true; platform = 'local' })
} finally {
    if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $savedBatonHome }
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n$($script:passes) PASS, $($script:failures) FAIL"
if ($script:failures -gt 0) { exit 1 }
exit 0
