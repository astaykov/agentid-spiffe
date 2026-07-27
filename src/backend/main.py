"""
AI Agent REST API — corrected three-leg FMI/FIC flow per:
https://github.com/AzureAD/microsoft-authentication-library-for-dotnet/wiki/How-to-Use-FIC-and-FMI-in-Agentic-Scenarios

Flow:
1. Validate the inbound Entra ID access token from the SPA (JWT bearer,
   audience = Blueprint's exposed API scope).
2. Fetch a JWT-SVID from the local SPIRE Workload API. This is used ONLY as
   the Blueprint CCA's credential — the Blueprint is the sole holder of a
   real credential in this flow (normally a certificate with SN+I; here a
   SPIFFE JWT-SVID assertion instead).
3. Leg 1 — Blueprint -> Entra: client_credentials, scope
   api://AzureADTokenExchange/.default, fmi_path=<agent_app_id>.
   Returns T1, an FMI token scoped to this specific agent. The Agent Identity
   holds NO credential and NO FIC of its own — T1 IS its credential.
4. Leg 2 (user-scoped) — Agent CCA -> Entra: on-behalf-of grant. The agent
   authenticates with T1 as its client assertion (obtained transparently via
   the Blueprint FMI exchange in the assertion callback) and exchanges the
   inbound user access token for a downstream token on behalf of the signed-in
   user. No UPN is needed — the user is identified by the assertion itself.

The Blueprint CCA's assertion callback re-fetches a fresh JWT-SVID on each
invocation (SVIDs are short-lived); MSAL caches T1 and the downstream result
internally so this only actually round-trips to SPIRE/Entra when the cache
misses or expires.
"""
import asyncio
import json
import logging
import os
import stat
import time
import uuid
from pathlib import Path
from typing import Literal, Optional

import httpx
import jwt
import msal
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from jwt import PyJWKClient
from openai import APIConnectionError, APIError, APITimeoutError, OpenAI
from pydantic import BaseModel, ConfigDict, Field

app = FastAPI(title="backend")
logger = logging.getLogger("uvicorn.error")


def _validate_agent_mode(mode: str) -> str:
    valid_modes = {"user_context", "app_only"}
    if mode not in valid_modes:
        expected = ", ".join(sorted(valid_modes))
        raise RuntimeError(f"Invalid AGENT_MODE {mode!r}; expected one of: {expected}")
    return mode


def _parse_scopes(value: str) -> list[str]:
    scopes = value.split()
    if not scopes:
        raise RuntimeError("DOWNSTREAM_SCOPE must contain at least one scope")
    return scopes


def _parse_read_only_scopes(value: str) -> list[str]:
    scopes = _parse_scopes(value)
    non_read_scopes = [
        scope
        for scope in scopes
        if ".Read." not in scope.rsplit("/", 1)[-1]
    ]
    if non_read_scopes:
        raise RuntimeError(
            "DOWNSTREAM_SCOPE must contain only read permissions; rejected: "
            + ", ".join(non_read_scopes)
        )
    return scopes


TENANT_ID = os.environ["ENTRA_TENANT_ID"]
BLUEPRINT_CLIENT_ID = os.environ["BLUEPRINT_CLIENT_ID"]
AGENT_IDENTITY_CLIENT_ID = os.environ["AGENT_IDENTITY_CLIENT_ID"]
DOWNSTREAM_SCOPES = _parse_read_only_scopes(os.environ["DOWNSTREAM_SCOPE"])
EXPECTED_AUDIENCE = BLUEPRINT_CLIENT_ID
EXPECTED_DELEGATED_SCOPE = os.environ.get("EXPECTED_DELEGATED_SCOPE", "agent.invoke")
SPA_CLIENT_ID = os.environ["SPA_CLIENT_ID"]
BLUEPRINT_SCOPE = f"api://{BLUEPRINT_CLIENT_ID}/{EXPECTED_DELEGATED_SCOPE}"
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"
SPIRE_SOCKET = os.environ.get("SPIRE_SOCKET", "/run/spire/sockets/agent.sock")
SPIFFE_AUDIENCE = os.environ.get("SPIFFE_JWT_AUDIENCE", "api://AzureADTokenExchange")
FIC_EXCHANGE_SCOPE = ["api://AzureADTokenExchange/.default"]
AGENT_MODE = _validate_agent_mode(os.environ.get("AGENT_MODE", "user_context"))
MCP_SERVER_URL = os.environ.get(
    "MCP_SERVER_URL",
    "https://mcp.svc.cloud.microsoft/enterprise",
)
AZURE_OPENAI_ENDPOINT = os.environ.get("AZURE_OPENAI_ENDPOINT", "").rstrip("/")
AZURE_OPENAI_DEPLOYMENT = os.environ.get(
    "AZURE_OPENAI_DEPLOYMENT",
    "gpt-5.4-nano",
)
AI_AGENT_SYSTEM_PROMPT = os.environ.get(
    "AI_AGENT_SYSTEM_PROMPT",
    "You are seasoned Entra ID Adminsitrator with access to Microosft MCP Server "
    "for Enterprise. Use the tools provided by that MCP server to assist the "
    "humans. Only **READ** operations are allowed! Answer only questions related "
    "to Entra ID!",
)

