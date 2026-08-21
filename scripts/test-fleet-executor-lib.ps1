#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/fleet-executor-lib.ps1"

$script:fail = 0
function Check($n,$c){ if($c){Write-Host "PASS: $n"} else {Write-Host "FAIL: $n"; $script:fail++} }

function New-TempRepo {
    param([string]$Root)
    $p = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    & git -C $p init -q
    & git -C $p config user.email 'test@test.local'
    & git -C $p config user.name 'baton-test'
    Set-Content -LiteralPath (Join-Path $p 'a.txt') -Value 'hello' -Encoding utf8NoBOM
    & git -C $p add -A 2>$null | Out-Null
    & git -C $p commit -q -m 'init' 2>$null | Out-Null
    return $p
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exec-lib-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$savedObserve = $env:BATON_ROUTING_OBSERVE
try {
    # #159: isolating — never write outcome ratings into the real knowledge store.
    $env:BATON_ROUTING_OBSERVE = 'off'
    $repo = New-TempRepo -Root $tmpRoot

    # ---- New-RunWorktree ----
    $wt = New-RunWorktree -RepoPath $repo -RunId 'go-t1'
    Check 'W1 worktree dir exists' (Test-Path $wt.worktree)
    Check 'W2 worktree lives under sibling .baton-worktrees' ($wt.worktree -like (Join-Path $tmpRoot '.baton-worktrees\*'))
    Check 'W3 branch named baton/run-<id>' ($wt.branch -eq 'baton/run-go-t1')
    Check 'W4 base_sha is repo HEAD' ($wt.base_sha -eq ([string](& git -C $repo rev-parse HEAD)).Trim())
    Check 'W5 worktree checked out on the run branch' ((([string](& git -C $wt.worktree branch --show-current)).Trim()) -eq 'baton/run-go-t1')

    $notRepo = Join-Path $tmpRoot 'plain'; New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $threw = $false; try { New-RunWorktree -RepoPath $notRepo -RunId 'x' | Out-Null } catch { $threw = $true }
    Check 'W6 non-repo throws' $threw

    # ---- Get-RunDiff ----
    Check 'D1 fresh worktree diff is empty' ((Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha) -eq '')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'a.txt') -Value 'changed' -Encoding utf8NoBOM
    $d1 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D2 edited file appears in diff' ($d1 -match 'changed')
    Set-Content -LiteralPath (Join-Path $wt.worktree 'brand-new.txt') -Value 'i am new' -Encoding utf8NoBOM
    $d2 = Get-RunDiff -Worktree $wt.worktree -BaseSha $wt.base_sha
    Check 'D3 NEW (untracked) file captured in diff' ($d2 -match 'brand-new\.txt')
    Check 'D4 diff grew with the new file' ($d2.Length -gt $d1.Length)
    Check 'D5 user repo tree untouched by worktree edits' (-not (Test-Path (Join-Path $repo 'brand-new.txt')))

    # ---- Get-WorktreeTreeSha ----
    $t1 = Get-WorktreeTreeSha -Worktree $wt.worktree
    $t2 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S1 stable tree sha when nothing changes' (($null -ne $t1) -and ($t1 -eq $t2))
    Set-Content -LiteralPath (Join-Path $wt.worktree 'another.txt') -Value 'x' -Encoding utf8NoBOM
    $t3 = Get-WorktreeTreeSha -Worktree $wt.worktree
    Check 'S2 tree sha changes when a file lands' ($t3 -ne $t1)
    Check 'S3 non-repo path -> $null' ($null -eq (Get-WorktreeTreeSha -Worktree $notRepo))

    # ---- Test-ProviderAgentic ----
    Check 'A1 agentic:true is authoritative' (Test-ProviderAgentic -Provider @{ agentic = $true; platform = 'local' })
    Check 'A2 agentic:false is authoritative' (-not (Test-ProviderAgentic -Provider @{ agentic = $false; platform = 'codex' }))
    Check 'A3 platform codex inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'codex' })
    Check 'A4 platform claude inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'claude' })
    Check 'A5 platform gemini inferred agentic' (Test-ProviderAgentic -Provider @{ platform = 'gemini' })
    Check 'A6 platform local not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'local' }))
    Check 'A7 platform github not agentic' (-not (Test-ProviderAgentic -Provider @{ platform = 'github' }))
    Check 'A8 no platform, no marker -> not agentic' (-not (Test-ProviderAgentic -Provider @{ name = 'mystery' }))
    Check 'A9 agentic:true cannot grant HTTP edit powers' (-not (Test-ProviderAgentic -Provider @{ kind = 'http'; agentic = $true; platform = 'codex' }))
    Check 'A10 agentic:true cannot grant stdio-json edit powers' (-not (Test-ProviderAgentic -Provider @{ kind = 'stdio-json'; agentic = $true; platform = 'codex' }))

    # ---- Format-ZeroCandidateWhy / Get-CapabilityCostTierFloor (#127) ----
    $zcMsg = Format-ZeroCandidateWhy -Capability 'code-gen' -TierCap 'free' -Stakes 'low' -Floor 'paid'
    Check 'ZC1 message names capability and tier cap' (
        ($zcMsg -match 'capability code-gen:') -and ($zcMsg -match 'tier <=free'))
    Check 'ZC2 message names stakes and floor' (
        ($zcMsg -match 'stakes low caps tier') -and ($zcMsg -match 'cheapest eligible = paid'))
    Check 'ZC3 message lists remedies' (
        ($zcMsg -match 'raise task est_cost_tier') -and ($zcMsg -match '--stakes standard\|high'))
    $zcFloorFleet = Join-Path $tmpRoot 'zc-floor-fleet.yaml'
    Set-Content -LiteralPath $zcFloorFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, summarize]
providers:
  - name: paid-agentic
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: local-nonagentic
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: local-sum
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    capabilities: [summarize]
    command_template: 'echo "{{prompt}}"'
'@
    Check 'ZC4 code-gen floor is paid (non-agentic local ignored)' (
        (Get-CapabilityCostTierFloor -Capability 'code-gen' -FleetPath $zcFloorFleet) -eq 'paid')
    Check 'ZC5 summarize floor is local' (
        (Get-CapabilityCostTierFloor -Capability 'summarize' -FleetPath $zcFloorFleet) -eq 'local')
    Check 'ZC6 unclaimed capability is UNAVAILABLE' (
        (Get-CapabilityCostTierFloor -Capability 'plan-review' -FleetPath $zcFloorFleet) -eq 'UNAVAILABLE')
    Check 'ZC7 missing fleet is UNAVAILABLE fail-soft' (
        (Get-CapabilityCostTierFloor -Capability 'code-gen' -FleetPath (Join-Path $tmpRoot 'no-fleet.yaml')) -eq 'UNAVAILABLE')
    # Context-floor parity with Select-Capability (#127 review): a known-small-context
    # cheap provider must not understate the reported floor.
    $zcCtxFleet = Join-Path $tmpRoot 'zc-ctx-floor-fleet.yaml'
    Set-Content -LiteralPath $zcCtxFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [summarize]
capability_floors:
  summarize: 65536
providers:
  - name: cheap-small
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    capabilities: [summarize]
    context: 8192
    command_template: 'echo "{{prompt}}"'
  - name: mid-eligible
    kind: cli
    enabled: true
    cost_tier: free
    platform: local
    capabilities: [summarize]
    context: 131072
    command_template: 'echo "{{prompt}}"'
