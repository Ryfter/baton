[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $parts = foreach ($item in $Value) {
            ConvertTo-PlainText -Value $item
        }
        return ($parts | Where-Object { $_ }) -join "`n"
    }

    $properties = @("text", "content", "message", "result", "response", "output")
    foreach ($name in $properties) {
        if ($Value.PSObject.Properties.Name -contains $name) {
            $text = ConvertTo-PlainText -Value $Value.$name
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
    }

    return ""
}

function Get-DirectAssistantText {
    param([object]$Payload)

    $fields = @(
        "final_message",
        "finalMessage",
        "assistant_message",
        "assistantMessage",
        "message",
        "response",
        "output",
        "content",
        "text"
    )

    foreach ($field in $fields) {
        if ($Payload.PSObject.Properties.Name -contains $field) {
            $text = ConvertTo-PlainText -Value $Payload.$field
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return $text
            }
        }
    }

    return ""
}

function Get-TranscriptAssistantText {
    param([string]$TranscriptPath)

    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path -LiteralPath $TranscriptPath)) {
        return ""
    }

    $lastAssistantText = ""

    foreach ($line in Get-Content -LiteralPath $TranscriptPath -Tail 200) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        $isAssistant = $false
        if (($entry.PSObject.Properties.Name -contains "type") -and $entry.type -eq "assistant") {
            $isAssistant = $true
        }
        if (($entry.PSObject.Properties.Name -contains "role") -and $entry.role -eq "assistant") {
            $isAssistant = $true
        }
        if (($entry.PSObject.Properties.Name -contains "message") -and
            ($entry.message.PSObject.Properties.Name -contains "role") -and
            $entry.message.role -eq "assistant") {
            $isAssistant = $true
        }

        if (-not $isAssistant) {
            continue
        }

        $text = ConvertTo-PlainText -Value $entry
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $lastAssistantText = $text
        }
    }

    return $lastAssistantText
}

function Normalize-Capture {
    param([string]$Text)

    return (($Text -replace "\s+", " ").Trim(" `t`r`n.;,:"))
}

function New-DecisionMatch {
    param([string]$Text)

    $normalized = $Text -replace "\s+", " "
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    $patterns = @(
        @{
            Kind = "over"
            Regex = "\bI(?:'ll| will)\s+go with\s+(?<chosen>[^.;:`r`n]{3,120}?)\s+over\s+(?<alt>[^.;`r`n]{3,120})(?:[.;]|$)"
        },
        @{
            Kind = "because"
            Regex = "\b(?:I\s+)?chose\s+(?<chosen>[^.;:`r`n]{3,140}?)\s+because\s+(?<reason>[^.;`r`n]{8,240})(?:[.;]|$)"
        },
        @{
            Kind = "rather-than"
            Regex = "\b(?:I\s+)?decided\s+to\s+(?<chosen>[^.;:`r`n]{3,160}?)\s+rather than\s+(?<alt>[^.;`r`n]{3,160})(?:[.;]|$)"
        }
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($normalized, $pattern.Regex, $options)
        if (-not $match.Success) {
            continue
        }

        $chosen = Normalize-Capture -Text ($match.Groups["chosen"].Value)
        $alternative = ""
        $reason = ""

        if ($match.Groups["alt"].Success) {
            $alternative = Normalize-Capture -Text ($match.Groups["alt"].Value)
        }
        if ($match.Groups["reason"].Success) {
            $reason = Normalize-Capture -Text ($match.Groups["reason"].Value)
        }

        if ($chosen.Length -lt 3) {
            continue
        }
        if ($pattern.Kind -ne "because" -and $alternative.Length -lt 3) {
            continue
        }
        if ($pattern.Kind -eq "because" -and $reason.Length -lt 8) {
            continue
        }

        return [pscustomobject]@{
            Chosen = $chosen
            Alternative = $alternative
            Reason = $reason
            Kind = $pattern.Kind
        }
    }

    return $null
}

function ConvertTo-YamlValue {
    param([string]$Value)

    $escaped = ($Value -replace "\\", "\\" -replace '"', '\"')
    return '"' + $escaped + '"'
}

$stdin = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($stdin)) {
    exit 0
}

try {
    $payload = $stdin | ConvertFrom-Json -ErrorAction Stop
}
catch {
    exit 0
}

$assistantText = Get-DirectAssistantText -Payload $payload
if ([string]::IsNullOrWhiteSpace($assistantText) -and ($payload.PSObject.Properties.Name -contains "transcript_path")) {
    $assistantText = Get-TranscriptAssistantText -TranscriptPath $payload.transcript_path
}

if ([string]::IsNullOrWhiteSpace($assistantText)) {
    exit 0
}

$decision = New-DecisionMatch -Text $assistantText
if ($null -eq $decision) {
    exit 0
}

$title = "Decision: $($decision.Chosen)"
if ($title.Length -gt 90) {
    $title = $title.Substring(0, 87).TrimEnd() + "..."
}

$alternative = if ($decision.Alternative) { $decision.Alternative } else { "Not captured from final response." }
$rationale = if ($decision.Reason) { $decision.Reason } else { "The final response explicitly selected this option over an alternative." }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$fileName = "decision-intake-$timestamp.md"
$tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$draftPath = Join-Path -Path $tempRoot -ChildPath $fileName

$markdown = @(
    "---"
    "title: $(ConvertTo-YamlValue -Value $title)"
    "confidence: medium"
    "revisit-if: $(ConvertTo-YamlValue -Value "New evidence changes the tradeoff, requirements shift, or the rejected alternative becomes materially cheaper.")"
    "---"
    ""
    "## Chosen"
    $decision.Chosen
    ""
    "## Alternatives"
    $alternative
    ""
    "## Rationale"
    $rationale
    ""
) -join "`n"

Set-Content -LiteralPath $draftPath -Value $markdown -Encoding UTF8
Write-Output "Decision draft captured: $draftPath. Suggested intake: d### intake `"$draftPath`""
