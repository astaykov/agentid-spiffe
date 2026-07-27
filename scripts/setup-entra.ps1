#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
  Creates and configures an Entra Agent ID blueprint, its blueprint principal,
    an Agent Identity, and the browser SPA app registration before deployment.

.DESCRIPTION
  Uses delegated Microsoft Graph permissions throughout. Agent Identity
  creation uses AgentIdentity.Create.All from the signed-in user's token and
  does not authenticate as the blueprint or use a blueprint secret.

.NOTES
  The delegated permissions require administrator consent. The signed-in user
  must be permitted to create the blueprint and blueprint principal. Because
  the same user creates the blueprint, that user becomes its owner and can
  create Agent Identities associated with it.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [ValidateNotNullOrEmpty()]
    [string]$BlueprintDisplayName = "poc-agent-blueprint",

    [ValidateNotNullOrEmpty()]
    [string]$AgentIdentityDisplayName = "poc-agent-identity-1",

    [ValidateNotNullOrEmpty()]
    [string]$SpaDisplayName = "poc-agent-spa",

    [ValidateNotNullOrEmpty()]
    [string]$LocalSpaRedirectUri = "http://localhost:8000/spa/",

    [ValidateNotNullOrEmpty()]
    [string]$AgentInvokeScope = "agent.invoke",

    [ValidateNotNullOrEmpty()]
    [string]$EnvFilePath = (Join-Path $PSScriptRoot "..\.env"),

    [ValidateNotNullOrEmpty()]
    [string]$EnvTemplatePath = (Join-Path $PSScriptRoot "..\.env.example")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$spaRedirectUri = [uri]$LocalSpaRedirectUri
$isLocalHttpRedirect = $spaRedirectUri.Scheme -eq "http" -and $spaRedirectUri.IsLoopback
if (-not $spaRedirectUri.IsAbsoluteUri -or
    ($spaRedirectUri.Scheme -ne "https" -and -not $isLocalHttpRedirect)) {
    throw "LocalSpaRedirectUri must use HTTPS, except for an HTTP loopback URI."
}

$graphHeaders = @{ "OData-Version" = "4.0" }
$graphScopes = @(
    "AgentIdentityBlueprint.Create"
    "AgentIdentityBlueprint.UpdateAuthProperties.All"
    "AgentIdentityBlueprintPrincipal.Create"
    "AgentIdentity.Create.All"
    "AgentIdentity.DeleteRestore.All"
    "AgentIdentityBlueprint.DeleteRestore.All"
    "Application.ReadWrite.All"
    "DelegatedPermissionGrant.ReadWrite.All"
    "User.Read"
)

function Invoke-GraphJsonRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("POST", "PATCH")]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Body
    )

    Invoke-MgGraphRequest `
        -Method $Method `
        -Uri $Uri `
        -Headers $graphHeaders `
        -Body ($Body | ConvertTo-Json -Depth 10) `
        -ContentType "application/json"
}

function Update-DotEnvFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$TemplatePath,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values
    )

    $targetPath = [System.IO.Path]::GetFullPath($Path)
    $sourceTemplatePath = [System.IO.Path]::GetFullPath($TemplatePath)
    $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)

    if (-not [System.IO.File]::Exists($sourceTemplatePath)) {
        throw "Environment template not found: $sourceTemplatePath"
    }

    if (-not [System.IO.Directory]::Exists($targetDirectory)) {
        throw "Environment file directory not found: $targetDirectory"
    }

    $sourcePath = if ([System.IO.File]::Exists($targetPath)) {
        $targetPath
    }
    else {
        $sourceTemplatePath
    }

    $content = [System.IO.File]::ReadAllText($sourcePath)
    $lineEnding = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadTrailingLineEnding = $content.EndsWith("`n")

    $managedValues = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in $Values.GetEnumerator()) {
        $value = [string]$entry.Value
        if ($value.Contains("`r") -or $value.Contains("`n")) {
            throw "Environment value '$($entry.Key)' must not contain a line break."
        }
        $managedValues.Add([string]$entry.Key, $value)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [regex]::Split($content, "`r?`n")) {
        $lines.Add($line)
    }
    if ($hadTrailingLineEnding -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq "") {
        $lines.RemoveAt($lines.Count - 1)
    }

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $updatedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        $match = [regex]::Match($line, "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")
        $key = if ($match.Success) { $match.Groups[1].Value } else { $null }

        if ($null -ne $key -and $managedValues.ContainsKey($key)) {
            if ($seenKeys.Add($key)) {
                $updatedLines.Add("$key=$($managedValues[$key])")
            }
            continue
        }

        $updatedLines.Add($line)
    }

    foreach ($entry in $Values.GetEnumerator()) {
        $key = [string]$entry.Key
        if ($seenKeys.Add($key)) {
            $updatedLines.Add("$key=$($managedValues[$key])")
        }
    }

    $updatedContent = [string]::Join($lineEnding, $updatedLines)
    if ($hadTrailingLineEnding) {
        $updatedContent += $lineEnding
    }

    $temporaryPath = Join-Path $targetDirectory ".$([System.IO.Path]::GetFileName($targetPath)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $updatedContent,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryPath, $targetPath, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }

    return $targetPath
}

Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes $graphScopes `
    -ContextScope CurrentUser `
    -NoWelcome

