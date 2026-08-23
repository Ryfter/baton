#!/usr/bin/env pwsh
<#
.SYNOPSIS
  baton CLI dispatcher — vendor-neutral front door over existing fleet runners.

.DESCRIPTION
  baton <verb> [args...]   resolve verb → runner, invoke with full arg passthrough
  baton                    list verbs
  baton --help | -h        list verbs
  baton --version          print version
  baton verbs --json       machine-readable verb registry

  Does not re-parse runner flags. Exit code is the runner's exit code.
  Unknown verb → exit 2 (with a closest-name hint when distance is small).
#>
$ErrorActionPreference = 'Stop'

# Entry scripts dir for Resolve-BatonScript install-location candidate.
$script:BatonEntryScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'baton-resolve.ps1')

function ConvertFrom-BatonYamlValue {
    param([string]$Raw)
    $v = $Raw.Trim()
    if ($v.Length -ge 1 -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
        $q = $v[0]
        $end = $v.IndexOf($q, 1)
        $v = if ($end -ge 1) { $v.Substring(1, $end - 1) } else { $v.Substring(1) }
    } else {
        $hash = $v.IndexOf(' #')
        if ($hash -ge 0) { $v = $v.Substring(0, $hash).TrimEnd() }
    }
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    return $v
}

function New-BatonFlagAliasMap {
    <# Case-sensitive map: exact token match only (no case folding). #>
    return [System.Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal
    )
}

function Read-BatonVerbs {
    <# Hand-rolled shallow YAML parser for verbs.yaml (same style as Read-Fleet).
       Also supports an optional nested flag_aliases map under each verb:
         flag_aliases:
           --project: -Project
       Nested keys use Ordinal (case-sensitive) matching at apply time. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "verbs.yaml not found at $Path"
    }
    $verbs = [System.Collections.ArrayList]@()
    $current = $null
    $inFlagAliases = $false
    $flagAliasIndent = 0
    foreach ($rawLine in (Get-Content -LiteralPath $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^verbs:\s*$') { continue }

        if ($rawLine -match '^\s*-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$verbs.Add($current) }
            $current = @{
                name         = [string](ConvertFrom-BatonYamlValue $matches[1])
                summary      = ''
                class        = ''
                runner       = ''
                json         = $false
                flag_aliases = $null
            }
            $inFlagAliases = $false
            $flagAliasIndent = 0
            continue
        }
        if (-not $current) { continue }

        # Nested flag_aliases map: enter on bare "flag_aliases:" key.
        if ($rawLine -match '^(?<indent>\s+)flag_aliases:\s*$') {
            $current.flag_aliases = New-BatonFlagAliasMap
            $inFlagAliases = $true
            $flagAliasIndent = $matches['indent'].Length
            continue
        }
        # While inside flag_aliases, only accept *more-indented* "key: value"
        # lines as map entries (keys may start with dashes, e.g. --project).
        # Same-or-less indent falls through to normal verb-key handling.
        if ($inFlagAliases -and $rawLine -match '^(?<indent>\s+)(?<key>\S+):\s*(?<val>.+?)\s*$') {
            if ($matches['indent'].Length -gt $flagAliasIndent) {
                $aliasKey = [string]$matches['key']
                $aliasVal = [string](ConvertFrom-BatonYamlValue $matches['val'])
                if (-not [string]::IsNullOrWhiteSpace($aliasKey) -and
                    -not [string]::IsNullOrWhiteSpace($aliasVal)) {
                    $current.flag_aliases[$aliasKey] = $aliasVal
                }
                continue
            }
            $inFlagAliases = $false
            $flagAliasIndent = 0
            # fall through — this line is a sibling verb key
        }

        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $inFlagAliases = $false
            $flagAliasIndent = 0
            $key = $matches[1]
            $val = ConvertFrom-BatonYamlValue $matches[2]
            switch ($key) {
                'summary' { $current.summary = [string]$val }
                'class'   { $current.class   = [string]$val }
                'runner'  { $current.runner  = [string]$val }
                'json'    { $current.json    = [bool]$val }
                'name'    { $current.name    = [string]$val }
            }
        }
    }
    if ($current) { [void]$verbs.Add($current) }
    return @($verbs.ToArray())
}

