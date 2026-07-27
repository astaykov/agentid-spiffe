#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Deletes the Entra objects created for this POC after azd tears down Azure.

.DESCRIPTION
    Intended for the azd postdown hook. Removes delegated grants, the Agent
  Identity, the SPA principal and application, and the Agent Identity Blueprint.
  The Blueprint deletion cascades to its principal and any remaining children.
  Generated client IDs are reset in root .env only after Graph cleanup succeeds.
#>

[CmdletBinding()]
param(
    [string]$TenantId = $env:ENTRA_TENANT_ID,
    [string]$BlueprintClientId = $env:BLUEPRINT_CLIENT_ID,
    [string]$AgentIdentityClientId = $env:AGENT_IDENTITY_CLIENT_ID,
    [string]$SpaClientId = $env:SPA_CLIENT_ID,
    [string]$EnvFilePath = (Join-Path $PSScriptRoot "..\.env")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-NonEmptyGuid {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    $parsedValue = [guid]::Empty
    return [guid]::TryParse($Value, [ref]$parsedValue) -and $parsedValue -ne [guid]::Empty
}

function Get-SingleGraphObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("applications", "servicePrincipals")]
        [string]$Collection,

        [Parameter(Mandatory)]
        [string]$AppId,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    $filter = [uri]::EscapeDataString("appId eq '$AppId'")
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/${Collection}?`$filter=$filter&`$select=id,appId,displayName" `
        -Headers @{ "OData-Version" = "4.0" }
    $objects = @($response.value)

    if ($objects.Count -gt 1) {
        throw "Microsoft Graph returned multiple $Purpose objects for app ID $AppId."
    }

    if ($objects.Count -eq 0) {
        return $null
    }

    return $objects[0]
}

function Remove-ClientDelegatedGrants {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ClientObjectId,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    $filter = [uri]::EscapeDataString("clientId eq '$ClientObjectId'")
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$filter&`$select=id" `
        -Headers @{ "OData-Version" = "4.0" }

    foreach ($grant in @($response.value)) {
        Invoke-MgGraphRequest `
            -Method DELETE `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" `
            -Headers @{ "OData-Version" = "4.0" }
        Write-Host "Deleted delegated permission grant '$($grant.id)' for $Purpose."
    }
}

function Reset-GeneratedClientIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $targetPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($targetPath)) {
        Write-Host "Root environment file does not exist; no generated IDs need resetting."
        return
    }

    $content = [System.IO.File]::ReadAllText($targetPath)
    $lineEnding = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadTrailingLineEnding = $content.EndsWith("`n")
    $zeroGuid = [guid]::Empty.ToString()
    $managedKeys = @(
        "BLUEPRINT_CLIENT_ID"
        "AGENT_IDENTITY_CLIENT_ID"
        "SPA_CLIENT_ID"
    )
    $managedKeySet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($key in $managedKeys) {
        $null = $managedKeySet.Add($key)
    }
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $updatedLines = [System.Collections.Generic.List[string]]::new()

    foreach ($line in [regex]::Split($content, "`r?`n")) {
        if ($hadTrailingLineEnding -and $line -eq "" -and
            $updatedLines.Count -gt 0 -and $updatedLines[$updatedLines.Count - 1] -eq "") {
            continue
        }

        $match = [regex]::Match($line, "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")
        $key = if ($match.Success) { $match.Groups[1].Value } else { $null }
        if ($null -ne $key -and $managedKeySet.Contains($key)) {
            if ($seenKeys.Add($key)) {
                $updatedLines.Add("$key=$zeroGuid")
            }
            continue
        }

        $updatedLines.Add($line)
    }

    foreach ($key in $managedKeys) {
        if ($seenKeys.Add($key)) {
            $updatedLines.Add("$key=$zeroGuid")
        }
    }

    while ($updatedLines.Count -gt 0 -and $updatedLines[$updatedLines.Count - 1] -eq "") {
        $updatedLines.RemoveAt($updatedLines.Count - 1)
    }

    $updatedContent = [string]::Join($lineEnding, $updatedLines)
    if ($hadTrailingLineEnding) {
        $updatedContent += $lineEnding
    }

    $targetDirectory = [System.IO.Path]::GetDirectoryName($targetPath)
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

    Write-Host "Reset generated Entra client IDs in $targetPath."
}

