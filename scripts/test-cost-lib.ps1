#!/usr/bin/env pwsh
# Tests for scripts/cost-lib.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'cost-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpKb = Join-Path $env:TEMP "cost-kb-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpKb | Out-Null

# --- First entry creates the file ---
$r1 = Add-CostEntry -Total 100.00 -Source 'Test billing' -Note 'first' -Project 'p1' -KbRoot $tmpKb
$costPath = Join-Path $tmpKb 'projects/p1/cost.md'
Assert "first entry creates cost.md" (Test-Path $costPath)
$state = Read-CostState -Path $costPath
Assert "first entry current = 100" ($state.current -eq 100.00)
Assert "first entry count = 1" ($state.entries.Count -eq 1)
Assert "Add-CostEntry returns delta = 100" ($r1.delta -eq 100.00)

# --- Second entry: positive delta ---
Add-CostEntry -Total 150.50 -Source 'Test billing' -Note 'second' -Project 'p1' -KbRoot $tmpKb | Out-Null
$state = Read-CostState -Path $costPath
Assert "second entry current = 150.50" ($state.current -eq 150.50)
Assert "second entry count = 2" ($state.entries.Count -eq 2)

# Header reflects latest total
$content = Get-Content $costPath -Raw
Assert "header shows current 150.50" ($content -match '\*\*Current total: \$150\.50\*\*')

# --- Third entry: delta calculation ---
$r3 = Add-CostEntry -Total 200.25 -Source 'Test billing' -Note 'third' -Project 'p1' -KbRoot $tmpKb
$content = Get-Content $costPath -Raw
Assert "third entry has +49.75 delta in table" ($content -match '\+\$49\.75')
Assert "Add-CostEntry returns delta 49.75 (within rounding)" ([Math]::Abs($r3.delta - 49.75) -lt 0.005)

# --- Pipe in note is sanitized ---
Add-CostEntry -Total 250.00 -Note 'has | pipe' -Project 'p1' -KbRoot $tmpKb | Out-Null
$content = Get-Content $costPath -Raw
Assert "pipe in note sanitized to ¦" ($content -match 'has ¦ pipe')

# --- Negative delta (credit / correction) ---
$r5 = Add-CostEntry -Total 240.00 -Note 'credit' -Project 'p1' -KbRoot $tmpKb
$content = Get-Content $costPath -Raw
Assert "negative delta shown as -$10.00" ($content -match '-\$10\.00')
Assert "Add-CostEntry returns negative delta" ($r5.delta -lt 0)

# --- New project auto-creates its own dir ---
Add-CostEntry -Total 25.00 -Source 'Test' -Project 'p2' -KbRoot $tmpKb | Out-Null
Assert "p2 cost.md created" (Test-Path (Join-Path $tmpKb 'projects/p2/cost.md'))

# --- Read-CostState on missing file → empty state ---
$empty = Read-CostState -Path (Join-Path $env:TEMP "nope-$(Get-Random).md")
Assert "missing file → current = 0" ($empty.current -eq [decimal]0)
Assert "missing file → no entries" ($empty.entries.Count -eq 0)

# --- Get-CostPath with explicit project ---
$path = Get-CostPath -Project 'p1' -KbRoot $tmpKb
Assert "Get-CostPath returns expected path" ($path -eq (Join-Path $tmpKb 'projects/p1/cost.md'))

Remove-Item $tmpKb -Recurse -Force
if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
