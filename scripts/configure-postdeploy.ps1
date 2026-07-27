#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
  Applies deployment-generated URLs to the existing Entra registrations.

.DESCRIPTION
  Intended for the azd postdeploy hook. Adds SPA_URL to the SPA application's
  SPA redirect URIs and upserts the Blueprint federated identity credential
    from FIC_ISSUER, FIC_SUBJECT, and FIC_AUDIENCE. Also grants tenant-wide
    delegated consent from the SPA to the Blueprint and from the Agent Identity
    to the configured downstream API scopes.
#>

[CmdletBinding()]
param(
    [string]$TenantId = $env:ENTRA_TENANT_ID,
    [string]$BlueprintClientId = $env:BLUEPRINT_CLIENT_ID,
    [string]$AgentIdentityClientId = $env:AGENT_IDENTITY_CLIENT_ID,
    [string]$SpaClientId = $env:SPA_CLIENT_ID,
    [string]$AgentInvokeScope = $env:EXPECTED_DELEGATED_SCOPE,
    [string]$DownstreamScope = $env:DOWNSTREAM_SCOPE,
    [string]$SpaUrl = $env:SPA_URL,
    [string]$FicIssuer = $env:FIC_ISSUER,
    [string]$FicSubject = $env:FIC_SUBJECT,
    [string]$FicAudience = $env:FIC_AUDIENCE,
    [string]$FicName = "spire-jwt-svid-blueprint"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-RequiredValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Required azd environment value '$Name' is missing. Run the Entra bootstrap before azd up and verify the deployment outputs."
    }
}

foreach ($requiredValue in ([ordered]@{
    ENTRA_TENANT_ID    = $TenantId
    BLUEPRINT_CLIENT_ID = $BlueprintClientId
    AGENT_IDENTITY_CLIENT_ID = $AgentIdentityClientId
    SPA_CLIENT_ID       = $SpaClientId
    EXPECTED_DELEGATED_SCOPE = $AgentInvokeScope
    DOWNSTREAM_SCOPE    = $DownstreamScope
    SPA_URL             = $SpaUrl
    FIC_ISSUER          = $FicIssuer
    FIC_SUBJECT         = $FicSubject
    FIC_AUDIENCE        = $FicAudience
}).GetEnumerator()) {
    Assert-RequiredValue -Name $requiredValue.Key -Value $requiredValue.Value
}

foreach ($clientId in ([ordered]@{
    BLUEPRINT_CLIENT_ID = $BlueprintClientId
    AGENT_IDENTITY_CLIENT_ID = $AgentIdentityClientId
    SPA_CLIENT_ID       = $SpaClientId
}).GetEnumerator()) {
    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse($clientId.Value, [ref]$parsedClientId)) {
        throw "Azd environment value '$($clientId.Key)' must be a GUID."
    }
}

if ($FicName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{2,119}$') {
    throw "FicName must be 3-120 characters and contain only letters, numbers, underscores, or hyphens."
}

$spaUri = [uri]$SpaUrl
if (-not $spaUri.IsAbsoluteUri -or $spaUri.Scheme -ne "https" -or
    -not $spaUri.AbsolutePath.EndsWith("/spa/", [System.StringComparison]::Ordinal)) {
    throw "SPA_URL must be an absolute HTTPS URI ending in /spa/."
}

$issuerUri = [uri]$FicIssuer
if (-not $issuerUri.IsAbsoluteUri -or $issuerUri.Scheme -ne "https" -or
    -not $issuerUri.AbsolutePath.EndsWith("/spiffe-oidc", [System.StringComparison]::Ordinal)) {
    throw "FIC_ISSUER must be an absolute HTTPS URI ending in /spiffe-oidc."
}

$subjectUri = [uri]$FicSubject
if (-not $subjectUri.IsAbsoluteUri -or $subjectUri.Scheme -ne "spiffe") {
    throw "FIC_SUBJECT must be an absolute SPIFFE URI."
}

if ($FicAudience -ne "api://AzureADTokenExchange") {
    throw "FIC_AUDIENCE must be api://AzureADTokenExchange."
}

$graphHeaders = @{ "OData-Version" = "4.0" }

