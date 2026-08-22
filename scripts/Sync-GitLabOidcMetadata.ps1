[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [uri] $GitLabBaseUrl,

    [Parameter(Mandatory)]
    [uri] $PublicIssuerUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string] $MetadataBucket,

    [string] $AwsProfile = '',

    [string] $AwsRegion = 'us-east-1',

    [string] $AwsCommand = 'aws',

    [ValidateRange(60, 3600)]
    [int] $CacheSeconds = 300,

    [switch] $ValidatePublic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BaseUrl {
    param([uri] $Value)

    return $Value.AbsoluteUri.TrimEnd('/')
}

function Invoke-JsonGet {
    param([uri] $Uri)

    $response = Invoke-WebRequest -Uri $Uri -Method Get -Headers @{ Accept = 'application/json' }
    if ($response.StatusCode -ne 200) {
        throw "GET $Uri returned HTTP $($response.StatusCode)."
    }

    return $response.Content | ConvertFrom-Json
}

function Invoke-Aws {
    param([string[]] $Arguments)

    $output = & $AwsCommand @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed with exit code $LASTEXITCODE."
    }

    return $output
}

function Get-AwsArguments {
    param([string[]] $Arguments)

    $result = @($Arguments)
    if ($AwsProfile -ne '') {
        $result += @('--profile', $AwsProfile)
    }
    if ($AwsRegion -ne '') {
        $result += @('--region', $AwsRegion)
    }
    $result += @('--no-cli-pager')
    return $result
}

$gitLabUrl = Get-BaseUrl -Value $GitLabBaseUrl
$publicIssuer = Get-BaseUrl -Value $PublicIssuerUrl

if ($PublicIssuerUrl.Scheme -ne 'https') {
    throw 'PublicIssuerUrl must use HTTPS.'
}

$sourceDiscoveryUrl = [uri] "$gitLabUrl/.well-known/openid-configuration"
$sourceJwksUrl = [uri] "$gitLabUrl/oauth/discovery/keys"
$publicDiscoveryUrl = [uri] "$publicIssuer/.well-known/openid-configuration"
$publicJwksUrl = [uri] "$publicIssuer/oauth/discovery/keys"

Write-Verbose "Reading private GitLab discovery metadata from $sourceDiscoveryUrl"
$discovery = Invoke-JsonGet -Uri $sourceDiscoveryUrl
Write-Verbose "Reading private GitLab signing keys from $sourceJwksUrl"
$jwks = Invoke-JsonGet -Uri $sourceJwksUrl

if (-not $discovery.issuer) {
    throw 'The GitLab discovery document does not contain an issuer.'
}
if (-not $discovery.jwks_uri) {
    throw 'The GitLab discovery document does not contain a jwks_uri.'
}
if (-not $jwks.keys -or @($jwks.keys).Count -eq 0) {
    throw 'The GitLab JWKS document contains no signing keys; refusing to publish it.'
}

# AWS must see the public mirror as the issuer. The source document may still
# contain the private GitLab URL, especially before GitLab is reconfigured.
$discovery.issuer = $publicIssuer
$discovery.jwks_uri = $publicJwksUrl.AbsoluteUri

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "gitlab-oidc-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null

try {
    $discoveryPath = Join-Path $temporaryDirectory 'openid-configuration.json'
    $jwksPath = Join-Path $temporaryDirectory 'keys.json'

    $discovery | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $discoveryPath -Encoding utf8 -NoNewline
    $jwks | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $jwksPath -Encoding utf8 -NoNewline

    $objects = @(
        [pscustomobject]@{
            Key         = 'oauth/discovery/keys'
            Path        = $jwksPath
            ContentType = 'application/json'
        },
        [pscustomobject]@{
            Key         = '.well-known/openid-configuration'
            Path        = $discoveryPath
            ContentType = 'application/json'
        }
    )

    $results = foreach ($object in $objects) {
        $hash = (Get-FileHash -LiteralPath $object.Path -Algorithm SHA256).Hash.ToLowerInvariant()
        $headArgs = Get-AwsArguments -Arguments @(
            's3api', 'head-object',
            '--bucket', $MetadataBucket,
            '--key', $object.Key,
            '--output', 'json'
        )

        $remoteHash = $null
        $headOutput = & $AwsCommand @headArgs 2>$null
        $headExitCode = $LASTEXITCODE
        if ($headExitCode -eq 0 -and $headOutput) {
            $head = $headOutput | ConvertFrom-Json
            if ($head.Metadata -and $head.Metadata.sha256) {
                $remoteHash = [string] $head.Metadata.sha256
            }
        }
        elseif ($headExitCode -ne 254) {
            throw "Unable to inspect s3://$MetadataBucket/$($object.Key); AWS CLI exit code was $headExitCode."
        }

        if ($remoteHash -eq $hash) {
            [pscustomobject]@{
                Key    = $object.Key
                Status = 'unchanged'
                Sha256 = $hash
            }
            continue
        }

        $target = "s3://$MetadataBucket/$($object.Key)"
        if ($PSCmdlet.ShouldProcess($target, 'publish OIDC metadata')) {
            # Publish JWKS before discovery when keys change, so AWS can find a
            # newly issued key before GitLab advertises the mirrored issuer.
            $putArgs = Get-AwsArguments -Arguments @(
                's3api', 'put-object',
                '--bucket', $MetadataBucket,
                '--key', $object.Key,
                '--body', $object.Path,
                '--content-type', $object.ContentType,
                '--cache-control', "max-age=$CacheSeconds",
                '--metadata', "sha256=$hash",
                '--server-side-encryption', 'AES256',
                '--output', 'json'
            )
            Invoke-Aws -Arguments $putArgs | Out-Null
            $status = 'uploaded'
        }
        else {
            $status = 'whatif'
        }

        [pscustomobject]@{
            Key    = $object.Key
            Status = $status
            Sha256 = $hash
        }
    }

    if ($ValidatePublic -and -not $WhatIfPreference) {
        Write-Verbose "Validating public discovery metadata at $publicDiscoveryUrl"
        $publicDiscovery = Invoke-JsonGet -Uri $publicDiscoveryUrl
        $publicKeys = Invoke-JsonGet -Uri $publicJwksUrl

        if ($publicDiscovery.issuer -ne $publicIssuer) {
            throw "Public discovery issuer '$($publicDiscovery.issuer)' does not equal '$publicIssuer'."
        }
        if ($publicDiscovery.jwks_uri -ne $publicJwksUrl.AbsoluteUri) {
            throw "Public discovery jwks_uri '$($publicDiscovery.jwks_uri)' does not equal '$($publicJwksUrl.AbsoluteUri)'."
        }
        if (-not $publicKeys.keys -or @($publicKeys.keys).Count -eq 0) {
            throw 'Public JWKS contains no signing keys.'
        }
    }

    $results | ConvertTo-Json -Depth 5
}
finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
