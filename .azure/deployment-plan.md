# Azure Deployment Plan

> **Status:** Implementation validated; ready for deployment

## Architecture

One Azure Container App and one remotely built ACR image contain:

- SPIRE Server and Agent
- SPIRE OIDC discovery provider
- FastAPI API and health endpoints
- SPA served under `/spa/`

Supporting resources are one Container Apps environment, Basic ACR,
Log Analytics workspace, user-assigned identity, Foundry AI Services resource,
`gpt-5.4-nano` deployment, `AcrPull`, and `Cognitive Services OpenAI User`
assignments.

There is no second SPA app, custom domain, certificate, persistent storage,
database, or Key Vault.

## Configuration

The ignored root `.env` file is the sole application configuration source.
An interactive PowerShell `preprovision` hook conditionally bootstraps Entra,
updates `.env`, and imports it into AZD. Required Bicep parameters are mapped in
`infra/main.parameters.json`; derived SPA and audience values are computed by
the backend.

An interactive `postdeploy` PowerShell hook uses the persisted Bicep outputs
to preserve and add the production SPA redirect URI and upsert the named
Blueprint FIC through Microsoft Graph. It also grants tenant-wide delegated
consent from the SPA to the Blueprint and from the Agent Identity to the
configured downstream API scopes.

An interactive `postdown` hook deletes the delegated grants, Agent Identity,
SPA application/principal, and Blueprint after successful Azure teardown, then resets
the generated client IDs in root `.env`. Blueprint deletion cascades to its
principal and remaining children.

## Public Paths

- SPA: `/spa/`
- API: `/invoke`
- FIC issuer: `<ACA-origin>/spiffe-oidc`
- OIDC metadata: `/spiffe-oidc/.well-known/openid-configuration`
- JWKS: `/spiffe-oidc/keys`

The SPA redirect URI must be `<ACA-origin>/spa/`.
The generated ACA origin starts with `https://spiffe.`.

## POC Limitation

Every backend restart rotates the SPIRE JWT `kid`, which can conflict with
Microsoft Entra metadata/JWKS caching. This architecture is not for production.

## Lifecycle

```powershell
azd up
azd down --purge
```

ACR Tasks performs one remote image build. Bicep provisions a placeholder image
before AZD deploys the built image.

## Validation

- [x] One Docker Compose service
- [x] One AZD service with `remoteBuild: true`
- [x] One Container App resource in Bicep
- [x] One root dotenv source and guarded preprovision bootstrap/import
- [x] Preprovision hook reuses complete IDs, bootstraps placeholders, and
	blocks partial state
- [x] Consolidated image builds locally
- [x] All 15 application, agent, and route tests pass
- [x] `/spiffe-oidc` and `/spa/` route behavior covered by tests
- [x] Native MCP agent token forwarding, tool metadata, history, and timeout
	behavior covered by tests
- [x] Foundry AI Services, `gpt-5.4-nano`, keyless RBAC, and agent environment
	configuration compile in Bicep
- [x] Azure preview contains one Container App, one environment, ACR, and logs
- [x] Preview-created empty resource group removed after validation
- [x] Postdeploy hook preserves existing SPA redirects and upserts the FIC
- [x] Postdeploy hook first-run and rerun behavior validated with mocked Graph
- [x] SPA and Agent Identity delegated grants validated with mocked Graph
- [x] Postdown grant/object deletion, dotenv reset, rerun, and malformed-input
	behavior validated with mocked Graph
- [ ] Deploy and validate health, SPA, metadata, and JWKS
- [ ] Confirm the postdeploy Entra updates in the deployed tenant