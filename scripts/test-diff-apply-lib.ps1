#!/usr/bin/env pwsh
<# Hermetic tests for the diff-apply edit-block parser (d103, Task 1).
   Pure parser — no BATON_HOME, no filesystem, no fleet config needed. #>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$failures = 0
function Assert($label, $cond) {
    if ($cond) { Write-Host "PASS  $label" -ForegroundColor Green }
    else { Write-Host "FAIL  $label" -ForegroundColor Red; $script:failures++ }
}

. (Join-Path $here 'diff-apply-lib.ps1')

# ---------- P1: one well-formed block ----------
$t1 = @'
FILE: src/foo.ps1
<<<<<<< SEARCH
old line
=======
new line
>>>>>>> REPLACE
'@
$r1 = ConvertFrom-EditBlocks -Text $t1
Assert 'P1 result=ok' ($r1.result -eq 'ok')
Assert 'P1 one block' (@($r1.blocks).Count -eq 1)
Assert 'P1 path exact' ($r1.blocks[0].path -eq 'src/foo.ps1')
Assert 'P1 search exact' ($r1.blocks[0].search -eq 'old line')
Assert 'P1 replace exact' ($r1.blocks[0].replace -eq 'new line')
Assert 'P1 is_create false' ($r1.blocks[0].is_create -eq $false)

# ---------- P2: two blocks, different files ----------
$t2 = @'
FILE: a.ps1
<<<<<<< SEARCH
aaa
=======
AAA
>>>>>>> REPLACE
FILE: b.ps1
<<<<<<< SEARCH
bbb
=======
BBB
>>>>>>> REPLACE
'@
$r2 = ConvertFrom-EditBlocks -Text $t2
Assert 'P2 result=ok' ($r2.result -eq 'ok')
Assert 'P2 two blocks' (@($r2.blocks).Count -eq 2)
Assert 'P2 order preserved (first is a.ps1)' ($r2.blocks[0].path -eq 'a.ps1')
Assert 'P2 order preserved (second is b.ps1)' ($r2.blocks[1].path -eq 'b.ps1')

# ---------- P3: two blocks, same file ----------
$t3 = @'
FILE: same.ps1
<<<<<<< SEARCH
one
=======
ONE
>>>>>>> REPLACE
FILE: same.ps1
<<<<<<< SEARCH
two
=======
TWO
>>>>>>> REPLACE
'@
$r3 = ConvertFrom-EditBlocks -Text $t3
Assert 'P3 result=ok' ($r3.result -eq 'ok')
Assert 'P3 two blocks' (@($r3.blocks).Count -eq 2)
Assert 'P3 order preserved (first search=one)' ($r3.blocks[0].search -eq 'one')
Assert 'P3 order preserved (second search=two)' ($r3.blocks[1].search -eq 'two')
Assert 'P3 both same file' ($r3.blocks[0].path -eq 'same.ps1' -and $r3.blocks[1].path -eq 'same.ps1')

# ---------- P4: prose before, between, and after blocks ----------
$t4 = @'
Sure, here is the fix:

FILE: c.ps1
<<<<<<< SEARCH
ccc
=======
CCC
>>>>>>> REPLACE

And here is another one:

FILE: d.ps1
<<<<<<< SEARCH
ddd
=======
DDD
>>>>>>> REPLACE

Let me know if you need anything else.
'@
$r4 = ConvertFrom-EditBlocks -Text $t4
Assert 'P4 result=ok' ($r4.result -eq 'ok')
Assert 'P4 two blocks despite prose' (@($r4.blocks).Count -eq 2)
Assert 'P4 first block intact' ($r4.blocks[0].path -eq 'c.ps1' -and $r4.blocks[0].search -eq 'ccc' -and $r4.blocks[0].replace -eq 'CCC')
Assert 'P4 second block intact' ($r4.blocks[1].path -eq 'd.ps1' -and $r4.blocks[1].search -eq 'ddd' -and $r4.blocks[1].replace -eq 'DDD')

# ---------- P5: CRLF input parses identically to LF form ----------
$t5lf = @'
FILE: e.ps1
<<<<<<< SEARCH
eee
=======
EEE
>>>>>>> REPLACE
'@
$t5crlf = $t5lf -replace "`n", "`r`n"
$r5lf = ConvertFrom-EditBlocks -Text $t5lf
$r5crlf = ConvertFrom-EditBlocks -Text $t5crlf
Assert 'P5 CRLF result=ok' ($r5crlf.result -eq 'ok')
Assert 'P5 CRLF matches LF block count' (@($r5crlf.blocks).Count -eq @($r5lf.blocks).Count)
Assert 'P5 CRLF path matches LF' ($r5crlf.blocks[0].path -eq $r5lf.blocks[0].path)
Assert 'P5 CRLF search matches LF' ($r5crlf.blocks[0].search -eq $r5lf.blocks[0].search)
Assert 'P5 CRLF replace matches LF' ($r5crlf.blocks[0].replace -eq $r5lf.blocks[0].replace)

