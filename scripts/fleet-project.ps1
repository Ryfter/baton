#!/usr/bin/env pwsh
<#
.SYNOPSIS
  /baton:project — the project registry command center (d076).
  list [--json] | archive <slug> | unarchive <slug> | hide <slug> | set-blurb <slug> "<text>"
#>
param(
    [Parameter(Position = 0)][string]$Subcommand,
    [Parameter(Position = 1)][string]$Slug,
    [Parameter(Position = 2)][string]$Value,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'registry-lib.ps1')

function Write-Usage {
    [Console]::Error.WriteLine("Usage: /baton:project list [--json] | archive <slug> | unarchive <slug> | hide <slug> | set-blurb <slug> `"<text>`"")
}

function Get-RecordForSlug {
    param([string]$WantSlug)
    $projectsRoot = Join-Path (Get-BatonHome) 'projects'
    foreach ($p in @(Find-ProjectFolders)) {
        if ($p.slug -eq $WantSlug.ToLowerInvariant() -or $p.id -eq $WantSlug.ToLowerInvariant()) {
            $rec = Read-ProjectRecord -ProjectId $p.id -ProjectsRoot $projectsRoot
            $h = @{}
            if ($rec) { foreach ($pr in $rec.PSObject.Properties) { $h[$pr.Name] = $pr.Value } }
            $h['id'] = $p.id
            if (-not $h.ContainsKey('name')) { $h['name'] = (Split-Path -Leaf $p.folder) }
            if (-not $h.ContainsKey('folder')) { $h['folder'] = $p.folder }
            return @{ record = $h; projectsRoot = $projectsRoot }
        }
    }
    return $null
}

function Set-RecordField {
    param([string]$WantSlug, [string]$Field, [object]$FieldValue)
    $ctx = Get-RecordForSlug -WantSlug $WantSlug
    if (-not $ctx) { [Console]::Error.WriteLine("No project matches '$WantSlug'."); exit 2 }
    $ctx.record[$Field] = $FieldValue
    Write-ProjectRecord -Record $ctx.record -ProjectsRoot $ctx.projectsRoot
}

switch (($Subcommand | ForEach-Object { $_.ToLowerInvariant() })) {
    'list' {
        $roster = Get-ProjectRoster
        if ($Json) {
            ConvertTo-Json -InputObject $roster -Depth 6
        } else {
            function Show($title, $rows) {
                Write-Host "== $title =="
                if (@($rows).Count -eq 0) { Write-Host "  (none)"; return }
                foreach ($r in $rows) {
                    $tag = if ($r.resumable) { ' [resumable]' } else { '' }
                    Write-Host ("  {0,-24} {1}{2}" -f $r.slug, $r.blurb, $tag)
                }
            }
            Show 'Active'   $roster.active
            Show 'Inactive' $roster.inactive
            Show 'Archived' $roster.archived
        }
        exit 0
    }
    'archive'   { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'archived' -FieldValue $true;  Write-Host "Archived '$Slug'."; exit 0 }
    'unarchive' { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'archived' -FieldValue $false; Write-Host "Unarchived '$Slug'."; exit 0 }
    'hide'      { if (-not $Slug) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'hidden' -FieldValue $true;    Write-Host "Hid '$Slug'."; exit 0 }
    'set-blurb' { if (-not $Slug -or $null -eq $Value) { Write-Usage; exit 2 }; Set-RecordField -WantSlug $Slug -Field 'blurb' -FieldValue $Value; Write-Host "Blurb set for '$Slug'."; exit 0 }
    default     { Write-Usage; exit 2 }
}
