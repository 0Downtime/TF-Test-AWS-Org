[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1024, 65535)]
    [int] $Port,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $DiscoveryPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $JwksPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $path = $context.Request.Url.AbsolutePath

        switch ($path) {
            '/.well-known/openid-configuration' {
                $file = $DiscoveryPath
                $contentType = 'application/json'
                break
            }
            '/oauth/discovery/keys' {
                $file = $JwksPath
                $contentType = 'application/json'
                break
            }
            default {
                $context.Response.StatusCode = 404
                $context.Response.Close()
                continue
            }
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $file -Raw))
        $context.Response.StatusCode = 200
        $context.Response.ContentType = $contentType
        $context.Response.ContentLength64 = $bytes.Length
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
}
finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
}
