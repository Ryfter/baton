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

# =====================================================================
# Applier checks (A*, d103 Task 2) — Test-DiffApplyPathSafe /
# Invoke-EditBlockApply. Hermetic: fixtures live in a temp worktree that
# is removed in the finally block. No git init required.
# =====================================================================

$applyTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-diffapply-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Force -Path $applyTmp | Out-Null
$script:wtSeq = 0

function New-FixtureWorktree {
    $script:wtSeq++
    $p = Join-Path $applyTmp ("wt{0}" -f $script:wtSeq)
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}
function Set-FixtureFile {
    param([string]$Root, [string]$Rel, [string]$Text, [bool]$Bom = $false)
    $full = Join-Path $Root $Rel
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($full, $Text, [System.Text.UTF8Encoding]::new($Bom))
    return $full
}
function Get-FixtureText {
    param([string]$Root, [string]$Rel)
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root $Rel))
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    return [System.Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
}
function Test-FixtureBom {
    param([string]$Root, [string]$Rel)
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root $Rel))
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}
function New-Blk {
    param([string]$Path, [string]$Search, [string]$Replace)
    return [ordered]@{ path = $Path; search = $Search; replace = $Replace; is_create = ($Search -eq '') }
}
function Get-Sha {
    param([string]$P)
    return (Get-FileHash -LiteralPath $P -Algorithm SHA256).Hash
}

