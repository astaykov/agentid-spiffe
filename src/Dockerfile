# Merged backend image for Azure Container Apps.
#
# Azure Container Apps gives each app a single public HTTPS ingress and its
# sidecar containers do NOT share a PID namespace. SPIRE workload attestation
# needs the SPIRE agent and the workload (uvicorn) in the SAME PID namespace,
# so we run spire-server + spire-agent + oidc-discovery-provider + the FastAPI
# app together in ONE container. FastAPI reverse-proxies the OIDC discovery +
# JWKS endpoints (see main.py) so everything is reachable on one HTTPS origin.
#
# Build context is the src/ folder (see azure.yaml / docker-compose). The
# FastAPI backend lives under backend/ and SPIRE configuration under spire/.
#
# SPIRE 1.10.x ships musl-linked Linux binaries only -> Alpine base.
FROM python:3.12-alpine

ARG SPIRE_VERSION=1.10.1

RUN apk add --no-cache bash curl ca-certificates tar

# spire-server + spire-agent from the main tarball; oidc-discovery-provider
# from the spire-extras tarball.
RUN curl -sSL https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/spire-${SPIRE_VERSION}-linux-amd64-musl.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=2 \
      spire-${SPIRE_VERSION}/bin/spire-server \
      spire-${SPIRE_VERSION}/bin/spire-agent \
 && curl -sSL https://github.com/spiffe/spire/releases/download/v${SPIRE_VERSION}/spire-extras-${SPIRE_VERSION}-linux-amd64-musl.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=2 \
      spire-extras-${SPIRE_VERSION}/bin/oidc-discovery-provider

# Python dependencies (musllinux wheels are available for cryptography,
# uvloop, httptools, etc., so no build toolchain is needed).
WORKDIR /app
COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Application, SPA assets, and SPIRE configuration.
COPY backend/main.py /app/main.py
COPY spa/ /app/spa/
COPY spire/server.conf /run/spire/config/server.conf
COPY spire/agent.conf /run/spire/config/agent.conf
COPY spire/oidc-discovery-provider.conf /run/spire/config/oidc-discovery-provider.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && mkdir -p /run/spire/data/server /run/spire/data/agent /run/spire/sockets

# 8000 = FastAPI (public ingress: /invoke, /healthz, /.well-known/*, /keys).
# 8443 = oidc-discovery-provider (internal only; fronted by FastAPI).
EXPOSE 8000 8443
ENTRYPOINT ["/entrypoint.sh"]