# OIDC federation endpoints.
#
# Azure Container Apps gives each app a single HTTPS ingress, so in the merged
# backend image this API also fronts the SPIRE OIDC discovery + JWKS endpoints
# (served locally by oidc-discovery-provider) under the same public origin.
# OIDC_ISSUER_URL is the public base URL (= the JWT-SVID `iss` and the Entra FIC
# issuer); OIDC_PROVIDER_URL is where the local provider actually listens.
OIDC_ISSUER_URL = os.environ.get("OIDC_ISSUER_URL", "https://poc.local").rstrip("/")
OIDC_PROVIDER_URL = os.environ.get("OIDC_PROVIDER_URL", "http://localhost:8443").rstrip("/")
SPA_DIRECTORY = Path(os.environ.get("SPA_DIRECTORY", "/app/spa"))

_jwks_client = PyJWKClient(f"{AUTHORITY}/discovery/v2.0/keys")


def _enforce_delegated_scope(claims: dict) -> None:
    granted_scopes = claims.get("scp")
    if (
        not isinstance(granted_scopes, str)
        or EXPECTED_DELEGATED_SCOPE not in granted_scopes.split()
    ):
        raise HTTPException(
            status_code=403,
            detail=f"Missing required delegated scope: {EXPECTED_DELEGATED_SCOPE}",
        )


# ---------------------------------------------------------------------------
# Step 1: validate the inbound user token from the SPA
# ---------------------------------------------------------------------------
def validate_inbound_token(auth_header: Optional[str]) -> dict:
    if not auth_header or not auth_header.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = auth_header.split(" ", 1)[1]
    try:
        signing_key = _jwks_client.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=EXPECTED_AUDIENCE,
            issuer=f"{AUTHORITY}/v2.0",
        )
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")
    _enforce_delegated_scope(claims)
    return claims


# ---------------------------------------------------------------------------
# JWT-SVID provider — the Blueprint's only credential.
#
# Mirrors the pattern in Azure/azure-workload-identity's MSAL example
# (examples/msal-python/token_credential.py): a plain callable is handed to
# client_credential={"client_assertion": ...} and MSAL "lazily calls it
# whenever a new token is needed" (per the MSAL docs' note on raw assertions,
# https://learn.microsoft.com/python/api/msal/msal.application.confidentialclientapplication).
# That example re-reads a projected token file on each call; here we re-fetch
# from the SPIRE Workload API instead. The JwtSource is opened once and kept
# open for the process lifetime (it maintains a streaming connection to the
# SPIRE Agent and refreshes the SVID internally), rather than reconnecting
# on every call.
# ---------------------------------------------------------------------------
class SpiffeJwtProvider:
    def __init__(self, socket_path: str, audience: str):
        self._socket_path = socket_path
        self._audience = audience
        self._source = None  # opened lazily on first use

    def _ensure_source(self):
        # Opened lazily (NOT at import time) so the app can start before the
        # SPIRE agent has created its socket. JwtSource blocks until the first
        # Workload API update or until the timeout, so a brief startup race is
        # tolerated instead of crashing the process at boot.
        if self._source is None:
            from spiffe import JwtSource

            self._source = JwtSource(
                socket_path=f"unix://{self._socket_path}",
                timeout_in_seconds=30,
            )
        return self._source

    def __call__(self, ctx=None) -> str:
        """Zero/one-arg callable — MSAL lazily invokes this whenever a fresh
        client assertion is needed for a Leg 1 request."""
        svid = self._ensure_source().fetch_svid(audience={self._audience})
        token = svid.token
        # Debug aid: Entra does not surface the client assertion it received in
        # any customer-visible log, so log the issued JWT-SVID here (header +
        # claims + raw token) so it can be inspected — e.g. pasted into
        # https://jwt.ms — while wiring up the federated identity credential.
        try:
            header = jwt.get_unverified_header(token)
            claims = jwt.decode(token, options={"verify_signature": False})
            print(f"[svid] issued header={header} claims={claims}", flush=True)
            print(f"[svid] raw assertion: {token}", flush=True)
        except Exception as exc:  # never let logging break the token flow
            print(f"[svid] could not decode issued SVID for logging: {exc}", flush=True)
        return token

    def close(self):
        if self._source is not None:
            self._source.close()


