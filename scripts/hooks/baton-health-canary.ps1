# baton-health-canary.ps1 — SessionStart loud check for cross-platform control-plane breakage.
# Writes ~/.baton/logs/health-canary.log and prints CRITICAL lines to stderr so they show up.
# Exit 0 always (never block the session); the point is visibility, not gating.

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $HOME '.baton/logs'
$log = Join-Path $logDir 'health-canary.log'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$ts = (Get-Date).ToUniversalTime().ToString('o')
$issues = [System.Collections.Generic.List[string]]::new()

# 1) pwsh must start
try {
    $ver = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ver)) {
        $issues.Add("pwsh probe failed (exit=$LASTEXITCODE). Baton hooks that shell to pwsh are dead. Re-apply DOTNET_ROOT pin on Homebrew pwsh.")
    }
} catch {
    $issues.Add("pwsh probe threw: $_. Baton hooks that shell to pwsh are dead.")
}

# 2) Parse Claude settings as JSON; flag real Windows separators in string values
#    (not JSON \" escapes). Pattern: /Users/...\<segment> where segment is a name char.
$settingsPaths = @(
    (Join-Path $HOME '.claude/settings.json'),
    (Join-Path $HOME '.claude/settings.local.json')
)
$winSep = [regex]'/Users/[^\\"]*\\[A-Za-z]'
foreach ($sp in $settingsPaths) {
    if (-not (Test-Path -LiteralPath $sp)) { continue }
    try {
        $obj = Get-Content -LiteralPath $sp -Raw -ErrorAction Stop | ConvertFrom-Json
        $json = $obj | ConvertTo-Json -Depth 40 -Compress
        if ($winSep.IsMatch($json)) {
            $issues.Add("Windows-style path separators in $sp — hooks/config will not resolve on macOS.")
        }
    } catch {
        $issues.Add("Could not parse $sp as JSON: $_")
    }
}

# 3) Guard present in source
$guard = Join-Path $HOME 'dev/Baton/scripts/hooks/_pwsh-guard.ps1'
if (-not (Test-Path -LiteralPath $guard)) {
    $issues.Add("Missing $guard — dead-pwsh fail-open not installed in source.")
}

$line = if ($issues.Count -eq 0) {
    "[$ts] OK pwsh+paths"
} else {
    "[$ts] CRITICAL $($issues.Count) issue(s): " + ($issues -join ' | ')
}
Add-Content -Path $log -Value $line

if ($issues.Count -gt 0) {
    foreach ($i in $issues) {
        [Console]::Error.WriteLine("BATON HEALTH CRITICAL: $i")
    }
}

exit 0
