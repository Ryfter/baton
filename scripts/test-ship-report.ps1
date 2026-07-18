#!/usr/bin/env pwsh
# Hermetic tests for ship-report-lib.ps1 + fleet-ship-report.ps1.
# Fixture journals under $env:TEMP; $env:BATON_HOME pointed at the fixture root.
# git/gh wrappers stubbed — NEVER touches real ~/.baton, ~/.claude, or D:\Dev\Grimdex.
$ErrorActionPreference = 'Stop'

$script:fail = 0
function Check($n, $c) {
    if ($c) { Write-Host "PASS: $n" }
    else { Write-Host "FAIL: $n"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ship-report-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$prevBatonHome = $env:BATON_HOME
$env:BATON_HOME = $tmp
$script:threw = $false

try {
    . "$PSScriptRoot/ship-report-lib.ps1"

    # ---- fixtures ----
    $journal = Join-Path $tmp 'model-routing-log.md'
    $usagePath = Join-Path $tmp 'usage-journal.jsonl'
    $runsRoot = Join-Path $tmp 'runs'
    $runDir = Join-Path $runsRoot 'go-fixture-1'
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    # Fleet journal: Write-FleetJournalLine shape (placeholder providers only).
    # Phase tags use ONLY the real LinearPhases vocabulary (research|design|
    # code.sprint-N|review) — there is no phase:fix / phase:verification in the real
    # model, so the fix + verification rows classify from their SUMMARY text.
    $journalLines = @(
        '# Model Routing Log'
        '# --- entries below this line ---'
        '2026-07-10T10:00:00Z | fleet | worker-a | 120s | exit:0 | "implement feature slice" | host:testbox | job:j1 | phase:code.sprint-1 | tok:439000(exact)'
        '2026-07-10T11:00:00Z | fleet | worker-a | 30s | exit:0 | "more build work" | host:testbox | phase:code.sprint-1 | tok:1000(estimate)'
        '2026-07-10T12:00:00Z | fleet | worker-b | 45s | exit:0 | "adversarial review of diff" | host:testbox | phase:review | tok:25000(exact)'
        '2026-07-10T12:30:00Z | fleet | worker-local | 10s | exit:0 | "powershell lens review" | host:testbox | phase:review | tok:0(estimate)'
        '2026-07-10T13:00:00Z | fleet | worker-b | 20s | exit:0 | "fix pass on findings" | host:testbox | phase:code.sprint-1 | tok:2000(exact)'
        '2026-07-10T14:00:00Z | fleet | worker-local | 5s | exit:0 | "full local gate + pytest" | host:testbox | phase:review | tok:0(estimate)'
        # Real writer emits zzz numeric offsets, not Z (fleet-lib.ps1:618). -06:00 == 15:30Z, in-window build row.
        '2026-07-10T09:30:00-06:00 | fleet | worker-a | 15s | exit:0 | "kickoff build" | host:testbox | phase:code.sprint-1 | tok:500(estimate)'
        # Outside window (should be ignored when window is set)
        '2026-07-01T09:00:00Z | fleet | worker-old | 1s | exit:0 | "unrelated prior work" | host:testbox | tok:99999(exact)'
    )
    Set-Content -LiteralPath $journal -Value ($journalLines -join "`n") -Encoding utf8NoBOM

    # Usage journal: ONE real cap-death for worker-a in window == a lockout PLUS its
    # matching failover recovery (worker=original_worker). That pair must count as 1,
    # not 2. A third lockout sits outside the window.
    $usageRows = @(
        (@{ ts = '2026-07-10T10:30:00.0000000Z'; event = 'lockout'; worker = 'worker-a'; reason = 'cap' } | ConvertTo-Json -Compress)
        (@{ ts = '2026-07-10T10:45:00.0000000Z'; event = 'failover'; worker = 'worker-a'; original_worker = 'worker-a'; substitute = 'worker-b'; reason = 'cap' } | ConvertTo-Json -Compress)
        (@{ ts = '2026-07-01T01:00:00.0000000Z'; event = 'lockout'; worker = 'worker-a'; reason = 'old' } | ConvertTo-Json -Compress)
    )
    Set-Content -LiteralPath $usagePath -Value ($usageRows -join "`n") -Encoding utf8NoBOM

    # decisions.jsonl with depth_tier high
    $dec = @(
        (@{
            ts = '2026-07-10T10:00:00Z'; task_id = 't1'; chose = 'worker-a'
            stakes = 'high'; stakes_basis = 'operator'; depth_tier = 'high'
            depth_applied = $true; selection_mode = 'champion'; cost_tier = 'paid'
        } | ConvertTo-Json -Compress)
    )
    Set-Content -LiteralPath (Join-Path $runDir 'decisions.jsonl') -Value ($dec -join "`n") -Encoding utf8NoBOM

    # ---- Parse-FleetJournalLine ----
    $line = $journalLines[2]
    $parsed = Parse-FleetJournalLine -Line $line
    Check 'J1 parses provider' ($parsed.provider -eq 'worker-a')
    Check 'J2 parses duration' ($parsed.duration_s -eq 120)
    Check 'J3 parses exit' ($parsed.exit_code -eq 0)
    Check 'J4 parses tokens exact' ($parsed.tokens -eq 439000 -and $parsed.tokens_basis -eq 'exact')
    Check 'J5 parses host' ($parsed.host -eq 'testbox')
    Check 'J6 parses phase' ($parsed.phase -eq 'code.sprint-1')
    Check 'J7 comment lines skipped' ($null -eq (Parse-FleetJournalLine -Line '# Model Routing Log'))
    Check 'J8 non-fleet skipped' ($null -eq (Parse-FleetJournalLine -Line '2026-07-10T10:00:00Z | route | x | y'))

    $rows = @(Read-FleetJournalRows -Path $journal)
    Check 'J9 reads all fleet rows' ($rows.Count -eq 8)

    # ---- stage classification (summary is the real signal; phase = secondary hint) ----
    Check 'S1 build summary/phase -> build' ((Get-ShipReportStage -Row $parsed) -eq 'build')
    $rev = Parse-FleetJournalLine -Line $journalLines[4]
    Check 'S2 review phase -> review' ((Get-ShipReportStage -Row $rev) -eq 'review')
    # Fix + verification have NO phase in the real model — they classify from summary text.
    $fix = Parse-FleetJournalLine -Line $journalLines[6]
    Check 'S3 fix via summary (phase is code.sprint-1) -> fix' ((Get-ShipReportStage -Row $fix) -eq 'fix')
    $ver = Parse-FleetJournalLine -Line $journalLines[7]
    Check 'S4 verification via summary (phase is review) -> verification' ((Get-ShipReportStage -Row $ver) -eq 'verification')
    $kw = [ordered]@{ phase = ''; summary = 'run adversarial review now'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S5 summary keyword -> review' ((Get-ShipReportStage -Row $kw) -eq 'review')
    # Most-specific-first ordering: shared tokens ('findings'/'test') must not misroute.
    $kwFix = [ordered]@{ phase = ''; summary = 'fix pass addressing review findings'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S6 fix-before-review ordering -> fix' ((Get-ShipReportStage -Row $kwFix) -eq 'fix')
    $kwRev = [ordered]@{ phase = ''; summary = 'deep review of diff'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S7 review keyword -> review' ((Get-ShipReportStage -Row $kwRev) -eq 'review')
    $kwVer = [ordered]@{ phase = ''; summary = 'verification gate run'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S8 verification keyword -> verification' ((Get-ShipReportStage -Row $kwVer) -eq 'verification')
    # Secondary phase hint maps to REAL vocabulary when summary is neutral.
    $phaseBuild = [ordered]@{ phase = 'code.sprint-2'; summary = 'did some things'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S9 real phase code.sprint-N hint -> build' ((Get-ShipReportStage -Row $phaseBuild) -eq 'build')
    $phaseRev = [ordered]@{ phase = 'review'; summary = 'general notes'; provider = 'x'; tokens = 0; tokens_basis = 'estimate' }
    Check 'S10 real phase review hint -> review' ((Get-ShipReportStage -Row $phaseRev) -eq 'review')

    # ---- token fold (never silent exact+estimate sum) ----
    $mixed = @(
        [ordered]@{ provider = 'worker-a'; tokens = 100; tokens_basis = 'exact' }
        [ordered]@{ provider = 'worker-a'; tokens = 50; tokens_basis = 'estimate' }
        [ordered]@{ provider = 'worker-b'; tokens = 20; tokens_basis = 'exact' }
    )
    $fold = Fold-ShipReportTokens -Rows $mixed
    Check 'T1 exact total separate' ([long]$fold.exact_total -eq 120)
    Check 'T2 estimate total separate' ([long]$fold.estimate_total -eq 50)
    $fmt = Format-ShipReportTokenFold -Fold $fold
    Check 'T3 render shows exact basis' ($fmt -match 'exact')
    Check 'T4 render shows estimate basis' ($fmt -match 'estimate')
    Check 'T5 render names both providers' (($fmt -match 'worker-a') -and ($fmt -match 'worker-b'))
    # Critical: must not show a single summed number across bases as if they were one
    Check 'T6 does not silently claim 170 total' (-not ($fmt -match '\b170\b'))

    # ---- confirmed-rate zero-denom guards ----
    Check 'R1 zero findings -> n/a' ((Get-ShipReportConfirmedRate -FindingsTotal 0 -FindingsConfirmed 0) -eq 'n/a')
    Check 'R2 null findings -> n/a' ((Get-ShipReportConfirmedRate -FindingsTotal $null -FindingsConfirmed 3) -eq 'n/a')
    Check 'R3 null confirmed -> n/a' ((Get-ShipReportConfirmedRate -FindingsTotal 8 -FindingsConfirmed $null) -eq 'n/a')
    Check 'R4 8/8 -> 1' ((Get-ShipReportConfirmedRate -FindingsTotal 8 -FindingsConfirmed 8) -eq 1)
    Check 'R5 3/11 -> ~0.2727' (
        [math]::Abs([double](Get-ShipReportConfirmedRate -FindingsTotal 11 -FindingsConfirmed 3) - 0.2727) -lt 0.001
    )

    # ---- review record parse (absent = n/a, never guess) ----
    $rr = Parse-ReviewRecordText -Text @"
VERDICT: SHIP-WITH-TWEAKS
some findings text
FINDINGS-COUNT: 8
CONFIRMED-COUNT: 8
"@
    Check 'V1 verdict parsed' ($rr.verdict -eq 'SHIP-WITH-TWEAKS')
    Check 'V2 findings parsed' ($rr.findings_count -eq 8)
    Check 'V3 confirmed parsed' ($rr.confirmed_count -eq 8)
    $rrMissing = Parse-ReviewRecordText -Text 'just a freeform comment with no markers'
    Check 'V4 missing verdict is null' ($null -eq $rrMissing.verdict)
    Check 'V5 missing findings is null' ($null -eq $rrMissing.findings_count)
    Check 'V6 missing confirmed is null' ($null -eq $rrMissing.confirmed_count)
    $merged = Merge-ReviewRecords -Records @($rr, $rrMissing)
    Check 'V7 merge keeps findings' ($merged.findings_count -eq 8)
    Check 'V8 merge rate 1.0' ($merged.confirmed_rate -eq 1)
    $onlyFindings = Parse-ReviewRecordText -Text "FINDINGS-COUNT: 5`n"
    $merged2 = Merge-ReviewRecords -Records @($onlyFindings)
    Check 'V9 findings without confirmed -> rate n/a' ($merged2.confirmed_rate -eq 'n/a')

    # ---- window filter ----
    $from = ConvertTo-ShipReportDateTime -Ts '2026-07-10T00:00:00Z'
    $to = ConvertTo-ShipReportDateTime -Ts '2026-07-11T00:00:00Z'
    $windowed = Select-FleetRowsInWindow -Rows $rows -From $from -To $to
    Check 'W1 window drops old row' (@($windowed | Where-Object { $_.provider -eq 'worker-old' }).Count -eq 0)
    Check 'W2 window keeps in-range rows' ($windowed.Count -eq 7)

    # ---- cap-death fold ----
    $usage = @(Read-UsageJournalRows -Path $usagePath)
    $cap = Get-ShipReportCapDeaths -UsageRows $usage -FleetRows $windowed -From $from -To $to
    # One lockout + its recovery failover = ONE cap-death, not two.
    Check 'C1 lockout+its failover recovery -> 1 cap-death' ($cap.count -eq 1)
    # Out-of-window lockout (2026-07-01) is filtered: widening the window to include it
    # yields 2 lockouts, proving the window bound is actually applied (not vacuous).
    $capWide = Get-ShipReportCapDeaths -UsageRows $usage -FleetRows $windowed `
        -From (ConvertTo-ShipReportDateTime -Ts '2026-06-01T00:00:00Z') -To $to
    Check 'C2 widened window includes the 2026-07-01 lockout -> 2' ($capWide.count -eq 2)
    # Two INDEPENDENT lockouts (different workers) -> 2; the failover is not double-counted.
    $twoLockRows = @(
        [pscustomobject]@{ ts = '2026-07-10T10:30:00Z'; event = 'lockout'; worker = 'worker-a'; reason = 'cap' }
        [pscustomobject]@{ ts = '2026-07-10T13:30:00Z'; event = 'lockout'; worker = 'worker-b'; reason = 'cap' }
        [pscustomobject]@{ ts = '2026-07-10T10:45:00Z'; event = 'failover'; worker = 'worker-a'; original_worker = 'worker-a'; substitute = 'worker-b' }
    )
    $capTwo = Get-ShipReportCapDeaths -UsageRows $twoLockRows -FleetRows $windowed -From $from -To $to
    Check 'C3 two independent lockouts -> 2 (failover not counted)' ($capTwo.count -eq 2)

    # ---- duration / token format helpers ----
    $t0 = ConvertTo-ShipReportDateTime -Ts '2026-07-10T10:00:00Z'
    $t1 = $t0.AddHours(2.5)
    Check 'D1 wall-clock ~2.5h' ((Format-ShipReportDuration -From $t0 -To $t1) -eq '~2.5h')
    Check 'D2 missing bound -> n/a' ((Format-ShipReportDuration -From $null -To $t1) -eq 'n/a')
    Check 'D3 token compact 439k' ((Format-ShipReportTokenCount -Tokens 439000) -eq '439k')
    Check 'D4 token small stays raw' ((Format-ShipReportTokenCount -Tokens 42) -eq '42')

    # ---- card assembly with stubs ----
    $script:ShipReportGhInvoker = {
        param($ghArgs)
        # Return a canned PR view JSON when asked
        $joined = $ghArgs -join ' '
        if ($joined -match 'pr view') {
            $body = @{
                number = 94
                title = 'fixture PR'
                state = 'MERGED'
                headRefName = 'feature/fixture-ship'
                baseRefName = 'master'
                mergedAt = '2026-07-10T16:00:00Z'
                mergeCommit = @{ oid = 'fcfc1df0123456789abcdef' }
                url = 'https://example.invalid/pr/94'
                closingIssuesReferences = @(@{ number = 90 })
                commits = @(
                    @{ oid = 'aaa'; committedDate = '2026-07-10T10:00:00Z'; messageHeadline = 'feat: start' }
                    @{ oid = 'bbb'; committedDate = '2026-07-10T13:10:00Z'; messageHeadline = 'fix: polish findings' }
                    @{ oid = 'ccc'; committedDate = '2026-07-10T14:00:00Z'; messageHeadline = 'test: gates' }
                    @{ oid = 'ddd'; committedDate = '2026-07-10T15:00:00Z'; messageHeadline = 'docs: note' }
                    @{ oid = 'eee'; committedDate = '2026-07-10T15:30:00Z'; messageHeadline = 'chore: tidy' }
                    @{ oid = 'fff'; committedDate = '2026-07-10T15:40:00Z'; messageHeadline = 'refactor: x' }
                    @{ oid = 'ggg'; committedDate = '2026-07-10T15:50:00Z'; messageHeadline = 'feat: more' }
                    @{ oid = 'hhh'; committedDate = '2026-07-10T15:55:00Z'; messageHeadline = 'feat: done' }
                )
                comments = @(
                    @{ body = "VERDICT: SHIP-WITH-TWEAKS`nFINDINGS-COUNT: 8`nCONFIRMED-COUNT: 8`n" }
                    @{ body = "lens output`nFINDINGS-COUNT: 11`nCONFIRMED-COUNT: 3`n" }
                )
                body = 'Closes #90'
            }
            return ,@(($body | ConvertTo-Json -Depth 8 -Compress))
        }
        if ($joined -match 'pr comment') { return ,@('commented') }
        return ,@('{}')
    }
    $script:ShipReportGitInvoker = {
        param($repoRoot, $gitArgs)
        $joined = $gitArgs -join ' '
        if ($joined -match '^log ') {
            return @(
                "aaa`t2026-07-10T10:00:00Z`tfeat: start"
                "bbb`t2026-07-10T13:10:00Z`tfix: polish findings"
                "ccc`t2026-07-10T14:00:00Z`ttest: gates"
                "ddd`t2026-07-10T15:00:00Z`tdocs: note"
                "eee`t2026-07-10T15:30:00Z`tchore: tidy"
                "fff`t2026-07-10T15:40:00Z`trefactor: x"
                "ggg`t2026-07-10T15:50:00Z`tfeat: more"
                "hhh`t2026-07-10T15:55:00Z`tfeat: done"
            )
        }
        return @()
    }

    $prMeta = Get-ShipReportPrMeta -PrNumber 94
    Check 'P1 PR number' ($prMeta.pr_number -eq 94)
    Check 'P2 branch' ($prMeta.branch -eq 'feature/fixture-ship')
    Check 'P3 merge sha' ($prMeta.merge_sha -eq 'fcfc1df0123456789abcdef')
    Check 'P4 linked issue' ($prMeta.linked_issue -eq 90)
    Check 'P5 commit count from gh' ($prMeta.commit_count -eq 8)
    Check 'P6 two review comments' ($prMeta.comment_bodies.Count -eq 2)

    $gitStats = Get-ShipReportGitBranchStats -RepoRoot $tmp -Branch 'feature/fixture-ship' -Base 'master'
    Check 'G1 git commit count 8' ($gitStats.commit_count -eq 8)

    $decisions = @(Read-RunDecisions -RunDir $runDir)
    Check 'N1 decisions loaded' ($decisions.Count -eq 1 -and $decisions[0].depth_tier -eq 'high')

    $card = Build-ShipReportCard `
        -FleetRows $rows `
        -UsageRows $usage `
        -Decisions $decisions `
        -PrMeta $prMeta `
        -GitStats $gitStats `
        -RunId 'go-fixture-1'

    Check 'A1 card has PR' ($card.pr_number -eq 94)
    Check 'A2 build mentions worker-a' ($card.dimensions.build -match 'worker-a')
    Check 'A3 build surfaces exact basis' ($card.dimensions.build -match 'exact')
    # Build stage estimate = worker-a 1000 (row[3]) + 500 (numeric-offset row) = 1500,
    # kept separate from the 439000 exact; the dimension surfaces the estimate basis.
    Check 'A4 build estimate total is exactly 1500, shown separately' (
        ([long]$card.tokens.by_stage.build.estimate_total -eq 1500) -and ($card.dimensions.build -match 'estimate')
    )
    Check 'A5 build includes cap-death' ($card.dimensions.build -match 'cap-death')
    Check 'A6 build includes commits' ($card.dimensions.build -match '8 commit')
    Check 'A7 review has findings' ($card.dimensions.review -match 'findings')
    Check 'A8 review depth deep' ($card.dimensions.review -match 'deep')
    Check 'A9 fix mentions worker-b' ($card.dimensions.fix -match 'worker-b')
    # Exactly one verification dispatch (worker-local, 0 tokens estimate).
    Check 'A10 verification renders dispatch + zero-token fold' (
        $card.dimensions.verification -eq '1 verification dispatch, worker-local 0 tok'
    )
    Check 'A11 wall-clock present' ($card.dimensions.wall_clock -match '~')
    Check 'A12 conductor not tracked' ($card.dimensions.conductor_overhead -eq 'not tracked')
    Check 'A13 outcome merged sha short' ($card.dimensions.outcome -match 'merged `fcfc1df`')
    Check 'A14 defects placeholder' ($card.dimensions.outcome -match 'post-merge defects')
    Check 'A15 confirmed rate is number' ($card.review.confirmed_rate -is [double] -or $card.review.confirmed_rate -eq 1)
    # 8+11 findings, 8+3 confirmed
    Check 'A16 findings total 19' ($card.review.findings_count -eq 19)
    Check 'A17 confirmed total 11' ($card.review.confirmed_count -eq 11)
    Check 'A18 exact/estimate totals not combined field' (
        ($null -ne $card.tokens.exact_total) -and ($null -ne $card.tokens.estimate_total)
    )

    $md = Format-ShipReportCard -Card $card
    Check 'M1 markdown has table header' ($md -match '\| Dimension \| Value \|')
    Check 'M2 markdown Build row' ($md -match '\| Build \|')
    Check 'M3 markdown Conductor overhead' ($md -match 'Conductor overhead')
    Check 'M4 markdown honest mixed-basis note when both present' (
        ([long]$card.tokens.exact_total -eq 0) -or ([long]$card.tokens.estimate_total -eq 0) -or ($md -match 'Token bases not combined')
    )

    # ---- pipe in verdict must not break the card's markdown table (cell escaping) ----
    $pipeMeta = [ordered]@{
        pr_number = 7; title = 'pipe'; state = 'MERGED'; branch = 'feature/pipe'
        base_branch = 'master'; merged_at = $null; merge_sha = 'deadbeef'
        url = ''; linked_issue = $null; commit_count = 1; first_commit_at = $null
        comment_bodies = @('VERDICT: needs work | also see notes'); body = ''
    }
    $pipeCard = Build-ShipReportCard -FleetRows @() -UsageRows @() -Decisions @() -PrMeta $pipeMeta
    Check 'M5 review dim carries raw verdict pipe pre-render' ($pipeCard.dimensions.review -match '\|')
    $pipeMd = Format-ShipReportCard -Card $pipeCard
    Check 'M6 rendered card escapes verdict pipe to slash' ($pipeMd -match 'needs work / also see notes')
    Check 'M7 rendered card has no raw pipe inside the verdict cell' (-not ($pipeMd -match 'needs work \| also'))

    # ---- missing-data honesty ----
    $emptyCard = Build-ShipReportCard -FleetRows @() -UsageRows @() -Decisions @() -PrMeta $null -GitStats $null
    Check 'H1 empty build is n/a' ($emptyCard.dimensions.build -eq 'n/a')
    Check 'H2 empty review is n/a' ($emptyCard.dimensions.review -eq 'n/a')
    Check 'H3 empty wall-clock is n/a' ($emptyCard.dimensions.wall_clock -eq 'n/a')
    Check 'H4 conductor always not tracked' ($emptyCard.dimensions.conductor_overhead -eq 'not tracked')
    Check 'H5 empty findings rate n/a' ($emptyCard.review.confirmed_rate -eq 'n/a')

    # ---- write + --all trend ----
    $written = Write-ShipReportToRunDir -RunDir $runDir -Card $card -Markdown $md
    Check 'F1 wrote md' (Test-Path -LiteralPath $written.md)
    Check 'F2 wrote json' (Test-Path -LiteralPath $written.json)

    # Second card for trend
    $card2 = Build-ShipReportCard -FleetRows @() -UsageRows @() -PrMeta ([ordered]@{
        pr_number = 50; title = 'older'; state = 'MERGED'; branch = 'feature/old'
        base_branch = 'master'; merged_at = $null; merge_sha = 'abcd1234'
        url = ''; linked_issue = $null; commit_count = 1
        first_commit_at = $null; comment_bodies = @(); body = ''
    })
    $run2 = Join-Path $runsRoot 'go-fixture-2'
    $null = Write-ShipReportToRunDir -RunDir $run2 -Card $card2

    $trendCards = @(Read-ShipReportCardsFromRuns -RunsRoot $runsRoot)
    Check 'F3 reads 2 cards' ($trendCards.Count -eq 2)
    $trendMd = Format-ShipReportTrendTable -Cards $trendCards
    Check 'F4 trend table header' ($trendMd -match 'Confirmed rate')
    Check 'F5 trend includes both PRs' (($trendMd -match '#94') -and ($trendMd -match '#50'))
    $emptyTrend = Format-ShipReportTrendTable -Cards @()
    Check 'F6 empty trend still table' ($emptyTrend -match 'none' -and $emptyTrend -match 'Ship-report trend')

    # ---- CLI via child process (hermetic BATON_HOME + stubs are in-process only;
    #      exercise exit codes and --all/--json against written fixtures) ----
    $cli = Join-Path $PSScriptRoot 'fleet-ship-report.ps1'

    # --all against fixture BATON_HOME
    $allOut = & pwsh -NoProfile -File $cli -All -BatonHome $tmp 2>$null | Out-String
    Check 'CLI1 --all exit 0' ($LASTEXITCODE -eq 0)
    Check 'CLI2 --all shows trend' ($allOut -match 'Ship-report trend')
    Check 'CLI3 --all lists PR 94' ($allOut -match '#94')

    $allJson = & pwsh -NoProfile -File $cli -All -Json -BatonHome $tmp 2>$null | Out-String
    Check 'CLI4 --all --json exit 0' ($LASTEXITCODE -eq 0)
    $allParsed = $allJson | ConvertFrom-Json
    Check 'CLI5 --all --json is array' (@($allParsed).Count -ge 2)

    # missing args -> exit 2
    $errOut = & pwsh -NoProfile -File $cli -BatonHome $tmp 2>&1 | Out-String
    Check 'CLI6 no-args exit 2' ($LASTEXITCODE -eq 2)
    Check 'CLI7 no-args error mentions usage' ($errOut -match 'pr-number|--all|-Branch')

    # invalid PR
    & pwsh -NoProfile -File $cli 'not-a-number' -BatonHome $tmp 2>$null | Out-Null
    Check 'CLI8 bad PR exit 2' ($LASTEXITCODE -eq 2)

    # -RunDir only (no gh): should still render and write
    $runOnly = Join-Path $runsRoot 'go-wip'
    New-Item -ItemType Directory -Force -Path $runOnly | Out-Null
    # Seed a tiny journal already in BATON_HOME
    $wipOut = & pwsh -NoProfile -File $cli -RunDir $runOnly -BatonHome $tmp 2>$null | Out-String
    Check 'CLI9 -RunDir exit 0' ($LASTEXITCODE -eq 0)
    Check 'CLI10 -RunDir writes ship-report.md' (Test-Path (Join-Path $runOnly 'ship-report.md'))
    Check 'CLI11 -RunDir card has conductor gap' ($wipOut -match 'not tracked')

    # -Branch only with stubbed env: no real git needed if repo empty — still exit 0/2 ok
    # Without gh and with branch, git may fail soft; runner catches and continues.
    $branchOut = & pwsh -NoProfile -File $cli -Branch 'feature/does-not-exist-xyz' -BatonHome $tmp -RepoRoot $tmp 2>$null | Out-String
    Check 'CLI12 -Branch exit 0 (soft git miss)' ($LASTEXITCODE -eq 0)
    Check 'CLI13 -Branch renders card' ($branchOut -match 'Ship report|Dimension')

    # --post without PR number should fail when only branch... already covered.
    # Post with PR will call real gh unless we only test the guard:
    & pwsh -NoProfile -File $cli -Branch 'x' -Post -BatonHome $tmp 2>$null | Out-Null
    Check 'CLI14 --post without PR exits 2' ($LASTEXITCODE -eq 2)

    # In-process post with stub
    $posted = $false
    $script:ShipReportGhInvoker = {
        param($ghArgs)
        $script:lastGh = $ghArgs -join ' '
        if (($ghArgs -join ' ') -match 'pr comment') { $script:postedFlag = $true; return ,@('ok') }
        return ,@('{}')
    }
    $script:postedFlag = $false
    $null = Post-ShipReportPrComment -PrNumber 94 -Body "# hi`n"
    Check 'CLI15 post uses gh pr comment' ($script:postedFlag -eq $true)

    # defaults honor BATON_HOME
    $defs = Get-ShipReportDefaults -BatonHome $tmp
    Check 'ENV1 fleet journal under BATON_HOME' ($defs.fleet_journal -eq $journal)
    Check 'ENV2 usage journal under BATON_HOME' ($defs.usage_journal -eq $usagePath)

    # findings bit formatting
    Check 'FMT1 findings with confirmed' ((Format-ShipReportFindingsBit -FindingsCount 8 -ConfirmedCount 8) -eq '8 findings / 8 confirmed')
    Check 'FMT2 findings without confirmed' ((Format-ShipReportFindingsBit -FindingsCount 8 -ConfirmedCount $null) -eq '8 findings / n/a confirmed')
    Check 'FMT3 no findings' ((Format-ShipReportFindingsBit -FindingsCount $null -ConfirmedCount $null) -eq 'n/a')
}
catch {
    $script:threw = $true
    Write-Host ("FAIL: uncaught exception: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    $script:fail++
}
finally {
    $script:ShipReportGitInvoker = $null
    $script:ShipReportGhInvoker = $null
    if ($null -eq $prevBatonHome) { Remove-Item Env:BATON_HOME -ErrorAction SilentlyContinue }
    else { $env:BATON_HOME = $prevBatonHome }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    if ($script:fail -gt 0 -or $script:threw) {
        Write-Host "`n$($script:fail) CHECK(S) FAILED" -ForegroundColor Red
        exit 1
    }
    Write-Host "`nALL CHECKS PASS" -ForegroundColor Green
    exit 0
}