$clientIds = [ordered]@{
    BLUEPRINT_CLIENT_ID      = $BlueprintClientId
    AGENT_IDENTITY_CLIENT_ID = $AgentIdentityClientId
    SPA_CLIENT_ID            = $SpaClientId
}
$activeClientIds = [System.Collections.Generic.List[object]]::new()
foreach ($clientId in $clientIds.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$clientId.Value)) {
        continue
    }

    $parsedClientId = [guid]::Empty
    if (-not [guid]::TryParse([string]$clientId.Value, [ref]$parsedClientId)) {
        throw "Environment value '$($clientId.Key)' must be a GUID."
    }
    if ($parsedClientId -ne [guid]::Empty) {
        $activeClientIds.Add($clientId)
    }
}

if ($activeClientIds.Count -eq 0) {
    Write-Host "No generated Entra client IDs are configured; skipping Graph cleanup."
    Reset-GeneratedClientIds -Path $EnvFilePath
    return
}

if (-not (Test-NonEmptyGuid -Value $TenantId)) {
    throw "ENTRA_TENANT_ID must be a nonzero GUID when generated Entra client IDs are configured."
}

Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes @(
        "Application.ReadWrite.All"
        "AgentIdentity.DeleteRestore.All"
        "AgentIdentityBlueprint.DeleteRestore.All"
        "DelegatedPermissionGrant.ReadWrite.All"
    ) `
    -ContextScope CurrentUser `
    -NoWelcome

& {
    if (Test-NonEmptyGuid -Value $AgentIdentityClientId) {
        $agentIdentity = Get-SingleGraphObject `
            -Collection "servicePrincipals" `
            -AppId $AgentIdentityClientId `
            -Purpose "Agent Identity"
        if ($null -ne $agentIdentity) {
            Remove-ClientDelegatedGrants `
                -ClientObjectId $agentIdentity.id `
                -Purpose "Agent Identity"
            Invoke-MgGraphRequest `
                -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($agentIdentity.id)/microsoft.graph.agentIdentity" `
                -Headers @{ "OData-Version" = "4.0" }
            Write-Host "Deleted Agent Identity '$($agentIdentity.displayName)'."
        }
        else {
            Write-Host "Agent Identity app ID $AgentIdentityClientId is already absent."
        }
    }

    if (Test-NonEmptyGuid -Value $SpaClientId) {
        $spaPrincipal = Get-SingleGraphObject `
            -Collection "servicePrincipals" `
            -AppId $SpaClientId `
            -Purpose "SPA service principal"
        if ($null -ne $spaPrincipal) {
            Remove-ClientDelegatedGrants `
                -ClientObjectId $spaPrincipal.id `
                -Purpose "SPA"
            Invoke-MgGraphRequest `
                -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($spaPrincipal.id)" `
                -Headers @{ "OData-Version" = "4.0" }
            Write-Host "Deleted SPA service principal '$($spaPrincipal.displayName)'."
        }

        $spaApplication = Get-SingleGraphObject `
            -Collection "applications" `
            -AppId $SpaClientId `
            -Purpose "SPA application"
        if ($null -ne $spaApplication) {
            Invoke-MgGraphRequest `
                -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/applications/$($spaApplication.id)" `
                -Headers @{ "OData-Version" = "4.0" }
            Write-Host "Deleted SPA application '$($spaApplication.displayName)'."
        }
        elseif ($null -eq $spaPrincipal) {
            Write-Host "SPA app ID $SpaClientId is already absent."
        }
    }

    if (Test-NonEmptyGuid -Value $BlueprintClientId) {
        $blueprintApplication = Get-SingleGraphObject `
            -Collection "applications" `
            -AppId $BlueprintClientId `
            -Purpose "Agent Identity Blueprint"
        if ($null -ne $blueprintApplication) {
            Invoke-MgGraphRequest `
                -Method DELETE `
                -Uri "https://graph.microsoft.com/v1.0/applications/$($blueprintApplication.id)/microsoft.graph.agentIdentityBlueprint" `
                -Headers @{ "OData-Version" = "4.0" }
            Write-Host "Deleted Agent Identity Blueprint '$($blueprintApplication.displayName)'; Entra will cascade cleanup to its principal and remaining child identities."
        }
        else {
            Write-Host "Blueprint app ID $BlueprintClientId is already absent."
        }
    }
}

Reset-GeneratedClientIds -Path $EnvFilePath
