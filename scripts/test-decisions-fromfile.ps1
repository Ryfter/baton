#!/usr/bin/env pwsh
# Tests for Add-DecisionRecordFromFile (file-based intake).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'decisions-lib.ps1')

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

$tmpKb = Join-Path $env:TEMP "dec-fromfile-kb-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $tmpKb | Out-Null

# --- T1: happy path ---
$draft1 = Join-Path $env:TEMP "draft1-$(Get-Random).md"
@'
---
title: Plan X foo bar
confidence: high
revisit-if: when Y changes
project: testproj
---

**Chosen:** Option A with rationale baked in.

**Alternatives:**
- Option B — slower
- Option C — costs more

**Rationale:** Option A balances speed and cost best for the current corpus size and aligns with prior decisions in this project.
'@ | Set-Content -Path $draft1 -Encoding utf8NoBOM

$r = Add-DecisionRecordFromFile -Path $draft1 -KbRoot $tmpKb
Assert "T1 returns id"        ($r.id -eq 'd001')
Assert "T1 writes final file" (Test-Path $r.path)
Assert "T1 draft deleted"     (-not (Test-Path $draft1))
$final = Get-Content $r.path -Raw
Assert "T1 id in front-matter"     ($final -match '(?m)^id: d001')
Assert "T1 timestamp present"      ($final -match '(?m)^timestamp: \d{4}-')
Assert "T1 project from front-matter" ($final -match '(?m)^project: testproj')
Assert "T1 confidence preserved"   ($final -match '(?m)^confidence: high')
Assert "T1 revisit-if quoted"      ($final -match '(?m)^revisit-if: "when Y changes"')
Assert "T1 H1 title"               ($final -match '(?m)^# Plan X foo bar')
Assert "T1 chosen body preserved"  ($final -match '\*\*Chosen:\*\* Option A')
Assert "T1 alternatives preserved" ($final -match 'Option B — slower')
Assert "T1 rationale preserved"    ($final -match '\*\*Rationale:\*\* Option A balances')
Assert "T1 feedback section added" ($final -match '(?m)^## Feedback')

# --- T2: second call yields d002 ---
$draft2 = Join-Path $env:TEMP "draft2-$(Get-Random).md"
@'
---
title: Another decision
confidence: med
revisit-if: never
project: testproj
---

**Chosen:** Pick this.

**Alternatives:**
- Other — bad

**Rationale:** Because.
'@ | Set-Content -Path $draft2 -Encoding utf8NoBOM
$r2 = Add-DecisionRecordFromFile -Path $draft2 -KbRoot $tmpKb
Assert "T2 next id is d002" ($r2.id -eq 'd002')

# --- T3: KeepDraft retains the draft file ---
$draft3 = Join-Path $env:TEMP "draft3-$(Get-Random).md"
@'
---
title: Keep me
confidence: low
revisit-if: tomorrow
project: testproj
---

**Chosen:** X

**Alternatives:**
- Y — n

**Rationale:** Because.
'@ | Set-Content -Path $draft3 -Encoding utf8NoBOM
$r3 = Add-DecisionRecordFromFile -Path $draft3 -KbRoot $tmpKb -KeepDraft
Assert "T3 returns id d003"   ($r3.id -eq 'd003')
Assert "T3 draft preserved"   (Test-Path $draft3)
Remove-Item $draft3 -Force -ErrorAction SilentlyContinue

# --- T4: missing required front-matter rejected ---
$bad = Join-Path $env:TEMP "draft-bad-$(Get-Random).md"
@'
---
title: Missing confidence
revisit-if: x
project: testproj
---

**Chosen:** x

**Alternatives:**
- y — n

**Rationale:** because
'@ | Set-Content -Path $bad -Encoding utf8NoBOM
$threw = $false
try { Add-DecisionRecordFromFile -Path $bad -KbRoot $tmpKb | Out-Null } catch { $threw = $true }
Assert "T4 missing confidence throws" $threw
Remove-Item $bad -Force -ErrorAction SilentlyContinue

# --- T5: invalid confidence value rejected ---
$bad2 = Join-Path $env:TEMP "draft-bad2-$(Get-Random).md"
@'
---
title: Bad confidence
confidence: maybe
revisit-if: x
project: testproj
---

**Chosen:** x

**Alternatives:**
- y — n

**Rationale:** because
'@ | Set-Content -Path $bad2 -Encoding utf8NoBOM
$threw = $false
try { Add-DecisionRecordFromFile -Path $bad2 -KbRoot $tmpKb | Out-Null } catch { $threw = $true }
Assert "T5 invalid confidence throws" $threw
Remove-Item $bad2 -Force -ErrorAction SilentlyContinue

# --- T6: missing **Rationale:** section rejected ---
$bad3 = Join-Path $env:TEMP "draft-bad3-$(Get-Random).md"
@'
---
title: No rationale
confidence: high
revisit-if: x
project: testproj
---

**Chosen:** x

**Alternatives:**
- y — n
'@ | Set-Content -Path $bad3 -Encoding utf8NoBOM
$threw = $false
try { Add-DecisionRecordFromFile -Path $bad3 -KbRoot $tmpKb | Out-Null } catch { $threw = $true }
Assert "T6 missing Rationale section throws" $threw
Remove-Item $bad3 -Force -ErrorAction SilentlyContinue

# --- T7: missing front-matter fence entirely rejected ---
$bad4 = Join-Path $env:TEMP "draft-bad4-$(Get-Random).md"
"# Just a title" | Set-Content -Path $bad4 -Encoding utf8NoBOM
$threw = $false
try { Add-DecisionRecordFromFile -Path $bad4 -KbRoot $tmpKb | Out-Null } catch { $threw = $true }
Assert "T7 no front-matter throws" $threw
Remove-Item $bad4 -Force -ErrorAction SilentlyContinue

# --- T8: opt-out — global opt-out file ---
$tmpOptOut = Join-Path $env:TEMP "decisions-off-$(Get-Random)"
Set-Content -Path $tmpOptOut -Value '' -Encoding utf8NoBOM
$draft5 = Join-Path $env:TEMP "draft5-$(Get-Random).md"
@'
---
title: Should not save
confidence: high
revisit-if: x
project: testproj
---

**Chosen:** x

**Alternatives:**
- y — n

**Rationale:** because
'@ | Set-Content -Path $draft5 -Encoding utf8NoBOM
$r5 = Add-DecisionRecordFromFile -Path $draft5 -KbRoot $tmpKb -OptOutPath $tmpOptOut
Assert "T8 opt-out returns null" ($null -eq $r5)
Remove-Item $tmpOptOut -Force -ErrorAction SilentlyContinue
Remove-Item $draft5 -Force -ErrorAction SilentlyContinue

# Cleanup
Remove-Item $tmpKb -Recurse -Force -ErrorAction SilentlyContinue

if ($failures -gt 0) { Write-Host "`n$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "`nAll tests passed." -ForegroundColor Green
