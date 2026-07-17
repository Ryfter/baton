#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][ValidateSet('usage-total','usage-sum','no-usage','non-200','timeout')][string]$Mode,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$CapturePath,
    [int]$MaxRequests = 1,
    [int]$DelayMs = 0
)

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start()
    Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding utf8NoBOM
    for ($requestIndex = 0; $requestIndex -lt $MaxRequests; $requestIndex++) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
            $requestLine = $reader.ReadLine()
            $contentLength = 0
            while ($true) {
                $headerLine = $reader.ReadLine()
                if ($null -eq $headerLine -or $headerLine -eq '') { break }
                $lengthMatch = [regex]::Match($headerLine, '^Content-Length:\s*(\d+)$', 'IgnoreCase')
                if ($lengthMatch.Success) { $contentLength = [int]$lengthMatch.Groups[1].Value }
            }
            $body = ''
            if ($contentLength -gt 0) {
                $buffer = [char[]]::new($contentLength)
                $readCount = 0
                while ($readCount -lt $contentLength) {
                    $chunk = $reader.Read($buffer, $readCount, $contentLength - $readCount)
                    if ($chunk -le 0) { break }
                    $readCount += $chunk
                }
                $body = [string]::new($buffer, 0, $readCount)
            }
            $capture = [ordered]@{ request_line = $requestLine; body = $body }
            Add-Content -LiteralPath $CapturePath `
                -Value (ConvertTo-Json -InputObject $capture -Compress) -Encoding utf8NoBOM

            $path = ([string]$requestLine -split ' ')[1]
            if ($path -eq '/v1/models') {
                $status = '200 OK'
                $responseObject = [ordered]@{ data = @([ordered]@{ id = 'listed-model' }) }
            } elseif ($Mode -eq 'non-200') {
                $status = '503 Service Unavailable'
                $responseObject = [ordered]@{ error = [ordered]@{ message = 'fixture unavailable' } }
            } else {
                if ($Mode -eq 'timeout' -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
                $status = '200 OK'
                $responseObject = [ordered]@{
                    choices = @([ordered]@{ message = [ordered]@{ content = "reply:$Mode" } })
                }
                if ($Mode -eq 'usage-total') {
                    $responseObject.usage = [ordered]@{ total_tokens = 41; prompt_tokens = 10; completion_tokens = 31 }
                } elseif ($Mode -eq 'usage-sum') {
                    $responseObject.usage = [ordered]@{ prompt_tokens = 12; completion_tokens = 8 }
                }
            }
            $json = ConvertTo-Json -InputObject $responseObject -Depth 8 -Compress
            $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
            $headers = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            $stream.Write($payload, 0, $payload.Length)
            $stream.Flush()
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
