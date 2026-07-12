#!/usr/bin/env pwsh
# Tests for scripts/fleet-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

# --- Read-Fleet ---
$fleet = Read-Fleet -Path $fixture
Assert "Read-Fleet returns 10 providers" ($fleet.Count -eq 10)
Assert "first provider name is stub-cli" ($fleet[0].name -eq 'stub-cli')
Assert "stub-cli kind is cli" ($fleet[0].kind -eq 'cli')
Assert "stub-cli enabled is boolean true" ($fleet[0].enabled -eq $true)
Assert "stub-disabled enabled is boolean false" (($fleet | Where-Object { $_.name -eq 'stub-disabled' }).enabled -eq $false)
Assert "stub-with-model has model_default" (($fleet | Where-Object { $_.name -eq 'stub-with-model' }).model_default -eq 'default-model')
Assert "stub-with-env has env hashtable" (($fleet | Where-Object { $_.name -eq 'stub-with-env' }).env.FLEET_TEST_VAR -eq 'box2-value')
Assert "stub-http has base_url" (($fleet | Where-Object { $_.name -eq 'stub-http' }).base_url -eq 'http://localhost:9999')

# --- Get-FleetProvider ---
$p = Get-FleetProvider -Name 'stub-cli' -Path $fixture
Assert "Get-FleetProvider finds stub-cli" ($p.name -eq 'stub-cli')
$missing = Get-FleetProvider -Name 'does-not-exist' -Path $fixture
Assert "Get-FleetProvider returns null for missing" ($null -eq $missing)

# --- Resolve-FleetCommand ---
$cliP = Get-FleetProvider -Name 'stub-cli' -Path $fixture
$cmd = Resolve-FleetCommand -Provider $cliP -Prompt 'foo'
Assert "substitutes {{prompt}}" ($cmd -eq 'pwsh -NoProfile -Command "Write-Output hello-foo"')

$modelP = Get-FleetProvider -Name 'stub-with-model' -Path $fixture
$cmd2 = Resolve-FleetCommand -Provider $modelP -Prompt 'bar'
Assert "uses model_default when no model given" ($cmd2 -eq 'pwsh -NoProfile -Command "Write-Output default-model:bar"')
$cmd3 = Resolve-FleetCommand -Provider $modelP -Prompt 'bar' -Model 'override-model'
Assert "explicit model overrides default" ($cmd3 -eq 'pwsh -NoProfile -Command "Write-Output override-model:bar"')

# Missing {{prompt}} in template should throw
$badProvider = @{ name = 'bad'; kind = 'cli'; command_template = 'echo no-placeholder' }
$threw = $false
try { Resolve-FleetCommand -Provider $badProvider -Prompt 'x' } catch { $threw = $true }
Assert "rejects template lacking {{prompt}}" ($threw)

