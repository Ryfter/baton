#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Credential handling for authenticated HTTP instruments.
.DESCRIPTION
  Extracted from fleet-lib so that both the dispatch transport and the usage
  probes can use it WITHOUT the two libraries having to source each other.
  fleet-lib needs usage-probe-lib (the prepaid cap guard) and usage-probe-lib
  needs these two helpers; a shared leaf breaks that cycle instead of papering
  over it with a lazy in-function load.

  Rules enforced here, not in documentation:
    - A row names the ENVIRONMENT VARIABLE holding its credential, never the
      credential, so registry files stay safe to commit and share.
    - A declared-but-unset key is a loud error, never a silent downgrade to an
      anonymous request.
    - Anything that might be journaled gets the credential scrubbed out of it.
#>

function Resolve-FleetHttpAuth {
    <# Build the request headers for an HTTP instrument, and report the secret so
       callers can scrub it out of anything they journal.

       A row that declares `api_key_env` but whose variable is unset is a LOUD
       failure, never a silent unauthenticated call: against a paid endpoint an
       anonymous request is a 401 whose message says nothing useful, and against
       a permissive one it would spend from the wrong account.

       Returns @{ headers; secret; error }. `error` non-null means do not dispatch. #>
    param([Parameter(Mandatory)][hashtable]$Provider)
    $headers = @{}
    if ($Provider.headers -is [hashtable]) {
        foreach ($headerName in $Provider.headers.Keys) {
            $headers[[string]$headerName] = [string]$Provider.headers[$headerName]
        }
    }
    $keyEnv = [string]$Provider.api_key_env
    if ([string]::IsNullOrWhiteSpace($keyEnv)) {
        return @{ headers = $headers; secret = $null; error = $null }
    }
    $secret = [Environment]::GetEnvironmentVariable($keyEnv)
    if ([string]::IsNullOrWhiteSpace($secret)) {
        return @{
            headers = $null
            secret = $null
            error = "api_key_env '$keyEnv' is declared but not set in the environment."
        }
    }
    # Defaults cover every OpenAI-compatible endpoint (Authorization: Bearer ...).
    # auth_header / auth_prefix exist for the x-api-key dialects; an explicitly
    # empty auth_prefix is honoured, so ContainsKey (not truthiness) decides.
    $authHeader = if ($Provider.auth_header) { [string]$Provider.auth_header } else { 'Authorization' }
    $authPrefix = if ($Provider.ContainsKey('auth_prefix')) { [string]$Provider.auth_prefix } else { 'Bearer ' }
    $headers[$authHeader] = "$authPrefix$secret"
    return @{ headers = $headers; secret = [string]$secret; error = $null }
}

function Protect-FleetSecret {
    <# Redact a live credential out of transport text before it reaches a journal
       or the console. No secret / no text -> the text unchanged. #>
    param([string]$Text, [string]$Secret)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrWhiteSpace($Secret)) { return $Text }
    return $Text.Replace($Secret, '<redacted>')
}
