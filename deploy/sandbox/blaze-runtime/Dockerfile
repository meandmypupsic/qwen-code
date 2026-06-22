# Blaze Runtime replacement for the old nessy-cli async sandbox image flow.
# This image installs a pre-published npm artifact and starts one long-lived
# `blaze-runtime serve` process from entrypoint.sh.

ARG BASE_IMAGE=docker-hosted.artifactory.tcsbank.ru/cicd-images/nodejs-22
FROM --platform=linux/amd64 ${BASE_IMAGE}

ARG NPM_REGISTRY=https://artifactory.tcsbank.ru/artifactory/api/npm/npm-all/
ARG BLAZE_RUNTIME_PACKAGE=@art/blaze-runtime
ARG BLAZE_RUNTIME_VERSION=0.18.7

ENV BLAZE_RUNTIME_PACKAGE=${BLAZE_RUNTIME_PACKAGE}
ENV BLAZE_RUNTIME_PORT=4170
ENV BLAZE_RUNTIME_HOST=0.0.0.0
ENV BLAZE_RUNTIME_WORKSPACE=/workspace

# Match the old nessy-cli async image behavior: internal CA bundle plus a few
# diagnostic tools that are useful when sandbox startup or SSE proxying fails.
ADD https://nexus.tcsbank.ru/repository/dist/tinkoff-root-certs/tinkoff-bundle.crt /usr/local/share/ca-certificates/tinkoff-bundle.crt
RUN update-ca-certificates
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/tinkoff-bundle.crt

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    lsof \
    procps \
    ripgrep \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN npm config set registry "${NPM_REGISTRY}" \
  && npm config set strict-ssl false \
  && npm config set ca ""

RUN npm install -g --no-cache "${BLAZE_RUNTIME_PACKAGE}@${BLAZE_RUNTIME_VERSION}" \
  && npm cache clean --force

WORKDIR /workspace
RUN mkdir -p /workspace /root/.blaze-runtime

COPY deploy/sandbox/blaze-runtime/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4170

ENTRYPOINT ["/entrypoint.sh"]
