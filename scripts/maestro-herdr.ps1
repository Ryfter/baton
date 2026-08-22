#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Maestro ↔ Herdr runtime bridge — doctor, prompt, wait, fire (slice 6 spike).

.DESCRIPTION
  Optional path when HERDR=1: long-running agent labor in persistent Herdr panes
  instead of inline fleet-go. Requires a running Herdr server and HERDR_TARGET
  (agent pane name) for fire.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Subcommand,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest,
    [string]$Target,
    [string]$Text,
    [string]$Kind = 'grok',
    [string]$Pane,
    [string]$Name,
    [int]$TimeoutMs = 1800000,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Write-HerdrUserError([string]$Msg) {
    [Console]::Error.WriteLine($Msg)
    exit 2
}

function Get-HerdrExe {
    $cmd = Get-Command herdr -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'herdr not found on PATH — install from https://herdr.dev/' }
    return $cmd.Source
}

function Invoke-HerdrCli {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [int]$TimeoutSec = 0
    )
    $exe = Get-HerdrExe
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.Arguments = ($Args | ForEach-Object {
        if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch { }
            throw "herdr timed out after ${TimeoutSec}s"
        }
    } else {
        $proc.WaitForExit()
    }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $proc.StandardOutput.ReadToEnd()
        Stderr   = $proc.StandardError.ReadToEnd()
    }
}

function Test-HerdrDoctor {
    $exe = Get-HerdrExe
    $ver = & $exe --version 2>&1 | Out-String
    $status = Invoke-HerdrCli -Args @('status', 'server') -TimeoutSec 5
    $ok = ($status.ExitCode -eq 0)
    return [pscustomobject]@{
        exe           = $exe
        version       = $ver.Trim()
        server_ok     = $ok
        server_stdout = $status.Stdout.Trim()
        server_stderr = $status.Stderr.Trim()
    }
}

function Invoke-HerdrPromptWait {
    param(
        [Parameter(Mandatory)][string]$AgentTarget,
        [Parameter(Mandatory)][string]$PromptText,
        [int]$WaitMs = 1800000
    )
    $args = @('agent', 'prompt', $AgentTarget, $PromptText, '--wait', '--until', 'blocked', '--until', 'idle', '--until', 'done')
    if ($WaitMs -gt 0) { $args += @('--timeout', [string]$WaitMs) }
    $r = Invoke-HerdrCli -Args $args -TimeoutSec ([Math]::Max(30, [int][Math]::Ceiling($WaitMs / 1000.0) + 15))
    return $r
}

function Invoke-MaestroHerdrFire {
    <# Called from maestro-lib when HERDR=1. Returns same shape as fleet-go patch hints. #>
    param(
        [Parameter(Mandatory)][string]$Goal,
        [string]$Target = $(if ($env:HERDR_TARGET) { $env:HERDR_TARGET } else { '' }),
        [string]$Kind = $(if ($env:HERDR_KIND) { $env:HERDR_KIND } else { 'grok' }),
        [int]$TimeoutMs = $(if ($env:HERDR_TIMEOUT_MS) { [int]$env:HERDR_TIMEOUT_MS } else { 1800000 })
    )
    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw 'HERDR=1 requires HERDR_TARGET (herdr agent name)'
    }
    Test-HerdrDoctor | Out-Null
    $r = Invoke-HerdrPromptWait -AgentTarget $Target -PromptText $Goal -WaitMs $TimeoutMs
    $status = 'done'
    if ($r.ExitCode -ne 0) {
        $combined = ($r.Stdout + $r.Stderr)
        if ($combined -match 'agent_blocked|quota|rate.?limit') { $status = 'waiting-quota' }
        elseif ($combined -match 'timeout|stalled') { $status = 'done' }
        else { $status = 'done' }
    }
    return [pscustomobject]@{
        status   = $status
        run_id   = ('herdr-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        provider = "herdr:$Kind"
        exit     = $r.ExitCode
        stdout   = $r.Stdout
        stderr   = $r.Stderr
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Subcommand) {
        Write-HerdrUserError 'usage: maestro-herdr <doctor|prompt|wait|fire|start> ...'
    }
    switch ($Subcommand.ToLowerInvariant()) {
        'doctor' {
            $d = Test-HerdrDoctor
            if ($Json) { $d | ConvertTo-Json -Depth 4 } else {
                Write-Host ("herdr: {0} ({1})" -f $d.exe, $d.version)
                Write-Host ("server: {0}" -f $(if ($d.server_ok) { 'ok' } else { 'unreachable' }))
                if ($d.server_stderr) { Write-Host $d.server_stderr }
            }
            exit $(if ($d.server_ok) { 0 } else { 1 })
        }
        'prompt' {
            if (-not $Target -or -not $Text) { Write-HerdrUserError 'prompt requires -Target and -Text' }
            $r = Invoke-HerdrPromptWait -AgentTarget $Target -PromptText $Text -WaitMs $TimeoutMs
            if ($Json) { @{ exit = $r.ExitCode; stdout = $r.Stdout; stderr = $r.Stderr } | ConvertTo-Json }
            else { if ($r.Stdout) { Write-Host $r.Stdout }; if ($r.Stderr) { [Console]::Error.WriteLine($r.Stderr) } }
            exit $r.ExitCode
        }
        'wait' {
            if (-not $Target) { Write-HerdrUserError 'wait requires -Target' }
            $args = @('agent', 'wait', $Target, '--until', 'blocked', '--until', 'idle', '--until', 'done')
            if ($TimeoutMs -gt 0) { $args += @('--timeout', [string]$TimeoutMs) }
            $r = Invoke-HerdrCli -Args $args
            if ($Json) { @{ exit = $r.ExitCode; stdout = $r.Stdout; stderr = $r.Stderr } | ConvertTo-Json }
            else { if ($r.Stdout) { Write-Host $r.Stdout } }
            exit $r.ExitCode
        }
        'fire' {
            if (-not $Text) { Write-HerdrUserError 'fire requires -Text (goal prompt)' }
            $f = Invoke-MaestroHerdrFire -Goal $Text -Target $Target -Kind $Kind -TimeoutMs $TimeoutMs
            if ($Json) { $f | ConvertTo-Json -Depth 4 } else {
                Write-Host ("herdr-fire: status={0} run_id={1} provider={2} exit={3}" -f $f.status, $f.run_id, $f.provider, $f.exit)
            }
            exit $f.exit
        }
        'start' {
            if (-not $Name -or -not $Pane) { Write-HerdrUserError 'start requires -Name and -Pane' }
            $args = @('agent', 'start', $Name, '--kind', $Kind, '--pane', $Pane) + @($Rest)
            $r = Invoke-HerdrCli -Args $args
            if ($Json) { @{ exit = $r.ExitCode; stdout = $r.Stdout; stderr = $r.Stderr } | ConvertTo-Json }
            else { if ($r.Stdout) { Write-Host $r.Stdout }; if ($r.Stderr) { [Console]::Error.WriteLine($r.Stderr) } }
            exit $r.ExitCode
        }
        default { Write-HerdrUserError "unknown subcommand: $Subcommand" }
    }
}
