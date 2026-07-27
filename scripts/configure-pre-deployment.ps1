#Requires -Version 7.0

<#
.SYNOPSIS
  Prepares Entra identities and imports root configuration before azd provision.

.DESCRIPTION
  Intended for the azd preprovision hook. Runs setup-entra.ps1 only when all
  generated Entra client IDs are missing or placeholder GUIDs. Existing IDs
  are reused so repeated azd up commands do not create duplicate objects.
#>

[CmdletBinding()]
param(
    [string]$EnvFilePath = (Join-Path $PSScriptRoot "..\.env"),
    [string]$EnvTemplatePath = (Join-Path $PSScriptRoot "..\.env.example"),
    [string]$SetupScriptPath = (Join-Path $PSScriptRoot "setup-entra.ps1")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DotEnvValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $values = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::Ordinal
    )
    if (-not [System.IO.File]::Exists($Path)) {
        return $values
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $match = [regex]::Match($line, "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")
        if ($match.Success) {
            $values[$match.Groups[1].Value] = $match.Groups[2].Value.Trim()
        }
    }

    return $values
}

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

$targetEnvPath = [System.IO.Path]::GetFullPath($EnvFilePath)
$templatePath = [System.IO.Path]::GetFullPath($EnvTemplatePath)
$setupPath = [System.IO.Path]::GetFullPath($SetupScriptPath)

if (-not [System.IO.File]::Exists($templatePath)) {
    throw "Environment template not found: $templatePath"
}
if (-not [System.IO.File]::Exists($setupPath)) {
    throw "Entra setup script not found: $setupPath"
}

$environmentValues = Get-DotEnvValues -Path $targetEnvPath
$tenantId = if ($environmentValues.ContainsKey("ENTRA_TENANT_ID") -and
    (Test-NonEmptyGuid -Value $environmentValues["ENTRA_TENANT_ID"])) {
    $environmentValues["ENTRA_TENANT_ID"]
}
elseif (Test-NonEmptyGuid -Value $env:ENTRA_TENANT_ID) {
    $env:ENTRA_TENANT_ID
}
else {
    throw "Set ENTRA_TENANT_ID to a nonzero tenant GUID in .env before running azd up."
}

$generatedClientIdKeys = @(
    "BLUEPRINT_CLIENT_ID"
    "AGENT_IDENTITY_CLIENT_ID"
    "SPA_CLIENT_ID"
)
$validClientIdKeys = @(
    $generatedClientIdKeys | Where-Object {
        $environmentValues.ContainsKey($_) -and
        (Test-NonEmptyGuid -Value $environmentValues[$_])
    }
)

if ($validClientIdKeys.Count -eq 0) {
    Write-Host "Generated Entra client IDs are absent. Running the Entra bootstrap."
    & $setupPath `
        -TenantId $tenantId `
        -EnvFilePath $targetEnvPath `
        -EnvTemplatePath $templatePath

    $environmentValues = Get-DotEnvValues -Path $targetEnvPath
    $missingGeneratedKeys = @(
        $generatedClientIdKeys | Where-Object {
            -not $environmentValues.ContainsKey($_) -or
            -not (Test-NonEmptyGuid -Value $environmentValues[$_])
        }
    )
    if ($missingGeneratedKeys.Count -gt 0) {
        throw "Entra bootstrap did not produce valid values for: $($missingGeneratedKeys -join ', ')."
    }
}
elseif ($validClientIdKeys.Count -eq $generatedClientIdKeys.Count) {
    Write-Host "Existing Entra client IDs found in .env; skipping object creation."
}
else {
    $missingGeneratedKeys = @($generatedClientIdKeys | Where-Object { $_ -notin $validClientIdKeys })
    throw "Partial Entra bootstrap state detected. Valid IDs: $($validClientIdKeys -join ', '); missing or placeholder IDs: $($missingGeneratedKeys -join ', '). Reconcile .env before rerunning azd up to avoid duplicate Entra objects."
}

if (-not $environmentValues.ContainsKey("EXPECTED_DELEGATED_SCOPE") -or
    [string]::IsNullOrWhiteSpace($environmentValues["EXPECTED_DELEGATED_SCOPE"])) {
    throw "EXPECTED_DELEGATED_SCOPE is missing from .env."
}

Write-Host "Importing $targetEnvPath into the selected azd environment."
& azd env set --file $targetEnvPath --no-prompt
if ($LASTEXITCODE -ne 0) {
    throw "azd env set failed with exit code $LASTEXITCODE."
}
