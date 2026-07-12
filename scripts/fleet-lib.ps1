#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Shared library for the fleet dispatch layer. Dot-source from the slash
  command, doctor, and tests.

.DESCRIPTION
  Parses fleet.yaml (hand-rolled minimal parser — shallow schema only),
  resolves command templates, dispatches to cli/http providers, and journals
  each invocation. See docs/superpowers/specs/2026-05-26-plan4-fleet-design.md.
#>

. "$PSScriptRoot/baton-home.ps1"
$script:DefaultFleetPath = (Join-Path (Get-BatonHome) 'fleet.yaml')

function Set-JsonFileAtomic {
    # Write JSON to a temp sibling then Move-Item -Force, so a concurrent reader
    # (the dashboard cockpit polling every 2s) never sees a half-written file.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
    $tmp = "$Path.tmp"
    Set-Content -LiteralPath $tmp -Value $Json -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertFrom-FleetValue {
    # Strip an inline comment + surrounding quotes; coerce true/false to bool.
    param([string]$Raw)
    $v = $Raw.Trim()
    if ($v.Length -ge 1 -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
        # Quoted: the value is the span up to the matching closing quote; anything
        # after it (e.g. a trailing "  # wraith2 over Tailscale") is a comment.
        $q = $v[0]
        $end = $v.IndexOf($q, 1)
        $v = if ($end -ge 1) { $v.Substring(1, $end - 1) } else { $v.Substring(1) }
    } else {
        # Unquoted: a whitespace-preceded '#' starts a comment (YAML rule). A '#'
        # with no preceding space (e.g. a hex colour 'ab#cd') stays in the value.
        $hash = $v.IndexOf(' #')
        if ($hash -ge 0) { $v = $v.Substring(0, $hash).TrimEnd() }
    }
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    return $v
}

function Read-Fleet {
    <# Parse fleet.yaml into an array of provider hashtables. #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) {
        throw "fleet.yaml not found at $Path. Run scripts/bootstrap.ps1 to deploy the seed."
    }
    $providers = [System.Collections.ArrayList]@()
    $current = $null
    $inEnv = $false
    $envIndent = 0

    foreach ($rawLine in (Get-Content $Path)) {
        if ($rawLine -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
        if ($rawLine -match '^providers:\s*$') { continue }

        # New provider: "  - name: <value>"
        if ($rawLine -match '^(\s*)-\s+name:\s*(.+?)\s*$') {
            if ($current) { [void]$providers.Add($current) }
            $current = @{ name = (ConvertFrom-FleetValue $matches[2]); env = $null }
            $inEnv = $false
            continue
        }
        # A new top-level key (no indentation) ends the providers block — stop
        # absorbing indented children (e.g. capability_floors entries) into the
        # last provider. `providers:` itself is skipped above.
        if ($current -and $rawLine -match '^[\w.-]+:') {
            [void]$providers.Add($current)
            $current = $null
            $inEnv = $false
            continue
        }
        if (-not $current) { continue }

        $indent = ($rawLine -replace '\S.*$', '').Length

        # env: block opener (no value on the line)
        if ($rawLine -match '^(\s+)env:\s*$') {
            $current.env = @{}
            $inEnv = $true
            $envIndent = $matches[1].Length
            continue
        }

        # env entry (deeper indentation than the env: key)
        if ($inEnv -and $indent -gt $envIndent -and $rawLine -match '^\s+([\w.-]+):\s*(.+?)\s*$') {
            $current.env[$matches[1]] = (ConvertFrom-FleetValue $matches[2])
            continue
        }

        # indentation returned to field level — exit env block and fall through
        if ($inEnv) {
            $inEnv = $false
        }

        # ordinary field (including lines that just exited the env block)
        if ($rawLine -match '^\s+([\w.-]+):\s*(.*?)\s*$') {
            $key = $matches[1]
            $val = $matches[2]
            # Skip env key when it has no value (already handled above); value would be empty
            if ($key -eq 'env' -and $val -eq '') { continue }
            $parsed = ConvertFrom-FleetValue $val
            # Inline YAML list value: 'capabilities: [a, b]' -> string[].
            if ($parsed -is [string] -and $parsed -match '^\[(.*)\]$') {
                $inner = $matches[1].Trim()
                $parsed = if ($inner) {
                    @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
                } else { @() }
            }
            $current[$key] = $parsed
        }
    }
    if ($current) { [void]$providers.Add($current) }
    return $providers.ToArray()
}

function Get-FleetProvider {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path = $script:DefaultFleetPath
    )
    return (Read-Fleet -Path $Path | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Get-FleetResearchDefault {
    <# Read the top-level `research_default: [a, b, c]` key from fleet.yaml.
       Returns a string[] of provider names (empty array if the key is absent). #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) { return @() }
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*research_default:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}

function Get-FleetKeepList {
    <# Top-level `keep_list: ['*heretic*', ...]` glob list (models Kevin keeps for
       personal use — inventory tags them, recommendations never propose culling).
       Returns string[] (empty if the key or file is absent). #>
    param([string]$Path = $script:DefaultFleetPath)
    if (-not (Test-Path $Path)) { return @() }
    foreach ($line in (Get-Content $Path)) {
        if ($line -match '^\s*keep_list:\s*\[(.*)\]\s*$') {
            $inner = $matches[1].Trim()
            if (-not $inner) { return @() }
            return @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
        }
    }
    return @()
}

function Resolve-FleetCommand {
    <# Substitute {{prompt}} and {{model}} into a cli provider's command_template. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model
    )
    $template = $Provider.command_template
    if (-not $template) { throw "Provider '$($Provider.name)' has no command_template." }
    # stdin providers pipe the prompt in rather than interpolating it, so they
    # legitimately omit {{prompt}} from the template (e.g. 'codex exec -').
    # {{prompt_file}} providers are likewise exempt: the prompt rides a temp file
    # whose path is substituted only inside Invoke-Fleet-Cli, never here.
    if ($template -notmatch '\{\{prompt\}\}' -and $Provider.stdin -ne $true -and $template -notmatch '\{\{prompt_file\}\}') {
        throw "Provider '$($Provider.name)' command_template lacks the required {{prompt}} placeholder."
    }
    $resolvedModel = if ($Model) { $Model } else { $Provider.model_default }
    # Literal .Replace() — NOT -replace — so $-sequences in the prompt (e.g. "$PATH",
    # "$1") are not interpreted as regex backreferences. Shell-escaping of quotes is
    # still a known limitation; Plan 5 hardens prompt passing via stdin.
    $cmd = $template.Replace('{{prompt}}', $Prompt)
    if ($null -ne $resolvedModel) { $cmd = $cmd.Replace('{{model}}', [string]$resolvedModel) }
    return $cmd
}