_jwt_svid_provider = SpiffeJwtProvider(SPIRE_SOCKET, SPIFFE_AUDIENCE)


# ---------------------------------------------------------------------------
# Blueprint CCA — sole holder of a real credential (the JWT-SVID).
#
# Do NOT pass a static string here: SVIDs are short-lived, so client_credential
# must be a callable (see msal docs above) that MSAL invokes fresh each time
# the cached T1 has expired.
# ---------------------------------------------------------------------------
blueprint_app = msal.ConfidentialClientApplication(
    BLUEPRINT_CLIENT_ID,
    client_credential={"client_assertion": _jwt_svid_provider},
    authority=AUTHORITY,
)


# ---------------------------------------------------------------------------
# Agent CCA cache — one per agent app id. Each holds NO credential of its
# own; its assertion callback chains back to the Blueprint for Leg 1 (T1),
# scoped via fmi_path so multiple agents can share one Blueprint safely.
# ---------------------------------------------------------------------------
_agent_apps: dict = {}


def _get_agent_app(agent_app_id: str):
    if agent_app_id not in _agent_apps:

        def assertion_cb(ctx=None) -> str:
            # Leg 1: Blueprint -> Entra, FMI token (T1) scoped to this agent.
            result = blueprint_app.acquire_token_for_client(
                FIC_EXCHANGE_SCOPE,
                fmi_path=agent_app_id,
            )
            if "access_token" not in result:
                raise RuntimeError(
                    f"Leg 1 (Blueprint FMI exchange) failed: "
                    f"{result.get('error')}: {result.get('error_description')}"
                )
            return result["access_token"]

        _agent_apps[agent_app_id] = msal.ConfidentialClientApplication(
            agent_app_id,
            client_credential={"client_assertion": assertion_cb},
            authority=AUTHORITY,
        )
    return _agent_apps[agent_app_id]


# ---------------------------------------------------------------------------
# App-only downstream token: agent acting as itself, no user context
# ---------------------------------------------------------------------------
def get_app_only_token(agent_app_id: str, scopes: list) -> str:
    agent_app = _get_agent_app(agent_app_id)
    result = agent_app.acquire_token_for_client(scopes)
    if "access_token" not in result:
        raise HTTPException(
            status_code=502,
            detail=f"App-only token acquisition failed: {result.get('error_description')}",
        )
    return result["access_token"]


# ---------------------------------------------------------------------------
# User-scoped downstream token: on-behalf-of exchange.
#
# The agent CCA authenticates with its own credential — T1, obtained
# transparently via the Blueprint FMI exchange in the assertion callback
# (Leg 1) — and performs an OAuth 2.0 on-behalf-of exchange, swapping the
# inbound user access token for a downstream token for the signed-in user.
# No UPN is needed: the user is identified by the assertion. MSAL caches the
# result internally (keyed by the assertion), so repeat calls are served from
# cache until expiry.
# ---------------------------------------------------------------------------
def get_user_scoped_token(agent_app_id: str, scopes: list, user_assertion: str) -> str:
    agent_app = _get_agent_app(agent_app_id)
    result = agent_app.acquire_token_on_behalf_of(
        user_assertion=user_assertion,
        scopes=scopes,
    )
    if "access_token" not in result:
        raise HTTPException(
            status_code=502,
            detail=f"Leg 3 (on-behalf-of exchange) failed: {result.get('error_description')}",
        )
    return result["access_token"]


# ---------------------------------------------------------------------------
# Local agent — Azure OpenAI Responses API with the authenticated enterprise
# MCP endpoint as a native tool. The Agent Identity token grants only the
# read-only DOWNSTREAM_SCOPES configured for this application.
# ---------------------------------------------------------------------------
_openai_client: Optional[OpenAI] = None