'@
    Check 'ZC8 context floor excludes cheap under-context provider' (
        (Get-CapabilityCostTierFloor -Capability 'summarize' -FleetPath $zcCtxFleet) -eq 'free')

    # ---- Get-EditPoolExclusions + cause-aware zero-candidate why (#124) ----
    $epUsage = Join-Path $tmpRoot 'ep-usage.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'lockout'; worker = 'paid-agentic'; reason = 'cap'; reset_at = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $epUsage -Encoding utf8NoBOM
    $excl = @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'paid' -FleetPath $zcFloorFleet -UsagePath $epUsage)
    # reset_at format-agnostic: ConvertFrom-Json materializes the journal's ISO string
    # as [datetime], so Get-WorkerState's [string] cast yields a locale rendering.
    Check 'EP1 locked-out eligible provider -> usage exclusion with reset_at' (
        @($excl | Where-Object { $_.name -eq 'paid-agentic' -and $_.stage -eq 'usage' -and $_.reason -eq 'waiting_for_reset' -and "$($_.reset_at)" -match '2030' }).Count -eq 1)
    Check 'EP2 non-agentic provider -> static not edit-eligible' (
        @($excl | Where-Object { $_.name -eq 'local-nonagentic' -and $_.stage -eq 'static' -and $_.reason -eq 'not edit-eligible' }).Count -eq 1)
    Check 'EP3 non-claiming provider -> static does-not-claim' (
        @($excl | Where-Object { $_.name -eq 'local-sum' -and $_.stage -eq 'static' -and $_.reason -match 'does not claim' }).Count -eq 1)
    $exclFree = @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'free' -FleetPath $zcFloorFleet -UsagePath (Join-Path $tmpRoot 'no-usage.jsonl'))
    Check 'EP4 tier above cap -> static exclusion (no usage journal)' (
        @($exclFree | Where-Object { $_.name -eq 'paid-agentic' -and $_.stage -eq 'static' -and $_.reason -match 'above cap free' }).Count -eq 1)
    Check 'EP5 missing fleet fail-soft empty' (
        @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'paid' -FleetPath (Join-Path $tmpRoot 'no-fleet.yaml') -UsagePath $epUsage).Count -eq 0)
    $zcAvail = Format-ZeroCandidateWhy -Capability 'code-gen' -TierCap 'paid' -Stakes 'standard' -Floor 'paid' -Exclusions $excl
    Check 'ZC9 usage exclusions -> availability-shaped why, no stakes remedy' (
        ($zcAvail -match 'labor unavailable') -and ($zcAvail -match 'paid-agentic') -and ($zcAvail -notmatch 'stakes'))
    $zcStatic = Format-ZeroCandidateWhy -Capability 'code-gen' -TierCap 'free' -Stakes 'low' -Floor 'paid' -Exclusions $exclFree
    Check 'ZC10 static-only exclusions keep the #127 stakes/tier message' (
        ($zcStatic -match 'stakes low caps tier') -and ($zcStatic -notmatch 'labor unavailable'))
    # Mixed pool (Grok review): a usage-out cheap provider AND a tier-capped provider —
    # the availability message must keep the stakes remedy alive, not suppress it.
    $mixedExcl = @(
        [ordered]@{ name = 'cheap-locked'; stage = 'usage'; reason = 'waiting_for_reset'; reset_at = '2030-01-01T00:00:00Z'; eta = $null }
        [ordered]@{ name = 'paid-agentic'; stage = 'static'; reason = 'cost_tier paid above cap free'; reset_at = $null; eta = $null }
    )
    $zcMixed = Format-ZeroCandidateWhy -Capability 'code-gen' -TierCap 'free' -Stakes 'low' -Floor 'paid' -Exclusions $mixedExcl
    Check 'ZC11 mixed pool keeps BOTH remedies: availability + tier note' (
        ($zcMixed -match 'labor unavailable') -and ($zcMixed -match 'paid-agentic sat above the tier cap') -and
        ($zcMixed -match 'est_cost_tier'))
    # Route-around parity (Grok review): cooldown is a hard usage exclusion; 'limited'
    # WITHOUT conserve mode is still a candidate, so the audit must not claim it.
    $epUsage2 = Join-Path $tmpRoot 'ep-usage2.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'cooldown'; worker = 'paid-agentic'; until = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $epUsage2 -Encoding utf8NoBOM
    $exclCd = @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'paid' -FleetPath $zcFloorFleet -UsagePath $epUsage2)
    Check 'EP6 cooldown -> usage exclusion cooling_down' (
        @($exclCd | Where-Object { $_.name -eq 'paid-agentic' -and $_.stage -eq 'usage' -and $_.reason -eq 'cooling_down' }).Count -eq 1)
    $epUsage3 = Join-Path $tmpRoot 'ep-usage3.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'limited'; worker = 'paid-agentic'; reason = 'probe'; reset_at = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $epUsage3 -Encoding utf8NoBOM
    $exclLim = @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'paid' -FleetPath $zcFloorFleet -UsagePath $epUsage3)
    Check 'EP7 limited without conserve -> NOT a usage exclusion (still a candidate)' (
        @($exclLim | Where-Object { $_.name -eq 'paid-agentic' -and $_.stage -eq 'usage' }).Count -eq 0 -and
        @($exclLim | Where-Object { $_.name -eq 'paid-agentic' -and $_.reason -match 'eligible by this audit' }).Count -eq 1)

    # Spawner zero-candidate seam: an availability-emptied pool sets labor='unavailable'
    # and carries the exclusion audit on the result (#124).
    $luFleet = Join-Path $tmpRoot 'lu-fleet.yaml'
    Set-Content -LiteralPath $luFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: locked-agentic
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
    $luUsage = Join-Path $tmpRoot 'lu-usage.jsonl'
    (@{ ts = '2026-01-01T00:00:00Z'; event = 'lockout'; worker = 'locked-agentic'; reason = 'cap'; reset_at = '2030-01-01T00:00:00Z' } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $luUsage -Encoding utf8NoBOM
    $luRun = Join-Path $tmpRoot 'lu-run'
    New-Item -ItemType Directory -Force -Path $luRun | Out-Null
    $luSp = New-AgenticSpawner -Worktree (Join-Path $tmpRoot 'lu-wt-absent') -FleetPath $luFleet `
        -ToolsPath (Join-Path $tmpRoot 'lu-tools-absent.yaml') -MaxCostTier 'paid' -RunDir $luRun `
        -UsagePath $luUsage -RatingsPath (Join-Path $tmpRoot 'lu-ratings.jsonl') `
        -JournalPath (Join-Path $tmpRoot 'lu-journal.jsonl') `
        -ProbeCachePath (Join-Path $tmpRoot 'lu-probe.jsonl') -FleetJournalPath (Join-Path $tmpRoot 'lu-fj.md')
    $luR = & $luSp @{ id = 't1'; desc = 'edit thing'; command = 'edit'; capability = 'code-gen' }
    Check 'LU1 spawner flags labor unavailable' ($luR.ok -eq $false -and [string]$luR.labor -eq 'unavailable')
    Check 'LU2 why is availability-shaped and names the provider' (
        ($luR.why -match 'labor unavailable') -and ($luR.why -match 'locked-agentic'))
    Check 'LU3 exclusion audit rides the result' (
        @($luR.exclusions | Where-Object { $_.stage -eq 'usage' -and $_.name -eq 'locked-agentic' }).Count -eq 1)
    # Config-shaped empty pool (tier cap, nobody usage-blocked) must NOT claim labor
    # unavailability — the #127 stakes remedy stands.
    $luSp2 = New-AgenticSpawner -Worktree (Join-Path $tmpRoot 'lu-wt-absent') -FleetPath $luFleet `
        -ToolsPath (Join-Path $tmpRoot 'lu-tools-absent.yaml') -MaxCostTier 'free' -RunDir $luRun `
        -UsagePath (Join-Path $tmpRoot 'no-usage.jsonl') -RatingsPath (Join-Path $tmpRoot 'lu-ratings.jsonl') `
        -JournalPath (Join-Path $tmpRoot 'lu-journal.jsonl') `
        -ProbeCachePath (Join-Path $tmpRoot 'lu-probe.jsonl') -FleetJournalPath (Join-Path $tmpRoot 'lu-fj.md')
    $luR2 = & $luSp2 @{ id = 't1'; desc = 'edit thing'; command = 'edit'; capability = 'code-gen' }
    Check 'LU4 tier-capped empty pool keeps labor flag empty + stakes message' (
        $luR2.ok -eq $false -and [string]$luR2.labor -eq '' -and ($luR2.why -match 'stakes'))

    # ---- Eligibility agreement: Test-ProviderEditCapable vs Test-PlannerProviderEditEligible ----
    # Drift guard for the intentional mirror pair (d078/d091/d103 / #127 review). The
    # executor side is the COMBINED predicate (agentic harness OR diff-apply opt-in),
    # which is exactly what the planner mirror models.
    # Same case table intent as conductor suite if ever split; load planner mirror here.
    if (-not (Get-Command Test-PlannerProviderEditEligible -ErrorAction SilentlyContinue)) {
        . "$PSScriptRoot/conductor-lib.ps1"
    }
    $eligCases = @(
        @{ name='http agentic true';          kind='http';       agentic=$true;  platform='codex';   expect=$false }
        @{ name='stdio-json agentic true';    kind='stdio-json'; agentic=$true;  platform='claude';  expect=$false }
        @{ name='cli agentic true';           kind='cli';        agentic=$true;  platform='local';   expect=$true }
        @{ name='cli agentic false';          kind='cli';        agentic=$false; platform='codex';   expect=$false }
        @{ name='cli agentic absent codex';   kind='cli';        agentic=$null;  platform='codex';   expect=$true }
        @{ name='cli agentic absent claude';  kind='cli';        agentic=$null;  platform='claude';  expect=$true }
        @{ name='cli agentic absent gemini';  kind='cli';        agentic=$null;  platform='gemini';  expect=$true }
        @{ name='cli agentic absent other';   kind='cli';        agentic=$null;  platform='local';   expect=$false }
        @{ name='cli agentic absent noplat';  kind='cli';        agentic=$null;  platform=$null;     expect=$false }
        @{ name='http agentic false';         kind='http';       agentic=$false; platform='codex';   expect=$false }
        @{ name='cli agentic true noplat';    kind='cli';        agentic=$true;  platform=$null;     expect=$true }
        # DA12 (d103): diff-apply rows must agree too — the mirror has to know the new
        # opt-in, not just the d091 transport veto.
        @{ name='DA12 http diff_apply true';        kind='http';       agentic=$null;  platform='local'; diff_apply=$true;  expect=$true }
        @{ name='DA12 stdio-json diff_apply true';  kind='stdio-json'; agentic=$null;  platform='local'; diff_apply=$true;  expect=$true }
        @{ name='DA12 http diff_apply over agentic false'; kind='http'; agentic=$false; platform='codex'; diff_apply=$true; expect=$true }
        @{ name='DA12 http diff_apply false';       kind='http';       agentic=$true;  platform='codex'; diff_apply=$false; expect=$false }
        @{ name='DA12 http diff_apply absent';      kind='http';       agentic=$null;  platform='local'; expect=$false }
        @{ name='DA12 cli diff_apply true local';   kind='cli';        agentic=$null;  platform='local'; diff_apply=$true;  expect=$false }
    )
    foreach ($ec in $eligCases) {
        $prov = @{ kind = $ec.kind }
        if ($null -ne $ec.agentic) { $prov['agentic'] = $ec.agentic }
        if ($null -ne $ec.platform) { $prov['platform'] = $ec.platform }
        if ($null -ne $ec.diff_apply) { $prov['diff_apply'] = $ec.diff_apply }
        $a = [bool](Test-ProviderEditCapable -Provider $prov)
        $b = [bool](Test-PlannerProviderEditEligible -Provider $prov)
        Check "EA $($ec.name) agreement" (($a -eq $b) -and ($a -eq $ec.expect))
    }

    if (Get-Command Test-ProviderDepthTier -ErrorAction SilentlyContinue) {
        $tierProvider = @{ kind='cli'; command_template='tool {{tier_args}} "{{prompt}}"'; tier_med='--effort medium' }
        Check 'DT1 valid CLI named tier with consuming template is applied' (Test-ProviderDepthTier -Provider $tierProvider -DepthTier med)
        Check 'DT2 template that drops tier args is not applied' (-not (Test-ProviderDepthTier -Provider @{ kind='cli'; command_template='tool "{{prompt}}"'; tier_med='--effort medium' } -DepthTier med))
        Check 'DT3 HTTP provider cannot apply CLI named tier' (-not (Test-ProviderDepthTier -Provider @{ kind='http'; command_template='tool {{tier_args}}'; tier_med='--effort medium' } -DepthTier med))
        Check 'DT4 unsafe tier fragment is not applied' (-not (Test-ProviderDepthTier -Provider @{ kind='cli'; command_template='tool {{tier_args}}'; tier_med='$(unsafe)' } -DepthTier med))
        Check 'DT5 command resolution consumes the named tier fragment' ((Resolve-FleetCommand -Provider $tierProvider -Prompt 'p' -Tier med) -match '--effort medium')
    } else {
        Check 'DT1 Test-ProviderDepthTier exists' $false
    }

    # ---- Resolve-TaskDepthPolicy (d086 PR-B, pure table) ----
    if (Get-Command Resolve-TaskDepthPolicy -ErrorAction SilentlyContinue) {
        $depthCases = @(
            @{ name='low caps paid estimate at free'; stakes='low'; estimate='paid'; run='paid'; depth='low'; mode='economy'; cap='free' },
            @{ name='low honors local task estimate'; stakes='low'; estimate='local'; run='paid'; depth='low'; mode='economy'; cap='local' },
            @{ name='low honors local run ceiling'; stakes='low'; estimate='paid'; run='local'; depth='low'; mode='economy'; cap='local' },
            @{ name='standard honors free run ceiling'; stakes='standard'; estimate='paid'; run='free'; depth='med'; mode='economy'; cap='free' },
            @{ name='standard honors local estimate'; stakes='standard'; estimate='local'; run='paid'; depth='med'; mode='economy'; cap='local' },
            @{ name='high uses champion under run ceiling'; stakes='high'; estimate='local'; run='free'; depth='high'; mode='champion'; cap='free' },
            @{ name='high can use paid run ceiling'; stakes='high'; estimate='local'; run='paid'; depth='high'; mode='champion'; cap='paid' }
        )
        foreach ($depthCase in $depthCases) {
            $depthTask = [pscustomobject]@{ stakes=$depthCase.stakes; stakes_basis="basis $($depthCase.name)"; est_cost_tier=$depthCase.estimate }
            $depthPolicy = Resolve-TaskDepthPolicy -Task $depthTask -RunMaxCostTier $depthCase.run
            Check "DPOL $($depthCase.name)" (
                $depthPolicy.stakes -eq $depthCase.stakes -and $depthPolicy.depth_tier -eq $depthCase.depth -and
                $depthPolicy.selection_mode -eq $depthCase.mode -and $depthPolicy.max_cost_tier -eq $depthCase.cap)
        }
        $legacyPolicy = Resolve-TaskDepthPolicy -Task ([pscustomobject]@{ est_cost_tier='paid' }) -RunMaxCostTier paid
        Check 'DPOL missing stakes defaults to documented standard policy' (
            $legacyPolicy.stakes -eq 'standard' -and $legacyPolicy.stakes_basis -eq 'legacy plan omitted stakes' -and
            $legacyPolicy.depth_tier -eq 'med' -and $legacyPolicy.max_cost_tier -eq 'paid')
        $overridePolicy = Resolve-TaskDepthPolicy -Task ([pscustomobject]@{ stakes='low'; stakes_basis='planner'; est_cost_tier='local' }) -RunMaxCostTier paid -StakesOverride high
        Check 'DPOL operator override wins and records its basis' (
            $overridePolicy.stakes -eq 'high' -and $overridePolicy.stakes_basis -eq 'operator override: --stakes high' -and
            $overridePolicy.selection_mode -eq 'champion' -and $overridePolicy.max_cost_tier -eq 'paid')
    } else {
        Check 'DPOL Resolve-TaskDepthPolicy exists' $false
    }

    # ---- Remove-RunWorktree ----
    Remove-RunWorktree -Worktree $wt.worktree -RepoPath $repo -Force
    Check 'R1 worktree dir removed' (-not (Test-Path $wt.worktree))
    $branches = [string](& git -C $repo branch --list 'baton/run-go-t1')
    Check 'R2 run branch KEPT after removal' ($branches -match 'baton/run-go-t1')

    # ---- Publish-RunBranch ----
    # Break caught: a retained changed branch stays zero commits ahead or absent
    # from the remote, so the supposedly-retained work is local-disk-only (#157).
    $archiveRoot = Join-Path $tmpRoot 'archive-success-case'
    $archiveRepo = New-TempRepo -Root $archiveRoot
    $archiveRemote = Join-Path $archiveRoot 'origin.git'
    $archiveRunDir = Join-Path $archiveRoot 'run'
    New-Item -ItemType Directory -Force -Path $archiveRunDir | Out-Null
    & git init --bare -q $archiveRemote
    & git -C $archiveRepo remote add origin $archiveRemote
    $archiveBase = ([string](& git -C $archiveRepo rev-parse HEAD)).Trim()
    $archiveWt = New-RunWorktree -RepoPath $archiveRepo -RunId 'archive-success'
    Set-Content -LiteralPath (Join-Path $archiveWt.worktree 'new.txt') -Value 'retained' -Encoding utf8NoBOM

    $archive = $null
    $archiveError = ''
    try {
        $archive = Publish-RunBranch -Worktree $archiveWt.worktree -RepoPath $archiveRepo `
            -Branch $archiveWt.branch -BaseSha $archiveBase -RunDir $archiveRunDir
    } catch {
        $archiveError = $_.Exception.Message
    }
    if (-not [string]::IsNullOrWhiteSpace($archiveError)) {
        Write-Host "INFO: AR1 archive error: $archiveError"
    }
    $localTip = ([string](& git -C $archiveWt.worktree rev-parse HEAD)).Trim()
    $remoteTip = [string](& git --git-dir $archiveRemote rev-parse "refs/heads/$($archiveWt.branch)" 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($archiveError)) {
        Write-Host "INFO: AR1 local tip=$localTip remote tip=$($remoteTip.Trim())"
    }
    Check 'AR1 changed retained branch is committed and pushed' (
        [string]::IsNullOrWhiteSpace($archiveError) -and
        $null -ne $archive -and $archive.status -eq 'pushed' -and
        $archive.committed -eq $true -and $archive.pushed -eq $true -and
        $localTip -ne $archiveBase -and $remoteTip.Trim() -eq $localTip)

    $existingRoot = Join-Path $tmpRoot 'archive-existing-commit'
    $existingRepo = New-TempRepo -Root $existingRoot
    $existingRemote = Join-Path $existingRoot 'origin.git'
    $existingRunDir = Join-Path $existingRoot 'run'
    & git init --bare -q $existingRemote
    & git -C $existingRepo remote add origin $existingRemote
    $existingBase = ([string](& git -C $existingRepo rev-parse HEAD)).Trim()
    $existingWt = New-RunWorktree -RepoPath $existingRepo -RunId 'existing-commit'
    Set-Content -LiteralPath (Join-Path $existingWt.worktree 'worker.txt') -Value 'worker commit' -Encoding utf8NoBOM
    & git -C $existingWt.worktree add -A
    & git -C $existingWt.worktree commit -q -m 'worker commit'
    $beforeCount = [int](& git -C $existingWt.worktree rev-list --count HEAD)
    $archiveExisting = Publish-RunBranch -Worktree $existingWt.worktree -RepoPath $existingRepo `
        -Branch $existingWt.branch -BaseSha $existingBase -RunDir $existingRunDir
    $afterCount = [int](& git -C $existingWt.worktree rev-list --count HEAD)
    Check 'AR4 existing worker commit is pushed without archive commit' (
        $archiveExisting.status -eq 'pushed' -and
        $archiveExisting.committed -eq $false -and
        $afterCount -eq $beforeCount)

    $emptyRoot = Join-Path $tmpRoot 'archive-empty'
    $emptyRepo = New-TempRepo -Root $emptyRoot
    $emptyRemote = Join-Path $emptyRoot 'origin.git'
    $emptyRunDir = Join-Path $emptyRoot 'run'
    & git init --bare -q $emptyRemote
    & git -C $emptyRepo remote add origin $emptyRemote
    $emptyBase = ([string](& git -C $emptyRepo rev-parse HEAD)).Trim()
    $emptyWt = New-RunWorktree -RepoPath $emptyRepo -RunId 'empty'
    $emptyBefore = [int](& git -C $emptyWt.worktree rev-list --count HEAD)
    $archiveEmpty = Publish-RunBranch -Worktree $emptyWt.worktree -RepoPath $emptyRepo `
        -Branch $emptyWt.branch -BaseSha $emptyBase -RunDir $emptyRunDir
    $emptyAfter = [int](& git -C $emptyWt.worktree rev-list --count HEAD)
    $emptyRemoteRef = [string](& git --git-dir $emptyRemote branch --list $emptyWt.branch)
    Check 'AR5 unchanged run skips without fake commit or push' (
        $archiveEmpty.status -eq 'skipped-no-changes' -and
        $archiveEmpty.committed -eq $false -and
        $archiveEmpty.pushed -eq $false -and
        $emptyAfter -eq $emptyBefore -and
        [string]::IsNullOrWhiteSpace($emptyRemoteRef))

    $brokenRoot = Join-Path $tmpRoot 'archive-broken-origin'
    $brokenRepo = New-TempRepo -Root $brokenRoot
    $brokenRunDir = Join-Path $brokenRoot 'run'
    & git -C $brokenRepo remote add origin (Join-Path $brokenRoot 'missing-origin.git')
    $brokenBase = ([string](& git -C $brokenRepo rev-parse HEAD)).Trim()
    $brokenWt = New-RunWorktree -RepoPath $brokenRepo -RunId 'broken-origin'
    Set-Content -LiteralPath (Join-Path $brokenWt.worktree 'recover-me.txt') -Value 'recover me' -Encoding utf8NoBOM
    $archiveBroken = Publish-RunBranch -Worktree $brokenWt.worktree -RepoPath $brokenRepo `
        -Branch $brokenWt.branch -BaseSha $brokenBase -RunDir $brokenRunDir
    Check 'AR6 push failure is structured and preserves local recovery state' (
        $archiveBroken.status -eq 'failed' -and
        $archiveBroken.reason -match 'origin|push' -and
        (Test-Path (Join-Path $brokenWt.worktree 'recover-me.txt')))

    $wrongRunDir = Join-Path $brokenRoot 'wrong-run'
    $archiveWrong = Publish-RunBranch -Worktree $brokenWt.worktree -RepoPath $brokenRepo `
        -Branch 'main' -BaseSha $brokenBase -RunDir $wrongRunDir
    Check 'AR7 wrong branch is refused before push' (
        $archiveWrong.status -eq 'failed' -and
        $archiveWrong.reason -match 'expected branch|baton/run-')

    $artifact = Get-Content -Raw (Join-Path $brokenRunDir 'archive.json') | ConvertFrom-Json
    Check 'AR8 archive artifact has stable schema and fields' (
        $artifact.schema -eq 1 -and $artifact.status -eq 'failed' -and
        $null -ne $artifact.committed -and $null -ne $artifact.pushed -and
        $artifact.remote -eq 'origin')
    Check 'AR9 archive report formatter distinguishes success, skip, and failure' (
        (Format-RunArchiveSection -Archive $archive -Worktree $archiveWt.worktree) -match 'Archived unreviewed' -and
        (Format-RunArchiveSection -Archive $archiveEmpty -Worktree $emptyWt.worktree) -match 'no archive commit or push' -and
        (Format-RunArchiveSection -Archive $archiveBroken -Worktree $brokenWt.worktree) -match 'ARCHIVE FAILED')

    # ---- New-AgenticSpawner (hermetic: fake dispatcher, temp fleet.yaml, temp BATON_HOME) ----
    $savedBatonHome = $env:BATON_HOME
    $env:BATON_HOME = Join-Path $tmpRoot 'baton-home'
    New-Item -ItemType Directory -Force -Path $env:BATON_HOME | Out-Null
    # Coordination store for the LOCAL-tier fixtures below. Local dispatch is now gated
    # on a resource claim, and coordination-lib grants nothing without DECLARED host
    # capacity (absent/0 VRAM means "I don't know", which means deny). Placeholder names
    # only — host-a / stack-a / model-large are never a real host, stack, or model.
    # Hermetic: this lives under the temp BATON_HOME, never the operator's ~/.baton.
    New-Item -ItemType Directory -Force -Path (Join-Path $env:BATON_HOME 'coordination') | Out-Null
    Set-Content -LiteralPath (Join-Path $env:BATON_HOME 'coordination/config.json') -Encoding utf8NoBOM -Value @'
{
  "hosts": { "host-a": { "vram_gb": 48 } },
  "profiles": { "model-large": { "vram_gb": 8, "class": "broad" } }
}
'@
    try {
        $fleetPath = Join-Path $env:BATON_HOME 'fleet.yaml'
        Set-Content -LiteralPath $fleetPath -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
  - name: fake-agentic
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.1
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--effort low'
    tier_med: '--effort medium'
    tier_high: '--effort high'
  - name: fake-champion
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 0.9
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_high: '--effort high'
'@
        $toolsPath = Join-Path $env:BATON_HOME 'tools.yaml'   # intentionally absent file
        $repo2 = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'sp')).FullName
        $wt2 = New-RunWorktree -RepoPath $repo2 -RunId 'go-sp1'
        $runDir2 = Join-Path $tmpRoot 'run-sp1'
        New-Item -ItemType Directory -Force -Path $runDir2 | Out-Null
        $task = [pscustomobject]@{ id = 't1'; desc = 'write the feature'; capability = 'code-gen'; est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'ordinary bounded feature' }

        # dispatcher that EDITS (writes into its cwd — must be the worktree)
        $editDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'made-by-instrument.txt') -Value 'work' -Encoding utf8NoBOM
            return @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $cwdBefore = (Get-Location).Path
        $sp = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -MaxCostTier 'paid' -RunDir $runDir2 -Dispatcher $editDisp
        $r = & $sp $task
        Check 'P1 edit task ok' ($r.ok -eq $true)
        Check 'P2 picked the agentic provider (local filtered out)' ($r.chose -eq 'fake-agentic')
        Check 'P3 why records diff grew' ($r.why -match 'diff grew')
        Check 'P4 edit landed IN the worktree' (Test-Path (Join-Path $wt2.worktree 'made-by-instrument.txt'))
        Check 'P5 user repo untouched' (-not (Test-Path (Join-Path $repo2 'made-by-instrument.txt')))
        Check 'P6 caller cwd untouched' ((Get-Location).Path -eq $cwdBefore)
        Check 'P7 per-task diff written' (Test-Path (Join-Path $runDir2 'tasks/t1.diff'))
        Check 'P8 per-task diff names the new file' ((Get-Content -Raw (Join-Path $runDir2 'tasks/t1.diff')) -match 'made-by-instrument\.txt')
        Check 'P8a standard stakes route economy at med depth' (
            $r.stakes -eq 'standard' -and $r.stakes_basis -eq 'ordinary bounded feature' -and
            $r.depth_tier -eq 'med' -and $r.selection_mode -eq 'economy' -and $r.tier_cap -eq 'paid')
        Check 'P8b selected provider actual tier and named depth are recorded' ($r.selected_cost_tier -eq 'free' -and $r.depth_applied -eq $true)

        $legacySpawnerOk = $true
        $legacyR = $null
        try {
            $legacySpawner = New-AgenticSpawner $wt2.worktree $fleetPath $toolsPath paid $runDir2 $editDisp
            $legacyR = & $legacySpawner $task
        } catch { $legacySpawnerOk = $false }
        Check 'P8b1 legacy positional spawner signature remains compatible' (
            $legacySpawnerOk -and $null -ne $legacySpawner -and $null -ne $legacyR -and
            $legacyR.ok -eq $true -and $legacyR.chose -eq $r.chose -and
            $legacyR.stakes -eq $r.stakes -and $legacyR.depth_tier -eq $r.depth_tier -and
            $legacyR.selection_mode -eq $r.selection_mode -and $legacyR.stakes_basis -eq $r.stakes_basis)

        $highSeen = @{ tier = ''; pick = '' }
        $highDisp = { param($pick, $prompt, $depthTier)
            $highSeen.tier = $depthTier; $highSeen.pick = [string]$pick.name
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $highTask = [pscustomobject]@{ id='t-high'; desc='security change'; capability='code-gen'; est_cost_tier='local'; stakes='high'; stakes_basis='authentication boundary' }
        $spHigh = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -MaxCostTier paid -Dispatcher $highDisp
        $rHigh = & $spHigh $highTask
        Check 'P8c high stakes uses champion selection and run cap' (
            $rHigh.chose -eq 'fake-champion' -and $rHigh.selection_mode -eq 'champion' -and
            $rHigh.depth_tier -eq 'high' -and $rHigh.tier_cap -eq 'paid')
        Check 'P8d dispatcher receives generic tier and selected actual tier is logged' (
            $highSeen.tier -eq 'high' -and $highSeen.pick -eq 'fake-champion' -and
            $rHigh.depth_applied -eq $true -and $rHigh.selected_cost_tier -eq 'paid')

        $spOverride = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -MaxCostTier paid -StakesOverride high -Dispatcher $highDisp
        $rOverride = & $spOverride $task
        Check 'P8e spawner-level operator override reaches routing policy' (
            $rOverride.stakes -eq 'high' -and $rOverride.stakes_basis -eq 'operator override: --stakes high' -and
            $rOverride.chose -eq 'fake-champion' -and $rOverride.depth_tier -eq 'high')

        # dispatcher that does NOTHING, exit 0
        $noopDisp = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $sp2 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r2 = & $sp2 $task
        Check 'P9 no-op exit 0 is ok' ($r2.ok -eq $true)
        Check 'P10 no-op why says no changes' ($r2.why -match 'no changes')

        # dispatcher that FAILS (exit 1)
        $failDisp = { param($pick, $prompt) @{ stdout = ''; stderr = 'boom'; exit_code = 1; duration_s = 0 } }
        $sp3 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -UsagePath (Join-Path $env:BATON_HOME 'usage-p11.jsonl') -Dispatcher $failDisp
        $r3 = & $sp3 $task
        Check 'P11 nonzero exit is NOT ok' ($r3.ok -eq $false)
        Check 'P12 failure why names provider + exit' ($r3.why -match 'fake-agentic.*exit 1')

        # fleet with ONLY non-agentic providers -> no edit-capable candidate
        $fleetLocalOnly = Join-Path $env:BATON_HOME 'fleet-local-only.yaml'
        Set-Content -LiteralPath $fleetLocalOnly -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    command_template: 'echo "{{prompt}}"'
'@
        $sp4 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetLocalOnly -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r4 = & $sp4 $task
        Check 'P13 local-only fleet -> not ok' ($r4.ok -eq $false)
        Check 'P14 message names the capability and tier collision (#127)' (
            ($r4.why -match 'capability code-gen:') -and
            ($r4.why -match 'cheapest eligible = UNAVAILABLE') -and
            ($r4.why -match 'raise task est_cost_tier'))

        # agentic: true override on a local entry -> eligible
        $fleetOverride = Join-Path $env:BATON_HOME 'fleet-override.yaml'
        Set-Content -LiteralPath $fleetOverride -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen, reasoning]
providers:
  - name: fake-local-agentic
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    agentic: true
    host: host-a
    stack: stack-a
    load_profile: model-large
    vram_gb: 8
    command_template: 'echo "{{prompt}}"'
'@
        $sp5 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetOverride -ToolsPath $toolsPath -Dispatcher $noopDisp
        $r5 = & $sp5 $task
        Check 'P15 agentic:true override makes a local entry eligible' ($r5.chose -eq 'fake-local-agentic')
        Check 'P16 provider without named med tier remains eligible and records depth_applied false' (
            $r5.depth_tier -eq 'med' -and $r5.depth_applied -eq $false -and $r5.selected_cost_tier -eq 'local')

        # ---- I1: tools.yaml candidate with platform: codex must be filtered by source ----
        $toolsWithPlatform = Join-Path $env:BATON_HOME 'tools-platform.yaml'
        Set-Content -LiteralPath $toolsWithPlatform -Encoding utf8NoBOM -Value @'
tools:
  - name: fake-tool
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    capability: code-gen
'@
        # Local-only fleet + a tools.yaml entry that would otherwise infer agentic via
        # platform: codex — must still yield "no edit-capable candidate" (tool filtered
        # by source, local fleet entry filtered by platform).
        $sp6 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetLocalOnly -ToolsPath $toolsWithPlatform -Dispatcher $noopDisp
        $r6 = & $sp6 $task
        Check 'I1a tools.yaml platform:codex candidate does not make local-only fleet edit-capable' ($r6.ok -eq $false)
        Check 'I1a why says capability tier collision (#127)' (
            ($r6.why -match 'capability code-gen:') -and ($r6.why -match 'cheapest eligible'))

        # Main fleet (has fake-agentic) + the same tools.yaml entry -> must still pick
        # the fleet candidate, never the tool.
        $sp7 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsWithPlatform -Dispatcher $noopDisp
        $r7 = & $sp7 $task
        Check 'I1b chose fleet candidate, not the tools.yaml entry' ($r7.chose -eq 'fake-agentic')
        Check 'I1b never chose fake-tool' ($r7.chose -ne 'fake-tool')

        # ---- M4: dispatcher throw is caught and returned as a failed task, not a crash ----
        $throwDisp = { param($pick, $prompt) throw 'boom' }
        $sp8 = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $fleetPath -ToolsPath $toolsPath `
            -UsagePath (Join-Path $env:BATON_HOME 'usage-m4.jsonl') -Dispatcher $throwDisp
        $cwdBeforeThrow = (Get-Location).Path
        $r8 = & $sp8 $task
        Check 'M4a dispatcher throw is caught, task returns not-ok' ($r8.ok -eq $false)
        Check 'M4a why records dispatch error' ($r8.why -match 'dispatch error')
        Check 'M4b caller cwd unchanged after a dispatch throw' ((Get-Location).Path -eq $cwdBeforeThrow)

        # ================= Reactive usage failover (d083 slice 1) =================
        # Tree restoration is the clean-state gate used before a substitute runs.
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Value 'before' -Encoding utf8NoBOM
        $restoreTree = Get-WorktreeTreeSha -Worktree $wt2.worktree
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Value 'after' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $wt2.worktree 'restore-drop.txt') -Value 'drop' -Encoding utf8NoBOM
        $restoreOk = Restore-WorktreeTreeSnapshot -Worktree $wt2.worktree -TreeSha $restoreTree
        Check 'UF0 restore snapshot succeeds' $restoreOk
        Check 'UF0 restore snapshot restores tracked content' (((Get-Content -LiteralPath (Join-Path $wt2.worktree 'restore-kept.txt') -Raw).Trim()) -eq 'before')
        Check 'UF0 restore snapshot removes new untracked content' (-not (Test-Path -LiteralPath (Join-Path $wt2.worktree 'restore-drop.txt')))
        Check 'UF0 restore snapshot returns exact tree' ((Get-WorktreeTreeSha -Worktree $wt2.worktree) -eq $restoreTree)
        Check 'UF0 invalid snapshot fails closed' (-not (Restore-WorktreeTreeSnapshot -Worktree $wt2.worktree -TreeSha 'not-a-tree'))

        $failoverFleet = Join-Path $env:BATON_HOME 'fleet-failover.yaml'
        Set-Content -LiteralPath $failoverFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-substitute
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $failoverUsage = Join-Path $env:BATON_HOME 'usage-failover.jsonl'
        $failoverSeen = @{ calls = 0; names = @(); depths = @(); locked_before_retry = $false; clean_before_retry = $false }
        $failoverDispatcher = {
            param($pick, $prompt, $depthTier)
            $failoverSeen.calls++
            $failoverSeen.names += [string]$pick.name
            $failoverSeen.depths += [string]$depthTier
            if ($failoverSeen.calls -eq 1) {
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt') -Value 'partial' -Encoding utf8NoBOM
                return @{ stdout=''; stderr="You've hit your usage limit. Try again at 2099-01-01T00:00:00Z."; exit_code=1; duration_s=0 }
            }
            $failoverSeen.clean_before_retry = -not (Test-Path -LiteralPath (Join-Path (Get-Location).Path 'partial-attempt.txt'))
            if (Test-Path -LiteralPath $failoverUsage) {
                $beforeRetryRows = @(Get-Content -LiteralPath $failoverUsage | ForEach-Object { $_ | ConvertFrom-Json })
                $failoverSeen.locked_before_retry = @($beforeRetryRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'lockout' }).Count -eq 1
            }
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'substitute-result.txt') -Value 'peer work' -Encoding utf8NoBOM
            return @{ stdout='done'; stderr=''; exit_code=0; duration_s=0 }
        }.GetNewClosure()
        $failoverTask = [pscustomobject]@{ id='uf1'; desc='usage failover fixture'; capability='code-gen'; est_cost_tier='paid'; stakes='standard'; stakes_basis='bounded fixture' }
        $failoverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $failoverUsage -Dispatcher $failoverDispatcher
        $failoverResult = & $failoverSpawner $failoverTask
        Check 'UF1 substitute retry succeeds' ($failoverResult.ok -eq $true)
        Check 'UF1 exactly one substitute is attempted' ($failoverSeen.calls -eq 2)
        Check 'UF1 attempted workers are primary then substitute' (($failoverSeen.names -join ',') -eq 'worker-primary,worker-substitute')
        Check 'UF1 same depth policy reaches both attempts' (($failoverSeen.depths -join ',') -eq 'med,med')
        Check 'UF1 primary is locked before substitute dispatch' $failoverSeen.locked_before_retry
        Check 'UF1 substitute starts from clean state' $failoverSeen.clean_before_retry
        Check 'UF1 failed attempt partial file is absent' (-not (Test-Path -LiteralPath (Join-Path $wt2.worktree 'partial-attempt.txt')))
        Check 'UF1 substitute result remains' (Test-Path -LiteralPath (Join-Path $wt2.worktree 'substitute-result.txt'))
        Check 'UF1 result chooses substitute' ($failoverResult.chose -eq 'worker-substitute')
        Check 'UF1 one-line operator hop is legible' ($failoverResult.why -match '^usage failover: worker-primary -> worker-substitute \(quota_exhausted; reset ' -and $failoverResult.why -notmatch "`r|`n")
        Check 'UF1 v1.17 policy fields survive' ($failoverResult.stakes -eq 'standard' -and $failoverResult.depth_tier -eq 'med' -and $failoverResult.selection_mode -eq 'economy' -and $failoverResult.tier_cap -eq 'free')
        Check 'UF1 selected peer tier is within ceiling' ($failoverResult.selected_cost_tier -eq 'free')
        $failoverRows = @(Get-Content -LiteralPath $failoverUsage | ForEach-Object { $_ | ConvertFrom-Json })
        $hopRows = @($failoverRows | Where-Object { $_.event -eq 'failover' })
        Check 'UF1 usage journal has one hop row' ($hopRows.Count -eq 1)
        Check 'UF1 hop row carries required workers and reason' ($hopRows[0].original_worker -eq 'worker-primary' -and $hopRows[0].substitute -eq 'worker-substitute' -and $hopRows[0].reason -eq 'quota_exhausted')
        Check 'UF1 hop row records partial diff' ($hopRows[0].had_partial_diff -eq $true)
        # worker-paid is in the failover fleet above MaxCostTier=free; must never be attempted.
        Check 'UF1 paid peer above max_cost_tier is refused' ($failoverSeen.names -notcontains 'worker-paid')

        # A second hard failure ends after the one substitute; it never cascades.
        $cascadeUsage = Join-Path $env:BATON_HOME 'usage-no-cascade.jsonl'
        $cascadeSeen = @{ calls = 0 }
        $cascadeDispatcher = {
            param($pick, $prompt, $depthTier)
            $cascadeSeen.calls++
            return @{ stdout=''; stderr='HTTP 429 Too Many Requests. Retry-After: 120'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $cascadeSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $cascadeUsage -Dispatcher $cascadeDispatcher
        $cascadeResult = & $cascadeSpawner $failoverTask
        Check 'UF2 second hard limit does not cascade' ($cascadeSeen.calls -eq 2 -and $cascadeResult.ok -eq $false)

        # Auth/config and ambiguous failures never enter the substitute loop.
        # auth+quota co-occurrence must stay auth_config (no failover).
        foreach ($negativeCase in @(
            @{ name='auth'; message='HTTP 401 invalid API key'; expected='auth_config' },
            @{ name='auth-quota'; message='HTTP 401 unauthorized; usage limit exceeded'; expected='auth_config' },
            @{ name='ambiguous'; message='remote command ended unexpectedly'; expected='ambiguous' },
            @{ name='retry-fix'; message='retry after fixing tests'; expected='ambiguous' },
            @{ name='limit-retries'; message='hit your limit of 3 retries'; expected='ambiguous' }
        )) {
            $negativeUsage = Join-Path $env:BATON_HOME "usage-$($negativeCase.name).jsonl"
            $negativeSeen = @{ calls = 0 }
            $negativeDispatcher = {
                param($pick, $prompt, $depthTier)
                $negativeSeen.calls++
                return @{ stdout=''; stderr=$negativeCase.message; exit_code=1; duration_s=0 }
            }.GetNewClosure()
            $negativeSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $negativeUsage -Dispatcher $negativeDispatcher
            $negativeResult = & $negativeSpawner $failoverTask
            Check "UF3 $($negativeCase.name) does not retry" ($negativeSeen.calls -eq 1 -and $negativeResult.ok -eq $false)
            Check "UF3 $($negativeCase.name) reason is visible" ($negativeResult.why -match $negativeCase.expected)
            if ($negativeCase.name -eq 'auth-quota') {
                Check 'UF3 auth-quota does not journal lockout' (
                    -not (Test-Path -LiteralPath $negativeUsage) -or
                    @((Get-Content -LiteralPath $negativeUsage | ForEach-Object { $_ | ConvertFrom-Json }) |
                        Where-Object { $_.event -eq 'lockout' }).Count -eq 0)
            }
        }

        # context_overflow (#104): one substitute allowed, no lockout, prefer larger max_prompt_bytes.
        # Name order matters for equal-quality economy ranking (name is the last key):
        # worker-primary must sort before worker-sub-* so it is the first pick.
        $overflowFleet = Join-Path $env:BATON_HOME 'fleet-context-overflow.yaml'
        Set-Content -LiteralPath $overflowFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 20000
    command_template: 'echo "{{prompt}}"'
  - name: worker-sub-large
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 100000
    command_template: 'echo "{{prompt}}"'
  - name: worker-sub-small
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    max_prompt_bytes: 30000
    command_template: 'echo "{{prompt}}"'
'@
        $overflowUsage = Join-Path $env:BATON_HOME 'usage-context-overflow.jsonl'
        $overflowSeen = @{ calls = 0; names = [System.Collections.Generic.List[string]]::new(); locked_before_retry = $false }
        $overflowDispatcher = {
            param($pick, $prompt, $depthTier)
            $overflowSeen.calls++
            $overflowSeen.names.Add([string]$pick.name)
            if ($overflowSeen.calls -eq 1) {
                return @{ stdout = ''; stderr = 'context length exceeded'; exit_code = 1; duration_s = 0 }
            }
            # Second call = substitute dispatch; primary classification is already journaled.
            if (Test-Path -LiteralPath $overflowUsage) {
                $beforeRows = @(Get-Content -LiteralPath $overflowUsage | ForEach-Object { $_ | ConvertFrom-Json })
                $overflowSeen.locked_before_retry = @($beforeRows | Where-Object {
                    $_.worker -eq 'worker-primary' -and $_.event -in @('lockout', 'cooldown')
                }).Count -gt 0
            }
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'overflow-peer.txt') -Value 'larger peer ok' -Encoding utf8NoBOM
            return @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $overflowTask = [pscustomobject]@{ id = 'uf-ov'; desc = 'context overflow fixture'; capability = 'code-gen'; est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'bounded fixture' }
        $overflowSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $overflowFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $overflowUsage -Dispatcher $overflowDispatcher
        $overflowResult = & $overflowSpawner $overflowTask
        $overflowNames = ($overflowSeen.names -join ',')
        Check 'UF-OV context_overflow substitute succeeds' ($overflowResult.ok -eq $true)
        Check 'UF-OV exactly one substitute' ($overflowSeen.calls -eq 2)
        Check 'UF-OV prefers larger max_prompt_bytes peer' (
            $overflowNames -eq 'worker-primary,worker-sub-large' -and $overflowResult.chose -eq 'worker-sub-large')
        Check 'UF-OV primary is NOT locked before retry' (-not $overflowSeen.locked_before_retry)
        Check 'UF-OV hop line names context_overflow' (
            $overflowResult.why -match '^context_overflow: worker-primary -> worker-sub-large \(prefer larger context\)')
        $overflowRows = @(Get-Content -LiteralPath $overflowUsage | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'UF-OV journals context_overflow not lockout' (
            @($overflowRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'context_overflow' }).Count -eq 1 -and
            @($overflowRows | Where-Object { $_.worker -eq 'worker-primary' -and $_.event -eq 'lockout' }).Count -eq 0)
        Check 'UF-OV hop reason is context_overflow' (
            @($overflowRows | Where-Object { $_.event -eq 'failover' -and $_.reason -eq 'context_overflow' }).Count -eq 1)

        # quality_first refuses the only lower-quality peer loudly.
        $qualityFleet = Join-Path $env:BATON_HOME 'fleet-quality-floor.yaml'
        Set-Content -LiteralPath $qualityFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $qualitySeen = @{ calls = 0 }
        $qualityDispatcher = { param($pick, $prompt, $depthTier) $qualitySeen.calls++; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure()
        $qualitySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $qualityFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-quality.jsonl') -Dispatcher $qualityDispatcher
        $qualityResult = & $qualitySpawner $failoverTask
        Check 'UF4 quality_first refuses downgrade' ($qualitySeen.calls -eq 1 -and $qualityResult.ok -eq $false)
        Check 'UF4 no peer available is loud' ($qualityResult.why -match 'no peer available.*quality_first')
        Check 'UF4b quota-death no-peer flags labor unavailable + exclusion row (#124)' (
            ([string]$qualityResult.labor -eq 'unavailable') -and
            @($qualityResult.exclusions | Where-Object { $_.stage -eq 'usage' -and $_.reason -match 'no peer available' }).Count -ge 1)

        # High stakes re-resolves champion/high policy on the substitute too.
        $highFailoverUsage = Join-Path $env:BATON_HOME 'usage-high-failover.jsonl'
        $highFailoverSeen = @{ calls = 0; depths = @() }
        $highFailoverDispatcher = {
            param($pick, $prompt, $depthTier)
            $highFailoverSeen.calls++
            $highFailoverSeen.depths += $depthTier
            if ($highFailoverSeen.calls -eq 1) { return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }
            return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
        }.GetNewClosure()
        $highFailoverTask = [pscustomobject]@{ id='uf-high'; desc='high stakes fixture'; capability='code-gen'; est_cost_tier='free'; stakes='high'; stakes_basis='security boundary' }
        $highFailoverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $highFailoverUsage -Dispatcher $highFailoverDispatcher
        $highFailoverResult = & $highFailoverSpawner $highFailoverTask
        Check 'UF5 high stakes substitute succeeds' ($highFailoverResult.ok -eq $true -and $highFailoverSeen.calls -eq 2)
        Check 'UF5 high stakes depth is preserved on retry' (($highFailoverSeen.depths -join ',') -eq 'high,high')
        Check 'UF5 champion and cost cap are preserved' ($highFailoverResult.selection_mode -eq 'champion' -and $highFailoverResult.tier_cap -eq 'free' -and $highFailoverResult.selected_cost_tier -eq 'free')

        # Failed worktree restore refuses the substitute hop (no second dispatch).
        $restoreFailUsage = Join-Path $env:BATON_HOME 'usage-restore-fail.jsonl'
        $restoreFailSeen = @{ calls = 0 }
        $restoreFailDispatcher = {
            param($pick, $prompt, $depthTier)
            $restoreFailSeen.calls++
            return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $savedRestoreFn = (Get-Item -LiteralPath 'Function:Restore-WorktreeTreeSnapshot').ScriptBlock
        function Restore-WorktreeTreeSnapshot {
            param(
                [Parameter(Mandatory)][string]$Worktree,
                [Parameter(Mandatory)][string]$TreeSha
            )
            return $false
        }
        try {
            $restoreFailSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $failoverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $restoreFailUsage -Dispatcher $restoreFailDispatcher
            $restoreFailResult = & $restoreFailSpawner $failoverTask
        } finally {
            Set-Item -Path 'Function:Restore-WorktreeTreeSnapshot' -Value $savedRestoreFn
        }
        Check 'UF6 restore failure does not dispatch substitute' ($restoreFailSeen.calls -eq 1)
        Check 'UF6 restore failure is loud' ($restoreFailResult.ok -eq $false -and $restoreFailResult.why -match 'clean worktree restore failed')

        # Substitute peer above max_cost_tier is REFUSED even when quality is higher.
        $paidOnlyFleet = Join-Path $env:BATON_HOME 'fleet-paid-only-peer.yaml'
        Set-Content -LiteralPath $paidOnlyFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $paidPeerUsage = Join-Path $env:BATON_HOME 'usage-paid-peer.jsonl'
        $paidPeerSeen = @{ calls = 0; names = @() }
        $paidPeerDispatcher = {
            param($pick, $prompt, $depthTier)
            $paidPeerSeen.calls++
            $paidPeerSeen.names += [string]$pick.name
            return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
        }.GetNewClosure()
        $paidPeerSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $paidOnlyFleet -ToolsPath $toolsPath `
            -MaxCostTier free -UsagePath $paidPeerUsage -Dispatcher $paidPeerDispatcher
        $paidPeerResult = & $paidPeerSpawner $failoverTask
        Check 'UF7 paid peer above max_cost_tier is refused' (
            $paidPeerSeen.calls -eq 1 -and
            $paidPeerSeen.names -notcontains 'worker-paid' -and
            $paidPeerResult.ok -eq $false)
        Check 'UF7 no peer available names quality_first' ($paidPeerResult.why -match 'no peer available.*quality_first')

        # ================= Proactive usage preflight (d090 Layer 2) =================
        $spawnerParams = (Get-Command New-AgenticSpawner).Parameters
        $hasPreflightContract = $spawnerParams.ContainsKey('ProbeTransport') -and
            $spawnerParams.ContainsKey('ProbeCachePath') -and
            $spawnerParams.ContainsKey('FleetJournalPath') -and
            $spawnerParams.ContainsKey('ProbeClock')
        Check 'PF0 spawner exposes hermetic usage preflight seams' $hasPreflightContract
        if ($hasPreflightContract) {
            $probeNow = [datetimeoffset]::Parse('2026-07-16T12:00:00-06:00')
            $legacyOrder = @(
                [pscustomobject]@{ name='worker-z'; score=[double]1; source='fleet' },
                [pscustomobject]@{ name='worker-a'; score=[double]1; source='fleet' }
            )
            $legacyRanked = Sort-UsageSurplusCandidates -Candidates $legacyOrder -FleetPath $failoverFleet `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-none.jsonl') -Now $probeNow
            Check 'PF0 no surplus preference preserves legacy candidate order exactly' (
                (@($legacyRanked.name) -join ',') -eq 'worker-z,worker-a')
            function New-ExecutorProbeResponse {
                param(
                    [double]$FiveHourUsed,
                    [double]$WeeklyUsed,
                    [datetimeoffset]$At,
                    [double]$WeeklyResetHours = 48
                )
                return [pscustomobject]@{
                    jsonrpc = '2.0'; id = 2
                    result = [pscustomobject]@{
                        rateLimits = [pscustomobject]@{
                            limitId = 'synthetic'; limitName = 'synthetic'
                            primary = [pscustomobject]@{
                                usedPercent = $FiveHourUsed; windowDurationMins = 300
                                resetsAt = $At.AddHours(2).ToUnixTimeSeconds()
                            }
                            secondary = [pscustomobject]@{
                                usedPercent = $WeeklyUsed; windowDurationMins = 10080
                                resetsAt = $At.AddHours($WeeklyResetHours).ToUnixTimeSeconds()
                            }
                            credits = $null; individualLimit = $null; planType = $null; rateLimitReachedType = $null
                        }
                        rateLimitResetCredits = [pscustomobject]@{ availableCount = 0; credits = @() }
                    }
                }
            }

            $preflightFleet = Join-Path $env:BATON_HOME 'fleet-preflight.yaml'
            Set-Content -LiteralPath $preflightFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
      monthly_allowance: 100
  - name: worker-substitute
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo {{tier_args}} "{{prompt}}"'
    tier_low: '--depth low'
    tier_med: '--depth medium'
    tier_high: '--depth high'
  - name: worker-third
    kind: cli
    enabled: true
    cost_tier: free
    platform: gemini
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-paid
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 1.0
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $preflightTask = [pscustomobject]@{
                id='pf1'; desc='synthetic preflight fixture'; capability='code-gen'
                est_cost_tier='free'; stakes='standard'; stakes_basis='bounded fixture'
            }
            $probeClock = { return $probeNow }.GetNewClosure()

            # Under caps: selected worker dispatches and the raw response is cached.
            $underUsage = Join-Path $env:BATON_HOME 'usage-pf-under.jsonl'
            $underCache = Join-Path $env:BATON_HOME 'cache-pf-under.jsonl'
            $underSeen = @{ calls = 0; names = @(); probes = 0 }
            $underProbe = {
                param($clientVersion, $timeoutSeconds)
                $underSeen.probes++
                return (New-ExecutorProbeResponse -FiveHourUsed 40 -WeeklyUsed 50 -At $probeNow)
            }.GetNewClosure()
            $underDispatcher = {
                param($pick, $prompt, $depthTier)
                $underSeen.calls++; $underSeen.names += [string]$pick.name
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'pf-under.txt') -Value 'done' -Encoding utf8NoBOM
                return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
            }.GetNewClosure()
            $underSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $underUsage -Dispatcher $underDispatcher -ProbeTransport $underProbe `
                -ProbeCachePath $underCache -FleetJournalPath (Join-Path $env:BATON_HOME 'journal-pf-under.md') -ProbeClock $probeClock
            $underResult = & $underSpawner $preflightTask
            Check 'PF1 under caps dispatches the selected provider' ($underResult.ok -and $underSeen.calls -eq 1 -and $underSeen.names[0] -eq 'worker-primary')
            Check 'PF1 under caps probes once and caches raw response' ($underSeen.probes -eq 1 -and (Test-Path -LiteralPath $underCache))
            $underRows = @(Get-Content -LiteralPath $underUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF1 under caps journals dispatched with evidence' (
                @($underRows | Where-Object {
                    $_.event -eq 'preflight' -and $_.outcome -eq 'dispatched' -and
                    $null -ne $_.used_pct -and $null -ne $_.cap -and $_.window
                }).Count -eq 1)
            Check 'PF1 under caps never journals limited' (@($underRows | Where-Object { $_.event -eq 'limited' }).Count -eq 0)

            # Five-hour and weekly crossings reroute before the capped provider runs.
            foreach ($capCase in @(
                @{ name='five-hour'; five=[double]80; weekly=[double]20; window='five_hour'; knob='soft_cap_5h' },
                @{ name='weekly'; five=[double]20; weekly=[double]90; window='weekly'; knob='soft_cap_weekly' }
            )) {
                $capUsage = Join-Path $env:BATON_HOME "usage-pf-$($capCase.name).jsonl"
                $capCache = Join-Path $env:BATON_HOME "cache-pf-$($capCase.name).jsonl"
                $capSeen = @{ calls = 0; names = @(); depths = @() }
                $capProbe = {
                    param($clientVersion, $timeoutSeconds)
                    return (New-ExecutorProbeResponse -FiveHourUsed $capCase.five -WeeklyUsed $capCase.weekly -At $probeNow)
                }.GetNewClosure()
                $capDispatcher = {
                    param($pick, $prompt, $depthTier)
                    $capSeen.calls++; $capSeen.names += [string]$pick.name; $capSeen.depths += [string]$depthTier
                    Set-Content -LiteralPath (Join-Path (Get-Location).Path "pf-$($capCase.name).txt") -Value 'peer' -Encoding utf8NoBOM
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure()
                $capSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath $capUsage -Dispatcher $capDispatcher -ProbeTransport $capProbe `
                    -ProbeCachePath $capCache -FleetJournalPath (Join-Path $env:BATON_HOME "journal-pf-$($capCase.name).md") -ProbeClock $probeClock
                $capResult = & $capSpawner $preflightTask
                Check "PF2 $($capCase.name) cap reroutes before dispatch" (
                    $capResult.ok -and $capSeen.calls -eq 1 -and ($capSeen.names -join ',') -eq 'worker-substitute')
                Check "PF2 $($capCase.name) reroute preserves med depth and free ceiling" (
                    ($capSeen.depths -join ',') -eq 'med' -and $capResult.depth_tier -eq 'med' -and
                    $capResult.tier_cap -eq 'free' -and $capResult.selected_cost_tier -eq 'free')
                Check "PF2 $($capCase.name) loud line names all policy evidence" (
                    $capResult.why -match 'usage preflight: worker-primary' -and
                    $capResult.why -match $capCase.window -and $capResult.why -match $capCase.knob -and
                    $capResult.why -match '80%|90%' -and $capResult.why -match 'resets ' -and
                    $capResult.why -notmatch "`r|`n")
                $capRows = @(Get-Content -LiteralPath $capUsage | ForEach-Object { $_ | ConvertFrom-Json })
                Check "PF2 $($capCase.name) journals one limited observation" (
                    @($capRows | Where-Object { $_.event -eq 'limited' -and $_.window -eq $capCase.window }).Count -eq 1)
                Check "PF2 $($capCase.name) journals rerouted decision" (
                    @($capRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' -and $_.substitute -eq 'worker-substitute' }).Count -eq 1)
                Check "PF2 $($capCase.name) lower-quality and paid workers are refused" (
                    $capSeen.names -notcontains 'worker-lower' -and $capSeen.names -notcontains 'worker-paid')
            }

            # No equal-quality peer: hold loudly and do not dispatch anyone.
            $holdFleet = Join-Path $env:BATON_HOME 'fleet-preflight-hold.yaml'
            Set-Content -LiteralPath $holdFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: worker-lower
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.8
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $holdUsage = Join-Path $env:BATON_HOME 'usage-pf-hold.jsonl'
            $holdSeen = @{ calls = 0 }
            $holdSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $holdFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $holdUsage -Dispatcher { param($pick,$prompt,$depthTier) $holdSeen.calls++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-hold.jsonl') -ProbeClock $probeClock
            $holdResult = & $holdSpawner $preflightTask
            Check 'PF3 over cap with no peer holds without dispatch' (-not $holdResult.ok -and $holdSeen.calls -eq 0)
            Check 'PF3 hold is loud with exact no-peer context' ($holdResult.why -match 'no peer available \+ worker-primary over soft cap' -and $holdResult.why -notmatch "`r|`n")
            $holdRows = @(Get-Content -LiteralPath $holdUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF3 held outcome is journaled' (@($holdRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'held' }).Count -eq 1)
            Check 'PF3b preflight hold flags labor unavailable + soft-cap exclusion (#124)' (
                ([string]$holdResult.labor -eq 'unavailable') -and
                @($holdResult.exclusions | Where-Object { $_.stage -eq 'usage' -and $_.reason -match 'soft cap' }).Count -ge 1)

            # Transport failures are fail-open and dispatch the primary normally.
            foreach ($probeFailure in @(
                @{ name='timeout'; body={ param($clientVersion,$timeoutSeconds) throw 'synthetic timeout' } },
                @{ name='garbage'; body={ param($clientVersion,$timeoutSeconds) return 'synthetic garbage' } },
                @{ name='missing'; body={ param($clientVersion,$timeoutSeconds) throw 'synthetic missing binary' } }
            )) {
                $failureSeen = @{ calls = 0; name = '' }
                $failureDispatcher = {
                    param($pick,$prompt,$depthTier)
                    $failureSeen.calls++; $failureSeen.name = [string]$pick.name
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure()
                $failureSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME "usage-pf-fail-$($probeFailure.name).jsonl") `
                    -Dispatcher $failureDispatcher -ProbeTransport $probeFailure.body `
                    -ProbeCachePath (Join-Path $env:BATON_HOME "cache-pf-fail-$($probeFailure.name).jsonl") -ProbeClock $probeClock
                $failureResult = & $failureSpawner $preflightTask
                Check "PF4 $($probeFailure.name) probe failure fails open" (
                    $failureResult.ok -and $failureSeen.calls -eq 1 -and $failureSeen.name -eq 'worker-primary')
            }

            # Stale cache must invoke the transport once; fresh cache behavior is covered in probe suite.
            $staleCache = Join-Path $env:BATON_HOME 'cache-pf-stale.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-primary' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 30 -WeeklyUsed 40 -At $probeNow
            } -CachePath $staleCache -Now $probeNow -TtlSeconds 600)
            $staleSeen = @{ probes = 0; dispatches = 0 }
            $staleSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-stale.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $staleSeen.dispatches++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) $staleSeen.probes++; New-ExecutorProbeResponse -FiveHourUsed 35 -WeeklyUsed 45 -At $probeNow.AddMinutes(11) }.GetNewClosure() `
                -ProbeCachePath $staleCache -ProbeClock { $probeNow.AddMinutes(11) }.GetNewClosure()
            $staleResult = & $staleSpawner $preflightTask
            Check 'PF5 stale cache re-probes exactly once then dispatches' ($staleResult.ok -and $staleSeen.probes -eq 1 -and $staleSeen.dispatches -eq 1)

            # Failover WALK past a proactive reroute (#code-factory C1). This used to assert
            # calls -eq 1: a preflight reroute consumed the whole budget, so a substitute that
            # was ALSO capped ended the task. That is the factory stall -- during a quota storm
            # the preflight almost always hops first, which disabled dispatch failover exactly
            # when it was needed. The cascade concern is now handled by a BOUND, not a ban.
            # Every provider here answers 'quota exhausted'. The walk goes preflight
            # primary->substitute (hop 1), then substitute->third (hop 2), and then stops:
            # worker-lower is quality 0.8 and quality_first refuses to fail over BELOW the
            # current provider, so the walk ends on an empty peer pool rather than the hop
            # budget. Degrading quality to keep a task moving is never the trade made here.
            $oneHopSeen = @{ calls = 0; names = @() }
            $oneHopSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-one-hop.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $oneHopSeen.calls++; $oneHopSeen.names += [string]$pick.name; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-one-hop.jsonl') -ProbeClock $probeClock
            $oneHopResult = & $oneHopSpawner $preflightTask
            Check 'PF6 reroute then walk: dispatch failover continues past a preflight hop' (
                -not $oneHopResult.ok -and $oneHopSeen.calls -eq 2 -and
                ($oneHopSeen.names -join ',') -eq 'worker-substitute,worker-third' -and
                $oneHopResult.why -match 'no peer available' -and $oneHopResult.labor -eq 'unavailable')

            # The budget is what stops the cascade, and a preflight reroute counts against it:
            # with MaxFailoverHops=1 the old "one hop total" guarantee still holds exactly.
            $budgetSeen = @{ calls = 0; names = @() }
            $budgetSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -MaxFailoverHops 1 -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-budget.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $budgetSeen.calls++; $budgetSeen.names += [string]$pick.name; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-budget.jsonl') -ProbeClock $probeClock
            $budgetResult = & $budgetSpawner $preflightTask
            Check 'PF6b MaxFailoverHops bounds the walk; preflight reroute counts as a hop' (
                -not $budgetResult.ok -and $budgetSeen.calls -eq 1 -and
                ($budgetSeen.names -join ',') -eq 'worker-substitute')

            # A walk that finds a healthy peer must actually finish the task, not just stop
            # hopping -- the whole point of the walk is labor completing during a quota storm.
            $walkOkSeen = @{ calls = 0; names = @() }
            $walkOkSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-walk-ok.jsonl') `
                -Dispatcher {
                    param($pick,$prompt,$depthTier)
                    $walkOkSeen.calls++; $walkOkSeen.names += [string]$pick.name
                    if ([string]$pick.name -eq 'worker-third') { return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }
                    return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
                }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-walk-ok.jsonl') -ProbeClock $probeClock
            $walkOkResult = & $walkOkSpawner $preflightTask
            Check 'PF6c walk reaching a healthy peer completes the task and names the chain' (
                $walkOkResult.ok -and $walkOkResult.chose -eq 'worker-third' -and
                $walkOkSeen.calls -eq 2 -and $walkOkResult.why -match 'worker-substitute -> worker-third')

            # Round-2 C1: the PREFLIGHT reroute must honour the same budget the dispatch
            # walk does. At MaxFailoverHops=0 the task may not hop at all -- it holds on
            # the capped primary. Before this, the preflight rerouted unconditionally, so
            # the "no failover" setting still burned a peer.
            $pfZeroSeen = @{ calls = 0; names = @() }
            $pfZeroUsage = Join-Path $env:BATON_HOME 'usage-pf-zero-budget.jsonl'
            $pfZeroSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -MaxFailoverHops 0 -UsagePath $pfZeroUsage `
                -Dispatcher { param($pick,$prompt,$depthTier) $pfZeroSeen.calls++; $pfZeroSeen.names += [string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-zero-budget.jsonl') -ProbeClock $probeClock
            $pfZeroResult = & $pfZeroSpawner $preflightTask
            Check 'PF6d MaxFailoverHops=0 forbids the preflight reroute (holds, dispatches nobody)' (
                -not $pfZeroResult.ok -and $pfZeroSeen.calls -eq 0 -and $pfZeroResult.chose -eq 'worker-primary')
            Check 'PF6d zero-budget hold names the budget, not a missing peer' (
                $pfZeroResult.why -match 'failover budget spent' -and $pfZeroResult.why -notmatch "`r|`n" -and
                [string]$pfZeroResult.labor -eq 'unavailable')
            $pfZeroRows = @(Get-Content -LiteralPath $pfZeroUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF6d zero-budget journals held, never rerouted' (
                @($pfZeroRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'held' }).Count -eq 1 -and
                @($pfZeroRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }).Count -eq 0)

            # Round-2 C1: the preflight is a WALK too. Three probe-eligible providers, the
            # first two over cap: the task must reach the third rather than holding after
            # a single hop. worker-fourth exists only so the dispatch-stage budget test
            # below has somewhere left to go.
            $pfWalkFleet = Join-Path $env:BATON_HOME 'fleet-preflight-walk.yaml'
            # Names are deliberately a<b<c<d: equal-quality free peers tie-break by name,
            # so this fixes the walk order (a capped -> b capped -> c clean, d untried).
            Set-Content -LiteralPath $pfWalkFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: walk-a
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: walk-b
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: walk-c
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: walk-d
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            # Probes answer in walk order: a capped, b capped, c clean.
            $pfWalkProbeState = @{ n = 0 }
            $pfWalkProbe = {
                param($clientVersion, $timeoutSeconds)
                $pfWalkProbeState.n++
                $five = if ($pfWalkProbeState.n -le 2) { [double]80 } else { [double]40 }
                return (New-ExecutorProbeResponse -FiveHourUsed $five -WeeklyUsed 20 -At $probeNow)
            }.GetNewClosure()
            $pfWalkSeen = @{ calls = 0; names = @() }
            $pfWalkUsage = Join-Path $env:BATON_HOME 'usage-pf-walk.jsonl'
            $pfWalkSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $pfWalkFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $pfWalkUsage `
                -Dispatcher { param($pick,$prompt,$depthTier) $pfWalkSeen.calls++; $pfWalkSeen.names += [string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport $pfWalkProbe -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-walk.jsonl') -ProbeClock $probeClock
            $pfWalkResult = & $pfWalkSpawner $preflightTask
            Check 'PF6e preflight walks past a second capped provider to a clean one' (
                $pfWalkResult.ok -and $pfWalkSeen.calls -eq 1 -and
                ($pfWalkSeen.names -join ',') -eq 'walk-c')
            Check 'PF6e preflight walk narrates every hop in order' (
                $pfWalkResult.why -match 'walk-a' -and
                $pfWalkResult.why -match 'rerouting to walk-b' -and
                $pfWalkResult.why -match 'rerouting to walk-c' -and
                $pfWalkResult.why -notmatch "`r|`n")
            $pfWalkRows = @(Get-Content -LiteralPath $pfWalkUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF6e preflight walk journals one rerouted row per hop' (
                @($pfWalkRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }).Count -eq 2)

            # Round-2 C1: preflight hops count against the SHARED budget. Two preflight
            # hops with MaxFailoverHops=2 leaves the dispatch walk nothing, even though
            # walk-d is an untried equal-quality peer.
            $pfSharedProbeState = @{ n = 0 }
            $pfSharedProbe = {
                param($clientVersion, $timeoutSeconds)
                $pfSharedProbeState.n++
                $five = if ($pfSharedProbeState.n -le 2) { [double]80 } else { [double]40 }
                return (New-ExecutorProbeResponse -FiveHourUsed $five -WeeklyUsed 20 -At $probeNow)
            }.GetNewClosure()
            $pfSharedSeen = @{ calls = 0; names = @() }
            $pfSharedSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $pfWalkFleet -ToolsPath $toolsPath `
                -MaxCostTier free -MaxFailoverHops 2 -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-shared-budget.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $pfSharedSeen.calls++; $pfSharedSeen.names += [string]$pick.name; @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport $pfSharedProbe -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-shared-budget.jsonl') -ProbeClock $probeClock
            $pfSharedResult = & $pfSharedSpawner $preflightTask
            Check 'PF6f preflight hops spend the shared failover budget' (
                -not $pfSharedResult.ok -and $pfSharedSeen.calls -eq 1 -and
                ($pfSharedSeen.names -join ',') -eq 'walk-c')

            # Round-2 finding 6: a coordination denial ended the whole walk. A busy box is
            # a fact about ONE peer -- the others are still available, and the budget was
            # not spent -- so the denial costs a hop and the walk carries on.
            function Request-LocalDispatchClaim {
                param($Candidate, [string]$FleetPath = '', [string]$Worktree = '', [string]$RunDir = '', [int]$TtlSec = 0)
                if ([string]$Candidate.name -eq 'worker-substitute') {
                    return [ordered]@{ gated=$true; granted=$false; reason='box busy: stack-a held'; claim_id=''; ttl_sec=0; host='host-a'; stack='stack-a'; load_profile='' }
                }
                return [ordered]@{ gated=$false; granted=$true; reason='not_local'; claim_id=''; ttl_sec=0; host=''; stack=''; load_profile='' }
            }
            try {
                $denySeen = @{ calls = 0; names = @() }
                $denySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-coord-deny-walk.jsonl') `
                    -Dispatcher {
                        param($pick,$prompt,$depthTier)
                        $denySeen.calls++; $denySeen.names += [string]$pick.name
                        if ([string]$pick.name -eq 'worker-third') {
                            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'coord-deny-walk.txt') -Value 'done' -Encoding utf8NoBOM
                            return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                        }
                        return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
                    }.GetNewClosure()
                $denyResult = & $denySpawner $preflightTask
                Check 'CD1 a coordination-denied peer costs a hop, it does not end the walk' (
                    $denyResult.ok -and $denyResult.chose -eq 'worker-third' -and
                    ($denySeen.names -join ',') -eq 'worker-primary,worker-third')
                Check 'CD1 the denial stays visible in the why chain' (
                    $denyResult.why -match 'worker-substitute' -and $denyResult.why -match 'box busy' -and
                    $denyResult.why -notmatch "`r|`n")

                # Round-3 review: the failover journal is written BEFORE the coordination
                # gate, so a denied peer was recorded as a completed failover that never
                # ran -- and the next hop journaled a second failover from the same origin.
                # The usage journal is routing training data; a hop that did not happen
                # must not appear in it.
                $cdJournal = Join-Path $env:BATON_HOME 'usage-coord-deny-journal.jsonl'
                $cdjSeen = @{ names = @() }
                $cdjSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath $cdJournal `
                    -Dispatcher {
                        param($pick,$prompt,$depthTier)
                        $cdjSeen.names += [string]$pick.name
                        if ([string]$pick.name -eq 'worker-third') {
                            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'coord-deny-journal.txt') -Value 'done' -Encoding utf8NoBOM
                            return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                        }
                        return @{ stdout=''; stderr='quota exhausted'; exit_code=1; duration_s=0 }
                    }.GetNewClosure()
                $cdjResult = & $cdjSpawner $preflightTask
                $cdjRows = @(Get-Content -LiteralPath $cdJournal | ForEach-Object { $_ | ConvertFrom-Json })
                $cdjFailovers = @($cdjRows | Where-Object { $_.event -eq 'failover' })
                Check 'CD2 a denied peer is never journaled as a failover that ran' (
                    $cdjResult.ok -and @($cdjFailovers | Where-Object { $_.substitute -eq 'worker-substitute' }).Count -eq 0)
                Check 'CD2 exactly one failover row, for the hop that actually dispatched' (
                    $cdjFailovers.Count -eq 1 -and [string]$cdjFailovers[0].substitute -eq 'worker-third')
            } finally { . "$PSScriptRoot/fleet-executor-lib.ps1" }

            # Round-3 review: the FIRST dispatch's coordination denial still aborted the
            # task outright, so after a preflight walk a busy landing provider ended the
            # run with untried peers and hop budget both remaining -- the exact behaviour
            # finding 6 removed from the retry path, left in place one branch over.
            function Request-LocalDispatchClaim {
                param($Candidate, [string]$FleetPath = '', [string]$Worktree = '', [string]$RunDir = '', [int]$TtlSec = 0)
                if ([string]$Candidate.name -eq 'worker-primary') {
                    return [ordered]@{ gated=$true; granted=$false; reason='box busy: stack-a held'; claim_id=''; ttl_sec=0; host='host-a'; stack='stack-a'; load_profile='' }
                }
                return [ordered]@{ gated=$false; granted=$true; reason='not_local'; claim_id=''; ttl_sec=0; host=''; stack=''; load_profile='' }
            }
            try {
                $firstDenySeen = @{ names = @() }
                $firstDenySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-coord-deny-first.jsonl') `
                    -Dispatcher {
                        param($pick,$prompt,$depthTier)
                        $firstDenySeen.names += [string]$pick.name
                        Set-Content -LiteralPath (Join-Path (Get-Location).Path 'coord-deny-first.txt') -Value 'done' -Encoding utf8NoBOM
                        return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                    }.GetNewClosure()
                $firstDenyResult = & $firstDenySpawner $preflightTask
                Check 'CD3 a denied FIRST provider walks to an untried peer' (
                    $firstDenyResult.ok -and $firstDenyResult.chose -eq 'worker-substitute' -and
                    ($firstDenySeen.names -join ',') -eq 'worker-substitute')
                Check 'CD3 the first-dispatch denial stays in the why chain' (
                    $firstDenyResult.why -match 'worker-primary' -and $firstDenyResult.why -match 'box busy')
            } finally { . "$PSScriptRoot/fleet-executor-lib.ps1" }

            # Every peer busy is still a real outcome and must never read as success. With
            # no dispatch at all $res stays null, and `[int]$null -ne 0` is FALSE -- so the
            # walk fell straight through to the "no changes" success return.
            function Request-LocalDispatchClaim {
                param($Candidate, [string]$FleetPath = '', [string]$Worktree = '', [string]$RunDir = '', [int]$TtlSec = 0)
                return [ordered]@{ gated=$true; granted=$false; reason='box busy: stack-a held'; claim_id=''; ttl_sec=0; host='host-a'; stack='stack-a'; load_profile='' }
            }
            try {
                $allDenySeen = @{ calls = 0 }
                $allDenySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-coord-deny-all.jsonl') `
                    -Dispatcher { param($pick,$prompt,$depthTier) $allDenySeen.calls++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure()
                $allDenyResult = & $allDenySpawner $preflightTask
                Check 'CD4 every peer busy is a failure, never a silent success' (
                    -not $allDenyResult.ok -and $allDenySeen.calls -eq 0)
                Check 'CD4 total denial is labor-unavailable with the denials audited' (
                    [string]$allDenyResult.labor -eq 'unavailable' -and
                    @($allDenyResult.exclusions | Where-Object { $_.reason -match 'coordination denied' }).Count -ge 1)
            } finally { . "$PSScriptRoot/fleet-executor-lib.ps1" }

            # High stakes remains champion/high when preflight selects a peer.
            $pfHighSeen = @{ calls = 0; depths = @() }
            $pfHighTask = [pscustomobject]@{ id='pf-high'; desc='synthetic high'; capability='code-gen'; est_cost_tier='free'; stakes='high'; stakes_basis='security boundary' }
            $pfHighSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath (Join-Path $env:BATON_HOME 'usage-pf-high.jsonl') `
                -Dispatcher { param($pick,$prompt,$depthTier) $pfHighSeen.calls++; $pfHighSeen.depths += [string]$depthTier; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-high.jsonl') -ProbeClock $probeClock
            $pfHighResult = & $pfHighSpawner $pfHighTask
            Check 'PF7 high-stakes preflight peer keeps champion/high policy' (
                $pfHighResult.ok -and ($pfHighSeen.depths -join ',') -eq 'high' -and
                $pfHighResult.selection_mode -eq 'champion' -and $pfHighResult.tier_cap -eq 'free')

            # Token-fit and monthly pace append advisories but never auto-hold.
            $advisoryUsage = Join-Path $env:BATON_HOME 'usage-pf-advisory.jsonl'
            Add-UsageClassifyJournalRow -UsagePath $advisoryUsage -Row ([ordered]@{
                ts=$probeNow.ToString('o'); event='observation'; worker='worker-primary'; scope='paid_credit'
                source='billing_api'; consumed=[double]60; observed_at=$probeNow.ToString('o'); reset_at=$probeNow.AddDays(20).ToString('o')
            })
            $advisoryJournal = Join-Path $env:BATON_HOME 'journal-pf-advisory.md'
            Set-Content -LiteralPath $advisoryJournal -Encoding utf8NoBOM -Value @('# synthetic')
            foreach ($tokenValue in @(100,200,300,400,500)) {
                Add-Content -LiteralPath $advisoryJournal -Encoding utf8NoBOM -Value "2026-07-16T12:00:00-06:00 | fleet | worker-primary | 1s | exit:0 | `"synthetic`" | host:test | tok:$tokenValue(estimate)"
            }
            $advisorySeen = @{ calls = 0 }
            $advisoryFleet = Join-Path $env:BATON_HOME 'fleet-pf-advisory.yaml'
            (Get-Content -LiteralPath $preflightFleet -Raw).Replace('soft_cap_5h: 75', 'soft_cap_5h: 100') | Set-Content -LiteralPath $advisoryFleet -Encoding utf8NoBOM
            $advisorySpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $advisoryFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $advisoryUsage -FleetJournalPath $advisoryJournal `
                -Dispatcher { param($pick,$prompt,$depthTier) $advisorySeen.calls++; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) New-ExecutorProbeResponse -FiveHourUsed 98 -WeeklyUsed 20 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-advisory.jsonl') -ProbeClock $probeClock
            $advisoryResult = & $advisorySpawner $preflightTask
            Check 'PF8 fit/monthly advisories never auto-hold' ($advisoryResult.ok -and $advisorySeen.calls -eq 1 -and $advisoryResult.chose -eq 'worker-primary')
            Check 'PF8 result appends token-fit advisory' ($advisoryResult.why -match 'typical dispatch burns ~300 tok')
            Check 'PF8 result appends monthly pace advisory' ($advisoryResult.why -match 'monthly usage pace')

            # Fresh cached surplus preference changes only same-tier candidate order.
            $surplusFleet = Join-Path $env:BATON_HOME 'fleet-pf-surplus.yaml'
            Set-Content -LiteralPath $surplusFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-alpha
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-probe
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $surplusCache = Join-Path $env:BATON_HOME 'cache-pf-surplus.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-probe' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 20 -WeeklyUsed 40 -At $probeNow -WeeklyResetHours 12
            } -CachePath $surplusCache -Now $probeNow -TtlSeconds 600)
            $surplusUsage = Join-Path $env:BATON_HOME 'usage-pf-surplus.jsonl'
            $surplusSeen = @{ calls=0; name=''; probes=0 }
            $surplusSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $surplusFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $surplusUsage `
                -Dispatcher { param($pick,$prompt,$depthTier) $surplusSeen.calls++; $surplusSeen.name=[string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) $surplusSeen.probes++; throw 'fresh cache should be used' }.GetNewClosure() `
                -ProbeCachePath $surplusCache -ProbeClock { $probeNow.AddMinutes(5) }.GetNewClosure()
            $surplusResult = & $surplusSpawner $preflightTask
            Check 'PF9 surplus preference moves adapter-backed peer within the eligible tier' (
                $surplusResult.ok -and $surplusSeen.name -eq 'worker-probe' -and $surplusSeen.probes -eq 0)
            $surplusRows = @(Get-Content -LiteralPath $surplusUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF9 surplus reason lands in preflight journal' (
                @($surplusRows | Where-Object { $_.event -eq 'preflight' -and $_.reason -eq 'surplus_spend' }).Count -eq 1)

            # FIX 2: surplus on the weaker peer must not flip a real quality gap (0.90 vs 0.85).
            $qualitySurplusFleet = Join-Path $env:BATON_HOME 'fleet-pf-quality-surplus.yaml'
            Set-Content -LiteralPath $qualitySurplusFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-strong
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.90
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
  - name: worker-weak
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.85
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $qualitySurplusCache = Join-Path $env:BATON_HOME 'cache-pf-quality-surplus.jsonl'
            [void](Get-CodexUsageProbe -Worker 'worker-weak' -Transport {
                param($clientVersion,$timeoutSeconds)
                New-ExecutorProbeResponse -FiveHourUsed 20 -WeeklyUsed 40 -At $probeNow -WeeklyResetHours 12
            } -CachePath $qualitySurplusCache -Now $probeNow -TtlSeconds 600)
            # Economy score = tier_rank - quality*0.001 (both free => tier 0).
            $qualityCands = @(
                [pscustomobject]@{ name='worker-weak'; score=([double](0 - 0.85 * 0.001)); source='fleet'; quality=[double]0.85 },
                [pscustomobject]@{ name='worker-strong'; score=([double](0 - 0.90 * 0.001)); source='fleet'; quality=[double]0.90 }
            )
            $qualityRanked = Sort-UsageSurplusCandidates -Candidates $qualityCands -FleetPath $qualitySurplusFleet `
                -ProbeCachePath $qualitySurplusCache -Now $probeNow.AddMinutes(5)
            Check 'PF10 surplus on weaker peer does not flip a real quality gap' (
                @($qualityRanked)[0].name -eq 'worker-strong' -and
                [double](@($qualityRanked | Where-Object { $_.name -eq 'worker-weak' })[0].usage_preference) -gt 0)

            # FIX 3: two probe:true peers both over cap -> held, no dispatch, no hop chain.
            $bothOverFleet = Join-Path $env:BATON_HOME 'fleet-pf-both-over.yaml'
            Set-Content -LiteralPath $bothOverFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-primary
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
  - name: worker-peer
    kind: cli
    enabled: true
    cost_tier: free
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $bothOverSeen = @{ calls = 0; probes = 0; workers = @() }
            $bothOverProbe = {
                param($clientVersion, $timeoutSeconds)
                $bothOverSeen.probes++
                return (New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 20 -At $probeNow)
            }.GetNewClosure()
            $bothOverDispatcher = {
                param($pick, $prompt, $depthTier)
                $bothOverSeen.calls++
                $bothOverSeen.workers += [string]$pick.name
                return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
            }.GetNewClosure()
            $bothOverUsage = Join-Path $env:BATON_HOME 'usage-pf-both-over.jsonl'
            $bothOverSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $bothOverFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $bothOverUsage -Dispatcher $bothOverDispatcher -ProbeTransport $bothOverProbe `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-both-over.jsonl') -ProbeClock $probeClock
            $bothOverResult = & $bothOverSpawner $preflightTask
            Check 'PF11 both probe peers over cap holds without dispatch' (
                -not $bothOverResult.ok -and $bothOverSeen.calls -eq 0)
            Check 'PF11 both-over hold names both providers' (
                $bothOverResult.why -match 'worker-primary' -and $bothOverResult.why -match 'worker-peer' -and
                $bothOverResult.why -match 'also over soft cap' -and $bothOverResult.why -notmatch "`r|`n")
            Check 'PF11 both-over probes primary and substitute exactly once each' ($bothOverSeen.probes -eq 2)
            $bothOverRows = @(Get-Content -LiteralPath $bothOverUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF11 both-over journals held not rerouted' (
                @($bothOverRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'held' }).Count -eq 1 -and
                @($bothOverRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }).Count -eq 0)
            Check 'PF11b both-over-cap flags labor unavailable, names both providers (#124)' (
                ([string]$bothOverResult.labor -eq 'unavailable') -and
                @($bothOverResult.exclusions | Where-Object { $_.name -eq 'worker-primary' }).Count -eq 1 -and
                @($bothOverResult.exclusions | Where-Object { $_.name -eq 'worker-peer' }).Count -eq 1)

            # FIX 4: multi-window over-cap loud line names every crossed window.
            $multiWinUsage = Join-Path $env:BATON_HOME 'usage-pf-multi-window.jsonl'
            $multiWinSeen = @{ calls = 0; names = @() }
            $multiWinSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $preflightFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $multiWinUsage `
                -Dispatcher {
                    param($pick,$prompt,$depthTier)
                    $multiWinSeen.calls++; $multiWinSeen.names += [string]$pick.name
                    Set-Content -LiteralPath (Join-Path (Get-Location).Path 'pf-multi.txt') -Value 'peer' -Encoding utf8NoBOM
                    return @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 }
                }.GetNewClosure() `
                -ProbeTransport {
                    param($clientVersion,$timeoutSeconds)
                    New-ExecutorProbeResponse -FiveHourUsed 80 -WeeklyUsed 90 -At $probeNow
                }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-multi-window.jsonl') -ProbeClock $probeClock
            $multiWinResult = & $multiWinSpawner $preflightTask
            Check 'PF12 multi-window over-cap loud line names all crossings' (
                $multiWinResult.ok -and $multiWinResult.why -match 'five_hour' -and
                $multiWinResult.why -match 'weekly' -and $multiWinResult.why -match 'soft_cap_5h' -and
                $multiWinResult.why -match 'soft_cap_weekly')
            $multiWinRows = @(Get-Content -LiteralPath $multiWinUsage | ForEach-Object { $_ | ConvertFrom-Json })
            $multiWinPreflight = @($multiWinRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'rerouted' }) | Select-Object -First 1
            Check 'PF12 multi-window preflight journal names all crossings' (
                $null -ne $multiWinPreflight -and
                [string]$multiWinPreflight.window -match 'five_hour' -and
                [string]$multiWinPreflight.window -match 'weekly')

            # ---- #173: probe eligibility resolves by transport NAME, not platform ----
            # PF13: an explicit probe_transport on a NON-codex row reaches preflight. The
            # back-compat inference cannot fire here (platform is not codex), so a probe
            # happening at all proves the registered NAME is what opened the seam.
            $namedFleet = Join-Path $env:BATON_HOME 'fleet-pf-named-transport.yaml'
            Set-Content -LiteralPath $namedFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: worker-named
    kind: cli
    enabled: true
    cost_tier: free
    platform: claude
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
    usage_policy:
      probe: true
      probe_transport: codex-rate-limit
      soft_cap_5h: 75
      soft_cap_weekly: 85
'@
            $namedUsage = Join-Path $env:BATON_HOME 'usage-pf-named.jsonl'
            $namedSeen = @{ calls = 0; probes = 0; names = @() }
            $namedSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $namedFleet -ToolsPath $toolsPath `
                -MaxCostTier free -UsagePath $namedUsage `
                -Dispatcher { param($pick,$prompt,$depthTier) $namedSeen.calls++; $namedSeen.names += [string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                -ProbeTransport { param($clientVersion,$timeoutSeconds) $namedSeen.probes++; New-ExecutorProbeResponse -FiveHourUsed 40 -WeeklyUsed 50 -At $probeNow }.GetNewClosure() `
                -ProbeCachePath (Join-Path $env:BATON_HOME 'cache-pf-named.jsonl') -ProbeClock $probeClock
            $namedResult = & $namedSpawner $preflightTask
            Check 'PF13 explicit probe_transport reaches preflight on a non-codex row' (
                $namedResult.ok -and $namedSeen.probes -eq 1 -and $namedSeen.calls -eq 1 -and
                $namedSeen.names[0] -eq 'worker-named')
            $namedRows = @(Get-Content -LiteralPath $namedUsage | ForEach-Object { $_ | ConvertFrom-Json })
            Check 'PF13 explicit-transport preflight journals a dispatched decision' (
                @($namedRows | Where-Object { $_.event -eq 'preflight' -and $_.outcome -eq 'dispatched' }).Count -eq 1)

            # PF14 REGRESSION GUARD: no resolvable transport must never make a provider
            # un-dispatchable. probe: true with nothing to probe with => skip preflight
            # and dispatch normally. The transport seam throws if it is ever reached.
            foreach ($noProbeCase in @(
                @{ name='no-transport'; extra='' },
                @{ name='unknown-transport'; extra='      probe_transport: transport-not-registered' }
            )) {
                $guardFleet = Join-Path $env:BATON_HOME "fleet-pf-guard-$($noProbeCase.name).yaml"
                $guardYaml = @(
                    'general_capabilities: []'
                    'providers:'
                    '  - name: worker-unprobed'
                    '    kind: cli'
                    '    enabled: true'
                    '    cost_tier: free'
                    '    platform: claude'
                    '    quality: 0.9'
                    '    capabilities: [code-gen]'
                    "    command_template: 'echo `"{{prompt}}`"'"
                    '    usage_policy:'
                    '      probe: true'
                    '      soft_cap_5h: 75'
                    '      soft_cap_weekly: 85'
                )
                if ($noProbeCase.extra) { $guardYaml += $noProbeCase.extra }
                Set-Content -LiteralPath $guardFleet -Encoding utf8NoBOM -Value $guardYaml
                $guardUsage = Join-Path $env:BATON_HOME "usage-pf-guard-$($noProbeCase.name).jsonl"
                $guardSeen = @{ calls = 0; probes = 0; names = @() }
                $guardSpawner = New-AgenticSpawner -Worktree $wt2.worktree -FleetPath $guardFleet -ToolsPath $toolsPath `
                    -MaxCostTier free -UsagePath $guardUsage `
                    -Dispatcher { param($pick,$prompt,$depthTier) $guardSeen.calls++; $guardSeen.names += [string]$pick.name; @{ stdout='ok'; stderr=''; exit_code=0; duration_s=0 } }.GetNewClosure() `
                    -ProbeTransport { param($clientVersion,$timeoutSeconds) $guardSeen.probes++; throw 'no transport resolves: the probe must not be attempted' }.GetNewClosure() `
                    -ProbeCachePath (Join-Path $env:BATON_HOME "cache-pf-guard-$($noProbeCase.name).jsonl") -ProbeClock $probeClock
                $guardResult = & $guardSpawner $preflightTask
                Check "PF14 $($noProbeCase.name): provider with no probe still dispatches normally" (
                    $guardResult.ok -and $guardSeen.probes -eq 0 -and $guardSeen.calls -eq 1 -and
                    $guardSeen.names[0] -eq 'worker-unprobed')
                $guardRows = if (Test-Path -LiteralPath $guardUsage) {
                    @(Get-Content -LiteralPath $guardUsage | ForEach-Object { $_ | ConvertFrom-Json })
                } else { @() }
                Check "PF14 $($noProbeCase.name): preflight is skipped entirely, never held" (
                    @($guardRows | Where-Object { $_.event -eq 'preflight' }).Count -eq 0 -and
                    @($guardRows | Where-Object { $_.event -eq 'limited' }).Count -eq 0)
            }
        }

        # ================= New-VerifyingSpawner (VS-series, d082 V2) =================
        # Hermetic: a temp repo with a committed .baton/verification.json (a `unit` profile
        # whose argv runs a committed pwsh check), a REAL frozen contract, and an inner
        # dispatcher that edits the worktree. Real V1 runner throughout except VS2/VS3,
        # where BATON_VERIFY_TEST_HOOK forces the verdict sequence.
        function New-VerifyFixture {
            param([string]$Name, [hashtable]$VProfile, [string]$CheckBody = 'exit 0')
            $r = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot $Name)).FullName
            Set-Content -LiteralPath (Join-Path $r 'check.ps1') -Value $CheckBody -Encoding utf8NoBOM
            $cfgD = Join-Path $r '.baton'; New-Item -ItemType Directory -Force -Path $cfgD | Out-Null
            $cfg = @{ schema = 1; profiles = @{ unit = $VProfile } }
            ConvertTo-Json -InputObject $cfg -Depth 8 | Set-Content -LiteralPath (Join-Path $cfgD 'verification.json') -Encoding utf8NoBOM
            & git -C $r add -A 2>$null | Out-Null
            & git -C $r commit -q -m 'add verify config' 2>$null | Out-Null
            $w = New-RunWorktree -RepoPath $r -RunId "$Name-wt"
            $rd = Join-Path $tmpRoot "$Name-run"; New-Item -ItemType Directory -Force -Path $rd | Out-Null
            $fc = Get-FrozenVerificationContract -RepoPath $r -BaseSha $w.base_sha -ProfileName 'unit' -WorktreeRoot $w.worktree -RunTaskDir (Join-Path $rd 'tasks/t1')
            return @{ repo = $r; wt = $w; runDir = $rd; frozen = @{ 't1' = @{ contract = $fc.contract; contract_path = $fc.contract_path } }; fcOk = $fc.ok }
        }
        function New-VerifyTask { param([string[]]$Allowed = @(), [string]$Profile = 'unit')
            [pscustomobject]@{ id = 't1'; desc = 'implement the feature'; command = ''; capability = 'code-gen'
                depends_on = @(); est_cost_tier = 'free'; reversible = $true; verify_profile = $Profile; allowed_paths = $Allowed }
        }
        $writeDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path "w-$([guid]::NewGuid()).txt") -Value $prompt -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $noopDisp2 = { param($pick, $prompt) @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $forbidDisp = { param($pick, $prompt)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'forbidden.txt') -Value 'x' -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }
        $passProfile = @{ argv = @('pwsh', '-NoProfile', '-File', 'check.ps1'); proves = 'the unit check passes' }
        function Get-Attempts { param($rd) @(Get-Content -LiteralPath (Join-Path $rd 'tasks/t1/attempts.jsonl')) }

        # VS1 pass: check exits 0, inner writes a file -> ok, verdict pass, 1 attempt row.
        $fx1 = New-VerifyFixture -Name 'vs1' -VProfile $passProfile
        Check 'VS0 fixture frozen contract resolved' ($fx1.fcOk -eq $true)
        $in1 = New-AgenticSpawner -Worktree $fx1.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx1.runDir -Dispatcher $writeDisp
        $vs1 = New-VerifyingSpawner -InnerSpawner $in1 -Worktree $fx1.wt.worktree -BaseSha $fx1.wt.base_sha -RunDir $fx1.runDir -FrozenContracts $fx1.frozen
        $rv1 = & $vs1 (New-VerifyTask)
        Check 'VS1 ok true' ($rv1.ok -eq $true)
        Check 'VS1 verdict pass' ($rv1.verification.verdict -eq 'pass')
        Check 'VS1 not retried' ($rv1.verification.retried -eq $false)
        Check 'VS1 verification.json written' (Test-Path (Join-Path $fx1.runDir 'tasks/t1/verification.json'))
        $a1rows = @(Get-Attempts $fx1.runDir)
        Check 'VS1 one attempt row' ($a1rows.Count -eq 1)
        Check 'VS1 attempt first_try true' ((@($a1rows)[0] | ConvertFrom-Json).first_try -eq $true)

        # VS2 retry-then-pass (forced verdict via hook; inner writes each attempt -> grew).
        $hook2 = Join-Path $tmpRoot 'hook2.ps1'
        Set-Content -LiteralPath $hook2 -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) { return @{ verdict='pass'; ok=$true; grade='bounded'; failure_category=''; proves='hooked pass'; output_path=''; duration_ms=5 } }
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $fx2 = New-VerifyFixture -Name 'vs2' -VProfile $passProfile
        $in2 = New-AgenticSpawner -Worktree $fx2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx2.runDir -Dispatcher $writeDisp
        $vs2 = New-VerifyingSpawner -InnerSpawner $in2 -Worktree $fx2.wt.worktree -BaseSha $fx2.wt.base_sha -RunDir $fx2.runDir -FrozenContracts $fx2.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook2
        try { $rv2 = & $vs2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS2 retried true' ($rv2.verification.retried -eq $true)
        Check 'VS2 rework_cycles 1 (retry subsumed)' ($rv2.verification.rework_cycles -eq 1)
        Check 'VS2 final ok true' ($rv2.ok -eq $true)
        Check 'VS2 two attempt rows' (@(Get-Attempts $fx2.runDir).Count -eq 2)
        Check 'VS2 first_failure_category check-failed' ($rv2.verification.first_failure_category -eq 'check-failed')
        Check 'VS2 rework evidence file written' (Test-Path -LiteralPath (Join-Path $fx2.runDir 'tasks/t1/rework-evidence-1.md'))
        Check 'VS2 final rework preserves resolved depth policy metadata' (
            $rv2.stakes -eq 'standard' -and $rv2.stakes_basis -eq 'legacy plan omitted stakes' -and
            $rv2.depth_tier -eq 'med' -and $rv2.selection_mode -eq 'economy' -and
            $rv2.tier_cap -eq 'free' -and $rv2.depth_applied -eq $true -and
            $rv2.selected_cost_tier -eq 'free')

        # VS3 retry-then-fail (hook fails both attempts).
        $hook3 = Join-Path $tmpRoot 'hook3.ps1'
        Set-Content -LiteralPath $hook3 -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $fx3 = New-VerifyFixture -Name 'vs3' -VProfile $passProfile
        $in3 = New-AgenticSpawner -Worktree $fx3.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx3.runDir -Dispatcher $writeDisp
        $vs3 = New-VerifyingSpawner -InnerSpawner $in3 -Worktree $fx3.wt.worktree -BaseSha $fx3.wt.base_sha -RunDir $fx3.runDir -FrozenContracts $fx3.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook3
        try { $rv3 = & $vs3 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS3 not ok' ($rv3.ok -eq $false)
        Check 'VS3 verdict fail' ($rv3.verification.verdict -eq 'fail')
        Check 'VS3 retried true' ($rv3.verification.retried -eq $true)
        Check 'VS3 rework_cycles 1' ($rv3.verification.rework_cycles -eq 1)
        Check 'VS3 two attempt rows' (@(Get-Attempts $fx3.runDir).Count -eq 2)

        # VS4 scope-violation -> fail closed, NO rework (inner writes an out-of-scope file).
        $fx4 = New-VerifyFixture -Name 'vs4' -VProfile $passProfile
        $in4 = New-AgenticSpawner -Worktree $fx4.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx4.runDir -Dispatcher $forbidDisp
        $vs4 = New-VerifyingSpawner -InnerSpawner $in4 -Worktree $fx4.wt.worktree -BaseSha $fx4.wt.base_sha -RunDir $fx4.runDir -FrozenContracts $fx4.frozen
        $rv4 = & $vs4 (New-VerifyTask -Allowed @('allowed.txt'))
        Check 'VS4 verdict scope-violation' ($rv4.verification.verdict -eq 'scope-violation')
        Check 'VS4 not ok' ($rv4.ok -eq $false)
        Check 'VS4 not retried' ($rv4.verification.retried -eq $false)
        Check 'VS4 rework_cycles 0' ($rv4.verification.rework_cycles -eq 0)
        Check 'VS4 exactly one attempt row (no rework)' (@(Get-Attempts $fx4.runDir).Count -eq 1)

        # VS5 A5 no-change: check exits 0 but inner writes nothing -> demoted to no-change,
        # rework-eligible (2 rows), still fails.
        $fx5 = New-VerifyFixture -Name 'vs5' -VProfile $passProfile
        $in5 = New-AgenticSpawner -Worktree $fx5.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx5.runDir -Dispatcher $noopDisp2
        $vs5 = New-VerifyingSpawner -InnerSpawner $in5 -Worktree $fx5.wt.worktree -BaseSha $fx5.wt.base_sha -RunDir $fx5.runDir -FrozenContracts $fx5.frozen
        $rv5 = & $vs5 (New-VerifyTask)
        Check 'VS5 verdict fail' ($rv5.verification.verdict -eq 'fail')
        Check 'VS5 failure_category no-change' ($rv5.verification.failure_category -eq 'no-change')
        Check 'VS5 first_failure no-change' ($rv5.verification.first_failure_category -eq 'no-change')
        Check 'VS5 retried (two rows)' (@(Get-Attempts $fx5.runDir).Count -eq 2)

        # VS6 unverified: task with verify_profile='' delegates to inner, unverified=true,
        # no verification key.
        $fx6 = New-VerifyFixture -Name 'vs6' -VProfile $passProfile
        $in6 = New-AgenticSpawner -Worktree $fx6.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx6.runDir -Dispatcher $writeDisp
        $vs6 = New-VerifyingSpawner -InnerSpawner $in6 -Worktree $fx6.wt.worktree -BaseSha $fx6.wt.base_sha -RunDir $fx6.runDir -FrozenContracts @{}
        $rv6 = & $vs6 (New-VerifyTask -Profile '')
        Check 'VS6 unverified true' ($rv6.unverified -eq $true)
        Check 'VS6 no verification key' (-not $rv6.ContainsKey('verification'))
        Check 'VS6 delegated inner ok' ($rv6.ok -eq $true)

        # VS7 evidence prompt: carries the failure category, the fix-in-place instruction,
        # the original task, and the WHOLE prompt stays <=965 UTF-8 bytes even with a
        # flooding excerpt or an oversized desc (review I2 — survives inline instruments).
        $utf8 = [System.Text.Encoding]::UTF8
        $vs7out = Join-Path $tmpRoot 'vs7-out.txt'
        Set-Content -LiteralPath $vs7out -Value ('E' * 5000) -Encoding utf8NoBOM
        $vs7prompt = Format-VerifyEvidencePrompt -TaskDesc 'Original task text' -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out
        Check 'VS7 includes failure category' ($vs7prompt -match 'check-failed')
        Check 'VS7 includes fix-in-place instruction' ($vs7prompt -match 'Fix the EXISTING work')
        Check 'VS7 includes original task' ($vs7prompt -match 'Original task text')
        Check 'VS7 whole prompt <=965 UTF-8 bytes (flooding excerpt)' ($utf8.GetByteCount($vs7prompt) -le 965)
        $vs7big = Format-VerifyEvidencePrompt -TaskDesc ('D' * 4000) -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out
        Check 'VS7 whole prompt <=965 UTF-8 bytes (oversized desc)' ($utf8.GetByteCount($vs7big) -le 965)
        # An empty desc must NOT crash the retry (mandatory [string] rejects '' — the house
        # trap the V2 live smoke surfaced; a desc-less task must degrade, not kill the run).
        $vs7empty = $null
        $vs7ok = $true
        try { $vs7empty = Format-VerifyEvidencePrompt -TaskDesc '' -Verification @{ failure_category = 'check-failed' } -OutputPath $vs7out } catch { $vs7ok = $false }
        Check 'VS7 empty desc does not throw' ($vs7ok -and $null -ne $vs7empty)

        # VS8 (review I1/edge#4): add-then-revert nets to ZERO vs the pre-task baseline —
        # must NOT pass. Attempt 1 adds a file (hook forces check-failed -> retry); attempt 2
        # deletes it back to the task-start tree (hook forces pass). A5 must demote the
        # attempt-2 pass to no-change because the diff vs TASK START (not vs attempt 1) is empty.
        $hookPF = Join-Path $tmpRoot 'hookPF.ps1'
        Set-Content -LiteralPath $hookPF -Encoding utf8NoBOM -Value @'
function Invoke-TestVerify { param($Task, $Attempt, $Grew)
    if ($Attempt -ge 2) { return @{ verdict='pass'; ok=$true; grade='bounded'; failure_category=''; proves='hooked pass'; output_path=''; duration_ms=5 } }
    return @{ verdict='fail'; ok=$false; grade='invalid'; failure_category='check-failed'; proves='hooked'; output_path=''; duration_ms=5 }
}
'@
        $ctr8 = Join-Path $tmpRoot 'ctr8.txt'; Set-Content -LiteralPath $ctr8 -Value '0' -Encoding utf8NoBOM
        $disp8 = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctr8 -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctr8 -Value "$n" -Encoding utf8NoBOM
            $target = Join-Path (Get-Location).Path 'x8.txt'
            if ($n -eq 1) { Set-Content -LiteralPath $target -Value 'v1' -Encoding utf8NoBOM }
            else { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fx8 = New-VerifyFixture -Name 'vs8' -VProfile $passProfile
        $in8 = New-AgenticSpawner -Worktree $fx8.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx8.runDir -Dispatcher $disp8
        $vs8 = New-VerifyingSpawner -InnerSpawner $in8 -Worktree $fx8.wt.worktree -BaseSha $fx8.wt.base_sha -RunDir $fx8.runDir -FrozenContracts $fx8.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hookPF
        try { $rv8 = & $vs8 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS8 add-then-revert does NOT pass (net-zero vs task start)' ($rv8.ok -eq $false)
        Check 'VS8 verdict fail' ($rv8.verification.verdict -eq 'fail')
        Check 'VS8 demoted to no-change' ($rv8.verification.failure_category -eq 'no-change')

        # VS9 (review I1/edge#4): a legitimate repair whose attempt 2 makes NO further edit
        # must PASS. Attempt 1 makes the real change (hook forces check-failed -> retry);
        # attempt 2 edits nothing and the check passes. The diff vs TASK START is non-empty,
        # so A5 must NOT demote it (the old per-attempt baseline false-failed this).
        $ctr9 = Join-Path $tmpRoot 'ctr9.txt'; Set-Content -LiteralPath $ctr9 -Value '0' -Encoding utf8NoBOM
        $disp9 = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctr9 -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctr9 -Value "$n" -Encoding utf8NoBOM
            if ($n -eq 1) { Set-Content -LiteralPath (Join-Path (Get-Location).Path 'x9.txt') -Value 'real change' -Encoding utf8NoBOM }
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fx9 = New-VerifyFixture -Name 'vs9' -VProfile $passProfile
        $in9 = New-AgenticSpawner -Worktree $fx9.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fx9.runDir -Dispatcher $disp9
        $vs9 = New-VerifyingSpawner -InnerSpawner $in9 -Worktree $fx9.wt.worktree -BaseSha $fx9.wt.base_sha -RunDir $fx9.runDir -FrozenContracts $fx9.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hookPF
        try { $rv9 = & $vs9 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS9 legit no-further-edit repair PASSES (non-empty vs task start)' ($rv9.ok -eq $true)
        Check 'VS9 verdict pass' ($rv9.verification.verdict -eq 'pass')
        Check 'VS9 retried true' ($rv9.verification.retried -eq $true)

        # VS10 (review M2): spend accrues across BOTH attempts. Hook forces retry-then-pass;
        # a dispatcher stamps a distinct spend per attempt; the returned spend is their sum.
        $ctrS = Join-Path $tmpRoot 'ctrS.txt'; Set-Content -LiteralPath $ctrS -Value '0' -Encoding utf8NoBOM
        $dispS = {
            param($pick, $prompt)
            $n = [int]((Get-Content -LiteralPath $ctrS -Raw).Trim()) + 1
            Set-Content -LiteralPath $ctrS -Value "$n" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path (Get-Location).Path "s-$n.txt") -Value "$n" -Encoding utf8NoBOM
            @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $fxS = New-VerifyFixture -Name 'vsS' -VProfile $passProfile
        # New-AgenticSpawner sets spend from the cost estimate; both attempts share the same
        # tier, so summed spend == 2x a single attempt. Assert attempt-2 spend was not dropped.
        $inS = New-AgenticSpawner -Worktree $fxS.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxS.runDir -Dispatcher $dispS
        $vsS = New-VerifyingSpawner -InnerSpawner $inS -Worktree $fxS.wt.worktree -BaseSha $fxS.wt.base_sha -RunDir $fxS.runDir -FrozenContracts $fxS.frozen
        $inS1 = & $inS (New-VerifyTask)   # measure a single inner attempt's spend in isolation
        $singleSpend = [double]$inS1.spend
        Set-Content -LiteralPath $ctrS -Value '0' -Encoding utf8NoBOM
        $fxS2 = New-VerifyFixture -Name 'vsS2' -VProfile $passProfile
        $inS2 = New-AgenticSpawner -Worktree $fxS2.wt.worktree -FleetPath $fleetPath -ToolsPath $toolsPath -RunDir $fxS2.runDir -Dispatcher $dispS
        $vsS2 = New-VerifyingSpawner -InnerSpawner $inS2 -Worktree $fxS2.wt.worktree -BaseSha $fxS2.wt.base_sha -RunDir $fxS2.runDir -FrozenContracts $fxS2.frozen
        $env:BATON_VERIFY_TEST_HOOK = $hook2
        try { $rvS = & $vsS2 (New-VerifyTask) } finally { Remove-Item env:BATON_VERIFY_TEST_HOOK -ErrorAction SilentlyContinue }
        Check 'VS10 retried true' ($rvS.verification.retried -eq $true)
        Check 'VS10 spend summed across both attempts' ([Math]::Abs([double]$rvS.spend - (2 * $singleSpend)) -lt 0.0001)

        # ---- Diff-apply eligibility predicates (d103 / #168) ----
        # A text-transport provider has no filesystem harness, but it can still take
        # edit work when it opts in: Baton reads the files and applies the model's
        # SEARCH/REPLACE blocks. The d091 transport veto on Test-ProviderAgentic is
        # untouched — this is a SEPARATE capability, not a relaxation of that one.
        $daRow = @{ name = 'local-host-a'; kind = 'http'; diff_apply = $true; platform = 'codex' }
        Check 'DA1 http + diff_apply opt-in is a diff-apply provider' (
            Test-ProviderDiffApply -Provider @{ kind = 'http'; diff_apply = $true })
        Check 'DA2 stdio-json + diff_apply opt-in is a diff-apply provider' (
            Test-ProviderDiffApply -Provider @{ kind = 'stdio-json'; diff_apply = $true })
        Check 'DA3 http without diff_apply is not a diff-apply provider' (
            -not (Test-ProviderDiffApply -Provider @{ kind = 'http' }))
        Check 'DA4 http with diff_apply:false is not a diff-apply provider' (
            -not (Test-ProviderDiffApply -Provider @{ kind = 'http'; diff_apply = $false }))
        Check 'DA5 cli is never a diff-apply provider (already has hands)' (
            -not (Test-ProviderDiffApply -Provider @{ kind = 'cli'; diff_apply = $true }))
        Check 'DA6 diff_apply does NOT make a provider agentic (A9/A10 invariant holds)' (
            -not (Test-ProviderAgentic -Provider $daRow))
        Check 'DA7 diff-apply provider is edit-capable' (
            Test-ProviderEditCapable -Provider $daRow)
        Check 'DA8 agentic cli provider is edit-capable' (
            Test-ProviderEditCapable -Provider @{ name = 'cli-host-a'; kind = 'cli'; platform = 'claude' })
        Check 'DA9 local cli without opt-in is not edit-capable' (
            -not (Test-ProviderEditCapable -Provider @{ name = 'cli-host-b'; kind = 'cli'; platform = 'local' }))

        # DA10 (#168 regression guard): a fleet whose ONLY code-gen provider is a
        # local-tier diff-apply provider must report a 'local' floor. Before d103 this
        # returned UNAVAILABLE, which made every stakes=low task undispatchable
        # (Resolve-TaskDepthPolicy caps low at 'free', and the floor said 'paid').
        $daFleet = Join-Path $tmpRoot 'da-floor-fleet.yaml'
        Set-Content -LiteralPath $daFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-host-a
    kind: http
    enabled: true
    cost_tier: local
    platform: local
    diff_apply: true
    base_url: 'http://127.0.0.1:1'
    model_default: model-small
    capabilities: [code-gen]
'@
        Check 'DA10 #168 guard: local diff-apply provider gives code-gen a local floor' (
            (Get-CapabilityCostTierFloor -Capability 'code-gen' -FleetPath $daFleet) -eq 'local')
        Check 'DA10b diff-apply provider is not excluded as ineligible' (
            @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'local' -FleetPath $daFleet `
                -UsagePath (Join-Path $tmpRoot 'da-no-usage.jsonl') |
                Where-Object { $_.name -eq 'local-host-a' -and $_.reason -match 'not edit-eligible' }).Count -eq 0)

        # DA11: the exclusion reason has to tell an operator WHY a text-transport
        # provider was dropped — the remedy is the opt-in, not a tier or stakes change.
        $daFleetNoOptIn = Join-Path $tmpRoot 'da-no-optin-fleet.yaml'
        Set-Content -LiteralPath $daFleetNoOptIn -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-host-b
    kind: http
    enabled: true
    cost_tier: local
    platform: local
    base_url: 'http://127.0.0.1:1'
    model_default: model-small
    capabilities: [code-gen]