function Read-BatonVersionFromPluginJson {
    param([Parameter(Mandatory)][string]$PluginJsonPath)
    if (-not (Test-Path -LiteralPath $PluginJsonPath)) { return $null }
    $raw = Get-Content -LiteralPath $PluginJsonPath -Raw
    if ($raw -match '"version"\s*:\s*"([^"]+)"') {
        $ver = [string]$matches[1]
        if (-not [string]::IsNullOrWhiteSpace($ver)) { return $ver.Trim() }
    }
    return $null
}

function Get-BatonVersion {
    <# Resolve version without inventing a number.
       Order:
         1. .claude-plugin/plugin.json walking up from this script's location
         2. $env:BATON_REPO_ROOT/.claude-plugin/plugin.json
         3. baton-version.txt next to this script (bootstrap deploy marker)
         4. unknown
    #>
    # 1. Walk up from the dispatcher (source checkout: scripts/ → repo root).
    $dir = $PSScriptRoot
    while ($dir) {
        $candidate = Join-Path $dir '.claude-plugin' 'plugin.json'
        $found = Read-BatonVersionFromPluginJson -PluginJsonPath $candidate
        if ($found) { return $found }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }

    # 2. Explicit repo root override (deployed copy + BATON_REPO_ROOT set).
    if (-not [string]::IsNullOrWhiteSpace($env:BATON_REPO_ROOT)) {
        $candidate = Join-Path $env:BATON_REPO_ROOT '.claude-plugin' 'plugin.json'
        $found = Read-BatonVersionFromPluginJson -PluginJsonPath $candidate
        if ($found) { return $found }
    }

    # 3. Deployed marker written by bootstrap next to baton.ps1.
    $marker = Join-Path $PSScriptRoot 'baton-version.txt'
    if (Test-Path -LiteralPath $marker) {
        $text = (Get-Content -LiteralPath $marker -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) { return $text }
    }

    return 'unknown'
}

function Convert-BatonFlagAliases {
    <# Apply per-verb flag_aliases: exact key match only; values untouched.
       Stops translating after a bare "--" (everything after is verbatim).
       Unrecognised --flags pass through unchanged. #>
    param(
        [AllowEmptyCollection()]
        [object[]]$Tokens,
        $Aliases
    )
    if (-not $Aliases -or $Aliases.Count -eq 0) {
        return @($Tokens)
    }
    $out = [System.Collections.ArrayList]@()
    $rawPass = $false
    foreach ($tok in $Tokens) {
        $s = [string]$tok
        if ($rawPass) {
            [void]$out.Add($s)
            continue
        }
        if ($s -eq '--') {
            $rawPass = $true
            [void]$out.Add($s)
            continue
        }
        # Exact match only (Dictionary uses Ordinal comparer).
        if ($Aliases.ContainsKey($s)) {
            [void]$out.Add([string]$Aliases[$s])
            continue
        }
        [void]$out.Add($s)
    }
    return @($out.ToArray())
}

