[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [uri] $PublicIssuerUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$')]
    [string] $MetadataBucket,

    [ValidatePattern('^arn:aws:iam::[0-9]{12}:role/.+$')]
    [string] $RoleArn = '',

    [Parameter(Mandatory)]
    [string] $AllowedSubject,

    [string] $AwsProfile = '',

    [string] $AwsRegion = 'us-east-1',

    [string] $AwsCommand = 'aws',

    [string] $SyncScriptPath = (Join-Path $PSScriptRoot 'Sync-GitLabOidcMetadata.ps1'),

    [string] $ServerScriptPath = (Join-Path $PSScriptRoot 'PseudoGitLabOidcServer.ps1'),

    [switch] $SkipSts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-FreeLoopbackPort {
    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $tcp.Start()
        return ([System.Net.IPEndPoint] $tcp.LocalEndpoint).Port
    }
    finally {
        $tcp.Stop()
    }
}

function Restore-EnvironmentVariable {
    param(
        [string] $Name,
        [AllowNull()] [string] $Value
    )

    if ($null -eq $Value) {
        Remove-Item "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item "Env:$Name" $Value
    }
}

if ($PublicIssuerUrl.Scheme -ne 'https') {
    throw 'PublicIssuerUrl must use HTTPS.'
}
if (-not (Test-Path -LiteralPath $SyncScriptPath -PathType Leaf)) {
    throw "Sync script was not found: $SyncScriptPath"
}
if (-not (Test-Path -LiteralPath $ServerScriptPath -PathType Leaf)) {
    throw "Pseudo-GitLab server script was not found: $ServerScriptPath"
}
if (-not $SkipSts -and [string]::IsNullOrWhiteSpace($RoleArn)) {
    throw 'RoleArn is required unless SkipSts is specified.'
}

$publicIssuer = $PublicIssuerUrl.AbsoluteUri.TrimEnd('/')
$audience = 'sts.amazonaws.com'
$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "pseudo-gitlab-oidc-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null

$serverProcess = $null
$rsa = $null
$tokenPath = Join-Path $temporaryDirectory 'token.jwt'