def _get_openai_client() -> OpenAI:
    global _openai_client
    if not AZURE_OPENAI_ENDPOINT:
        raise HTTPException(
            status_code=503,
            detail="AZURE_OPENAI_ENDPOINT is not configured",
        )
    if _openai_client is None:
        token_provider = get_bearer_token_provider(
            DefaultAzureCredential(),
            "https://ai.azure.com/.default",
        )
        _openai_client = OpenAI(
            base_url=f"{AZURE_OPENAI_ENDPOINT}/openai/v1/",
            api_key=token_provider,
        )
    return _openai_client


def _run_agent_sync(message: str, mcp_token: str, history: Optional[list[dict]] = None) -> dict:
    request_id = str(uuid.uuid4())
    model_input = [*(history or []), {"role": "user", "content": message}]
    try:
        response = _get_openai_client().responses.create(
            model=AZURE_OPENAI_DEPLOYMENT,
            instructions=AI_AGENT_SYSTEM_PROMPT,
            input=model_input,
            tools=[
                {
                    "type": "mcp",
                    "server_label": "microsoft_mcp_enterprise",
                    "server_url": MCP_SERVER_URL,
                    "server_description": (
                        "Microsoft MCP Server for enterprise. Use only read "
                        "operations related to Microsoft Entra ID."
                    ),
                    "authorization": mcp_token,
                    "require_approval": "never",
                }
            ],
            store=False,
        )
    except APITimeoutError as exc:
        logger.error("Agent model timed out request_id=%s error=%s", request_id, exc)
        raise HTTPException(
            status_code=504,
            detail={"message": "AI agent timed out", "request_id": request_id},
        ) from exc
    except (APIConnectionError, APIError) as exc:
        logger.error(
            "Agent model request failed request_id=%s error_type=%s error=%s",
            request_id,
            type(exc).__name__,
            exc,
        )
        raise HTTPException(
            status_code=502,
            detail={"message": "AI agent request failed", "request_id": request_id},
        ) from exc

    answer = response.output_text.strip()
    if not answer:
        raise HTTPException(
            status_code=502,
            detail={"message": "AI agent returned no answer", "request_id": request_id},
        )

    tool_calls = [
        {
            "name": getattr(item, "name", None),
            "status": getattr(item, "status", None),
        }
        for item in response.output
        if getattr(item, "type", None) == "mcp_call"
    ]
    return {
        "answer": answer,
        "model": AZURE_OPENAI_DEPLOYMENT,
        "tool_calls": tool_calls,
        "request_id": request_id,
    }


class ChatMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=4000)


class InvokeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message: str = Field(min_length=1, max_length=4000)
    history: list[ChatMessage] = Field(default_factory=list, max_length=20)


@app.post("/invoke")
async def invoke(body: InvokeRequest, request: Request):
    auth_header = request.headers.get("authorization")
    claims = await asyncio.to_thread(validate_inbound_token, auth_header)

    if AGENT_MODE == "app_only":
        token = await asyncio.to_thread(
            get_app_only_token,
            AGENT_IDENTITY_CLIENT_ID,
            DOWNSTREAM_SCOPES,
        )
    else:
        # On-behalf-of: the raw inbound access token IS the user assertion.
        user_assertion = auth_header.split(" ", 1)[1]
        token = await asyncio.to_thread(
            get_user_scoped_token,
            AGENT_IDENTITY_CLIENT_ID,
            DOWNSTREAM_SCOPES,
            user_assertion,
        )

    history = [item.model_dump() for item in body.history]
    result = await asyncio.to_thread(
        _run_agent_sync,
        body.message.strip(),
        token,
        history,
    )
    return {
        "invoked_by": claims.get("preferred_username", claims.get("sub")),
        "mode": AGENT_MODE,
        **result,
    }


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "ts": time.time()}


def _is_spire_socket_ready() -> bool:
    try:
        return stat.S_ISSOCK(os.stat(SPIRE_SOCKET).st_mode)
    except OSError:
        return False


async def _probe_jwks(name: str, url: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=3) as client:
            response = await client.get(url)
            response.raise_for_status()
            jwks = response.json()
        if not isinstance(jwks, dict) or not jwks.get("keys"):
            raise ValueError("JWKS response contains no keys")
        return True
    except (httpx.HTTPError, ValueError, TypeError) as exc:
        logger.warning(
            "Readiness probe failed dependency=%s url=%s error_type=%s error=%s",
            name,
            url,
            type(exc).__name__,
            exc,
        )
        return False


