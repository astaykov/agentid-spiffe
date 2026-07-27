#!/bin/bash
set -euo pipefail

# Combined backend entrypoint: brings up the full SPIRE stack (server, agent,
# OIDC discovery provider) and then the FastAPI app, all in one PID namespace
# so the SPIRE unix WorkloadAttestor can attest uvicorn (selector unix:uid:0).

# The spire-server local API listens on this fixed default path (not the data
# dir); all spire-server CLI calls below target it explicitly.
SERVER_SOCK=/tmp/spire-server/private/api.sock

# ---------------------------------------------------------------------------
# Public OIDC issuer. In ACA this is the backend app's generated origin plus
# the fixed issuer path, for example:
#   OIDC_ISSUER_URL=https://backend-xxxx.azurecontainerapps.io/spiffe-oidc
# It becomes the JWT-SVID `iss` claim and must equal the Entra FIC issuer.
OIDC_ISSUER_URL="${OIDC_ISSUER_URL:-https://poc.local}"
OIDC_DOMAIN="$(printf '%s' "$OIDC_ISSUER_URL" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')"
if [ "$OIDC_DOMAIN" = "localhost" ]; then
  OIDC_DOMAINS='["localhost"]'
else
  OIDC_DOMAINS="[\"${OIDC_DOMAIN}\", \"localhost\"]"
fi
echo "[entrypoint] OIDC issuer=$OIDC_ISSUER_URL domains=$OIDC_DOMAINS"

sed -i "s#__OIDC_ISSUER_URL__#${OIDC_ISSUER_URL}#" /run/spire/config/server.conf
sed -i "s#__OIDC_DOMAINS__#${OIDC_DOMAINS}#" /run/spire/config/oidc-discovery-provider.conf

# This is intentionally an ephemeral POC. Reset all SPIRE server and agent
# state on every container start, including the CA journal and signing keys.
# The resulting JWT `kid` changes after any restart or redeployment, which can
# conflict with Microsoft Entra's cached federated-issuer metadata.
rm -rf /run/spire/data/server /run/spire/data/agent
mkdir -p /run/spire/data/server /run/spire/data/agent

echo "[entrypoint] starting spire-server..."
spire-server run -config /run/spire/config/server.conf &
SERVER_PID=$!

# wait for server API socket
for i in $(seq 1 30); do
  if spire-server healthcheck -socketPath "$SERVER_SOCK" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "[entrypoint] generating join token..."
JOIN_TOKEN=$(spire-server token generate -spiffeID spiffe://poc.local/agent/node1 -socketPath "$SERVER_SOCK" | awk -F': ' '{print $2}')

echo "[entrypoint] registering the agent workload entry (unix:uid:0)..."
spire-server entry create \
  -socketPath "$SERVER_SOCK" \
  -parentID spiffe://poc.local/agent/node1 \
  -spiffeID spiffe://poc.local/agent/identity-1 \
  -selector unix:uid:0 || true

echo "[entrypoint] starting spire-agent..."
spire-agent run -config /run/spire/config/agent.conf -joinToken "$JOIN_TOKEN" &
AGENT_PID=$!

echo "[entrypoint] starting oidc-discovery-provider..."
oidc-discovery-provider -config /run/spire/config/oidc-discovery-provider.conf &
DP_PID=$!

# Give the agent a moment to attest and create its Workload API socket before
# the app's first SVID fetch.
sleep 3

echo "[entrypoint] starting FastAPI (uvicorn) on :8000..."
cd /app
uvicorn main:app --host 0.0.0.0 --port 8000 &
API_PID=$!

# If any core process dies, exit so the platform restarts the whole replica.
wait -n "$SERVER_PID" "$AGENT_PID" "$DP_PID" "$API_PID"
echo "[entrypoint] a core process exited; shutting down replica."
exit 1