try {
    # ---------- A1: single exact match ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'src/a.txt' "alpha`nbeta`ngamma`n" | Out-Null
    $a1 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'src/a.txt' 'beta' 'BETA')) -AllowedPaths @()
    Assert 'A1 ok=true' ($a1.ok -eq $true)
    Assert 'A1 result=ok' ($a1.result -eq 'ok')
    Assert 'A1 blocks_applied=1' ($a1.blocks_applied -eq 1)
    Assert 'A1 files_written lists the path' (@($a1.files_written) -contains 'src/a.txt')
    Assert 'A1 content updated' ((Get-FixtureText $wt 'src/a.txt') -eq "alpha`nBETA`ngamma`n")

    # ---------- A2: search text absent ----------
    $wt = New-FixtureWorktree
    $f2 = Set-FixtureFile $wt 'a.txt' "alpha`nbeta`n"
    $h2 = Get-Sha $f2
    $a2 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'a.txt' 'zeta' 'ZETA')) -AllowedPaths @()
    Assert 'A2 ok=false' ($a2.ok -eq $false)
    Assert 'A2 result=search-not-found' ($a2.result -eq 'search-not-found')
    Assert 'A2 error names the path' ($a2.error -match 'a\.txt')
    Assert 'A2 file byte-identical' ((Get-Sha $f2) -eq $h2)

    # ---------- A3: search text appears twice ----------
    $wt = New-FixtureWorktree
    $f3 = Set-FixtureFile $wt 'a.txt' "dup`nmid`ndup`n"
    $h3 = Get-Sha $f3
    $a3 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'a.txt' 'dup' 'DUP')) -AllowedPaths @()
    Assert 'A3 ok=false' ($a3.ok -eq $false)
    Assert 'A3 result=search-ambiguous' ($a3.result -eq 'search-ambiguous')
    Assert 'A3 file byte-identical' ((Get-Sha $f3) -eq $h3)

    # ---------- A4: two blocks, second matches what the first wrote ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'a.txt' "one`n" | Out-Null
    $a4 = Invoke-EditBlockApply -Worktree $wt -Blocks @(
        (New-Blk 'a.txt' 'one' 'two'),
        (New-Blk 'a.txt' 'two' 'three')
    ) -AllowedPaths @()
    Assert 'A4 ok=true' ($a4.ok -eq $true)
    Assert 'A4 blocks_applied=2' ($a4.blocks_applied -eq 2)
    Assert 'A4 content is three' ((Get-FixtureText $wt 'a.txt') -eq "three`n")
    Assert 'A4 one written file' (@($a4.files_written).Count -eq 1)

    # ---------- A5: good block + later bad block => nothing written at all ----------
    $wt = New-FixtureWorktree
    $f5a = Set-FixtureFile $wt 'x.txt' "good`n"
    $f5b = Set-FixtureFile $wt 'y.txt' "yyy`n"
    $h5a = Get-Sha $f5a
    $h5b = Get-Sha $f5b
    $a5 = Invoke-EditBlockApply -Worktree $wt -Blocks @(
        (New-Blk 'x.txt' 'good' 'GOOD'),
        (New-Blk 'y.txt' 'absent' 'NOPE')
    ) -AllowedPaths @()
    Assert 'A5 ok=false' ($a5.ok -eq $false)
    Assert 'A5 result=search-not-found' ($a5.result -eq 'search-not-found')
    Assert 'A5 first file SHA256 unchanged' ((Get-Sha $f5a) -eq $h5a)
    Assert 'A5 second file SHA256 unchanged' ((Get-Sha $f5b) -eq $h5b)
    Assert 'A5 nothing reported written' (@($a5.files_written).Count -eq 0)

    # ---------- A6: create a new file (empty SEARCH) ----------
    $wt = New-FixtureWorktree
    $a6 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'newdir/new.txt' '' 'created content')) -AllowedPaths @()
    Assert 'A6 ok=true' ($a6.ok -eq $true)
    Assert 'A6 file exists' (Test-Path -LiteralPath (Join-Path $wt 'newdir/new.txt'))
    Assert 'A6 exact content' ((Get-FixtureText $wt 'newdir/new.txt') -eq "created content`n")
    Assert 'A6 no BOM on created file' (-not (Test-FixtureBom $wt 'newdir/new.txt'))

    # ---------- A7: create where the file already exists ----------
    $wt = New-FixtureWorktree
    $f7 = Set-FixtureFile $wt 'exists.txt' "orig`n"
    $h7 = Get-Sha $f7
    $a7 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'exists.txt' '' 'clobbered')) -AllowedPaths @()
    Assert 'A7 ok=false' ($a7.ok -eq $false)
    Assert 'A7 result=create-exists' ($a7.result -eq 'create-exists')
    Assert 'A7 existing file unchanged' ((Get-Sha $f7) -eq $h7)

    # ---------- A8: CRLF file, LF blocks => stays CRLF ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'crlf.txt' "a`r`nb`r`nc`r`n" | Out-Null
    $a8 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'crlf.txt' 'b' "B`nB2")) -AllowedPaths @()
    $t8 = Get-FixtureText $wt 'crlf.txt'
    Assert 'A8 ok=true' ($a8.ok -eq $true)
    Assert 'A8 exact CRLF content' ($t8 -eq "a`r`nB`r`nB2`r`nc`r`n")
    Assert 'A8 no lone LF remains' (-not ($t8.Replace("`r`n", '').Contains("`n")))

    # ---------- A9: LF file stays LF ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'lf.txt' "x`ny`n" | Out-Null
    $a9 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'lf.txt' 'y' "Y`nZ")) -AllowedPaths @()
    $t9 = Get-FixtureText $wt 'lf.txt'
    Assert 'A9 ok=true' ($a9.ok -eq $true)
    Assert 'A9 exact LF content' ($t9 -eq "x`nY`nZ`n")
    Assert 'A9 no CR introduced' (-not $t9.Contains("`r"))

    # ---------- A10: file with a BOM keeps its BOM ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'bom.txt' "alpha`nbeta`n" $true | Out-Null
    Assert 'A10 fixture starts with BOM' (Test-FixtureBom $wt 'bom.txt')
    $a10 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'bom.txt' 'beta' 'BETA')) -AllowedPaths @()
    Assert 'A10 ok=true' ($a10.ok -eq $true)
    Assert 'A10 BOM preserved' (Test-FixtureBom $wt 'bom.txt')
    Assert 'A10 content updated' ((Get-FixtureText $wt 'bom.txt') -eq "alpha`nBETA`n")

    # ---------- A11: file with no trailing newline keeps none ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'nonl.txt' 'no-newline-here' | Out-Null
    $a11 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'nonl.txt' 'newline' 'NEWLINE')) -AllowedPaths @()
    $t11 = Get-FixtureText $wt 'nonl.txt'
    Assert 'A11 ok=true' ($a11.ok -eq $true)
    Assert 'A11 exact content' ($t11 -eq 'no-NEWLINE-here')
    Assert 'A11 still no trailing newline' (-not $t11.EndsWith("`n"))

    # ---------- A12: search text full of regex metacharacters ----------
    $wt = New-FixtureWorktree
    $meta = '$x = @(1); a.b[0]'
    Set-FixtureFile $wt 'meta.txt' ("before`n" + $meta + "`nafter`n") | Out-Null
    $a12 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'meta.txt' $meta 'REPLACED')) -AllowedPaths @()
    Assert 'A12 ok=true' ($a12.ok -eq $true)
    Assert 'A12 literal (non-regex) replacement' ((Get-FixtureText $wt 'meta.txt') -eq "before`nREPLACED`nafter`n")

    # ---------- A13: parent escape ----------
    $wt = New-FixtureWorktree
    $a13 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk '../escape.txt' 'x' 'y')) -AllowedPaths @()
    $s13 = Test-DiffApplyPathSafe -Worktree $wt -RelPath '../escape.txt'
    Assert 'A13 result=path-rejected' ($a13.result -eq 'path-rejected')
    Assert 'A13 ok=false' ($a13.ok -eq $false)
    Assert 'A13 reason=parent-escape' ($s13.reason -eq 'parent-escape')
    Assert 'A13 nothing written outside worktree' (-not (Test-Path -LiteralPath (Join-Path $applyTmp 'escape.txt')))

    # ---------- A14: absolute path ----------
    $wt = New-FixtureWorktree
    $abs14 = Join-Path $applyTmp 'abs.txt'
    $a14 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk $abs14 'x' 'y')) -AllowedPaths @()
    $s14 = Test-DiffApplyPathSafe -Worktree $wt -RelPath $abs14
    Assert 'A14 result=path-rejected' ($a14.result -eq 'path-rejected')
    Assert 'A14 reason=absolute-path' ($s14.reason -eq 'absolute-path')
    Assert 'A14 nothing written' (-not (Test-Path -LiteralPath $abs14))

    # ---------- A15: .git path ----------
    $wt = New-FixtureWorktree
    $a15 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk '.git/config' 'x' 'y')) -AllowedPaths @()
    $s15 = Test-DiffApplyPathSafe -Worktree $wt -RelPath '.git/config'
    $s15b = Test-DiffApplyPathSafe -Worktree $wt -RelPath '.GIT/config'
    Assert 'A15 result=path-rejected' ($a15.result -eq 'path-rejected')
    Assert 'A15 reason=git-path' ($s15.reason -eq 'git-path')
    Assert 'A15 .git match is case-insensitive' ($s15b.reason -eq 'git-path')
    Assert 'A15 nothing written' (-not (Test-Path -LiteralPath (Join-Path $wt '.git/config')))

    # ---------- A16: path outside AllowedPaths ----------
    $wt = New-FixtureWorktree
    $f16 = Set-FixtureFile $wt 'src/a.txt' "alpha`n"
    $h16 = Get-Sha $f16
    $a16 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'src/a.txt' 'alpha' 'ALPHA')) -AllowedPaths @('other/')
    Assert 'A16 ok=false' ($a16.ok -eq $false)
    Assert 'A16 result=scope-rejected' ($a16.result -eq 'scope-rejected')
    Assert 'A16 file unchanged' ((Get-Sha $f16) -eq $h16)

    # ---------- A17: empty AllowedPaths => unrestricted (oracle's unenforced case) ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'src/a.txt' "alpha`n" | Out-Null
    $a17 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'src/a.txt' 'alpha' 'ALPHA')) -AllowedPaths @()
    Assert 'A17 ok=true (unenforced scope)' ($a17.ok -eq $true)
    Assert 'A17 content applied' ((Get-FixtureText $wt 'src/a.txt') -eq "ALPHA`n")

    # ---------- A18: deletion (empty replace) ----------
    $wt = New-FixtureWorktree
    Set-FixtureFile $wt 'del.txt' "keep1`ndelete me`nkeep2`n" | Out-Null
    $a18 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'del.txt' "delete me`n" '')) -AllowedPaths @()
    Assert 'A18 ok=true' ($a18.ok -eq $true)
    Assert 'A18 text removed, rest intact' ((Get-FixtureText $wt 'del.txt') -eq "keep1`nkeep2`n")

    # ---------- A19: symlinked ancestor directory is an escape ----------
    $wt = New-FixtureWorktree
    $linkTarget = Join-Path $applyTmp 'outside-target'
    New-Item -ItemType Directory -Force -Path $linkTarget | Out-Null
    # Symlink creation needs privileges we may not have; a directory junction is
    # the same ReparsePoint escape and needs none. Try both before skipping.
    $linkKind = ''
    foreach ($kind in @('SymbolicLink', 'Junction')) {
        try {
            New-Item -ItemType $kind -Path (Join-Path $wt 'link') -Target $linkTarget -ErrorAction Stop | Out-Null
            $linkKind = $kind
            break
        } catch { }
    }
    if ($linkKind) {
        $s19 = Test-DiffApplyPathSafe -Worktree $wt -RelPath 'link/x.txt'
        Assert "A19 reparse-point ancestor rejected ($linkKind)" ($s19.ok -eq $false -and $s19.reason -eq 'symlink-target')
        $a19 = Invoke-EditBlockApply -Worktree $wt -Blocks @((New-Blk 'link/x.txt' '' 'sneaky')) -AllowedPaths @()
        Assert 'A19 apply rejects reparse-point path' ($a19.result -eq 'path-rejected')
        Assert 'A19 nothing written through the link' (-not (Test-Path -LiteralPath (Join-Path $linkTarget 'x.txt')))
    } else {
        Write-Host "SKIP  A19 reparse-point check (this environment cannot create symlinks or junctions)" -ForegroundColor Yellow
    }

    # ---------- A20: assorted Test-DiffApplyPathSafe rejections + the happy path ----------
    $wt = New-FixtureWorktree
    Assert 'A20 empty path' ((Test-DiffApplyPathSafe -Worktree $wt -RelPath '   ').reason -eq 'empty-path')
    Assert 'A20 UNC path' ((Test-DiffApplyPathSafe -Worktree $wt -RelPath '\\server\share\x.txt').reason -eq 'absolute-path')
    Assert 'A20 control char' ((Test-DiffApplyPathSafe -Worktree $wt -RelPath "a$([char]1)b.txt").reason -eq 'control-char')
    Assert 'A20 empty interior segment' ((Test-DiffApplyPathSafe -Worktree $wt -RelPath 'a//b.txt').reason -eq 'git-path')
    $s20 = Test-DiffApplyPathSafe -Worktree $wt -RelPath 'src/deep/ok.txt'
    Assert 'A20 good path ok=true' ($s20.ok -eq $true)
    Assert 'A20 good path reason empty' ($s20.reason -eq '')
    Assert 'A20 good path resolves under worktree' ($s20.full.StartsWith([System.IO.Path]::GetFullPath($wt), [System.StringComparison]::OrdinalIgnoreCase))
    # ---------- A21: flush failure mid-batch rolls back every already-written
    #                 file byte-exact and deletes any newly-created file,
    #                 returning ok=false/result=flush-failed with no thrown
    #                 exception escaping the function (d103 Task 2 hardening).
    #
    #                 Deterministic forcing mechanism: hold a read-share-only
    #                 handle (FileAccess.Read, FileShare.Read) on the third
    #                 file. File.ReadAllBytes (load step) also opens with
    #                 FileShare.Read, so the load succeeds -- but
    #                 File.WriteAllText (flush step) needs write access,
    #                 which our handle denies, so the flush throws a sharing
    #                 violation exactly where the defect lives (step 5), not
    #                 at load (step 3) or validation. ----------
    $wt = New-FixtureWorktree
    $f21a = Set-FixtureFile $wt 'first.txt' "one`n"
    $h21a = Get-Sha $f21a
    $f21c = Set-FixtureFile $wt 'locked.txt' "locked`n"
    $h21c = Get-Sha $f21c
    $newPath21 = Join-Path $wt 'created/new.txt'

    $fsLock21 = [System.IO.File]::Open($f21c, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $a21 = Invoke-EditBlockApply -Worktree $wt -Blocks @(
            (New-Blk 'first.txt' 'one' 'ONE'),
            (New-Blk 'created/new.txt' '' 'brand new'),
            (New-Blk 'locked.txt' 'locked' 'LOCKED')
        ) -AllowedPaths @()
    } finally {
        $fsLock21.Dispose()
    }

    Assert 'A21 ok=false' ($a21.ok -eq $false)
    Assert 'A21 result=flush-failed' ($a21.result -eq 'flush-failed')
    Assert 'A21 error non-empty' (-not [string]::IsNullOrWhiteSpace($a21.error))
    Assert 'A21 already-written file rolled back byte-identical' ((Get-Sha $f21a) -eq $h21a)
    Assert 'A21 locked file left untouched' ((Get-Sha $f21c) -eq $h21c)
    Assert 'A21 newly-created file does not exist after rollback' (-not (Test-Path -LiteralPath $newPath21))

    # ---------- A22: the file the flush DIES on is enrolled in the rollback set
    #                 before its write is attempted, because WriteAllText truncates
    #                 on open and a throw part-way through would otherwise leave it
    #                 truncated and un-restored. Enrolling it means rollback may
    #                 revisit a file that was never actually opened -- so rollback
    #                 restores only when the bytes genuinely differ.
    #
    #                 This case forces the failure with a READ-ONLY file: the throw
    #                 happens at open, before any truncation, so the file is
    #                 untouched. The discriminating assertion is that this produces
    #                 NO spurious 'rollback failed' text -- a blind restore would
    #                 try to rewrite a read-only file and report a rollback error
    #                 for damage that never occurred.
    #
    #                 HONEST LIMIT: a genuine post-truncation I/O failure (disk
    #                 full, hardware error) cannot be forced deterministically on
    #                 this platform. The enrolment-before-write ordering is
    #                 defence-in-depth against it and is verified by inspection,
    #                 not by this check. ----------
    $wt22 = New-FixtureWorktree
    $f22a = Set-FixtureFile $wt22 'writable.txt' "one`n"
    $h22a = Get-Sha $f22a
    $f22b = Set-FixtureFile $wt22 'readonly.txt' "keep`n"
    $h22b = Get-Sha $f22b
    Set-ItemProperty -LiteralPath $f22b -Name IsReadOnly -Value $true
    try {
        $a22 = Invoke-EditBlockApply -Worktree $wt22 -Blocks @(
            (New-Blk 'writable.txt' 'one' 'ONE'),
            (New-Blk 'readonly.txt' 'keep' 'CHANGED')
        ) -AllowedPaths @()
    } finally {
        Set-ItemProperty -LiteralPath $f22b -Name IsReadOnly -Value $false
    }

    Assert 'A22 ok=false' ($a22.ok -eq $false)
    Assert 'A22 result=flush-failed' ($a22.result -eq 'flush-failed')
    Assert 'A22 writable file rolled back byte-identical' ((Get-Sha $f22a) -eq $h22a)
    Assert 'A22 read-only file untouched' ((Get-Sha $f22b) -eq $h22b)
    Assert 'A22 no spurious rollback error for the untouched failing file' ($a22.error -notmatch 'rollback failed')

    # C12: a max_prompt_bytes below the 4000-byte reserve must floor the context
    # budget at 0, not go negative. A negative budget would only behave correctly
    # by accident.
    $lim12 = Get-DiffApplyLimits -Provider @{ max_prompt_bytes = 1000 }
    Assert 'C12 tiny max_prompt_bytes floors at 0' ([int]$lim12.max_context_bytes -eq 0)
    Assert 'C12 does not go negative' ([int]$lim12.max_context_bytes -ge 0)
} catch {
    Write-Host "FAIL  A-section threw: $_" -ForegroundColor Red
    $script:failures++
} finally {
    if (Test-Path -LiteralPath $applyTmp) {
        Remove-Item -LiteralPath $applyTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# Context assembly + size envelope checks (C*, d103 Task 3) —
# Get-DiffApplyLimits / Get-DiffApplyContext / Build-DiffApplyPrompt.
# Hermetic: fresh temp worktree per fixture. Placeholder provider names
# only (never a real model id, endpoint, or host).
# =====================================================================

$applyTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("baton-diffapply-ctx-" + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
New-Item -ItemType Directory -Force -Path $applyTmp | Out-Null
$script:wtSeq = 0

try {
    # ---------- C1: limits default when provider declares none ----------
    $c1 = Get-DiffApplyLimits -Provider ([ordered]@{ id = 'local-host-a' })
    Assert 'C1 default max_context_bytes' ($c1.max_context_bytes -eq 24000)
    Assert 'C1 default max_files' ($c1.max_files -eq 4)
    Assert 'C1 default max_blocks' ($c1.max_blocks -eq 8)

    # ---------- C2: provider overrides are honored ----------
    $c2Provider = [ordered]@{
        id                = 'local-host-a'
        diff_apply_limits = [ordered]@{ max_context_bytes = 12000; max_files = 2; max_blocks = 3 }
    }
    $c2 = Get-DiffApplyLimits -Provider $c2Provider
    Assert 'C2 override max_context_bytes' ($c2.max_context_bytes -eq 12000)
    Assert 'C2 override max_files' ($c2.max_files -eq 2)
    Assert 'C2 override max_blocks' ($c2.max_blocks -eq 3)

    # ---------- C3: max_prompt_bytes clamps max_context_bytes ----------
    $c3Provider = [ordered]@{
        id               = 'local-host-a'
        max_prompt_bytes = 10000
    }
    $c3 = Get-DiffApplyLimits -Provider $c3Provider
    Assert 'C3 clamped to max_prompt_bytes - 4000' ($c3.max_context_bytes -eq 6000)

    # ---------- C4: two small files under a dir/ prefix ----------
    $wt4 = New-FixtureWorktree
    Set-FixtureFile $wt4 'dir/one.txt' "one`n" | Out-Null
    Set-FixtureFile $wt4 'dir/two.txt' "two`n" | Out-Null
    $limits4 = Get-DiffApplyLimits -Provider ([ordered]@{})
    $c4 = Get-DiffApplyContext -Worktree $wt4 -AllowedPaths @('dir/') -Limits $limits4
    Assert 'C4 ok=true' ($c4.ok -eq $true)
    Assert 'C4 file_count=2' ($c4.file_count -eq 2)
    Assert 'C4 both files present' (
        (@($c4.files | Where-Object { $_.path -eq 'dir/one.txt' }).Count -eq 1) -and
        (@($c4.files | Where-Object { $_.path -eq 'dir/two.txt' }).Count -eq 1)
    )
    Assert 'C4 text exact' ((@($c4.files | Where-Object { $_.path -eq 'dir/one.txt' }))[0].text -eq "one`n")

    # ---------- C5: file count over limit ----------
    $wt5 = New-FixtureWorktree
    Set-FixtureFile $wt5 'dir/a.txt' "a`n" | Out-Null
    Set-FixtureFile $wt5 'dir/b.txt' "b`n" | Out-Null
    Set-FixtureFile $wt5 'dir/c.txt' "c`n" | Out-Null
    $limits5 = Get-DiffApplyLimits -Provider ([ordered]@{ diff_apply_limits = [ordered]@{ max_files = 2 } })
    $c5 = Get-DiffApplyContext -Worktree $wt5 -AllowedPaths @('dir/') -Limits $limits5
    Assert 'C5 ok=false' ($c5.ok -eq $false)
    Assert 'C5 reason names files and limit' ($c5.reason -match 'files' -and $c5.reason -match '2')

    # ---------- C6: byte total over limit ----------
    $wt6 = New-FixtureWorktree
    Set-FixtureFile $wt6 'dir/big.txt' ('x' * 100) | Out-Null
    $limits6 = Get-DiffApplyLimits -Provider ([ordered]@{ diff_apply_limits = [ordered]@{ max_context_bytes = 50 } })
    $c6 = Get-DiffApplyContext -Worktree $wt6 -AllowedPaths @('dir/') -Limits $limits6
    Assert 'C6 ok=false' ($c6.ok -eq $false)
    Assert 'C6 reason names bytes and limit' ($c6.reason -match 'bytes' -and $c6.reason -match '50')

    # ---------- C7: .git/ contents never included ----------
    $wt7 = New-FixtureWorktree
    Set-FixtureFile $wt7 'dir/keep.txt' "keep`n" | Out-Null
    Set-FixtureFile $wt7 'dir/.git/config' "fake-git-config`n" | Out-Null
    $limits7 = Get-DiffApplyLimits -Provider ([ordered]@{})
    $c7 = Get-DiffApplyContext -Worktree $wt7 -AllowedPaths @('dir/') -Limits $limits7
    Assert 'C7 ok=true' ($c7.ok -eq $true)
    Assert 'C7 only keep.txt present' (@($c7.files).Count -eq 1 -and $c7.files[0].path -eq 'dir/keep.txt')

    # ---------- C8: non-existent path in AllowedPaths ----------
    $wt8 = New-FixtureWorktree
    Set-FixtureFile $wt8 'dir/real.txt' "real`n" | Out-Null
    $limits8 = Get-DiffApplyLimits -Provider ([ordered]@{})
    $c8 = Get-DiffApplyContext -Worktree $wt8 -AllowedPaths @('dir/real.txt', 'dir/new-file.txt') -Limits $limits8
    Assert 'C8 ok=true' ($c8.ok -eq $true)
    Assert 'C8 only existing file read' (@($c8.files).Count -eq 1 -and $c8.files[0].path -eq 'dir/real.txt')

    # ---------- C9: deterministic ordering ----------
    $wt9 = New-FixtureWorktree
    Set-FixtureFile $wt9 'dir/zzz.txt' "z`n" | Out-Null
    Set-FixtureFile $wt9 'dir/aaa.txt' "a`n" | Out-Null
    Set-FixtureFile $wt9 'dir/mmm.txt' "m`n" | Out-Null
    $limits9 = Get-DiffApplyLimits -Provider ([ordered]@{})
    $c9a = Get-DiffApplyContext -Worktree $wt9 -AllowedPaths @('dir/') -Limits $limits9
    $c9b = Get-DiffApplyContext -Worktree $wt9 -AllowedPaths @('dir/') -Limits $limits9
    $order9a = @($c9a.files | ForEach-Object { $_.path })
    $order9b = @($c9b.files | ForEach-Object { $_.path })
    Assert 'C9 sorted ordinal' (($order9a -join ',') -eq 'dir/aaa.txt,dir/mmm.txt,dir/zzz.txt')
    Assert 'C9 repeat call identical order' (($order9a -join ',') -eq ($order9b -join ','))

    # ---------- C10/C11: prompt content ----------
    $wt10 = New-FixtureWorktree
    Set-FixtureFile $wt10 'dir/one.txt' "hello`n" | Out-Null
    $limits10 = Get-DiffApplyLimits -Provider ([ordered]@{ diff_apply_limits = [ordered]@{ max_blocks = 5 } })
    $ctx10 = Get-DiffApplyContext -Worktree $wt10 -AllowedPaths @('dir/') -Limits $limits10
    $prompt10 = Build-DiffApplyPrompt -TaskDesc 'rename the greeting' -InputBlock '' -Context $ctx10 -AllowedPaths @('dir/') -Limits $limits10
    Assert 'C10 contains task desc' ($prompt10 -match [regex]::Escape('rename the greeting'))
    Assert 'C10 contains scope list entry' ($prompt10 -match [regex]::Escape('dir/'))
    Assert 'C10 contains file contents' ($prompt10 -match [regex]::Escape('hello'))
    Assert 'C10 contains SEARCH marker' ($prompt10 -match [regex]::Escape('<<<<<<< SEARCH'))
    Assert 'C10 contains separator marker' ($prompt10 -match '(?m)^=======\s*$')
    Assert 'C10 contains REPLACE marker' ($prompt10 -match [regex]::Escape('>>>>>>> REPLACE'))
    Assert 'C11 states block cap from Limits' ($prompt10 -match [regex]::Escape('5 blocks'))
    Assert 'C11 states the minimality rule verbatim' ($prompt10 -match [regex]::Escape('keep each SEARCH section as small as possible while still matching only once'))
} catch {
    Write-Host "FAIL  C-section threw: $_" -ForegroundColor Red
    $script:failures++
} finally {
    if (Test-Path -LiteralPath $applyTmp) {
        Remove-Item -LiteralPath $applyTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Host "`nFAILED: $failures assertion(s)" -ForegroundColor Red
} else {
    Write-Host "`nAll diff-apply-lib tests passed." -ForegroundColor Green
}
exit $failures
