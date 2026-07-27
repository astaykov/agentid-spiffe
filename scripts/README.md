# Entra Agent ID setup

The setup script creates these objects in order:

1. Agent Identity Blueprint application through the typed Microsoft Graph
   endpoint.
2. Identifier URI `api://<blueprint-app-id>` and delegated `agent.invoke`
   scope on the Blueprint application object.
3. SPA application registration with the local redirect URI configured as a
   Single-page application platform.
4. SPA service principal and a declared delegated API permission for the
   Blueprint's `agent.invoke` scope.
5. Agent Identity Blueprint Principal through its typed endpoint.
6. Agent Identity through the typed Microsoft Graph v1.0 service-principal
   endpoint.

The AZD `preprovision` hook runs this bootstrap automatically when the generated
client IDs are absent. It intentionally does not create a Federated Identity
Credential because the public SPIFFE issuer does not exist until Azure
Container Apps is deployed.

The Agent Identity request uses
`agentIdentityBlueprintId=<blueprint-app-id>`. It is made with the signed-in
user's delegated `AgentIdentity.Create.All` grant. The script does not
authenticate as the Blueprint and does not create or use a Blueprint secret.

## Prerequisites

- PowerShell 7 or later.
- Administrator consent for the delegated Microsoft Graph permissions.
- A signed-in user permitted to create Agent ID Blueprints and Blueprint
  Principals. The Blueprint creator becomes an owner and can create Agent
  Identities associated with that Blueprint.

Install the Graph authentication module:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

The complete setup requests these delegated permissions during sign-in:

| Permission | Used for |
|---|---|
| `AgentIdentityBlueprint.Create` | Create the typed Blueprint application |
| `AgentIdentityBlueprint.UpdateAuthProperties.All` | Configure identifier URI and `agent.invoke` |
| `AgentIdentityBlueprintPrincipal.Create` | Create the typed Blueprint Principal |
| `AgentIdentity.Create.All` | Create the Agent Identity as the signed-in user |
| `AgentIdentity.DeleteRestore.All` | Delete the Agent Identity during teardown |
| `AgentIdentityBlueprint.DeleteRestore.All` | Delete the Blueprint during teardown |
| `Application.ReadWrite.All` | Create the SPA application and service principal |
| `DelegatedPermissionGrant.ReadWrite.All` | Grant tenant-wide delegated consent after deployment |
| `User.Read` | Resolve the signed-in user as owner and sponsor |

Only `AgentIdentity.Create.All` is needed by a delegated client that creates
an Agent Identity for an existing Blueprint and already knows the sponsor and
Blueprint app IDs. This permission allows creation on behalf of the signed-in
user even when the client is not the parent Blueprint.

## Run independently

Direct execution is useful before local development. For Azure deployment,
`azd up` invokes the guarded preprovision orchestrator instead.

```powershell
.\scripts\setup-entra.ps1 `
   -TenantId "<tenant-id>"
```

Optional parameters include:

- `BlueprintDisplayName`
- `AgentIdentityDisplayName`
- `SpaDisplayName`
- `LocalSpaRedirectUri`
- `AgentInvokeScope`
- `EnvFilePath`
- `EnvTemplatePath`

The script configures `http://localhost:8000/spa/` as the initial redirect URI
under the SPA platform. Override `LocalSpaRedirectUri` when a different local
origin is required. HTTP is accepted only for a loopback address; other
redirect URIs must use HTTPS.

The script creates or updates the root `.env` after all Entra objects are
created. If `.env` does not exist, `.env.example` is used as its template. If
it already exists, unrelated settings, comments, and ordering are preserved.
Only these generated values are managed:

```dotenv
ENTRA_TENANT_ID=<tenant-id>
BLUEPRINT_CLIENT_ID=<blueprint-app-id>
AGENT_IDENTITY_CLIENT_ID=<agent-identity-app-id>
SPA_CLIENT_ID=<spa-application-client-id>
EXPECTED_DELEGATED_SCOPE=agent.invoke
```

The update is written through a temporary file in the same directory. Override
`EnvFilePath` or `EnvTemplatePath` only when using a nonstandard project
layout. The committed `.env.example` is never modified.

The SPA's **API permissions** page will show the declared delegated permission
`api://<blueprint-app-id>/agent.invoke`. The postdeploy hook grants tenant-wide
admin consent for this declared permission.

Complete any remaining placeholder settings in `.env`, including
`ENTRA_TENANT_ID`, then run `azd up`.

## Automatic predeployment configuration

The root `azure.yaml` registers `configure-pre-deployment.ps1` as an
interactive `preprovision` hook. On every `azd up`, it:

1. Reads the root `.env` and validates `ENTRA_TENANT_ID`.
2. Runs `setup-entra.ps1` only when all three generated client IDs are absent
   or placeholder GUIDs.