'@
        $daExcl = @(Get-EditPoolExclusions -Capability 'code-gen' -TierCap 'local' -FleetPath $daFleetNoOptIn `
            -UsagePath (Join-Path $tmpRoot 'da-no-usage.jsonl'))
        Check 'DA11 text-transport without opt-in names the missing diff_apply opt-in' (
            @($daExcl | Where-Object { $_.name -eq 'local-host-b' -and $_.stage -eq 'static' -and
                $_.reason -eq 'not edit-eligible (no diff_apply opt-in)' }).Count -eq 1)

        # ---- E-series (d103 Task 6): the diff-apply dispatch branch, end to end ----
        # Its own repo/worktree/fleet/run dir so it cannot disturb the fixtures above.
        # Placeholder provider names only — never a real model id, endpoint, or host.
        $daRepo = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $tmpRoot 'da-sp')).FullName
        $daWt = (New-RunWorktree -RepoPath $daRepo -RunId 'go-da1').worktree
        $daRunDir = Join-Path $tmpRoot 'run-da1'
        New-Item -ItemType Directory -Force -Path $daRunDir | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $daWt 'src') | Out-Null
        $daGreet = Join-Path $daWt 'src/greet.txt'
        $daOther = Join-Path $daWt 'src/other.txt'
        Set-Content -LiteralPath $daGreet -Value 'Hello' -Encoding utf8NoBOM
        # Over the 24000-byte default context envelope, so E7 can never dispatch.
        Set-Content -LiteralPath (Join-Path $daWt 'src/big.txt') -Value ('x' * 30000) -Encoding utf8NoBOM

        $daDispatchFleet = Join-Path $env:BATON_HOME 'fleet-diff-apply-dispatch.yaml'
        Set-Content -LiteralPath $daDispatchFleet -Encoding utf8NoBOM -Value @'
general_capabilities: []
providers:
  - name: local-host-a
    kind: http
    enabled: true
    cost_tier: local
    platform: local
    quality: 0.2
    diff_apply: true
    base_url: 'http://127.0.0.1:1'
    model_default: model-small
    host: host-a
    stack: stack-a
    load_profile: model-large
    vram_gb: 8
    capabilities: [code-gen]
  - name: cli-host-a
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
        $daObsPath = Join-Path $env:BATON_HOME 'diff-apply-observations.jsonl'
        $daScope = @('src/greet.txt')

        $daGoodBlocks = @'
Here is the change.

FILE: src/greet.txt
<<<<<<< SEARCH
Hello
=======
Goodbye
>>>>>>> REPLACE
'@
        $daSeen = @{ calls = 0; prompt = '' }
        $daGoodDisp = {
            param($pick, $prompt, $depthTier)
            $daSeen.calls++
            $daSeen.prompt = [string]$prompt
            return @{ stdout = $daGoodBlocks; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()

        # One usage journal per case: a failed attempt writes a cooldown, and a shared
        # journal would route-around the provider for every case after the first
        # failure. Same per-case isolation the UF/PF fixtures above use.
        $daNewSpawner = {
            param($DispatcherBlock, $Cap, $Tag)
            New-AgenticSpawner -Worktree $daWt -FleetPath $daDispatchFleet -ToolsPath $toolsPath `
                -MaxCostTier $Cap -RunDir $daRunDir -Dispatcher $DispatcherBlock `
                -UsagePath (Join-Path $env:BATON_HOME "usage-diff-apply-$Tag.jsonl")
        }.GetNewClosure()

        $daTask = { param($Id, $Paths) [pscustomobject]@{
            id = $Id; desc = 'replace the greeting'; capability = 'code-gen'
            stakes = 'standard'; stakes_basis = 'ordinary bounded feature'; allowed_paths = $Paths } }

        # E1/E2/E3 — a text-only provider actually implements the task.
        $daR1 = & (& $daNewSpawner $daGoodDisp 'local' 'e1') (& $daTask 'da-e1' $daScope)
        Check 'E1 diff-apply dispatch succeeds and routes to the text-only provider' (
            $daR1.ok -eq $true -and $daR1.chose -eq 'local-host-a')
        Check 'E1b the model edit landed on disk' (
            (Get-Content -Raw -LiteralPath $daGreet) -match 'Goodbye')
        Check 'E1c the model was handed the file contents, not the agentic prompt' (
            $daSeen.prompt -match 'SEARCH' -and $daSeen.prompt -match 'Hello')
        Check 'E2 why records the diff grew' ($daR1.why -match 'diff grew')
        Check 'E3 per-task diff written under RunDir' (
            Test-Path (Join-Path $daRunDir 'tasks/da-e1.diff'))

        # E4 — prose with no blocks is a FAILURE, not a no-change pass.
        $daBefore = [System.IO.File]::ReadAllBytes($daGreet)
        $daProseDisp = { param($pick, $prompt, $depthTier)
            @{ stdout = 'I would edit the greeting, but here is prose instead.'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $daR4 = & (& $daNewSpawner $daProseDisp 'local' 'e4') (& $daTask 'da-e4' $daScope)
        Check 'E4 prose-only output fails the task' ($daR4.ok -eq $false)
        Check 'E4b worktree byte-identical after a prose-only reply' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$daBefore, [byte[]][System.IO.File]::ReadAllBytes($daGreet)))

        # E5 — a SEARCH that does not match changes nothing.
        $daNoMatchDisp = { param($pick, $prompt, $depthTier)
            @{ stdout = @'
FILE: src/greet.txt
<<<<<<< SEARCH
this text is not in the file
=======
something else
>>>>>>> REPLACE
'@; stderr = ''; exit_code = 0; duration_s = 0 } }
        $daR5 = & (& $daNewSpawner $daNoMatchDisp 'local' 'e5') (& $daTask 'da-e5' $daScope)
        Check 'E5 unmatched SEARCH fails the task' ($daR5.ok -eq $false)
        Check 'E5b worktree byte-identical after an unmatched SEARCH' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$daBefore, [byte[]][System.IO.File]::ReadAllBytes($daGreet)))

        # E6 — a write outside allowed_paths is rejected by the scope oracle.
        $daOutOfScopeDisp = { param($pick, $prompt, $depthTier)
            @{ stdout = @'
FILE: src/other.txt
<<<<<<< SEARCH
=======
sneaky new file
>>>>>>> REPLACE
'@; stderr = ''; exit_code = 0; duration_s = 0 } }
        $daR6 = & (& $daNewSpawner $daOutOfScopeDisp 'local' 'e6') (& $daTask 'da-e6' $daScope)
        Check 'E6 out-of-scope write fails the task' ($daR6.ok -eq $false)
        Check 'E6b the out-of-scope file was never created' (-not (Test-Path -LiteralPath $daOther))
        Check 'E6c worktree byte-identical after an out-of-scope block' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$daBefore, [byte[]][System.IO.File]::ReadAllBytes($daGreet)))

        # E7 — over the size envelope: refused BEFORE any dispatch.
        $daEnvSeen = @{ calls = 0 }
        $daEnvDisp = { param($pick, $prompt, $depthTier)
            $daEnvSeen.calls++
            @{ stdout = ''; stderr = ''; exit_code = 0; duration_s = 0 } }.GetNewClosure()
        $daR7 = & (& $daNewSpawner $daEnvDisp 'local' 'e7') (& $daTask 'da-e7' @('src/big.txt'))
        Check 'E7 over-envelope task fails' ($daR7.ok -eq $false)
        Check 'E7b failure names the diff-apply envelope' ($daR7.why -match 'diff-apply envelope')
        Check 'E7c the model was never dispatched for an over-envelope task' ($daEnvSeen.calls -eq 0)

        # E8 — telemetry: the size-vs-outcome record the envelope will be tuned from.
        $daObsRows = @()
        if (Test-Path -LiteralPath $daObsPath) {
            $daObsRows = @(Get-Content -LiteralPath $daObsPath |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json })
        }
        Check 'E8 success row carries provider, context_bytes and file_count' (
            @($daObsRows | Where-Object {
                $_.provider -eq 'local-host-a' -and $_.task_id -eq 'da-e1' -and
                [int]$_.file_count -eq 1 -and [long]$_.context_bytes -gt 0 -and
                $_.parse_result -eq 'ok' -and $_.apply_result -eq 'ok' -and [int]$_.blocks_applied -eq 1
            }).Count -eq 1)
        Check 'E8b failure rows record how the attempt died' (
            @($daObsRows | Where-Object { $_.task_id -eq 'da-e4' -and $_.parse_result -eq 'empty' }).Count -eq 1 -and
            @($daObsRows | Where-Object { $_.task_id -eq 'da-e5' -and $_.apply_result -eq 'search-not-found' }).Count -eq 1 -and
            @($daObsRows | Where-Object { $_.task_id -eq 'da-e6' -and $_.apply_result -eq 'scope-rejected' }).Count -eq 1)
        Check 'E8c envelope row carries the size evidence that refused it' (
            @($daObsRows | Where-Object {
                $_.task_id -eq 'da-e7' -and $_.apply_result -eq 'envelope-exceeded' -and
                [long]$_.context_bytes -gt 24000
            }).Count -eq 1)
        Check 'E8d rows carry run_id and model_version provenance' (
            @($daObsRows | Where-Object { $_.task_id -eq 'da-e1' -and $_.run_id -eq 'run-da1' -and
                $_.model_version -eq 'model-small' }).Count -eq 1)

        # E9 — regression guard: an agentic cli provider in the SAME fleet is untouched
        # by this task. Its dispatcher returns prose (which the diff-apply path rejects)
        # and edits its cwd (which only the agentic path provides).
        $daCliDisp = { param($pick, $prompt, $depthTier)
            Set-Content -LiteralPath (Join-Path (Get-Location).Path 'made-by-agentic.txt') -Value 'work' -Encoding utf8NoBOM
            @{ stdout = 'prose only, no blocks'; stderr = ''; exit_code = 0; duration_s = 0 } }
        $daHighTask = [pscustomobject]@{ id = 'da-e9'; desc = 'ship it'; capability = 'code-gen'
            stakes = 'high'; stakes_basis = 'authentication boundary'; allowed_paths = $daScope }
        $daR9 = & (& $daNewSpawner $daCliDisp 'paid' 'e9') $daHighTask
        Check 'E9 agentic provider still takes the old path' (
            $daR9.ok -eq $true -and $daR9.chose -eq 'cli-host-a')
        Check 'E9b agentic dispatch still runs with cwd = the worktree' (
            Test-Path (Join-Path $daWt 'made-by-agentic.txt'))

        # E10 — return shape parity with Invoke-AgenticDispatchAttempt, plus prompt_sent.
        $daShape = Invoke-DiffApplyAttempt -Candidate ([pscustomobject]@{ name = 'local-host-a'; kind = 'http' }) `
            -TaskDesc 'replace the greeting' -InputBlock '' -AllowedPaths $daScope -DepthTier 'med' `
            -Worktree $daWt -FleetPath $daDispatchFleet -UsagePath (Join-Path $env:BATON_HOME 'usage-diff-apply-e10.jsonl') `
            -RunDir $daRunDir -TaskId 'da-e10' -Dispatcher $daNoMatchDisp
        $daShapeKeys = @($daShape.Keys | Sort-Object) -join ','
        Check 'E10 result shape is result + dispatch_error + prompt_sent' (
            $daShapeKeys -eq 'dispatch_error,prompt_sent,result')
        Check 'E10b result carries stdout/stderr/exit_code/duration_s' (
            $daShape.result.Contains('stdout') -and $daShape.result.Contains('stderr') -and
            $daShape.result.Contains('exit_code') -and $daShape.result.Contains('duration_s'))
        Check 'E10c prompt_sent is the diff-apply prompt that was dispatched' (
            [string]$daShape.prompt_sent -match 'SEARCH')

        # E11 — the prompt-crossing defect: the spawner must measure the prompt it
        # ACTUALLY sent, never the agentic prompt that was built but never dispatched.
        Set-Content -LiteralPath $daGreet -Value 'Hello' -Encoding utf8NoBOM
        $daPbSeen = @{ bytes = $null }
        $savedObsFn = (Get-Item -LiteralPath 'Function:Get-AgenticUsageObservation').ScriptBlock
        function Get-AgenticUsageObservation {
            param(
                $Result,
                [Parameter(Mandatory)][string]$Worker,
                [Parameter(Mandatory)][string]$UsagePath,
                [Nullable[long]]$PromptBytes = $null
            )
            $daPbSeen.bytes = $PromptBytes
            return @{ classification = 'ok'; hard_failover = $false; prompt_bytes = $PromptBytes }
        }
        try {
            $daR11 = & (& $daNewSpawner $daGoodDisp 'local' 'e11') (& $daTask 'da-e11' $daScope)
        } finally {
            Set-Item -Path 'Function:Get-AgenticUsageObservation' -Value $savedObsFn
        }
        $daAgenticPrompt = Build-AgenticWorkerPrompt -TaskDesc 'replace the greeting' -InputBlock '' -AllowedPaths $daScope
        Check 'E11 diff-apply run still succeeds under the observation probe' ($daR11.ok -eq $true)
        Check 'E11b observed prompt_bytes is the diff-apply prompt' (
            $null -ne $daPbSeen.bytes -and
            [long]$daPbSeen.bytes -eq (Get-Utf8ByteCount -Text $daSeen.prompt))
        Check 'E11c observed prompt_bytes is NOT the agentic prompt that was never sent' (
            [long]$daPbSeen.bytes -ne (Get-Utf8ByteCount -Text $daAgenticPrompt))

        # E12 — max_blocks is ENFORCED, not merely advertised. The prompt tells the
        # model "emit at most N blocks"; a model that ignores it must be refused
        # after parsing and BEFORE applying, or the size envelope (the mechanism for
        # discovering how small a task must be for a cheap model) measures nothing.
        Set-Content -LiteralPath $daGreet -Value 'Hello' -Encoding utf8NoBOM
        $daBefore12 = [System.IO.File]::ReadAllBytes($daGreet)
        # Nine blocks against the default max_blocks of 8. Every block is INDIVIDUALLY
        # valid and they chain (each SEARCHes what the previous one wrote), so an
        # unenforced cap applies all nine and the task succeeds — the check has to
        # discriminate on the cap, not on a block that happens to be broken.
        $daManyBlocks = ((1..9) | ForEach-Object {
            $from = if ($_ -eq 1) { 'Hello' } else { "step$($_ - 1)" }
            "FILE: src/greet.txt`n<<<<<<< SEARCH`n$from`n=======`nstep$_`n>>>>>>> REPLACE"
        }) -join "`n"
        $daManySeen = @{ calls = 0 }
        $daManyDisp = {
            param($pick, $prompt, $depthTier)
            $daManySeen.calls++
            @{ stdout = $daManyBlocks; stderr = ''; exit_code = 0; duration_s = 0 }
        }.GetNewClosure()
        $daR12 = & (& $daNewSpawner $daManyDisp 'local' 'e12') (& $daTask 'da-e12' $daScope)
        Check 'E12 too-many-blocks response fails the task' ($daR12.ok -eq $false)
        Check 'E12b failure names the diff-apply envelope' ($daR12.why -match 'diff-apply envelope')
        Check 'E12c worktree byte-identical after an over-cap response' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$daBefore12, [byte[]][System.IO.File]::ReadAllBytes($daGreet)))
        $daObsRows12 = @()
        if (Test-Path -LiteralPath $daObsPath) {
            $daObsRows12 = @(Get-Content -LiteralPath $daObsPath |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json })
        }
        Check 'E12d observation row is envelope-exceeded with the emitted block count' (
            @($daObsRows12 | Where-Object {
                $_.task_id -eq 'da-e12' -and $_.apply_result -eq 'envelope-exceeded' -and
                [int]$_.blocks_emitted -eq 9 -and [int]$_.blocks_applied -eq 0
            }).Count -eq 1)

        # ================================================================
        # C-series: the coordination gate (resource facet) wired into local
        # dispatch. Each case owns its BATON_HOME so store presence/absence is
        # exact and nothing here can reach the operator's real ~/.baton.
        # Placeholder names only — host-a / stack-a / stack-b / model-large.
        # ================================================================
        $cOuterHome = $env:BATON_HOME
        try {
            $cRoot = Join-Path $tmpRoot 'coord'
            New-Item -ItemType Directory -Force -Path $cRoot | Out-Null
            $cRepo = New-TempRepo -Root (New-Item -ItemType Directory -Force -Path (Join-Path $cRoot 'repo-root')).FullName
            $cWt = (New-RunWorktree -RepoPath $cRepo -RunId 'go-coord').worktree
            $cRunDir = Join-Path $cRoot 'run-coord'
            New-Item -ItemType Directory -Force -Path $cRunDir | Out-Null
            $cTools = Join-Path $cRoot 'tools-absent.yaml'

            # timeout_s is declared so C9 can assert the lease is derived from it.
            $cFleet = Join-Path $cRoot 'fleet-local.yaml'
            Set-Content -LiteralPath $cFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: local-a
    kind: cli
    enabled: true
    cost_tier: local
    platform: local
    agentic: true
    quality: 0.9
    host: host-a
    stack: stack-a
    load_profile: model-large
    vram_gb: 8
    timeout_s: 3600
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $cPaidFleet = Join-Path $cRoot 'fleet-paid.yaml'
            Set-Content -LiteralPath $cPaidFleet -Encoding utf8NoBOM -Value @'
general_capabilities: [code-gen]
providers:
  - name: paid-a
    kind: cli
    enabled: true
    cost_tier: paid
    platform: codex
    quality: 0.9
    capabilities: [code-gen]
    command_template: 'echo "{{prompt}}"'
'@
            $cTask = [pscustomobject]@{ id = 'c-task'; desc = 'write the feature'; capability = 'code-gen'
                stakes = 'standard'; stakes_basis = 'ordinary bounded feature' }

            # Plain scriptblocks throughout (never .GetNewClosure()): a new closure
            # captures only the immediate local scope and would blank $cRoot here.
            $cNewHome = {
                param([string]$Name, [switch]$WithCapacity)
                $h = Join-Path $cRoot $Name
                New-Item -ItemType Directory -Force -Path $h | Out-Null
                if ($WithCapacity) {
                    New-Item -ItemType Directory -Force -Path (Join-Path $h 'coordination') | Out-Null
                    Set-Content -LiteralPath (Join-Path $h 'coordination/config.json') -Encoding utf8NoBOM `
                        -Value '{ "hosts": { "host-a": { "vram_gb": 48 } } }'
                }
                return $h
            }

            # ---- C1: granted -> the dispatch happens and the worktree changes ----
            $cHomeOk = & $cNewHome 'home-ok' -WithCapacity
            $env:BATON_HOME = $cHomeOk
            $cSeen = @{ calls = 0 }
            $cEditDisp = {
                param($pick, $prompt, $depthTier)
                $cSeen.calls++
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'coord-edit.txt') -Value 'work' -Encoding utf8NoBOM
                @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
            }
            $cSp1 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cEditDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c1.jsonl')
            $cR1 = & $cSp1 $cTask
            Check 'C1 local dispatch under a granted claim succeeds' (
                $cR1.ok -eq $true -and $cR1.chose -eq 'local-a' -and $cSeen.calls -eq 1)
            Check 'C1b the worktree changed exactly as it did before the gate existed' (
                (Test-Path (Join-Path $cWt 'coord-edit.txt')) -and ($cR1.why -match 'diff grew'))
            Check 'C1c the coordination journal recorded a grant for host-a/stack-a' (
                @(Get-CoordJournal -BatonHome $cHomeOk | Where-Object {
                    $_.event -eq 'grant' -and $_.host -eq 'host-a' -and $_.stack -eq 'stack-a' -and
                    $_.load_profile -eq 'model-large' }).Count -ge 1)

            # ---- C2: the claim is RELEASED after a successful dispatch ----
            # Stack exclusivity is the proof: a claim for a different stack on the same
            # host is denied while ANY live claim exists there, so its success means
            # the dispatch's own claim is gone.
            $cAfter = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-large' `
                -VramGb 8 -RunId 'probe-run' -Project 'probe' -TtlSec 60 -BatonHome $cHomeOk
            Check 'C2 claim released after a successful dispatch (a fresh claim is granted)' (
                $cAfter.granted -eq $true)
            [void](Remove-ResourceClaim -ClaimId ([string]$cAfter.claim.claim_id) -BatonHome $cHomeOk)
            Check 'C2b no claim is left behind on host-a' (
                @(Get-ResourceClaims -HostName 'host-a' -BatonHome $cHomeOk).Count -eq 0)

            # ---- C3: denied -> the dispatcher is NEVER invoked ----
            # The real-world case: another run already loaded a model on this box.
            $cBlock = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-large' `
                -VramGb 8 -RunId 'other-run' -Project 'other' -TtlSec 300 -BatonHome $cHomeOk
            Check 'C3 setup: a competing run holds the box' ($cBlock.granted -eq $true)
            $cDeniedSeen = @{ calls = 0 }
            $cDeniedDisp = {
                param($pick, $prompt, $depthTier)
                $cDeniedSeen.calls++
                @{ stdout = 'should never run'; stderr = ''; exit_code = 0; duration_s = 0 }
            }
            $cSp3 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cDeniedDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c3.jsonl')
            $cR3 = & $cSp3 $cTask
            Check 'C3a a denied local dispatch never invokes the dispatcher' ($cDeniedSeen.calls -eq 0)
            Check 'C3b a denied local dispatch is not ok and flags labor unavailable' (
                $cR3.ok -eq $false -and [string]$cR3.labor -eq 'unavailable')
            Check 'C3c why names the denial reason verbatim and the provider' (
                ($cR3.why -match 'stack_exclusive') -and ($cR3.why -match 'local-a'))
            Check 'C3d the exclusion audit rides the result' (
                @($cR3.exclusions | Where-Object {
                    $_.name -eq 'local-a' -and $_.stage -eq 'usage' -and $_.reason -match 'stack_exclusive'
                }).Count -eq 1)
            [void](Remove-ResourceClaim -ClaimId ([string]$cBlock.claim.claim_id) -BatonHome $cHomeOk)

            # ---- C4: the claim is released even when the dispatch THROWS ----
            $cThrew = $false
            try {
                [void](Invoke-CoordinatedDispatch -Candidate ([pscustomobject]@{ name = 'local-a'; cost_tier = 'local' }) `
                    -FleetPath $cFleet -Worktree $cWt -RunDir $cRunDir -Dispatch { throw 'dispatch exploded' })
            } catch { $cThrew = $true }
            Check 'C4 a throwing dispatch still propagates out of the wrapper' $cThrew
            $cAfterThrow = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-large' `
                -VramGb 8 -TtlSec 60 -BatonHome $cHomeOk
            Check 'C4b claim released after a dispatch that throws (a fresh claim is granted)' (
                $cAfterThrow.granted -eq $true)
            [void](Remove-ResourceClaim -ClaimId ([string]$cAfterThrow.claim.claim_id) -BatonHome $cHomeOk)
            # Same property through the spawner, where the throw is caught downstream.
            $cThrowDisp = { param($pick, $prompt, $depthTier) throw 'instrument exploded' }
            $cSp4 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cThrowDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c4.jsonl')
            $cR4 = & $cSp4 $cTask
            Check 'C4c a throwing instrument fails the task without crashing the spawner' ($cR4.ok -eq $false)
            $cAfterSpawnThrow = Request-ResourceClaim -HostName 'host-a' -Stack 'stack-b' -LoadProfile 'model-large' `
                -VramGb 8 -TtlSec 60 -BatonHome $cHomeOk
            Check 'C4d claim released after a throwing spawner dispatch' ($cAfterSpawnThrow.granted -eq $true)
            [void](Remove-ResourceClaim -ClaimId ([string]$cAfterSpawnThrow.claim.claim_id) -BatonHome $cHomeOk)

            # ---- C5: THE REGRESSION GUARD ----
            # A paid provider must dispatch exactly as it does today with the
            # coordination store absent entirely. If coordination being unavailable
            # could break paid work, this whole change would be a net loss.
            $cHomeNone = & $cNewHome 'home-no-store'   # deliberately no coordination dir
            $env:BATON_HOME = $cHomeNone
            Check 'C5 setup: the coordination store does not exist' (
                -not (Test-Path (Join-Path $cHomeNone 'coordination')))
            $cPaidSeen = @{ calls = 0 }
            $cPaidDisp = {
                param($pick, $prompt, $depthTier)
                $cPaidSeen.calls++
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'paid-edit.txt') -Value 'work' -Encoding utf8NoBOM
                @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
            }
            $cSp5 = New-AgenticSpawner -Worktree $cWt -FleetPath $cPaidFleet -ToolsPath $cTools `
                -MaxCostTier 'paid' -RunDir $cRunDir -Dispatcher $cPaidDisp `
                -UsagePath (Join-Path $cHomeNone 'usage-c5.jsonl')
            $cR5 = & $cSp5 ([pscustomobject]@{ id = 'c-paid'; desc = 'write the feature'; capability = 'code-gen'
                est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'ordinary bounded feature' })
            Check 'C5 PAID PROVIDER DISPATCHES NORMALLY WITH THE COORDINATION STORE ABSENT' (
                $cR5.ok -eq $true -and $cR5.chose -eq 'paid-a' -and $cPaidSeen.calls -eq 1 -and
                (Test-Path (Join-Path $cWt 'paid-edit.txt')) -and ($cR5.why -match 'diff grew'))
            Check 'C5b non-local dispatch never touches the store — not even to create it' (
                -not (Test-Path (Join-Path $cHomeNone 'coordination')))
            $cPaidGate = Request-LocalDispatchClaim -Candidate ([pscustomobject]@{ name = 'paid-a'; cost_tier = 'paid' }) `
                -FleetPath $cPaidFleet -Worktree $cWt -RunDir $cRunDir
            Check 'C5c the gate reports non-local as ungated without consulting the store' (
                $cPaidGate.gated -eq $false -and $cPaidGate.granted -eq $true -and
                $cPaidGate.reason -eq 'not_local' -and $cPaidGate.claim_id -eq '' -and
                (-not (Test-Path (Join-Path $cHomeNone 'coordination'))))

            # ---- C6: an UNUSABLE store still cannot break paid work, and denies local ----
            $cHomeBroken = & $cNewHome 'home-broken'
            Set-Content -LiteralPath (Join-Path $cHomeBroken 'coordination') -Value 'a file, not a directory' -Encoding utf8NoBOM
            $env:BATON_HOME = $cHomeBroken
            $cPaidSeen2 = @{ calls = 0 }
            $cPaidDisp2 = {
                param($pick, $prompt, $depthTier)
                $cPaidSeen2.calls++
                Set-Content -LiteralPath (Join-Path (Get-Location).Path 'paid-edit-2.txt') -Value 'work' -Encoding utf8NoBOM
                @{ stdout = 'done'; stderr = ''; exit_code = 0; duration_s = 0 }
            }
            $cSp6 = New-AgenticSpawner -Worktree $cWt -FleetPath $cPaidFleet -ToolsPath $cTools `
                -MaxCostTier 'paid' -RunDir $cRunDir -Dispatcher $cPaidDisp2 `
                -UsagePath (Join-Path $cHomeBroken 'usage-c6.jsonl')
            $cR6 = & $cSp6 ([pscustomobject]@{ id = 'c-paid-2'; desc = 'write the feature'; capability = 'code-gen'
                est_cost_tier = 'paid'; stakes = 'standard'; stakes_basis = 'ordinary bounded feature' })
            Check 'C6 paid dispatch is unaffected by an UNUSABLE coordination store' (
                $cR6.ok -eq $true -and $cPaidSeen2.calls -eq 1 -and (Test-Path (Join-Path $cWt 'paid-edit-2.txt')))
            $cBrokenSeen = @{ calls = 0 }
            $cBrokenDisp = { param($pick, $prompt, $depthTier) $cBrokenSeen.calls++
                @{ stdout = 'should never run'; stderr = ''; exit_code = 0; duration_s = 0 } }
            $cSp6b = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cBrokenDisp `
                -UsagePath (Join-Path $cHomeBroken 'usage-c6b.jsonl')
            $cR6b = & $cSp6b $cTask
            Check 'C6b an unusable store FAILS CLOSED for local (denied, never dispatched)' (
                $cR6b.ok -eq $false -and $cBrokenSeen.calls -eq 0 -and
                [string]$cR6b.labor -eq 'unavailable' -and ($cR6b.why -match 'store_unavailable'))

            # ---- C7: an exception from the coordination call is a DENIAL ----
            $env:BATON_HOME = $cHomeOk
            $cThrowSeen = @{ calls = 0 }
            $cGateThrowDisp = { param($pick, $prompt, $depthTier) $cThrowSeen.calls++
                @{ stdout = 'should never run'; stderr = ''; exit_code = 0; duration_s = 0 } }
            $cSp7 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cGateThrowDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c7.jsonl')
            $cR7 = $null
            $cR7Escaped = $false
            function Request-ResourceClaim { throw 'coordination exploded' }
            try { $cR7 = & $cSp7 $cTask }
            catch { $cR7Escaped = $true }
            finally { . "$PSScriptRoot/coordination-lib.ps1" }
            Check 'C7 a throwing coordination call is a denial, never an implicit grant' (
                $null -ne $cR7 -and $cR7.ok -eq $false -and $cThrowSeen.calls -eq 0)
            Check 'C7b no exception escapes the spawner and why carries the fault' (
                (-not $cR7Escaped) -and ($cR7.why -match 'coordination exploded'))
            Check 'C7c the denial is labor-unavailable shaped' ([string]$cR7.labor -eq 'unavailable')

            # ---- C8: coordination-lib not loaded at all is also a denial ----
            $cNoLibSeen = @{ calls = 0 }
            $cNoLibDisp = { param($pick, $prompt, $depthTier) $cNoLibSeen.calls++
                @{ stdout = 'should never run'; stderr = ''; exit_code = 0; duration_s = 0 } }
            $cSp8 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cNoLibDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c8.jsonl')
            $cR8 = $null
            Remove-Item -LiteralPath 'Function:Request-ResourceClaim' -Force -ErrorAction SilentlyContinue
            try { $cR8 = & $cSp8 $cTask }
            finally { . "$PSScriptRoot/coordination-lib.ps1" }
            Check 'C8 an unloaded coordination library denies local dispatch' (
                $null -ne $cR8 -and $cR8.ok -eq $false -and $cNoLibSeen.calls -eq 0 -and
                ($cR8.why -match 'coordination_unavailable'))

            # ---- C9: the acquired TTL must OUTLIVE the dispatch timeout ----
            # The 60s library default would expire mid-dispatch and let a second run in.
            # Asserted on the value actually passed, not on observed behaviour.
            $cTtlSeen = @{ ttl = 0; host = ''; stack = ''; profile = ''; vram = [double]0 }
            $cTtlDisp = { param($pick, $prompt, $depthTier)
                @{ stdout = 'ok'; stderr = ''; exit_code = 0; duration_s = 0 } }
            $cSp9 = New-AgenticSpawner -Worktree $cWt -FleetPath $cFleet -ToolsPath $cTools `
                -MaxCostTier 'local' -RunDir $cRunDir -Dispatcher $cTtlDisp `
                -UsagePath (Join-Path $cHomeOk 'usage-c9.jsonl')
            function Request-ResourceClaim {
                param(
                    [Parameter(Mandatory)][string]$HostName,
                    [Parameter(Mandatory)][string]$Stack,
                    [Parameter(Mandatory)][string]$LoadProfile,
                    [double]$VramGb = 0, [string]$Class = '', [string]$RunId = '', [string]$Project = '',
                    [int]$Weight = 0, [int]$TtlSec = 60, [int]$TimeoutSec = 5, [string]$BatonHome = ''
                )
                $cTtlSeen.ttl = $TtlSec; $cTtlSeen.host = $HostName; $cTtlSeen.stack = $Stack
                $cTtlSeen.profile = $LoadProfile; $cTtlSeen.vram = $VramGb
                return [ordered]@{ granted = $true; reason = 'granted'; claim = [ordered]@{ claim_id = 'stub-claim-id' } }
            }
            try { $cR9 = & $cSp9 $cTask }
            finally { . "$PSScriptRoot/coordination-lib.ps1" }
            Check 'C9 the dispatch ran under the stub grant' ($cR9.ok -eq $true)
            Check 'C9a acquired TTL comfortably exceeds the declared dispatch timeout (3600s)' (
                [int]$cTtlSeen.ttl -ge 4200)
            Check 'C9b acquired TTL is far above the 60s library default' ([int]$cTtlSeen.ttl -gt 60)
            Check 'C9c claim identity is taken from the provider row' (
                $cTtlSeen.host -eq 'host-a' -and $cTtlSeen.stack -eq 'stack-a' -and
                $cTtlSeen.profile -eq 'model-large' -and [double]$cTtlSeen.vram -eq [double]8)
            Check 'C9d no declared timeout falls back to the generous constant' (
                (Get-CoordDispatchTtlSec -Provider @{ name = 'x' } -Candidate $null) -ge 1800)
            Check 'C9e a declared timeout always raises the lease above itself' (
                (Get-CoordDispatchTtlSec -Provider @{ timeout_s = '7200' } -Candidate $null) -gt 7200)
        } finally {
            $env:BATON_HOME = $cOuterHome
        }
    } finally {
        if ($null -eq $savedBatonHome) { Remove-Item env:BATON_HOME -ErrorAction SilentlyContinue }
        else { $env:BATON_HOME = $savedBatonHome }
    }
} finally {
    if ($null -eq $savedObserve) { Remove-Item env:BATON_ROUTING_OBSERVE -ErrorAction SilentlyContinue }
    else { $env:BATON_ROUTING_OBSERVE = $savedObserve }
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

if ($script:fail -gt 0) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host 'ALL PASS'
