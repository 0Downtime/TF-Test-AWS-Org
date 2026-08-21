[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$GitLabBaseUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$IssuerUrl,

    [Parameter(Mandatory)]
    [string]$BucketName,

    [Parameter(Mandatory)]
    [string]$DistributionId,

    [string]$AwsProfile,

    [string]$AwsRegion = 'us-east-1'
)

$ErrorActionPreference = 'Stop'

function Invoke-AwsCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ([string]::IsNullOrWhiteSpace($AwsProfile)) {
        & aws @Arguments
    }
    else {
        & aws --profile $AwsProfile @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed with exit code $LASTEXITCODE."
    }
}

$gitLabUrl = $GitLabBaseUrl.TrimEnd('/')
$issuer = $IssuerUrl.TrimEnd('/')
$wellKnownUri = "$issuer/.well-known/openid-configuration"
$jwksUri = "$issuer/oauth/discovery/keys"
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("gitlab-oidc-" + [guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null

try {
    Write-Information "Fetching GitLab OIDC configuration from $gitLabUrl" -InformationAction Continue
    $configuration = Invoke-RestMethod -Uri "$gitLabUrl/.well-known/openid-configuration"
    $keys = Invoke-RestMethod -Uri "$gitLabUrl/oauth/discovery/keys"

    if ($null -eq $configuration.issuer -or $null -eq $configuration.jwks_uri) {
        throw 'GitLab discovery response is missing issuer or jwks_uri.'
    }

    $configuration.issuer = $issuer
    $configuration.jwks_uri = $jwksUri

    $configurationPath = Join-Path $temporaryDirectory 'openid-configuration.json'
    $keysPath = Join-Path $temporaryDirectory 'keys.json'

    $configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configurationPath -Encoding utf8NoBOM
    $keys | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $keysPath -Encoding utf8NoBOM

    $commonArguments = @(
        's3', 'cp',
        '--region', $AwsRegion,
        '--cache-control', 'max-age=60, must-revalidate',
        '--content-type', 'application/json',
        '--sse', 'AES256'
    )

    # Publish JWKS first so a key rotation cannot produce a token whose key
    # is newer than the public verification set.
    Invoke-AwsCli -Arguments ($commonArguments + @(
        $keysPath,
        "s3://$BucketName/oauth/discovery/keys"
    ))

    Invoke-AwsCli -Arguments ($commonArguments + @(
        $configurationPath,
        "s3://$BucketName/.well-known/openid-configuration"
    ))

    Invoke-AwsCli -Arguments @(
        'cloudfront', 'create-invalidation',
        '--distribution-id', $DistributionId,
        '--paths', '/.well-known/openid-configuration', '/oauth/discovery/keys'
    )

    Write-Information "Published GitLab OIDC metadata at $wellKnownUri and $jwksUri" -InformationAction Continue
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
