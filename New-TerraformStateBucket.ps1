param(
    [string]$Profile = "management",
    [string]$Region = "us-east-1",
    [string]$BucketName = ""
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

function Invoke-Aws {
    param([string[]]$Arguments)

    # PowerShell 7 can turn native-command stderr into a terminating error.
    # Keep it in the captured output so the AWS CLI message is visible below.
    $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false

    try {
        $output = & aws @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    }

    if ($exitCode -ne 0) {
        throw "AWS CLI failed:`n$($output -join "`n")"
    }

    return $output
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI was not found. Install AWS CLI for Windows first."
}

Write-Host "Checking AWS credentials..."
$caller = ((Invoke-Aws -Arguments @(
    "sts", "get-caller-identity",
    "--profile", $Profile,
    "--output", "json"
)) -join "`n") | ConvertFrom-Json

$accountId = $caller.Account
Write-Host "Using AWS account: $accountId"

if ([string]::IsNullOrWhiteSpace($BucketName)) {
    $BucketName = "tfstate-0downtime-aws-org-$accountId"
}

Write-Host "Using bucket: $BucketName"

$bucketExists = $true
try {
    Invoke-Aws -Arguments @(
        "s3api", "head-bucket",
        "--bucket", $BucketName,
        "--profile", $Profile
    ) | Out-Null

    Write-Host "Bucket already exists and is accessible."
}
catch {
    $bucketExists = $false
    Write-Host "Creating bucket..."

    $createArgs = @(
        "s3api", "create-bucket",
        "--bucket", $BucketName,
        "--region", $Region,
        "--profile", $Profile
    )

    if ($Region -ne "us-east-1") {
        $createArgs += @(
            "--create-bucket-configuration",
            "LocationConstraint=$Region"
        )
    }

    Invoke-Aws -Arguments $createArgs | Out-Null
}

Write-Host "Enabling versioning..."
Invoke-Aws -Arguments @(
    "s3api", "put-bucket-versioning",
    "--bucket", $BucketName,
    "--versioning-configuration", "Status=Enabled",
    "--profile", $Profile
) | Out-Null

Write-Host "Enabling default AES-256 encryption..."
Invoke-Aws -Arguments @(
    "s3api", "put-bucket-encryption",
    "--bucket", $BucketName,
    "--server-side-encryption-configuration",
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}',
    "--profile", $Profile
) | Out-Null

Write-Host "Blocking public access..."
Invoke-Aws -Arguments @(
    "s3api", "put-public-access-block",
    "--bucket", $BucketName,
    "--public-access-block-configuration",
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true",
    "--profile", $Profile
) | Out-Null

Write-Host "Enforcing bucket ownership..."
Invoke-Aws -Arguments @(
    "s3api", "put-bucket-ownership-controls",
    "--bucket", $BucketName,
    "--ownership-controls",
    "Rules=[{ObjectOwnership=BucketOwnerEnforced}]",
    "--profile", $Profile
) | Out-Null

Write-Host "Adding tags..."
Invoke-Aws -Arguments @(
    "s3api", "put-bucket-tagging",
    "--bucket", $BucketName,
    "--tagging",
    "TagSet=[{Key=Purpose,Value=TerraformState},{Key=ManagedBy,Value=Terraform}]",
    "--profile", $Profile
) | Out-Null

Write-Host "Verifying versioning..."
$versioning = ((Invoke-Aws -Arguments @(
    "s3api", "get-bucket-versioning",
    "--bucket", $BucketName,
    "--profile", $Profile,
    "--output", "json"
)) -join "`n") | ConvertFrom-Json

if ($versioning.Status -ne "Enabled") {
    throw "Verification failed: bucket versioning is not enabled."
}

Write-Host "Verifying encryption..."
$encryption = ((Invoke-Aws -Arguments @(
    "s3api", "get-bucket-encryption",
    "--bucket", $BucketName,
    "--profile", $Profile,
    "--output", "json"
)) -join "`n") | ConvertFrom-Json

$algorithm = $encryption.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm

if ($algorithm -ne "AES256") {
    throw "Verification failed: expected AES256 encryption."
}

Write-Host "Verifying public access block..."
$publicAccess = ((Invoke-Aws -Arguments @(
    "s3api", "get-public-access-block",
    "--bucket", $BucketName,
    "--profile", $Profile,
    "--output", "json"
)) -join "`n") | ConvertFrom-Json

$config = $publicAccess.PublicAccessBlockConfiguration

if (
    -not $config.BlockPublicAcls -or
    -not $config.IgnorePublicAcls -or
    -not $config.BlockPublicPolicy -or
    -not $config.RestrictPublicBuckets
) {
    throw "Verification failed: public access is not fully blocked."
}

Write-Host ""
Write-Host "Terraform state bucket verified successfully." -ForegroundColor Green
Write-Host ""
Write-Host "Use this bucket in each stage's backend.hcl:"
Write-Host "bucket       = `"$BucketName`""
Write-Host "region       = `"$Region`""
Write-Host "use_lockfile = true"
Write-Host "encrypt      = true"
