# Tool images

The `tf-env` / `cfn-env` / `tf-docs` jobs default to pinned container images that **bake the heavy
CI tools**, so nothing heavy installs at runtime (only `jq` is ever auto-installed — it's tiny).

| Image | Bakes | Used by |
|-------|-------|---------|
| `ghcr.io/uaena1711/iac-github-tf`  | terraform, tflint, terraform-docs, jq, git | tf-env (lint/resolve/plan/apply), tf-docs |
| `ghcr.io/uaena1711/iac-github-cfn` | aws-cli v2, cfn-lint, jq, git | cfn-env (lint/resolve/plan/apply) |
| `ghcr.io/gitleaks/gitleaks`        | gitleaks | secret_scan (both) |

**Source & builds:** the Dockerfiles and the publish workflow live in a dedicated repo,
[**Uaena1711/iac-github-images**](https://github.com/Uaena1711/iac-github-images) (kept out of this
catalog — no monorepo). Its `publish.yml` is a thin caller of this catalog's
[`docker-image.yml`](docker-image.md) (`provider: ghcr`), so the tool-image builds **dogfood the
catalog** — multi-arch (amd64+arm64) to GHCR.

## No Docker Hub, no rate limits
- Published to **GHCR public → unlimited pulls**, no throttling.
- Built **FROM GHCR public bases** (`ghcr.io/terraform-linters/tflint`, `ghcr.io/astral-sh/uv`),
  not Docker Hub (anon 100/6h) or ECR. secret_scan uses **GHCR** gitleaks, not Docker Hub.
- Net: **zero Docker Hub pulls at build or runtime.**

## Pinning & overrides
The default `*_image` inputs reference an **immutable `@sha256` digest**. Override any per-job image
input to use your own (an AWS/terraform-capable image, or `""` to run on the host). Self-hosted
runners then only need **Docker** — the CLIs come from the image, not tools you maintain on the host.

## Tool versions
terraform 1.15.7 · tflint 0.63.1 · terraform-docs 0.24.0 · aws-cli 2.35.13 · cfn-lint 1.52.1 · gitleaks 8.30.1.
Bumping a version = update the Dockerfile in the images repo → it republishes → repin the digest here.