try {
    $port = Get-FreeLoopbackPort
    $sourceIssuer = "http://127.0.0.1:$port"
    $sourceJwksUrl = "$sourceIssuer/oauth/discovery/keys"

    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $rsaParameters = $rsa.ExportParameters($false)
    $keyId = "pseudo-gitlab-$([guid]::NewGuid().ToString('N'))"

    $jwks = [ordered]@{
        keys = @(
            [ordered]@{
                kty = 'RSA'
                use = 'sig'
                alg = 'RS256'
                kid = $keyId
                n   = ConvertTo-Base64Url -Bytes $rsaParameters.Modulus
                e   = ConvertTo-Base64Url -Bytes $rsaParameters.Exponent
            }
        )
    }

    $discovery = [ordered]@{
        issuer                                      = $sourceIssuer
        jwks_uri                                    = $sourceJwksUrl
        subject_types_supported                    = @('public')
        id_token_signing_alg_values_supported      = @('RS256')
        response_types_supported                   = @('id_token')
    }

    $discoveryPath = Join-Path $temporaryDirectory 'openid-configuration.json'
    $jwksPath = Join-Path $temporaryDirectory 'keys.json'
    $discovery | ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $discoveryPath -Encoding utf8 -NoNewline
    $jwks | ConvertTo-Json -Depth 20 -Compress | Set-Content -LiteralPath $jwksPath -Encoding utf8 -NoNewline

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $serverArguments = @(
        '-NoProfile',
        '-File', $ServerScriptPath,
        '-Port', $port,
        '-DiscoveryPath', $discoveryPath,
        '-JwksPath', $jwksPath
    )
    $serverProcess = Start-Process -FilePath $pwsh -ArgumentList $serverArguments -PassThru

    $sourceDiscoveryUrl = "$sourceIssuer/.well-known/openid-configuration"
    $ready = $false
    foreach ($attempt in 1..30) {
        try {
            $probe = Invoke-WebRequest -Uri $sourceDiscoveryUrl -UseBasicParsing
            if ($probe.StatusCode -eq 200) {
                $ready = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if (-not $ready) {
        throw 'The pseudo-GitLab HTTP server did not become ready.'
    }

    Write-Host 'Synchronizing pseudo-GitLab discovery and JWKS through the real sync script.'
    & $SyncScriptPath `
        -GitLabBaseUrl $sourceIssuer `
        -PublicIssuerUrl $publicIssuer `
        -MetadataBucket $MetadataBucket `
        -AwsProfile $AwsProfile `
        -AwsRegion $AwsRegion `
        -AwsCommand $AwsCommand `
        -ValidatePublic
    if ($LASTEXITCODE -ne 0) {
        throw "Metadata synchronization failed with exit code $LASTEXITCODE."
    }

    if ($SkipSts) {
        [pscustomobject]@{
            Test   = 'pseudo-gitlab-oidc-sync'
            Issuer = $publicIssuer
            Result = 'sync-passed'
        } | ConvertTo-Json -Depth 5
        return
    }

    $issuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{
        alg = 'RS256'
        kid = $keyId
        typ = 'JWT'
    } | ConvertTo-Json -Compress
    $payload = [ordered]@{
        iss = $publicIssuer
        sub = $AllowedSubject
        aud = $audience
        iat = $issuedAt
        exp = $issuedAt + 600
        jti = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    $encodedHeader = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))
    $encodedPayload = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))
    $signingInput = "$encodedHeader.$encodedPayload"
    $signature = $rsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $token = "$signingInput.$(ConvertTo-Base64Url -Bytes $signature)"
    Set-Content -LiteralPath $tokenPath -Value $token -Encoding utf8 -NoNewline
    if ($IsLinux -or $IsMacOS) {
        & chmod 600 $tokenPath
    }

    $savedEnvironment = @{
        AWS_PROFILE                 = $env:AWS_PROFILE
        AWS_ROLE_ARN                = $env:AWS_ROLE_ARN
        AWS_WEB_IDENTITY_TOKEN_FILE = $env:AWS_WEB_IDENTITY_TOKEN_FILE
        AWS_ROLE_SESSION_NAME       = $env:AWS_ROLE_SESSION_NAME
        AWS_REGION                  = $env:AWS_REGION
        AWS_DEFAULT_REGION          = $env:AWS_DEFAULT_REGION
        AWS_ACCESS_KEY_ID           = $env:AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY       = $env:AWS_SECRET_ACCESS_KEY
        AWS_SESSION_TOKEN           = $env:AWS_SESSION_TOKEN
        AWS_CREDENTIAL_EXPIRATION   = $env:AWS_CREDENTIAL_EXPIRATION
    }

    try {
        # Let the AWS CLI perform the standard web-identity exchange without
        # placing the synthetic JWT in a process argument or printing it.
        Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:AWS_CREDENTIAL_EXPIRATION -ErrorAction SilentlyContinue
        $env:AWS_ROLE_ARN = $RoleArn
        $env:AWS_WEB_IDENTITY_TOKEN_FILE = $tokenPath
        $env:AWS_ROLE_SESSION_NAME = 'PseudoGitLabOidcTest'
        $env:AWS_REGION = $AwsRegion
        $env:AWS_DEFAULT_REGION = $AwsRegion

        Write-Host 'Exchanging the synthetic GitLab-style JWT with AWS STS.'
        $identityJson = & $AwsCommand sts get-caller-identity --output json --region $AwsRegion
        if ($LASTEXITCODE -ne 0) {
            throw "AWS STS web-identity exchange failed with exit code $LASTEXITCODE."
        }

        $identity = $identityJson | ConvertFrom-Json
        [pscustomobject]@{
            Test                 = 'pseudo-gitlab-oidc'
            Issuer               = $publicIssuer
            Audience             = $audience
            Subject              = $AllowedSubject
            AssumedRoleAccountId = $identity.Account
            AssumedRoleArn       = $identity.Arn
            AssumedRoleUserId    = $identity.UserId
            Result               = 'passed'
        } | ConvertTo-Json -Depth 5
    }
    finally {
        foreach ($name in $savedEnvironment.Keys) {
            Restore-EnvironmentVariable -Name $name -Value $savedEnvironment[$name]
        }
    }
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($rsa) {
        $rsa.Dispose()
    }
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
