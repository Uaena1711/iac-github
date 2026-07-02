# `docker-image.yml` — reusable Docker image build/publish

Reusable **layer-2 pipeline** that builds **one** Docker image and **optionally pushes** it to a
**provider-selected** registry. Same flat, per-job-image shape as `tf-env`/`cfn-env` — each stage is
its own job in its own image, wired from the shared Tier-1 composites
([`checkout-artifact`](../actions/checkout-artifact), [`secret-scan`](../actions/secret-scan),
[`docker-lint`](../actions/docker-lint)). Call it once per image via a caller `strategy.matrix`.

```
checkout ────┐  (uploads the source as an artifact)
secret_scan ─┤
lint ────────┼─▶ build (+optional push) ─▶ check      (ONE image per call)
             │   (build pulls the source via download-artifact — no git/tar needed)
```

- **Standalone.** Nothing here touches the Terraform/CloudFormation pipelines.
- **Per-job images.** Each job runs in its own image via a `*_image` input (falling back to
  `container_image`, empty = the runner host) — only the tools that job needs. The **build** job is
  the one unavoidably-combined step (buildx + login + build-push share one BuildKit daemon + docker
  config) and must run on a **docker-capable** runner/image (host by default).
- **Optional push.** `push: false` = build-only validation (e.g. on PRs): no login, no digest.
- **Provider seam.** `provider` picks the login plugin; `registry` is the host. `ghcr` ships live,
  `ecr` ships as a reference plugin (needs AWS creds in the job — run `aws-oidc` first).
- **`platforms: linux/amd64`** (single native arch) **skips QEMU** — no `--privileged` container.
  QEMU only registers for a non-native arch. GitHub Actions `container:` jobs are Linux/amd64, so
  amd64-only is the right default for CI tool images.
- **gha cache**; tags/labels from `docker/metadata-action`; the pushed **digest is written to the
  run Summary** (pin it downstream).

## Quick start — one image

```yaml
name: publish
on:
  release: { types: [published] }
  workflow_dispatch:
permissions:
  contents: read
  packages: write            # GHCR push via GITHUB_TOKEN
jobs:
  image:
    uses: Uaena1711/iac-github/.github/workflows/docker-image.yml@v2
    with:
      image: ghcr.io/${{ github.repository_owner }}/my-app
      name: my-app
      context: .
    secrets: inherit
```

## Many images — caller matrix

```yaml
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        image:
          - { name: img-a, context: images/a }
          - { name: img-b, context: images/b }
    uses: Uaena1711/iac-github/.github/workflows/docker-image.yml@v2
    with:
      image: ghcr.io/${{ github.repository_owner }}/${{ matrix.image.name }}
      name: ${{ matrix.image.name }}          # unique per leg -> unique source artifact + cache
      context: ${{ matrix.image.context }}
      provider: ghcr                          # default
      platforms: linux/amd64                  # amd64-only -> no QEMU, no --privileged
    secrets: inherit
```

> When called from a `matrix`, the workflow-level `digest`/`tags` **outputs** are overwritten
> non-deterministically across legs — read the **per-image digest from the run Summary** instead.

## Build-only (no push)

```yaml
jobs:
  validate:
    uses: Uaena1711/iac-github/.github/workflows/docker-image.yml@v2
    with:
      image: ghcr.io/${{ github.repository_owner }}/my-app
      name: my-app
      context: .
      push: false              # build, don't push; no login, no creds
```

## Inputs

| input | default | purpose |
|-------|---------|---------|
| `image` | **required** | full image base ref, e.g. `ghcr.io/owner/name` |
| `name` | **required** | short image id (artifact/cache-safe), unique per matrix leg |
| `context` | **required** | build context directory |
| `provider` | `ghcr` | registry-login provider (only used when `push`) |
| `registry` | `ghcr.io` | registry host (`ecr`: `<acct>.dkr.ecr.<region>.amazonaws.com`) |
| `dockerfile` | `''` | Dockerfile path; empty → `<context>/Dockerfile` |
| `platforms` | `linux/amd64,linux/arm64` | buildx target platforms (`linux/amd64` skips QEMU) |
| `push` | `true` | push to the registry (false = build-only) |
| `aws_region` | `''` | forwarded to the `ecr` provider |
| `build_args` | `''` | newline-separated build args |
| `provenance` | `false` | build-push-action provenance attestation |
| `cache_scope` | `''` | gha cache scope; empty → falls back to `name` |
| `lint_threshold` | `error` | hadolint failure threshold: error \| warning \| info \| style |
| `container_image` | `''` | shared fallback image for every job (empty = host) |
| `checkout_image` | `''` | image for the checkout job (needs git) |
| `secret_scan_image` | GHCR gitleaks | image for the secret_scan job |
| `lint_image` | `''` | image for the lint job (hadolint; empty = host, pin installed) |
| `build_image` | `''` | image for the build job — must be docker-capable |
| `runs_on` | `ubuntu-latest` | runner label |
| `tags` | semver+sha+latest ruleset | `metadata-action` tag rules (overridable) |

**Secrets** (both optional): `registry_username` (default: the GitHub actor), `registry_password`
(default: `GITHUB_TOKEN`). For a non-GHCR provider, pass these. **Outputs:** `digest`, `tags`.

## Add a registry provider

Drop `actions/registry-login/providers/<name>.sh` defining `provider_login` (and optionally
`provider_check`), then call with `provider: <name>` — no change to `docker-image.yml`:

```sh
provider_login() {
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
}
```

See [`actions/registry-login/providers/README.md`](../actions/registry-login/providers/README.md)
for the full contract and the shipped providers.
