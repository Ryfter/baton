#!/usr/bin/env pwsh
# End-to-end dispatch tests using stub providers (no real CLIs / network).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fleet-lib.ps1')

$fixture = Join-Path $PSScriptRoot 'fixtures\fleet-sample.yaml'
$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpJournal = Join-Path $env:TEMP "fleet-disp-journal-$(Get-Random).md"
$noState    = Join-Path $env:TEMP "fleet-disp-nostate-$(Get-Random).json"

# --- cli dispatch ---
$env:CAO_STATE_PATH = $noState
try {
    $r = Invoke-Fleet -Name 'stub-cli' -Prompt 'world' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "cli dispatch captures stdout" (($r.stdout | Out-String).Trim() -eq 'hello-world')
Assert "cli dispatch exit 0" ($r.exit_code -eq 0)
Assert "cli dispatch measured duration" ($r.duration_s -ge 0)
Assert "cli dispatch wrote journal line" (@(Get-Content $tmpJournal | Where-Object { $_ -match '\| fleet \| stub-cli \|' }).Count -ge 1)

# --- model substitution through dispatch ---
$env:CAO_STATE_PATH = $noState
try {
    $r2 = Invoke-Fleet -Name 'stub-with-model' -Prompt 'p' -Model 'm123' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "model passed through dispatch" (($r2.stdout | Out-String).Trim() -eq 'm123:p')

# --- env var applied during call, restored after ---
$before = [Environment]::GetEnvironmentVariable('FLEET_TEST_VAR')
$env:CAO_STATE_PATH = $noState
try {
    $null = Invoke-Fleet -Name 'stub-with-env' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
$after = [Environment]::GetEnvironmentVariable('FLEET_TEST_VAR')
Assert "env var restored after dispatch" ($before -eq $after)

# --- disabled provider refused ---
$threw = $false
try { Invoke-Fleet -Name 'stub-disabled' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal } catch { $threw = $true }
Assert "disabled provider refused" ($threw)

# --- unknown provider refused ---
$threw2 = $false
try { Invoke-Fleet -Name 'does-not-exist' -Prompt 'x' -Path $fixture -JournalPath $tmpJournal } catch { $threw2 = $true }
Assert "unknown provider refused" ($threw2)

Remove-Item $tmpJournal -ErrorAction SilentlyContinue

# --- http dispatch via stub escape hatch ---
$tmpJournal2 = Join-Path $env:TEMP "fleet-http-journal-$(Get-Random).md"
$noState2    = Join-Path $env:TEMP "fleet-http-nostate-$(Get-Random).json"
$env:CAO_STATE_PATH = $noState2
try {
    $rh = Invoke-Fleet -Name 'stub-http' -Prompt 'ping' -Path $fixture -JournalPath $tmpJournal2
} finally { Remove-Item env:CAO_STATE_PATH -ErrorAction SilentlyContinue }
Assert "http dispatch calls Invoke-StubHttp" ($rh.stdout -eq 'stub-http-response:ping')
Assert "http dispatch exit 0" ($rh.exit_code -eq 0)
Assert "http dispatch journaled" (@(Get-Content $tmpJournal2 | Where-Object { $_ -match '\| fleet \| stub-http \|' }).Count -ge 1)
Remove-Item $tmpJournal2 -ErrorAction SilentlyContinue

# --- Test-StdinSafe predicate ---
Assert "stdin-safe: trailing quoted prompt (codex)" (Test-StdinSafe -Provider @{ name='c'; command_template='codex exec "{{prompt}}"' })
Assert "stdin-safe: trailing quoted prompt with model (ollama)" (Test-StdinSafe -Provider @{ name='o'; command_template='ollama run {{model}} "{{prompt}}"'; model_default='m' })
Assert "stdin-safe: embedded prompt -> legacy (test stub)" (-not (Test-StdinSafe -Provider @{ name='s'; command_template='pwsh -NoProfile -Command "Write-Output hello-{{prompt}}"' }))
Assert "stdin-safe: shell operator in tail -> legacy" (-not (Test-StdinSafe -Provider @{ name='p'; command_template='foo | bar "{{prompt}}"' }))
Assert "stdin-safe: already stdin:true -> not re-flagged" (-not (Test-StdinSafe -Provider @{ name='h'; stdin=$true; command_template='claude -p --model x' }))
# stdin:false is an explicit VETO of the clean-tail promotion: agy's `--print`
# requires an inline argument and does NOT read stdin — promotion turns
# 'agy --print "{{prompt}}"' into bare 'agy --print' (flag needs an argument).
Assert "stdin-safe: explicit stdin:false vetoes promotion (agy)" (-not (Test-StdinSafe -Provider @{ name='a'; stdin=$false; command_template='agy --print "{{prompt}}"' }))

# --- Regression: embedded-prompt stubs still interpolate ---
$tmpJ = New-TemporaryFile
$rReg = Invoke-Fleet -Name 'stub-cli' -Prompt 'world' -Path $fixture -JournalPath $tmpJ
Assert "regression: stub-cli still outputs hello-world (legacy path)" (($rReg.stdout | Out-String).Trim() -eq 'hello-world')
Remove-Item $tmpJ -ErrorAction SilentlyContinue

# --- Regression: stdin:true provider round-trips via stdin (guards the empty-prompt
#     Resolve-FleetCommand rejection that broke real stdin providers) ---
$tmpJs = New-TemporaryFile
$rStdin = Invoke-Fleet -Name 'stub-stdin' -Prompt 'HELLO-VIA-STDIN' -Path $fixture -JournalPath $tmpJs
Assert "stdin:true provider dispatches without throwing" ($rStdin.exit_code -eq 0)
Assert "stdin:true provider receives the prompt on stdin" (($rStdin.stdout | Out-String) -match 'HELLO-VIA-STDIN')
Remove-Item $tmpJs -ErrorAction SilentlyContinue

# --- {{prompt_file}} transport: quote-heavy round-trip + temp cleanup ---
# A prompt carrying embedded double quotes, {braces}, and a literal $1 — the exact
# shapes that break inline interpolation — must survive intact through the temp
# file. $pfCore is single-quoted so $1 stays literal (no PS expansion).
$pfCore = 'quote:"inner" brace:{x} dollar:$1'
$pfSentinel = 'PFSENT' + [guid]::NewGuid().ToString('N')
$pfPrompt = $pfCore + ' ' + $pfSentinel
# Journal to a .md path (not New-TemporaryFile) so it is not itself a *.tmp the
# cleanup scan below would mistake for a leaked prompt temp file — the sentinel
# rides the journal's prompt summary too.
$tmpJpf = Join-Path $env:TEMP "fleet-disp-pf-journal-$(Get-Random).md"
$rPf = Invoke-Fleet -Name 'stub-promptfile' -Prompt $pfPrompt -Path $fixture -JournalPath $tmpJpf
$pfOut = ($rPf.stdout | Out-String)
Assert "prompt_file round-trips quote-heavy text intact" ($pfOut.Contains($pfCore))
Assert "prompt_file dispatch exit 0" ($rPf.exit_code -eq 0)
# Temp cleanup: the finally in Invoke-Fleet-Cli deletes the temp file, so no *.tmp
# in $env:TEMP should still hold the unique sentinel after dispatch.
$pfLingering = @(Get-ChildItem -Path $env:TEMP -Filter '*.tmp' -File -ErrorAction SilentlyContinue |
    Where-Object { try { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop).Contains($pfSentinel) } catch { $false } })
Assert "prompt_file temp file cleaned up (no lingering sentinel)" ($pfLingering.Count -eq 0)
Remove-Item $tmpJpf -ErrorAction SilentlyContinue

# A {{prompt_file}} template must NOT be promoted to stdin (no trailing quoted
# {{prompt}} tail for Test-StdinSafe to strip) — the file branch owns it.
Assert "stdin-safe: {{prompt_file}} template not promoted to stdin" (-not (Test-StdinSafe -Provider @{ name='pf'; command_template='grok --prompt-file "{{prompt_file}}"' }))

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