function Test-StdinSafe {
    <# True when a cli provider's template can safely pipe the prompt via stdin:
       not already stdin, template ends in a standalone quoted {{prompt}}, and the
       command minus that tail has no shell operators. Keeps embedded-prompt and
       shell-wrapped templates on the legacy interpolation path. An explicit
       stdin:false is a per-provider VETO of the promotion (e.g. agy: `--print`
       requires an inline argument and does not read stdin — a promoted bare
       `agy --print` dies with "flag needs an argument"). #>
    param([Parameter(Mandatory)][hashtable]$Provider)
    if ($null -ne $Provider.stdin) { return $false }   # true = already stdin; false = veto
    $template = [string]$Provider.command_template
    if (-not $template) { return $false }
    if ($template -notmatch '\s+(["''])\{\{prompt\}\}\1\s*$') { return $false }
    $head = $template -replace '\s+(["''])\{\{prompt\}\}\1\s*$', ''
    if ($head -match '[|><&;`]' -or $head -match '\$\(') { return $false }
    return $true
}

function Get-FleetTokenUsage {
    <# Derive a token count + basis from a CLI provider's stdout.
       Returns @{ tokens = <int>; tokens_basis = 'exact'|'estimate' }.
       exact  : the row has a `token_usage` regex whose FIRST capture group is a
                number (commas/whitespace stripped) present in stdout.
       estimate: no field / no match -> ceil((len(prompt)+len(stdout))/4). The d059
                honesty rule: an estimate is never labelled exact. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [string]$Prompt = '',
        [string]$Stdout = ''
    )
    $regex = [string]$Provider.token_usage
    if ($regex) {
        $m = [regex]::Match($Stdout, $regex)
        if ($m.Success -and $m.Groups.Count -ge 2) {
            $digits = $m.Groups[1].Value -replace '[,\s]', ''
            $n = 0
            if ([int]::TryParse($digits, [ref]$n)) {
                return @{ tokens = $n; tokens_basis = 'exact' }
            }
        }
    }
    $len = $Prompt.Length + $Stdout.Length
    return @{ tokens = [int][math]::Ceiling($len / 4); tokens_basis = 'estimate' }
}

