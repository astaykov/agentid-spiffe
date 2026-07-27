// Infrastructure for the SPIFFE -> Entra Agent ID POC on Azure Container Apps.
// Deployed at resource-group scope (azd uses AZURE_RESOURCE_GROUP).
targetScope = 'resourceGroup'

@minLength(1)
@description('Name of the azd environment; used for tagging and name uniqueness.')
param environmentName string

@minLength(1)
@description('Azure region for all resources.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// Application configuration. Values are loaded from the root .env file by the
// preprovision hook, then mapped through main.parameters.json.
// ---------------------------------------------------------------------------
@description('Entra tenant id.')
param entraTenantId string

@description('Blueprint (AIB SPIFFE) app client id — holds the JWT-SVID credential.')
param blueprintClientId string

@description('Agent Identity app client id.')
param agentIdentityClientId string

@description('Whitespace-delimited downstream scopes requested for the MCP call.')
param downstreamScope string

@description('Delegated scope value required in the inbound SPA token scp claim.')
param expectedDelegatedScope string

@description('Downstream MCP server URL.')
param mcpServerUrl string

@description('Agent mode: user_context (3-leg) or app_only.')
param agentMode string

@description('Audience the SPIRE JWT-SVID is minted for (Entra token-exchange).')
param spiffeJwtAudience string

@description('SPA public client app id.')
param spaClientId string

@description('System instructions for the local tool-using AI agent.')
param aiAgentSystemPrompt string

// Provision with a public image. `azd up` subsequently builds, pushes, and
// deploys each real service image. This avoids stale ACR tags after `azd down`.
var placeholderImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
var oidcIssuerPath = '/spiffe-oidc'
var resourceToken = uniqueString(subscription().id, resourceGroup().id, environmentName)
var tags = { 'azd-env-name': environmentName }
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var openAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var aiModelDeploymentName = 'gpt-5.4-nano'

var backendAppName = 'spiffe'

// ---------------------------------------------------------------------------
// Observability + Container Apps environment
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Container registry (Basic SKU) + pull identity
// ---------------------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${resourceToken}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${resourceToken}'
  location: location
  tags: tags
}

// Foundry AI Services is used only as a stateless Responses API endpoint. The
// FastAPI backend owns the agent loop and supplies its per-user MCP token.
resource aiServices 'Microsoft.CognitiveServices/accounts@2025-09-01' = {
  name: 'ai${resourceToken}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: 'ai${resourceToken}'
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource aiModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-09-01' = {
  parent: aiServices
  name: aiModelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-nano'
      version: '2026-03-17'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource aiInference 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aiServices.id, pullIdentity.id, openAiUserRoleId)
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiUserRoleId)
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullIdentity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Public FQDN is deterministic (app name + environment default domain).
var backendFqdn = '${backendAppName}.${containerEnv.properties.defaultDomain}'

// Public origin the outside world (browser + Entra) reaches the backend on.
// This POC intentionally uses the generated ACA ingress domain.
var backendPublicOrigin = 'https://${backendFqdn}'

// The JWT-SVID `iss` and the Entra Federated Identity Credential issuer.
var backendIssuerUrl = '${backendPublicOrigin}${oidcIssuerPath}'

// ---------------------------------------------------------------------------
// Backend: merged SPIRE + FastAPI. Single replica (one SPIRE server/agent).
// ---------------------------------------------------------------------------
resource backend 'Microsoft.App/containerApps@2024-03-01' = {
  name: backendAppName
  location: location
  tags: union(tags, { 'azd-service-name': 'backend' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: placeholderImage
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 3
              failureThreshold: 3
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/readyz'
                port: 8000
                scheme: 'HTTP'
              }
              initialDelaySeconds: 5
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
              successThreshold: 1
            }
          ]
          env: [
            { name: 'ENTRA_TENANT_ID', value: entraTenantId }
            { name: 'BLUEPRINT_CLIENT_ID', value: blueprintClientId }
            { name: 'AGENT_IDENTITY_CLIENT_ID', value: agentIdentityClientId }
            { name: 'DOWNSTREAM_SCOPE', value: downstreamScope }
            { name: 'EXPECTED_DELEGATED_SCOPE', value: expectedDelegatedScope }
            { name: 'MCP_SERVER_URL', value: mcpServerUrl }
            { name: 'AGENT_MODE', value: agentMode }
            { name: 'SPIFFE_JWT_AUDIENCE', value: spiffeJwtAudience }
            { name: 'SPA_CLIENT_ID', value: spaClientId }
            { name: 'AZURE_CLIENT_ID', value: pullIdentity.properties.clientId }
            { name: 'AZURE_OPENAI_ENDPOINT', value: 'https://${aiServices.name}.services.ai.azure.com' }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: aiModelDeployment.name }
            { name: 'AI_AGENT_SYSTEM_PROMPT', value: aiAgentSystemPrompt }
            { name: 'OIDC_PROVIDER_URL', value: 'http://localhost:8443' }
            // Public issuer = ACA origin + /spiffe-oidc; also the Entra FIC issuer.
            { name: 'OIDC_ISSUER_URL', value: backendIssuerUrl }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs (azd persists these; the FIC_* ones are what you enter in Entra).
// ---------------------------------------------------------------------------
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.properties.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = acr.name
output BACKEND_FQDN string = backendFqdn
output BACKEND_PUBLIC_ORIGIN string = backendPublicOrigin
output BACKEND_URL string = backendPublicOrigin
output SPA_URL string = '${backendPublicOrigin}/spa/'
output AZURE_OPENAI_ENDPOINT string = 'https://${aiServices.name}.services.ai.azure.com'
output AZURE_OPENAI_DEPLOYMENT string = aiModelDeployment.name

// Values to configure the Entra Federated Identity Credential on the Blueprint app.
output FIC_ISSUER string = backendIssuerUrl
output FIC_SUBJECT string = 'spiffe://poc.local/agent/identity-1'
output FIC_AUDIENCE string = spiffeJwtAudience