& {
    $currentUser = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/me" `
        -Headers $graphHeaders

    if ([string]::IsNullOrWhiteSpace([string]$currentUser.id)) {
        throw "Microsoft Graph did not return the signed-in user's object ID."
    }

    $sponsorReference = "https://graph.microsoft.com/v1.0/users/$($currentUser.id)"
    Write-Host "Signed in as $($currentUser.displayName) ($($currentUser.id))"

    $blueprint = Invoke-GraphJsonRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications/microsoft.graph.agentIdentityBlueprint" `
        -Body @{
            "@odata.type"         = "Microsoft.Graph.AgentIdentityBlueprint"
            "displayName"         = $BlueprintDisplayName
            "sponsors@odata.bind" = @($sponsorReference)
            "owners@odata.bind"   = @($sponsorReference)
        }

    if ([string]::IsNullOrWhiteSpace([string]$blueprint.id) -or
        [string]::IsNullOrWhiteSpace([string]$blueprint.appId)) {
        throw "Microsoft Graph did not return both id and appId for the blueprint."
    }

    Write-Host "Blueprint object ID: $($blueprint.id)"
    Write-Host "Blueprint app ID:    $($blueprint.appId)"

    # Identifier URI and exposed scope are regular application-object
    # operations performed on the typed Blueprint application.
    $scopeId = [guid]::NewGuid().ToString()
    $null = Invoke-GraphJsonRequest `
        -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($blueprint.id)" `
        -Body @{
            "identifierUris" = @("api://$($blueprint.appId)")
            "api" = @{
                "requestedAccessTokenVersion" = 2
                "oauth2PermissionScopes" = @(
                    @{
                        "id"                      = $scopeId
                        "adminConsentDescription" = "Allow the application to invoke the agent on behalf of the signed-in user."
                        "adminConsentDisplayName" = "Invoke agent"
                        "isEnabled"               = $true
                        "type"                    = "User"
                        "value"                   = $AgentInvokeScope
                    }
                )
            }
        }

    # Register the browser client as an SPA and declare its delegated access
    # to the exact Blueprint scope created above. Declaring the permission does
    # not itself grant tenant-wide admin consent.
    $spaApplication = Invoke-GraphJsonRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications" `
        -Body @{
            "displayName"         = $SpaDisplayName
            "signInAudience"      = "AzureADMyOrg"
            "owners@odata.bind"   = @($sponsorReference)
            "spa" = @{
                "redirectUris" = @($spaRedirectUri.AbsoluteUri)
            }
            "requiredResourceAccess" = @(
                @{
                    "resourceAppId" = $blueprint.appId
                    "resourceAccess" = @(
                        @{
                            "id"   = $scopeId
                            "type" = "Scope"
                        }
                    )
                }
            )
        }

    if ([string]::IsNullOrWhiteSpace([string]$spaApplication.id) -or
        [string]::IsNullOrWhiteSpace([string]$spaApplication.appId)) {
        throw "Microsoft Graph did not return both id and appId for the SPA application."
    }

    $spaServicePrincipal = Invoke-GraphJsonRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
        -Body @{
            "appId" = $spaApplication.appId
        }

    if ([string]::IsNullOrWhiteSpace([string]$spaServicePrincipal.id)) {
        throw "Microsoft Graph did not return the SPA service principal object ID."
    }

    Write-Host "SPA application object ID:     $($spaApplication.id)"
    Write-Host "SPA application client ID:     $($spaApplication.appId)"
    Write-Host "SPA service principal ID:      $($spaServicePrincipal.id)"
    Write-Host "SPA local redirect URI:        $($spaRedirectUri.AbsoluteUri)"
    Write-Host "SPA requested delegated scope: api://$($blueprint.appId)/$AgentInvokeScope"

    # Blueprint creation does not create its service principal. The principal
    # must also be created through its typed endpoint.
    $blueprintPrincipal = Invoke-GraphJsonRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal" `
        -Body @{
            "appId" = $blueprint.appId
        }

    if ([string]::IsNullOrWhiteSpace([string]$blueprintPrincipal.id)) {
        throw "Microsoft Graph did not return the blueprint principal object ID."
    }

    Write-Host "Blueprint principal object ID: $($blueprintPrincipal.id)"

    # This typed call uses the signed-in user's delegated
    # AgentIdentity.Create.All grant. It does not authenticate as the blueprint.
    $agentIdentity = Invoke-GraphJsonRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/microsoft.graph.agentIdentity" `
        -Body @{
            "displayName"              = $AgentIdentityDisplayName
            "agentIdentityBlueprintId" = $blueprint.appId
            "sponsors@odata.bind"      = @($sponsorReference)
        }

    if ([string]::IsNullOrWhiteSpace([string]$agentIdentity.id) -or
        [string]::IsNullOrWhiteSpace([string]$agentIdentity.appId)) {
        throw "Microsoft Graph did not return both id and appId for the Agent Identity."
    }

    Write-Host "Agent Identity object ID: $($agentIdentity.id)"
    Write-Host "Agent Identity app ID:    $($agentIdentity.appId)"

    $environmentValues = [ordered]@{
        "ENTRA_TENANT_ID"                 = $TenantId
        "BLUEPRINT_CLIENT_ID"             = $blueprint.appId
        "AGENT_IDENTITY_CLIENT_ID"        = $agentIdentity.appId
        "SPA_CLIENT_ID"                   = $spaApplication.appId
        "EXPECTED_DELEGATED_SCOPE"        = $AgentInvokeScope
    }
    $updatedEnvFile = Update-DotEnvFile `
        -Path $EnvFilePath `
        -TemplatePath $EnvTemplatePath `
        -Values $environmentValues

    Write-Host ""
    Write-Host "Updated environment file: $updatedEnvFile"
    Write-Host "Managed values:"
    Write-Host "  ENTRA_TENANT_ID=$TenantId"
    Write-Host "  BLUEPRINT_CLIENT_ID=$($blueprint.appId)"
    Write-Host "  AGENT_IDENTITY_CLIENT_ID=$($agentIdentity.appId)"
    Write-Host "  SPA_CLIENT_ID=$($spaApplication.appId)"
    Write-Host "  EXPECTED_DELEGATED_SCOPE=$AgentInvokeScope"
    Write-Host ""
    Write-Host "After azd deploy or azd up, the interactive postdeploy hook will:"
    Write-Host "  1. Add SPA_URL to '$SpaDisplayName' as an SPA redirect URI."
    Write-Host "  2. Upsert the Blueprint FIC on '$BlueprintDisplayName'."
    Write-Host "  3. Grant tenant-wide delegated consent for the SPA and Agent Identity."
    Write-Host "The persisted Microsoft Graph context is reused by the postdeploy hook."
    Write-Host "The postdown hook deletes these Entra objects after Azure teardown and resets their client IDs in .env."
}