3. Reuses a complete existing ID set on subsequent deployments.
4. Stops on partial ID state to avoid silently creating duplicate objects.
5. Imports the resulting `.env` into the selected AZD environment before Bicep
   parameters are evaluated.

Run this phase independently with:

```powershell
azd hooks run preprovision
```

## Automatic post-deployment configuration

The Azure Container App FQDN is generated during deployment. Both the SPA
production redirect and the SPIFFE federated credential therefore belong in a
post-deployment step. The root `azure.yaml` registers
`configure-postdeploy.ps1` as an interactive `postdeploy` hook.

After `azd deploy` or `azd up`, the hook:

1. Reads `SPA_URL`, `FIC_ISSUER`, `FIC_SUBJECT`, and `FIC_AUDIENCE` directly
   from the AZD environment.
2. Resolves the SPA from `SPA_CLIENT_ID`, preserves existing SPA redirects,
   and adds `SPA_URL` when missing.
3. Resolves the Blueprint from `BLUEPRINT_CLIENT_ID` and upserts the named FIC
   with Microsoft Graph's `Prefer: create-if-missing` behavior.
4. Grants the SPA service principal tenant-wide delegated `agent.invoke`
   access to the Blueprint service principal.
5. Extracts the single resource appId from the `DOWNSTREAM_SCOPE` `api://`
   URIs, resolves that resource's tenant-local service principal through
   Microsoft Graph, and grants the scope claim values to the Agent Identity.
   Microsoft MCP Server for enterprise uses well-known appId
   `e8c77dc2-69b3-43f4-bc51-3213c9d915b4`.

New grants start one day before creation and expire six months after creation.
Existing grants are updated only when their scope set differs. The setup hook
requests all Graph scopes with `ContextScope CurrentUser` and intentionally
keeps that context connected so postdeploy can reuse it. A failure stops the
AZD command so Entra configuration cannot silently remain incomplete.

Run the hook independently after changing or refreshing deployment outputs:

```powershell
azd hooks run postdeploy
```

The operation is idempotent. The local and production redirect URIs coexist,
and the FIC named `spire-jwt-svid-blueprint` is created or updated on the
Blueprint application. Permission grants are not duplicated. No FIC is added
to the Agent Identity.

## Automatic teardown

The root `azure.yaml` registers `configure-postdown.ps1` as an interactive
`postdown` hook. `azd down` and `azd down --purge` run it only after Azure
resource deletion completes. The selected AZD environment persists and still
provides the Entra IDs to the hook.

The hook performs this idempotent cleanup order:

1. Deletes delegated permission grants owned by the Agent Identity.
2. Deletes the Agent Identity through its typed Microsoft Graph v1.0 endpoint.
3. Deletes delegated permission grants owned by the SPA.
4. Deletes the SPA service principal and application.
5. Deletes the Blueprint through its typed v1.0 endpoint. Microsoft Entra then
   cascades cleanup to the Blueprint Principal and any remaining child Agent
   Identities.
6. Resets `BLUEPRINT_CLIENT_ID`, `AGENT_IDENTITY_CLIENT_ID`, and
   `SPA_CLIENT_ID` to zero GUIDs in root `.env`, preserving unrelated settings.

Entra uses standard soft deletion: deleted applications, service principals,
and Agent ID objects are recoverable for 30 days. The Azure `--purge` switch
does not permanently delete Entra recycle-bin objects. If the user cancels
`azd down`, or Azure deletion fails, `postdown` doesn't run and Entra remains
intact. If Graph cleanup fails after Azure deletion, AZD reports the hook
failure and the hook can be rerun with `azd hooks run postdown`.

## Microsoft documentation

- [Create an agent identity blueprint](https://learn.microsoft.com/en-us/entra/agent-id/create-blueprint?tabs=microsoft-graph-api)
- [Create agent identities](https://learn.microsoft.com/en-us/entra/agent-id/create-delete-agent-identities?tabs=microsoft-graph-api)
- [Create agentIdentity API](https://learn.microsoft.com/en-us/graph/api/agentidentity-post?view=graph-rest-1.0)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference#agentidentitycreateall)
- [Create application API](https://learn.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0)
- [Redirect URI restrictions](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url)
- [Customize AZD workflows with hooks](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/azd-extensibility)
- [Upsert federated identity credential](https://learn.microsoft.com/en-us/graph/api/federatedidentitycredential-upsert?view=graph-rest-1.0)
- [Create delegated permission grant](https://learn.microsoft.com/en-us/graph/api/oauth2permissiongrant-post?view=graph-rest-1.0)
- [Delete and restore Agent ID objects](https://learn.microsoft.com/en-us/entra/agent-id/howto-delete-agent-identity)

All Microsoft Graph requests in these scripts use v1.0 endpoints.