# --- ConvertFrom-FleetValue: inline-comment stripping (Plan 9 base_url regression) ---
Assert "inline comment stripped (quoted)"   ((ConvertFrom-FleetValue "'http://100.115.71.9:11434'   # wraith2 over Tailscale") -eq 'http://100.115.71.9:11434')
Assert "inline comment stripped (unquoted)" ((ConvertFrom-FleetValue "dolphin3:8b   # fits 8GB") -eq 'dolphin3:8b')
Assert "plain quoted value preserved"        ((ConvertFrom-FleetValue "'http://localhost:1234'") -eq 'http://localhost:1234')
Assert "inner quotes preserved"              ((ConvertFrom-FleetValue "'claude -p `"{{prompt}}`"'") -eq 'claude -p "{{prompt}}"')
Assert "hash without leading space kept"     ((ConvertFrom-FleetValue "ab#cd") -eq 'ab#cd')

# --- Write-FleetJournalLine ---
$tmpJournal = Join-Path $env:TEMP "fleet-journal-$(Get-Random).md"
$tmpState   = Join-Path $env:TEMP "fleet-state-$(Get-Random).json"

# No active job -> line has no job/phase tags
Remove-Item $tmpState -ErrorAction SilentlyContinue
$env:CAO_STATE_PATH = $tmpState
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 2 -ExitCode 0 -Prompt 'hello world' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line = @(Get-Content $tmpJournal | Where-Object { $_ -match '\| fleet \|' })[-1]
Assert "fleet line written" ($line -match '\| fleet \| stub-cli \|')
Assert "fleet line has duration" ($line -match '\| 2s \|')
Assert "fleet line has exit" ($line -match 'exit:0')
Assert "fleet line has prompt summary" ($line -match '"hello world"')
Assert "no-job line has no job tag" ($line -notmatch 'job:')

# With active job -> tags appended. Use job-lib's Write-CurrentJob only to CREATE
# the state file; Write-FleetJournalLine reads it directly via env var.
. (Join-Path $PSScriptRoot 'job-lib.ps1')
Write-CurrentJob -StatePath $tmpState -JobId 'j-fleet-test' -Phase 'research'
$env:CAO_STATE_PATH = $tmpState
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 1 -ExitCode 0 -Prompt 'tagged' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line2 = @(Get-Content $tmpJournal | Where-Object { $_ -match 'tagged' })[-1]
Assert "active-job line has job tag" ($line2 -match 'job:j-fleet-test')
Assert "active-job line has phase tag" ($line2 -match 'phase:research')

# Pipe in prompt sanitized to ¦
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "nope-$(Get-Random).json")
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 0 -ExitCode 0 -Prompt 'a | b' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$line3 = @(Get-Content $tmpJournal)[-1]
Assert "pipe in prompt sanitized" ($line3 -match 'a ¦ b')

# Origin host tag (Plan 9 / issue #20) — always present so merged cross-machine
# journals are attributable per node; honors the CAO_FLEET_HOST override.
Assert "line has origin-host tag" ($line3 -match 'host:\S')
$env:CAO_STATE_PATH = (Join-Path $env:TEMP "nope-$(Get-Random).json")
$env:CAO_FLEET_HOST = 'testbox-9'
try {
    Write-FleetJournalLine -Provider 'stub-cli' -DurationS 0 -ExitCode 0 -Prompt 'host probe' -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH, env:CAO_FLEET_HOST -ErrorAction SilentlyContinue }
$line4 = @(Get-Content $tmpJournal | Where-Object { $_ -match 'host probe' })[-1]
Assert "origin-host override honored" ($line4 -match 'host:testbox-9')

Remove-Item $tmpJournal, $tmpState -ErrorAction SilentlyContinue

# --- Invoke-Fleet -NoJournal ---
$njJournal = Join-Path $env:TEMP "fleet-nojournal-$(Get-Random).md"
$njState   = Join-Path $env:TEMP "fleet-nojournal-state-$(Get-Random).json"
$env:CAO_STATE_PATH = $njState   # no such file → no tags either way
try {
    $njResult = Invoke-Fleet -Name 'stub-cli' -Prompt 'x' -Path $fixture -JournalPath $njJournal -NoJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "NoJournal returns a result" (($njResult.stdout | Out-String).Trim() -eq 'hello-x')
Assert "NoJournal writes NO journal file content" (-not (Test-Path $njJournal) -or (@(Get-Content $njJournal -ErrorAction SilentlyContinue | Where-Object { $_ -match '\| fleet \|' }).Count -eq 0))
Remove-Item $njJournal -ErrorAction SilentlyContinue

# --- Get-FleetResearchDefault ---
$rd = Get-FleetResearchDefault -Path $fixture
Assert "research_default returns 2 names" ($rd.Count -eq 2)
Assert "research_default first is stub-cli" ($rd[0] -eq 'stub-cli')
Assert "research_default second is stub-with-model" ($rd[1] -eq 'stub-with-model')

# absent key → empty array
$noRdFixture = Join-Path $env:TEMP "fleet-nord-$(Get-Random).yaml"
Set-Content -Path $noRdFixture -Value "providers:`n  - name: x`n    kind: cli`n    enabled: true`n    cost_tier: free`n    command_template: 'echo {{prompt}}'" -Encoding utf8NoBOM
$rdEmpty = Get-FleetResearchDefault -Path $noRdFixture
Assert "absent research_default → empty array" ($rdEmpty.Count -eq 0)
Remove-Item $noRdFixture -ErrorAction SilentlyContinue

# ===== models-as-tools: inline lists, top-level hardening, keep_list =====
$tmp = Join-Path $env:TEMP "baton-mat-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $matYaml = @"
keep_list: ['*heretic*', '*swahili*']

providers:
  - name: big-local
    kind: http
    enabled: true
    cost_tier: local
    base_url: 'http://localhost:1234'
    capabilities: [code-gen, synthesize]
    context: 32768
    usage_class: broad

capability_floors:
  summarize-long: 65536
"@
    $matPath = Join-Path $tmp 'mat-fleet.yaml'
    Set-Content -Path $matPath -Value $matYaml -Encoding utf8
    $matProviders = Read-Fleet -Path $matPath
    $bl = $matProviders | Where-Object { $_.name -eq 'big-local' }
    Assert 'inline list parses to array'      ($bl.capabilities -is [array] -and @($bl.capabilities).Count -eq 2 -and $bl.capabilities[1] -eq 'synthesize')
    Assert 'scalar fields still parse'        ($bl.context -eq '32768' -and $bl.usage_class -eq 'broad')
    Assert 'top-level key after providers not absorbed' (-not $bl.ContainsKey('summarize-long'))
    Assert 'keep_list reader'                 (@(Get-FleetKeepList -Path $matPath).Count -eq 2 -and (Get-FleetKeepList -Path $matPath)[0] -eq '*heretic*')
    Assert 'keep_list absent -> empty'        (@(Get-FleetKeepList -Path (Join-Path $tmp 'no-such.yaml')).Count -eq 0)
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ===== Get-FleetTokenUsage (token telemetry) =====
# exact: row has a token_usage regex with a numeric first capture group over stdout
$tokProvider = @{ name = 'tok'; token_usage = 'tokens used[:\s]+([\d,]+)' }
$r1 = Get-FleetTokenUsage -Provider $tokProvider -Prompt 'hi' -Stdout "did work`ntokens used: 14,350`ndone"
Assert "token exact: parses captured count" ($r1.tokens -eq 14350)
Assert "token exact: basis is exact"        ($r1.tokens_basis -eq 'exact')

# no regex on the row -> estimate over (prompt+stdout) length / 4
$estProvider = @{ name = 'est' }
$r2 = Get-FleetTokenUsage -Provider $estProvider -Prompt 'abcd' -Stdout 'efgh'   # 8 chars -> ceil(8/4)=2
Assert "token estimate: len/4"        ($r2.tokens -eq 2)
Assert "token estimate: basis is estimate" ($r2.tokens_basis -eq 'estimate')

# regex present but no match in stdout -> estimate (honest fallback, d059)
$r3 = Get-FleetTokenUsage -Provider $tokProvider -Prompt '' -Stdout 'no counter here'
Assert "token regex-no-match: falls back to estimate" ($r3.tokens_basis -eq 'estimate')

# empty prompt + empty stdout -> 0 tokens, no divide error
$r4 = Get-FleetTokenUsage -Provider $estProvider -Prompt '' -Stdout ''
Assert "token empty: zero tokens, no crash" ($r4.tokens -eq 0 -and $r4.tokens_basis -eq 'estimate')

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
