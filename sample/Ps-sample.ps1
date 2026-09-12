<#
.SYNOPSIS
    Prints a ready-to-paste deploy.mjs command for every environment in a
    Power Platform environment group.

.DESCRIPTION
    Resolves the named environment group and lists its member environments via
    the Power Platform environmentmanagement API, then prints one command per
    environment in the form:

        node deploy/deploy.mjs --env-id <guid> --env-url <url> --yes --connectors-only [--profile <AuthProfile>]

    The --profile argument is included only when -AuthProfile is supplied.

    Requires an Azure CLI or Az.Accounts session with access to the tenant
    (used to acquire a Power Platform API bearer token). Run 'az login' or
    'Connect-AzAccount' first if needed.

.PARAMETER EnvironmentGroupName
    Display name of the Power Platform environment group (e.g. "HSLU 2026").

.PARAMETER AuthProfile
    Optional value passed through as --profile. Omitted from the output when
    not supplied.

.EXAMPLE
    .\Get-DemoInstallCommand.ps1 -EnvironmentGroupName "HSLU 2026"

.EXAMPLE
    .\Get-DemoInstallCommand.ps1 -EnvironmentGroupName "HSLU 2026" -AuthProfile 1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentGroupName,

    [string]$AuthProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PpApiBase = 'https://api.powerplatform.com'
$script:PpApiVersion = '2024-10-01'

#region Helpers

function Get-TenantId {
    if (Get-Command -Name az -ErrorAction SilentlyContinue) {
        $tid = az account show --query tenantId --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($tid)) {
            return $tid.Trim()
        }
    }
    if (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Tenant -and $ctx.Tenant.Id) {
            return [string]$ctx.Tenant.Id
        }
    }
    return $null
}

function Get-PowerPlatformApiToken {
    $resource = 'https://api.powerplatform.com'
    $tenantId = Get-TenantId

    if (Get-Command -Name az -ErrorAction SilentlyContinue) {
        $azArgs = @(
            'account', 'get-access-token',
            '--resource', $resource,
            '--query', 'accessToken',
            '--output', 'tsv'
        )
        if ($tenantId) { $azArgs += @('--tenant', $tenantId) }

        $azToken = az @azArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($azToken)) {
            return $azToken.Trim()
        }
    }

    if (Get-Command -Name Get-AzAccessToken -ErrorAction SilentlyContinue) {
        $azParams = @{ ResourceUrl = $resource }
        if ($tenantId) { $azParams['TenantId'] = $tenantId }

        $tokenResult = Get-AzAccessToken @azParams
        if ($tokenResult -and $tokenResult.Token) {
            if ($tokenResult.Token -is [securestring]) {
                return ([System.Net.NetworkCredential]::new('', $tokenResult.Token)).Password
            }
            return [string]$tokenResult.Token
        }
    }

    throw @"
Unable to acquire a Power Platform API token (tenant: $tenantId).

Sign in first:
  - Azure CLI: az login --tenant $tenantId
  - Az PowerShell: Connect-AzAccount -Tenant $tenantId
"@
}

function Resolve-GroupId {
    param([string]$GroupName, [string]$ApiToken)

    $uri = "$script:PpApiBase/environmentmanagement/environmentGroups?api-version=$script:PpApiVersion"
    $headers = @{ Authorization = "Bearer $ApiToken" }

    do {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        foreach ($group in $response.value) {
            if ($group.displayName -eq $GroupName) {
                return [string]$group.id
            }
        }
        $uri = $response.PSObject.Properties['@odata.nextLink']?.Value
    } while ($uri)

    return $null
}

function Get-GroupEnvironments {
    param([string]$GroupId, [string]$ApiToken)

    $headers = @{ Authorization = "Bearer $ApiToken" }
    $uri = "$script:PpApiBase/environmentmanagement/environments?`$filter=environmentGroupId eq '$GroupId'&`$select=id,displayName,url&api-version=$script:PpApiVersion"

    $items = [System.Collections.Generic.List[object]]::new()
    do {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        foreach ($environment in $response.value) {
            [void]$items.Add($environment)
        }
        $uri = $response.PSObject.Properties['@odata.nextlink']?.Value
    } while ($uri)

    return @($items)
}

#endregion

#region Resolve group and environments

Write-Host 'Acquiring Power Platform API token...' -ForegroundColor Cyan
$ppApiToken = Get-PowerPlatformApiToken

Write-Host "Resolving environment group '$EnvironmentGroupName'..." -ForegroundColor Cyan
$groupId = Resolve-GroupId -GroupName $EnvironmentGroupName -ApiToken $ppApiToken

if (-not $groupId) {
    Write-Error "Environment group '$EnvironmentGroupName' was not found."
    exit 1
}
Write-Host "Group ID : $groupId`n" -ForegroundColor Green

$environments = Get-GroupEnvironments -GroupId $groupId -ApiToken $ppApiToken

if ($environments.Count -eq 0) {
    Write-Warning "No environments found in group '$EnvironmentGroupName'."
    exit 0
}

$environments = @($environments | Sort-Object displayName)

#endregion

#region Print commands

foreach ($environment in $environments) {
    $envUrl = ([string]$environment.url).TrimEnd('/') + '/'
    $command = "node deploy/deploy.mjs --env-id $($environment.id) --env-url $envUrl --yes --connectors-only"
    if ($AuthProfile) {
        $command += " --profile $AuthProfile"
    }
    Write-Output $command
}

#endregion
