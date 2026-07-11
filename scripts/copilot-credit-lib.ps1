#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Copilot Credit Budget (d079). Pulls current-cycle Copilot AI-credit usage from
  GitHub's user-level billing API and computes a cycle-anchored forecast for the
  /baton:usage panel. Informational + warning only — never governs dispatch.
.DESCRIPTION
  Fail-open everywhere: any failure collapses to ok=$false / status='unavailable'
  with a human reason; the panel can never break /baton:usage or its exit code.
  See docs/superpowers/specs/2026-07-06-copilot-credit-budget-design.md (d079).
#>
. "$PSScriptRoot/baton-home.ps1"
. "$PSScriptRoot/fleet-lib.ps1"   # Read-Fleet

function Get-CopilotFetchReason {
    <# Classify a fetch error into the spec's reason vocabulary. Pure. #>
    param([string]$ErrorText)
    $t = [string]$ErrorText
    if ($t -match '404' -or $t -match '403' -or $t -match "user['']?\s+scope" -or $t -match 'Not Found' -or $t -match 'not accessible') {
        return 'insufficient-scope'
    }
    return 'fetch-failed'
}

function Get-CopilotCreditConfig {
    <# Box-private knobs off the gh-copilot fleet row. budget = allowance (credits);
       credit_reset_day = billing-cycle day-of-month (1-28, else ignored);
       credit_warn_pct = warn threshold (default 80). Absent file/fields -> nulls. #>
    param(
        [string]$Worker = 'gh-copilot',
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')
    )
    $cfg = @{ budget = $null; reset_day = $null; warn_pct = 80 }
    if (-not (Test-Path $FleetPath)) { return $cfg }
    if (-not (Get-Command Read-Fleet -ErrorAction SilentlyContinue)) { return $cfg }
    foreach ($p in (Read-Fleet -Path $FleetPath)) {
        if ([string]$p.name -ne $Worker) { continue }
        if ($null -ne $p.budget) { $cfg.budget = [int]$p.budget }
        if ($null -ne $p.credit_reset_day) {
            $rd = 0
            if ([int]::TryParse([string]$p.credit_reset_day, [ref]$rd) -and $rd -ge 1 -and $rd -le 28) {
                $cfg.reset_day = $rd
            }
        }
        if ($null -ne $p.credit_warn_pct) {
            $wp = 0
            if ([int]::TryParse([string]$p.credit_warn_pct, [ref]$wp) -and $wp -ge 1 -and $wp -le 100) {
                $cfg.warn_pct = $wp
            }
        }
        break
    }
    return $cfg
}

function Resolve-CopilotLogin {
    <# GitHub login: -User, else BATON_GH_USER, else ambient `gh api user`. $null on failure. #>
    param([string]$User)
    if ($User) { return $User }
    if ($env:BATON_GH_USER) { return $env:BATON_GH_USER }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    try {
        $login = (& gh api user --jq .login 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $login) { return $login }
    } catch { }
    return $null
}

function Get-CopilotCreditUsage {
    <# Current-cycle Copilot AI-credit usage. Fail-open, never throws: ok=$false + reason
       (gh-cli-missing | insufficient-scope | org-managed | fetch-failed) on any failure.
       -Fetcher seam receives the login and returns the raw JSON response text.
       No leading slash on the gh api path (MSYS path-rewrite hygiene). #>
    param([string]$User, [scriptblock]$Fetcher)
    $result = [ordered]@{
        ok = $false; used = $null; amount = $null; currency = 'USD'
        by_model = @(); fetched_at = (Get-Date).ToUniversalTime().ToString('o'); reason = $null
    }
    $raw = $null
    try {
        if ($Fetcher) {
            $raw = & $Fetcher (Resolve-CopilotLogin -User $User)
        } elseif ($env:BATON_COPILOT_TEST_USAGE) {
            # hermetic test seam (BATON_GO_TEST_* pattern): canned response file
            $raw = Get-Content -LiteralPath $env:BATON_COPILOT_TEST_USAGE -Raw -ErrorAction Stop
        } elseif ($env:BATON_GH_BILLING_TOKEN) {
            $login = Resolve-CopilotLogin -User $User
            if (-not $login) { $result.reason = 'fetch-failed'; return $result }
            $headers = @{ Authorization = ('Bearer ' + $env:BATON_GH_BILLING_TOKEN); Accept = 'application/vnd.github+json' }
            $resp = Invoke-RestMethod -Uri ("https://api.github.com/users/$login/settings/billing/ai_credit/usage") -Headers $headers -ErrorAction Stop
            $raw = $resp | ConvertTo-Json -Depth 10
        } else {
            if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $result.reason = 'gh-cli-missing'; return $result }
            $login = Resolve-CopilotLogin -User $User
            if (-not $login) { $result.reason = 'fetch-failed'; return $result }
            $raw = & gh api ("users/$login/settings/billing/ai_credit/usage") 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { $result.reason = Get-CopilotFetchReason -ErrorText $raw; return $result }
        }
    } catch {
        $result.reason = Get-CopilotFetchReason -ErrorText $_.Exception.Message
        return $result
    }
    $data = $null
    try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $result.reason = 'fetch-failed'; return $result }
    $items = $data.usageItems
    if ($null -eq $items) { $result.reason = 'org-managed'; return $result }   # applicable shape absent
    $used = 0.0; $amount = 0.0
    $models = [ordered]@{}
    foreach ($it in @($items)) {
        if ([string]$it.product -ne 'Copilot AI Credits') { continue }
        $q = [double]$it.grossQuantity
        $a = [double]$it.grossAmount
        $used += $q; $amount += $a
        $m = [string]$it.model
        if (-not $m) { $m = '(unknown)' }
        if (-not $models.Contains($m)) { $models[$m] = @{ model = $m; credits = 0.0; amount = 0.0 } }
        $models[$m].credits += $q
        $models[$m].amount += $a
    }
    $result.ok = $true
    $result.used = $used
    $result.amount = [math]::Round($amount, 2)
    $result.by_model = @($models.Values | Sort-Object { -[double]$_.credits })
    return $result
}