@app.get("/readyz")
async def readyz():
    oidc_provider_ready, entra_jwks_ready = await asyncio.gather(
        _probe_jwks("oidc_provider", f"{OIDC_PROVIDER_URL}/keys"),
        _probe_jwks("entra_jwks", f"{AUTHORITY}/discovery/v2.0/keys"),
    )
    checks = {
        "spire_socket": _is_spire_socket_ready(),
        "oidc_provider": oidc_provider_ready,
        "entra_jwks": entra_jwks_ready,
    }
    status = "ready" if all(checks.values()) else "not_ready"
    status_code = 200 if status == "ready" else 503
    return JSONResponse(
        status_code=status_code,
        content={"status": status, "checks": checks, "ts": time.time()},
    )


@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse(url="/spa/")


@app.get("/spa", include_in_schema=False)
async def spa_redirect():
    return RedirectResponse(url="/spa/")


@app.get("/spa/env-config.js", include_in_schema=False)
async def spa_environment_config():
    config = {
        "SPA_CLIENT_ID": SPA_CLIENT_ID,
        "TENANT_ID": TENANT_ID,
        "BLUEPRINT_SCOPE": BLUEPRINT_SCOPE,
        "AGENT_API_URL": "/invoke",
    }
    return Response(
        content=f"window.__ENV__ = {json.dumps(config)};\n",
        media_type="application/javascript",
        headers={"Cache-Control": "no-store"},
    )


# ---------------------------------------------------------------------------
# OIDC federation endpoints (proxied from the local oidc-discovery-provider).
#
# Entra fetches <issuer>/.well-known/openid-configuration then its jwks_uri to
# validate the JWT-SVID at the FIC exchange. Because ACA exposes only one HTTPS
# ingress per app, we serve both here on the same public origin as /invoke and
# rewrite issuer/jwks_uri to the public URL so they resolve back to this app.
# ---------------------------------------------------------------------------
async def openid_configuration():
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{OIDC_PROVIDER_URL}/.well-known/openid-configuration")
        resp.raise_for_status()
        doc = resp.json()
    doc["issuer"] = OIDC_ISSUER_URL
    doc["jwks_uri"] = f"{OIDC_ISSUER_URL}/keys"
    # SPIRE's oidc-discovery-provider emits a minimal document that trips up
    # Microsoft Entra's OIDC metadata parser: authorization_endpoint is an empty
    # string (not a valid URI) and subject_types_supported is empty. Entra
    # rejects such a document during the FIC exchange and reports it generically
    # as AADSTS501661 "Request to External OIDC endpoint failed". Drop the empty
    # authorization_endpoint (not used for workload identity federation) and
    # ensure subject_types_supported is populated so the document is valid.
    if not doc.get("authorization_endpoint"):
        doc.pop("authorization_endpoint", None)
    if not doc.get("subject_types_supported"):
        doc["subject_types_supported"] = ["public"]
    return doc


async def oidc_keys():
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(f"{OIDC_PROVIDER_URL}/keys")
        resp.raise_for_status()
        jwks = resp.json()
    # SPIRE omits the optional JWKS "use" member; Microsoft's own federation
    # examples publish keys with "use":"sig". Add it for maximum compatibility
    # with strict validators.
    for _k in jwks.get("keys", []):
        _k.setdefault("use", "sig")
    return jwks


# When OIDC_ISSUER_URL contains a path (e.g. .../spiffe-oidc), Microsoft Entra's
# discovery-URL behaviour is ambiguous, so register BOTH conventions:
#   - OpenID Connect Discovery 1.0 appends:  {issuer}/.well-known/openid-configuration
#   - RFC 8414 inserts after the host:       {host}/.well-known/openid-configuration{path}
# Serving both guarantees Entra can retrieve the metadata whichever it uses.
from urllib.parse import urlparse as _urlparse

_issuer_path = _urlparse(OIDC_ISSUER_URL).path.rstrip("/")
if _issuer_path:
    app.add_api_route(
        f"{_issuer_path}/.well-known/openid-configuration",
        openid_configuration, methods=["GET"],
    )
    app.add_api_route(
        f"/.well-known/openid-configuration{_issuer_path}",
        openid_configuration, methods=["GET"],
    )
    app.add_api_route(f"{_issuer_path}/keys", oidc_keys, methods=["GET"])


@app.on_event("shutdown")
def _close_spiffe_source():
    _jwt_svid_provider.close()


# Keep this mount last so API, health, OIDC, and dynamic SPA config routes win.
app.mount("/spa", StaticFiles(directory=SPA_DIRECTORY, html=True), name="spa")