function Write-FleetJournalLine {
    <# Append a `fleet` line to the journal, picking up Plan 3 job/phase tags
       by reading the state file directly (honors $env:CAO_STATE_PATH). #>
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][int]$DurationS,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'model-routing-log.md'),
        [string]$StatePath = $(if ($env:CAO_STATE_PATH) { $env:CAO_STATE_PATH } else { Join-Path (Get-BatonHome) 'current-job.json' }),
        # Origin host (Plan 9): the machine that DISPATCHED this invocation, so a
        # journal merged across the Tailscale fleet stays attributable per node.
        # Override via CAO_FLEET_HOST; falls back to the OS hostname.
        [string]$OriginHost = $(if ($env:CAO_FLEET_HOST) { $env:CAO_FLEET_HOST } elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() })
        ,
        [int]$Tokens = 0,
        [string]$TokensBasis = 'estimate'
    )
    # Summarise + sanitise the prompt (max 100 chars, pipes -> ¦, newlines -> space)
    $summary = ($Prompt -replace '\|', '¦' -replace "`r?`n", ' ').Trim()
    if ($summary.Length -gt 100) { $summary = $summary.Substring(0, 100) + '…' }

    $ts = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    $line = "$ts | fleet | $Provider | ${DurationS}s | exit:$ExitCode | `"$summary`" | host:$OriginHost"

    # Pick up active-job tags straight from the state file. Self-contained:
    # no dependency on job-lib.ps1 being dot-sourced. Never throws.
    try {
        if (Test-Path $StatePath) {
            $raw = Get-Content $StatePath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $state = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($state.job_id -and $state.phase) {
                    $line += " | job:$($state.job_id) | phase:$($state.phase)"
                }
            }
        }
    } catch { }

    # Trailing token field (observe-only). Appended AFTER host:/job:/phase: so every
    # consumer that splits on ' | ' and prefix-matches ignores it (spec §4.2).
    $line += " | tok:$Tokens($TokensBasis)"

    $dir = Split-Path -Parent $JournalPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not (Test-Path $JournalPath)) {
        Set-Content -Path $JournalPath -Value "# Model Routing Log`n# --- entries below this line ---" -Encoding utf8NoBOM
    }
    Add-Content -Path $JournalPath -Value $line -Encoding utf8NoBOM
}