function Invoke-GraphJsonRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("POST", "PATCH")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Body,

        [hashtable]$Headers = $graphHeaders
    )

    Invoke-MgGraphRequest `
        -Method $Method `
        -Uri $Uri `
        -Headers $Headers `
        -Body ($Body | ConvertTo-Json -Depth 10) `
        -ContentType "application/json"
}

function Get-ServicePrincipalByAppId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    $servicePrincipal = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$AppId')?`$select=id,appId,displayName" `
        -Headers $graphHeaders

    if ([string]::IsNullOrWhiteSpace([string]$servicePrincipal.id)) {
        throw "Microsoft Graph did not return the $Purpose service principal for app ID $AppId."
    }

    return $servicePrincipal
}

function ConvertTo-NormalizedScopeString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope
    )

    return (($Scope -split '\s+' | Where-Object { $_ } | Sort-Object -Unique) -join " ")
}

function Set-TenantWideDelegatedGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClientObjectId,

        [Parameter(Mandatory)]
        [string]$ResourceObjectId,

        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $normalizedScope = ConvertTo-NormalizedScopeString -Scope $Scope
    if ([string]::IsNullOrWhiteSpace($normalizedScope)) {
        throw "The delegated scope for $Description is empty."
    }

    $filter = [uri]::EscapeDataString(
        "clientId eq '$ClientObjectId' and resourceId eq '$ResourceObjectId' and consentType eq 'AllPrincipals'"
    )
    $existingResponse = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$filter&`$select=id,scope" `
        -Headers $graphHeaders
    $existingGrants = @($existingResponse.value)

    if ($existingGrants.Count -gt 1) {
        throw "Multiple tenant-wide delegated grants exist for $Description. Reconcile them before rerunning deployment."
    }

    if ($existingGrants.Count -eq 0) {
        $now = [datetime]::UtcNow
        $null = Invoke-GraphJsonRequest `
            -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            -Body @{
                "clientId"    = $ClientObjectId
                "consentType" = "AllPrincipals"
                "principalId" = $null
                "resourceId"  = $ResourceObjectId
                "scope"       = $normalizedScope
                "startTime"   = $now.AddDays(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
                "expiryTime"  = $now.AddMonths(6).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        Write-Host "Created tenant-wide delegated grant for ${Description}: $normalizedScope"
        return
    }

    $existingGrant = $existingGrants[0]
    $existingScope = ConvertTo-NormalizedScopeString -Scope ([string]$existingGrant.scope)
    if ($existingScope -ne $normalizedScope) {
        $null = Invoke-GraphJsonRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existingGrant.id)" `
            -Body @{
                "scope" = $normalizedScope
            }
        Write-Host "Updated tenant-wide delegated grant for ${Description}: $normalizedScope"
    }
    else {
        Write-Host "Tenant-wide delegated grant for $Description is already configured."
    }
}

Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes "Application.ReadWrite.All", "DelegatedPermissionGrant.ReadWrite.All" `
    -ContextScope CurrentUser `
    -NoWelcome

