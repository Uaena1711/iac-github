# syntax=docker/dockerfile:1
# iac-github :: Terraform tool image — terraform + tflint + terraform-docs + jq + git.
# Baked so tf-env/tf-docs jobs install NOTHING heavy at runtime. Base is GHCR public (unlimited
# pulls, no Docker Hub / no ECR) and already ships tflint, so only terraform + terraform-docs are
# downloaded (verified against the vendors' SHA256SUMS). jq comes from the Alpine repo (tolerant tool).
FROM ghcr.io/terraform-linters/tflint:v0.63.1@sha256:890e37827d7b5e400f26137c5189c7efa581365fe9299b5b9814e5148d5978b9

# Pins match actions/tf-run + actions/tf-docs; tflint pin == the base tag above.
ARG TARGETARCH
ARG TERRAFORM_VERSION=1.15.7
ARG TERRAFORM_DOCS_VERSION=0.24.0

USER root
SHELL ["/bin/sh", "-euxc"]
RUN apk add --no-cache ca-certificates git curl unzip tar jq; \
    cd /tmp; \
    # terraform — verify against the official SHA256SUMS
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSLO "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"; \
    grep " terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip$" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -o "terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -d /usr/local/bin; \
    # terraform-docs — verify against its published .sha256sum (keep real filenames for -c)
    curl -fsSLO "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSLO "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}.sha256sum"; \
    grep "terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TARGETARCH}.tar.gz" "terraform-docs-v${TERRAFORM_DOCS_VERSION}.sha256sum" | sha256sum -c -; \
    tar -xzf "terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-${TARGETARCH}.tar.gz" terraform-docs; install -m0755 terraform-docs /usr/local/bin/terraform-docs; \
    rm -rf /tmp/*; \
    adduser -D -h /home/runner runner 2>/dev/null || true; \
    terraform version; tflint --version; terraform-docs --version; jq --version; git --version

USER runner
WORKDIR /work
SHELL ["/bin/sh", "-c"]
ENTRYPOINT []
CMD ["/bin/sh"]

LABEL org.opencontainers.image.source="https://github.com/Uaena1711/iac-github" \
      org.opencontainers.image.description="terraform + tflint + terraform-docs + jq + git for iac-github tf-env/tf-docs" \
      org.opencontainers.image.licenses="MIT"