function Invoke-Fleet-Cli {
    <# Run a kind: cli provider's resolved command, applying+restoring env vars. #>
    param(
        [Parameter(Mandatory)][hashtable]$Provider,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [int]$TimeoutS = 120
    )
    # Decide dispatch path. A {{prompt_file}} template takes precedence over the
    # stdin decision: the prompt is written to a temp file and its path substituted
    # (quote-safe + size-safe) for CLIs that neither read stdin nor tolerate inline
    # quotes (grok). Otherwise: stdin:true providers already omit {{prompt}}; clean-
    # tail interpolating providers are promoted to stdin (prompt-size / quote
    # hardening) by stripping the trailing quoted {{prompt}} token. For the stdin
    # and prompt-file cases we resolve {{model}} inline — NOT via Resolve-FleetCommand,
    # whose mandatory -Prompt would reject the empty prompt those dispatches use.
    $usePromptFile = ([string]$Provider.command_template) -match '\{\{prompt_file\}\}'
    $useStdin = (-not $usePromptFile) -and (($Provider.stdin -eq $true) -or (Test-StdinSafe -Provider $Provider))
    if ($usePromptFile) {
        # {{prompt_file}} is substituted with the temp path inside the try below,
        # where the file lives; resolve {{model}} now, same as the stdin branch.
        $cmd = [string]$Provider.command_template
        $resolvedModel = if ($Model) { $Model } else { $Provider.model_default }
        if ($null -ne $resolvedModel) { $cmd = $cmd.Replace('{{model}}', [string]$resolvedModel) }
    } elseif ($useStdin) {
        # stdin:true templates carry no {{prompt}}; Test-StdinSafe templates end in
        # a standalone quoted {{prompt}} that we strip. Both then resolve {{model}}.
        $cmd = if ($Provider.stdin -eq $true) { [string]$Provider.command_template }
               else { ([string]$Provider.command_template) -replace '\s+(["''])\{\{prompt\}\}\1\s*$', '' }
        $resolvedModel = if ($Model) { $Model } else { $Provider.model_default }
        if ($null -ne $resolvedModel) { $cmd = $cmd.Replace('{{model}}', [string]$resolvedModel) }
    } else {
        $cmd = Resolve-FleetCommand -Provider $Provider -Prompt $Prompt -Model $Model
    }

    $saved = @{}
    if ($Provider.env) {
        foreach ($k in $Provider.env.Keys) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            Set-Item "env:$k" $Provider.env[$k]
        }
    }
    $start = Get-Date
    try {
        if ($usePromptFile) {
            # Prompt-file path: write $Prompt to a unique temp file and hand its path
            # to the CLI. Quote-safe (the CLI reads the file, not an arg) and size-safe
            # (no 965-byte arg ceiling). Mirror the stdin branch's argv invocation:
            # split the template into whitespace tokens, find the standalone
            # {{prompt_file}} token (after stripping surrounding quotes), swap in the
            # temp path, and invoke via the call operator — NO Invoke-Expression, so a
            # $(, backtick, or $ in the temp path (username-dependent) is never reparsed.
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmp -Value $Prompt -Encoding utf8NoBOM
                $tokens = @($cmd -split '\s+' | Where-Object { $_ -ne '' })
                # A token is the prompt-file slot when, stripped of surrounding single/
                # double quotes, it equals {{prompt_file}} exactly (placeholder as its own
                # argument). An embedded placeholder inside a larger token is NOT argv-safe.
                $pfIdx = -1
                for ($ti = 0; $ti -lt $tokens.Count; $ti++) {
                    if (($tokens[$ti].Trim('"', "'")) -eq '{{prompt_file}}') { $pfIdx = $ti; break }
                }
                if ($pfIdx -ge 0) {
                    $argv = @($tokens)
                    $argv[$pfIdx] = $tmp
                    $exe = $argv[0]
                    $rest = @($argv | Select-Object -Skip 1)
                    $out = & $exe @rest 2>&1 | Out-String
                } else {
                    # Fallback: the placeholder is embedded inside a larger token (no
                    # standalone argv slot to target), so the call-operator path cannot
                    # substitute it. Substitute literally and run via Invoke-Expression —
                    # tolerable here because the substituted value is a temp path we
                    # created and the template carries its own quoting around the token.
                    $fileCmd = $cmd.Replace('{{prompt_file}}', $tmp)
                    $out = Invoke-Expression $fileCmd 2>&1 | Out-String
                }
            } finally {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
        } elseif ($useStdin) {
            # Robust path: pass the prompt via stdin instead of interpolating it
            # into the command string — immune to embedded quotes/backticks/$.
            # The template is a clean token list (e.g. 'codex exec -') with no
            # {{prompt}}; we split on whitespace and invoke via the call operator.
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $tmp -Value $Prompt -Encoding utf8NoBOM
                $tokens = $cmd -split '\s+' | Where-Object { $_ -ne '' }
                $exe = $tokens[0]
                $rest = @($tokens | Select-Object -Skip 1)
                $out = (Get-Content -LiteralPath $tmp -Raw | & $exe @rest 2>&1 | Out-String)
            } finally {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
        } else {
            # Legacy path: naive substitution. Embedded double-quotes may break
            # invocation — keep prompts single-quote-safe, or set `stdin: true`.
            $out = Invoke-Expression $cmd 2>&1 | Out-String
        }
        $exit = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        $duration = [int]((Get-Date) - $start).TotalSeconds
        $tok = Get-FleetTokenUsage -Provider $Provider -Prompt $Prompt -Stdout ([string]$out)
        return @{ stdout = $out; stderr = ''; exit_code = $exit; duration_s = $duration; tokens = $tok.tokens; tokens_basis = $tok.tokens_basis }
    } catch {
        $duration = [int]((Get-Date) - $start).TotalSeconds
        return @{ stdout = ''; stderr = $_.Exception.Message; exit_code = -1; duration_s = $duration; tokens = 0; tokens_basis = 'estimate' }
    } finally {
        foreach ($k in $saved.Keys) {
            if ($null -eq $saved[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
            else { Set-Item "env:$k" $saved[$k] }
        }
    }
}

function Invoke-Fleet {
    <# Main entry. Dispatches to cli or http; journals the invocation. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Model,
        [string]$Path = $script:DefaultFleetPath,
        [string]$JournalPath = (Join-Path (Get-BatonHome) 'model-routing-log.md'),
        [switch]$NoJournal
    )
    $provider = Get-FleetProvider -Name $Name -Path $Path
    if (-not $provider) { throw "Unknown fleet provider '$Name'. Run /fleet list to see valid names." }
    if ($provider.enabled -ne $true) { throw "Provider '$Name' is disabled in fleet.yaml. Set enabled: true to use." }

    if ($provider.kind -eq 'cli') {
        $result = Invoke-Fleet-Cli -Provider $provider -Prompt $Prompt -Model $Model
    } elseif ($provider.kind -eq 'http') {
        # Dot-source the per-provider escape hatch + call Invoke-<PascalName>.
        # Escape hatches live next to this library (scripts/fleet/), NOT next to
        # fleet.yaml — they're tied to the code location, not the config location.
        $scriptPath = Join-Path $PSScriptRoot "fleet/$Name.ps1"
        if (-not (Test-Path $scriptPath)) {
            throw "Provider '$Name' (kind: http) requires $scriptPath defining Invoke-<PascalName>."
        }
        . $scriptPath
        $fnName = 'Invoke-' + (($Name -split '-' | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '')
        $fn = Get-Command $fnName -ErrorAction SilentlyContinue
        if (-not $fn) { throw "$scriptPath must define $fnName." }
        $result = & $fn $provider $Prompt $Model
    } else {
        throw "Provider '$Name' has unknown kind '$($provider.kind)'."
    }

    # Normalize token fields so both cli and http paths carry them. HTTP hatches
    # that do not emit native counts fall back to an honest estimate (exact native
    # counts are a named follow-up, spec §4.1).
    if (-not $result.ContainsKey('tokens')) {
        $tok = Get-FleetTokenUsage -Provider $provider -Prompt $Prompt -Stdout ([string]$result.stdout)
        $result.tokens = $tok.tokens
        $result.tokens_basis = $tok.tokens_basis
    }

    if (-not $NoJournal) {
        Write-FleetJournalLine -Provider $Name -DurationS $result.duration_s `
            -ExitCode $result.exit_code -Prompt $Prompt -JournalPath $JournalPath `
            -Tokens $result.tokens -TokensBasis $result.tokens_basis
    }
    return $result
}
