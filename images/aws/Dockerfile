# syntax=docker/dockerfile:1
# iac-github :: AWS/CloudFormation tool image — aws-cli v2 + cfn-lint + jq + git.
# Baked so cfn-env jobs install NOTHING heavy at runtime. Base is GHCR public (unlimited pulls,
# no Docker Hub / no ECR), Debian 12 (glibc, required by aws-cli v2) with python + uv.
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim@sha256:e5b65587bce7de595f299855d7385fe7fca39b8a74baa261ba1b7147afa78e58

ARG TARGETARCH
ARG CFN_LINT_VERSION=1.52.1
ARG AWSCLI_VERSION=2.35.13

USER root
SHELL ["/bin/sh", "-euxc"]
RUN apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates git curl unzip jq; \
    rm -rf /var/lib/apt/lists/*; \
    case "$TARGETARCH" in amd64) A=x86_64 ;; arm64) A=aarch64 ;; *) echo "unsupported arch $TARGETARCH"; exit 1 ;; esac; \
    cd /tmp; \
    # aws-cli v2 (pinned, glibc). AWS ships a GPG sig, not a sha256; pinned-version URL over TLS.
    curl -fsSLO "https://awscli.amazonaws.com/awscli-exe-linux-${A}-${AWSCLI_VERSION}.zip"; \
    unzip -q "awscli-exe-linux-${A}-${AWSCLI_VERSION}.zip"; \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli; \
    rm -rf /tmp/*; \
    # cfn-lint baked into system python (no runtime pip)
    uv pip install --system --no-cache "cfn-lint==${CFN_LINT_VERSION}"; \
    useradd -m -u 1000 runner || true; \
    aws --version; cfn-lint --version; jq --version; git --version

USER runner
WORKDIR /work
SHELL ["/bin/sh", "-c"]
ENTRYPOINT []
CMD ["/bin/sh"]

LABEL org.opencontainers.image.source="https://github.com/Uaena1711/iac-github" \
      org.opencontainers.image.description="aws-cli v2 + cfn-lint + jq + git for iac-github cfn-env" \
      org.opencontainers.image.licenses="MIT"
