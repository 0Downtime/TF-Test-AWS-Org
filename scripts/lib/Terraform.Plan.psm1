Set-StrictMode -Version Latest

function Invoke-TerraformSavedPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagePath,

        [Parameter(Mandatory = $true)]
        [string]$PlanPath
    )

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw 'Terraform was not found. Install Terraform before applying the governance plan.'
    }

    $stage = (Resolve-Path -LiteralPath $StagePath -ErrorAction Stop).Path
    $plan = if ([IO.Path]::IsPathRooted($PlanPath)) {
        [IO.Path]::GetFullPath($PlanPath)
    } else {
        [IO.Path]::GetFullPath((Join-Path $stage $PlanPath))
    }

    Write-Information "Creating Terraform plan at $plan..." -InformationAction Continue
    & terraform "-chdir=$stage" plan -input=false "-out=$plan"
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform governance plan failed.'
    }

    Write-Information "Applying the saved Terraform plan at $plan..." -InformationAction Continue
    & terraform "-chdir=$stage" apply -input=false $plan
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform governance apply failed.'
    }

    return [pscustomobject]@{
        stagePath = $stage
        planPath  = $plan
    }
}

Export-ModuleMember -Function 'Invoke-TerraformSavedPlan'