# ---------- P6: unterminated block (no >>>>>>> REPLACE) ----------
$t6 = @'
FILE: f.ps1
<<<<<<< SEARCH
fff
=======
FFF
'@
$r6 = ConvertFrom-EditBlocks -Text $t6
Assert 'P6 result=malformed' ($r6.result -eq 'malformed')
Assert 'P6 zero blocks' (@($r6.blocks).Count -eq 0)
Assert 'P6 error mentions path' ($r6.error -eq 'unterminated block for f.ps1')

# ---------- P7: <<<<<<< SEARCH with no FILE: line ----------
$t7 = @'
<<<<<<< SEARCH
ggg
=======
GGG
>>>>>>> REPLACE
'@
$r7 = ConvertFrom-EditBlocks -Text $t7
Assert 'P7 result=malformed' ($r7.result -eq 'malformed')
Assert 'P7 zero blocks' (@($r7.blocks).Count -eq 0)
Assert 'P7 error text' ($r7.error -eq 'SEARCH block with no preceding FILE: line')

# ---------- P8: prose only, no blocks ----------
$t8 = @'
I looked at the file and it seems fine as-is. No changes needed.
'@
$r8 = ConvertFrom-EditBlocks -Text $t8
Assert 'P8 result=empty' ($r8.result -eq 'empty')
Assert 'P8 zero blocks' (@($r8.blocks).Count -eq 0)

# ---------- P9: empty string / whitespace only ----------
$r9a = ConvertFrom-EditBlocks -Text ''
Assert 'P9a empty string result=empty' ($r9a.result -eq 'empty')
Assert 'P9a empty string zero blocks' (@($r9a.blocks).Count -eq 0)
$r9b = ConvertFrom-EditBlocks -Text "   `n`n   "
Assert 'P9b whitespace-only result=empty' ($r9b.result -eq 'empty')
Assert 'P9b whitespace-only zero blocks' (@($r9b.blocks).Count -eq 0)

# ---------- P10: empty SEARCH section ----------
$t10 = @'
FILE: new.ps1
<<<<<<< SEARCH
=======
brand new content
>>>>>>> REPLACE
'@
$r10 = ConvertFrom-EditBlocks -Text $t10
Assert 'P10 result=ok' ($r10.result -eq 'ok')
Assert 'P10 one block' (@($r10.blocks).Count -eq 1)
Assert 'P10 search is empty' ($r10.blocks[0].search -eq '')
Assert 'P10 is_create true' ($r10.blocks[0].is_create -eq $true)

# ---------- P11: FILE: line followed by prose, then a real block elsewhere ----------
$t11 = @'
FILE: discarded.ps1
This is just prose explaining what I am about to do, not a real block.

FILE: real.ps1
<<<<<<< SEARCH
hhh
=======
HHH
>>>>>>> REPLACE
'@
$r11 = ConvertFrom-EditBlocks -Text $t11
Assert 'P11 result=ok' ($r11.result -eq 'ok')
Assert 'P11 one block (pending path discarded)' (@($r11.blocks).Count -eq 1)
Assert 'P11 real block parsed' ($r11.blocks[0].path -eq 'real.ps1' -and $r11.blocks[0].search -eq 'hhh' -and $r11.blocks[0].replace -eq 'HHH')

# ---------- P12: one good block followed by one unterminated block ----------
$t12 = @'
FILE: good.ps1
<<<<<<< SEARCH
iii
=======
III
>>>>>>> REPLACE
FILE: bad.ps1
<<<<<<< SEARCH
jjj
=======
JJJ
'@
$r12 = ConvertFrom-EditBlocks -Text $t12
Assert 'P12 result=malformed' ($r12.result -eq 'malformed')
Assert 'P12 zero blocks (all-or-nothing)' (@($r12.blocks).Count -eq 0)

# ---------- P13: search text containing a line that looks like prose but not a marker ----------
$t13 = @'
FILE: k.ps1
<<<<<<< SEARCH
this line mentions FILE: something.ps1 but is not a marker
this line has ======== (extra equals, not a bare marker)
=======
replaced
>>>>>>> REPLACE
'@
$r13 = ConvertFrom-EditBlocks -Text $t13
Assert 'P13 result=ok' ($r13.result -eq 'ok')
Assert 'P13 one block' (@($r13.blocks).Count -eq 1)
$expectedSearch13 = "this line mentions FILE: something.ps1 but is not a marker`nthis line has ======== (extra equals, not a bare marker)"
Assert 'P13 search preserved verbatim' ($r13.blocks[0].search -eq $expectedSearch13)

# ---------- P14: replace section empty (deletion) ----------
$t14 = @'
FILE: l.ps1
<<<<<<< SEARCH
delete me
=======
>>>>>>> REPLACE
'@
$r14 = ConvertFrom-EditBlocks -Text $t14
Assert 'P14 result=ok' ($r14.result -eq 'ok')
Assert 'P14 one block' (@($r14.blocks).Count -eq 1)
Assert 'P14 replace is empty' ($r14.blocks[0].replace -eq '')
Assert 'P14 is_create false' ($r14.blocks[0].is_create -eq $false)

if ($failures -gt 0) {
    Write-Host "`nFAILED: $failures assertion(s)" -ForegroundColor Red
} else {
    Write-Host "`nAll diff-apply-lib tests passed." -ForegroundColor Green
}
exit $failures