function Get-BatonEditDistance {
    <# Classic Levenshtein distance (case-insensitive). #>
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )
    $s = $A.ToLowerInvariant()
    $t = $B.ToLowerInvariant()
    $n = $s.Length
    $m = $t.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = [int[]]::new($m + 1)
    $curr = [int[]]::new($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $curr[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = if ($s[$i - 1] -eq $t[$j - 1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $curr[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $curr[$j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
        $tmp = $prev; $prev = $curr; $curr = $tmp
    }
    return $prev[$m]
}

function Find-BatonClosestVerb {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Verbs
    )
    $best = $null
    $bestDist = [int]::MaxValue
    foreach ($v in $Verbs) {
        $d = Get-BatonEditDistance -A $Name -B ([string]$v.name)
        if ($d -lt $bestDist) {
            $bestDist = $d
            $best = [string]$v.name
        }
    }
    # Only suggest when the match is "obviously near".
    $threshold = [Math]::Max(1, [Math]::Min(3, [int][Math]::Floor($Name.Length / 2)))
    if ($bestDist -le $threshold) { return $best }
    return $null
}

function Show-BatonHelp {
    param([Parameter(Mandatory)][object[]]$Verbs)
    Write-Output 'baton — vendor-neutral CLI for the Baton engine'
    Write-Output ''
    Write-Output 'Usage:'
    Write-Output '  baton <verb> [args...]'
    Write-Output '  baton --help | -h'
    Write-Output '  baton --version'
    Write-Output '  baton verbs --json'
    Write-Output ''

    $byClass = $Verbs | Group-Object -Property class | Sort-Object Name
    foreach ($group in $byClass) {
        $label = if ($group.Name) { $group.Name } else { 'other' }
        Write-Output ("{0}:" -f $label)
        foreach ($v in ($group.Group | Sort-Object name)) {
            $nm = [string]$v.name
            $sm = [string]$v.summary
            Write-Output ("  {0,-16} {1}" -f $nm, $sm)
        }
        Write-Output ''
    }
    Write-Output 'Pass --help after a verb for that runner''s own help.'
}

function Show-BatonVerbsJson {
    param([Parameter(Mandatory)][object[]]$Verbs)
    $payload = @(
        foreach ($v in $Verbs) {
            [ordered]@{
                name    = [string]$v.name
                summary = [string]$v.summary
                class   = [string]$v.class
                runner  = [string]$v.runner
            }
        }
    )
    $payload | ConvertTo-Json -Depth 4 -Compress:$false
}

# --- main -----------------------------------------------------------------

# Read automatic $args into a local name — never assign to $args.
$cliArgs = @($args)

$verbsPath = Join-Path $PSScriptRoot 'verbs.yaml'
$verbs = @(Read-BatonVerbs -Path $verbsPath)

if ($cliArgs.Count -eq 0) {
    # `baton` is the front door — you are in Maestro. --help lists engine verbs.
    try {
        $room = Resolve-BatonScript -Name 'maestro.ps1'
    } catch {
        [Console]::Error.WriteLine("baton: $($_.Exception.Message)")
        exit 1
    }
    # Same process so a piped line (and the keyboard) reach the room.
    & $room
    exit $LASTEXITCODE
}

$head = [string]$cliArgs[0]
$tail = @()
if ($cliArgs.Count -gt 1) {
    $tail = @($cliArgs[1..($cliArgs.Count - 1)])
}

switch -Regex ($head) {
    '^(--help|-h|help)$' {
        Show-BatonHelp -Verbs $verbs
        exit 0
    }
    '^--version$' {
        Write-Output (Get-BatonVersion)
        exit 0
    }
    '^verbs$' {
        $wantJson = $false
        foreach ($a in $tail) {
            if ($a -eq '--json' -or $a -eq '-json') { $wantJson = $true }
        }
        if ($wantJson) {
            Show-BatonVerbsJson -Verbs $verbs
            exit 0
        }
        Show-BatonHelp -Verbs $verbs
        exit 0
    }
}

$verb = $verbs | Where-Object { [string]$_.name -eq $head } | Select-Object -First 1
if (-not $verb) {
    $hint = Find-BatonClosestVerb -Name $head -Verbs $verbs
    $msg = "baton: unknown verb '$head'."
    if ($hint) { $msg += " Did you mean '$hint'?" }
    [Console]::Error.WriteLine($msg)
    [Console]::Error.WriteLine("Run 'baton --help' for the verb list.")
    exit 2
}

try {
    $runnerPath = Resolve-BatonScript -Name ([string]$verb.runner)
} catch {
    [Console]::Error.WriteLine("baton: $($_.Exception.Message)")
    exit 1
}

# Optional per-verb CLI flag aliases (exact-key only). Verbs without a map
# keep raw passthrough so runners that already take --flags are undisturbed.
if ($verb.flag_aliases -and $verb.flag_aliases.Count -gt 0) {
    $tail = @(Convert-BatonFlagAliases -Tokens $tail -Aliases $verb.flag_aliases)
}

# Full passthrough of (possibly alias-translated) tokens — runners own validation.
# Avoid re-ordering flags here. Exit code is the runner's exit code.
& pwsh -NoProfile -File $runnerPath @tail
exit $LASTEXITCODE