& {
    $spaApplicationUri = "https://graph.microsoft.com/v1.0/applications(appId='$SpaClientId')"
    $spaApplication = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "${spaApplicationUri}?`$select=id,displayName,spa" `
        -Headers $graphHeaders

    if ([string]::IsNullOrWhiteSpace([string]$spaApplication.id)) {
        throw "Microsoft Graph did not return the SPA application for client ID $SpaClientId."
    }

    $redirectUris = [System.Collections.Generic.List[string]]::new()
    $redirectUriSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($null -ne $spaApplication.spa -and $null -ne $spaApplication.spa.redirectUris) {
        foreach ($redirectUri in $spaApplication.spa.redirectUris) {
            if (-not [string]::IsNullOrWhiteSpace([string]$redirectUri) -and
                $redirectUriSet.Add([string]$redirectUri)) {
                $redirectUris.Add([string]$redirectUri)
            }
        }
    }

    if ($redirectUriSet.Add($spaUri.AbsoluteUri)) {
        $redirectUris.Add($spaUri.AbsoluteUri)
        $null = Invoke-GraphJsonRequest `
            -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($spaApplication.id)" `
            -Body @{
                "spa" = @{
                    "redirectUris" = @($redirectUris)
                }
            }
        Write-Host "Added SPA redirect URI '$($spaUri.AbsoluteUri)' to '$($spaApplication.displayName)'."
    }
    else {
        Write-Host "SPA redirect URI '$($spaUri.AbsoluteUri)' is already configured."
    }

    $blueprintApplicationUri = "https://graph.microsoft.com/v1.0/applications(appId='$BlueprintClientId')"
    $blueprintApplication = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "${blueprintApplicationUri}?`$select=id,displayName" `
        -Headers $graphHeaders

    if ([string]::IsNullOrWhiteSpace([string]$blueprintApplication.id)) {
        throw "Microsoft Graph did not return the Blueprint application for client ID $BlueprintClientId."
    }

    $ficHeaders = @{
        "OData-Version" = "4.0"
        "Prefer"        = "create-if-missing"
    }
    $ficUri = "https://graph.microsoft.com/v1.0/applications/$($blueprintApplication.id)/federatedIdentityCredentials(name='$FicName')"
    $null = Invoke-GraphJsonRequest `
        -Method PATCH `
        -Uri $ficUri `
        -Headers $ficHeaders `
        -Body @{
            "issuer"      = $issuerUri.AbsoluteUri.TrimEnd("/")
            "subject"     = $subjectUri.AbsoluteUri
            "audiences"   = @($FicAudience)
            "description" = "SPIFFE JWT-SVID trust for the Agent Identity Blueprint"
        }

    Write-Host "Upserted federated credential '$FicName' on '$($blueprintApplication.displayName)'."

    $spaServicePrincipal = Get-ServicePrincipalByAppId `
        -AppId $SpaClientId `
        -Purpose "SPA"
    $blueprintServicePrincipal = Get-ServicePrincipalByAppId `
        -AppId $BlueprintClientId `
        -Purpose "Blueprint"
    $agentIdentityServicePrincipal = Get-ServicePrincipalByAppId `
        -AppId $AgentIdentityClientId `
        -Purpose "Agent Identity"

    Set-TenantWideDelegatedGrant `
        -ClientObjectId $spaServicePrincipal.id `
        -ResourceObjectId $blueprintServicePrincipal.id `
        -Scope $AgentInvokeScope `
        -Description "SPA to Agent Identity Blueprint"

    $downstreamResourceAppIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $downstreamScopeValues = [System.Collections.Generic.List[string]]::new()
    foreach ($configuredScope in ($DownstreamScope -split '\s+' | Where-Object { $_ })) {
        $scopeUri = [uri]$configuredScope
        $scopeValue = $scopeUri.AbsolutePath.Trim("/")
        if (-not $scopeUri.IsAbsoluteUri -or $scopeUri.Scheme -ne "api" -or
            [string]::IsNullOrWhiteSpace($scopeValue)) {
            throw "DOWNSTREAM_SCOPE contains an invalid delegated scope URI: $configuredScope"
        }
        $resourceAppId = [guid]::Empty
        if (-not [guid]::TryParse($scopeUri.Host, [ref]$resourceAppId) -or
            $resourceAppId -eq [guid]::Empty) {
            throw "DOWNSTREAM_SCOPE contains an invalid resource app ID: $configuredScope"
        }
        $null = $downstreamResourceAppIds.Add($resourceAppId.ToString())
        $downstreamScopeValues.Add($scopeValue)
    }

    if ($downstreamResourceAppIds.Count -ne 1) {
        throw "DOWNSTREAM_SCOPE must target exactly one resource application; found $($downstreamResourceAppIds.Count)."
    }

    $downstreamResourceAppId = @($downstreamResourceAppIds)[0]
    $downstreamResource = Get-ServicePrincipalByAppId `
        -AppId $downstreamResourceAppId `
        -Purpose "downstream API"

    Set-TenantWideDelegatedGrant `
        -ClientObjectId $agentIdentityServicePrincipal.id `
        -ResourceObjectId $downstreamResource.id `
        -Scope ($downstreamScopeValues -join " ") `
        -Description "Agent Identity to $($downstreamResource.displayName)"
}
