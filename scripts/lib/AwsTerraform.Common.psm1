Set-StrictMode -Version Latest

function Get-ConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) {
        $value = $Object[$Name]
        if ($null -eq $value) {
            return $Default
        }
        return $value
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Assert-ValuePresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        $Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Configuration value '$Name' is required."
    }
}

function ConvertTo-RedactedAwsOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Output
    )

    return ($Output -join "`n") -replace '(?i)(token|secret|password|authorization)[^\r\n]*', '$1=<redacted>'
}

function Invoke-AwsCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'AWS CLI was not found. Install AWS CLI v2 first.'
    }

    $output = & aws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI failed:`n$(ConvertTo-RedactedAwsOutput -Output $output)"
    }

    return $output
}

function Invoke-AwsJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $json = (Invoke-AwsCli -Arguments ($Arguments + @('--output', 'json'))) -join "`n"
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Write-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 100)]
        [int]$Depth = 20
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $InputObject | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

Export-ModuleMember -Function @(
    'ConvertTo-RedactedAwsOutput',
    'Get-ConfigValue',
    'Invoke-AwsCli',
    'Invoke-AwsJson',
    'Assert-ValuePresent',
    'Write-JsonFile'
)