function Get-CopilotCreditForecast {
    <# Cycle-anchored forecast: run_rate = used / days-since-reset (first-call friendly,
       no journal history needed). status: unavailable | no_budget | no_reset_anchor | ok. #>
    param(
        [string]$User,
        [string]$FleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml'),
        [datetime]$Now = [datetime]::UtcNow,
        [scriptblock]$Fetcher
    )
    $cfg = Get-CopilotCreditConfig -FleetPath $FleetPath
    $u = Get-CopilotCreditUsage -User $User -Fetcher $Fetcher
    $result = [ordered]@{
        status = 'unavailable'; used = $null; budget = $cfg.budget; remaining = $null; pct = $null
        amount = $null; by_model = @(); reset_date = $null; days_elapsed = $null
        days_left_in_cycle = $null; run_rate = $null; days_to_exhaustion = $null
        warn = $false; warn_pct = $cfg.warn_pct; reason = $null
    }
    if (-not $u.ok) { $result.reason = $u.reason; return $result }
    $result.used = $u.used
    $result.amount = $u.amount
    $result.by_model = $u.by_model
    if ($null -eq $cfg.budget -or $cfg.budget -le 0) { $result.status = 'no_budget'; return $result }
    $result.remaining = [math]::Max(0, $cfg.budget - $u.used)
    $result.pct = [math]::Round(($u.used / $cfg.budget) * 100)   # budget > 0 guarded above
    $result.warn = ($result.pct -ge $cfg.warn_pct)
    if ($null -eq $cfg.reset_day) { $result.status = 'no_reset_anchor'; return $result }
    $nowUtc = $Now.ToUniversalTime()
    $anchor = [datetime]::new($nowUtc.Year, $nowUtc.Month, $cfg.reset_day, 0, 0, 0, [System.DateTimeKind]::Utc)
    if ($nowUtc -ge $anchor) { $lastReset = $anchor; $nextReset = $anchor.AddMonths(1) }
    else                     { $lastReset = $anchor.AddMonths(-1); $nextReset = $anchor }
    $result.reset_date = $nextReset.ToString('yyyy-MM-dd')
    $result.days_elapsed = [int][math]::Max(1, [math]::Floor(($nowUtc - $lastReset).TotalDays))  # never 0
    $result.days_left_in_cycle = [int][math]::Ceiling(($nextReset - $nowUtc).TotalDays)
    $result.run_rate = [math]::Round($u.used / $result.days_elapsed, 2)
    $result.days_to_exhaustion = if ($result.run_rate -gt 0) { [math]::Round($result.remaining / $result.run_rate, 2) } else { $null }
    $result.status = 'ok'
    return $result
}

function Write-CopilotCreditPanel {
    <# Render one /baton:usage panel. Untyped param (ordered-dict binding lesson).
       ASCII-only output (console-encoding safety). Never throws. #>
    param([Parameter(Mandatory)]$Forecast)
    Write-Host ''
    if ($Forecast.status -eq 'unavailable') {
        Write-Host ('Copilot Credits    unavailable (' + $Forecast.reason + ')')
        if ($Forecast.reason -eq 'insufficient-scope') {
            Write-Host '  fix: gh auth refresh -h github.com -s user'
        }
        return
    }
    if ($Forecast.status -eq 'no_budget') {
        Write-Host ('Copilot Credits    ' + $Forecast.used + ' used (no budget configured in fleet.yaml)')
        return
    }
    $head = 'Copilot Credits    ' + $Forecast.used + ' / ' + $Forecast.budget + '  (' + $Forecast.pct + '%)'
    if ($null -ne $Forecast.amount) {
        $head += '   ~$' + ('{0:N2}' -f [double]$Forecast.amount) + ' of $' + ('{0:N2}' -f ($Forecast.budget * 0.01))
    }
    Write-Host $head
    if ($Forecast.status -eq 'ok') {
        $line = '  run-rate ' + $Forecast.run_rate + '/day'
        if ($null -ne $Forecast.days_to_exhaustion) { $line += ' | ~' + $Forecast.days_to_exhaustion + ' days to exhaustion' }
        $line += ' | resets ' + $Forecast.reset_date + ' (' + $Forecast.days_left_in_cycle + 'd)'
        Write-Host $line
    }
    if (@($Forecast.by_model).Count -gt 0) {
        $mparts = @()
        foreach ($m in @($Forecast.by_model)) { $mparts += ($m.model + ' ' + $m.credits) }
        Write-Host ('  by model: ' + ($mparts -join ' | '))
    }
    if ($Forecast.warn) {
        Write-Host ('  WARNING: over ' + $Forecast.warn_pct + '% - check the Copilot code-review ruleset (biggest metered driver)')
    }
}
