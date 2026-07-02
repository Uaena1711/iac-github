# `docker-image.yml` — reusable Docker image build/publish

Reusable workflow that builds **one** Docker image and **optionally pushes** it to a
**provider-selected** registry. Login is delegated to the pluggable
[`registry-login`](../actions/registry-login) composite, so a registry (`ghcr`, `ecr`, …) is a
plugin — adding one is a single `providers/<name>.sh`, no workflow change. Call it once per image
via a caller `strategy.matrix`.

```
checkout ─▶ qemu/buildx ─▶ registry-login (if push) ─▶ metadata ─▶ build-push ─▶ digest→summary
```

- **Standalone.** Nothing here touches the Terraform/CloudFormation pipelines.
- **Optional push.** `push: false` = build-only validation (e.g. on PRs): no login, no digest.
- **Provider seam.** `provider` picks the login plugin; `registry` is the host. `ghcr` ships live,
  `ecr` ships as a reference plugin (needs AWS creds in the job — run `aws-oidc` first).
- **Multi-arch** (`linux/amd64,linux/arm64`) via buildx + QEMU; **gha cache**; tags/labels from
  `docker/metadata-action`. The pushed **digest is written to the run Summary** (pin it downstream).

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
      context: ${{ matrix.image.context }}
      provider: ghcr           # default
      cache_scope: ${{ matrix.image.name }}
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
      context: .
      push: false              # build, don't push; no login, no creds
```

## Inputs

| input | default | purpose |
|-------|---------|---------|
| `image` | **required** | full image base ref, e.g. `ghcr.io/owner/name` |
| `context` | **required** | build context directory |
| `provider` | `ghcr` | registry-login provider (only used when `push`) |
| `registry` | `ghcr.io` | registry host (`ecr`: `<acct>.dkr.ecr.<region>.amazonaws.com`) |
| `dockerfile` | `''` | Dockerfile path; empty → `<context>/Dockerfile` |
| `platforms` | `linux/amd64,linux/arm64` | buildx target platforms |
| `push` | `true` | push to the registry (false = build-only) |
| `aws_region` | `''` | forwarded to the `ecr` provider |
| `build_args` | `''` | newline-separated build args |
| `provenance` | `false` | build-push-action provenance attestation |
| `cache_scope` | `''` | gha cache scope; empty → falls back to `image` |
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
