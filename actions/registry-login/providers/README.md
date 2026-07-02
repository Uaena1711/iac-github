# registry-login providers

Each file here is a **plugin** for the `registry-login` action. The provider is selected by the
`provider` input (default `ghcr`). `registry-login.sh` sources `providers/<name>.sh` and calls its
functions to perform a `docker login`.

## Add a provider

Drop `providers/<name>.sh` defining:

```sh
# required: perform the `docker login` for this registry. Return non-zero on failure.
provider_login() {
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USERNAME" --password-stdin
}

# optional: preflight (deps present, config set). Return non-zero to abort before login.
provider_check() { command -v docker >/dev/null 2>&1; }
```

Then call the action (or the `docker-image.yml` workflow) with `provider: <name>`. That's the whole
contract — no change to `registry-login.sh` or any workflow.

Rules:
- POSIX sh, no bashisms (the action runs under `sh`).
- Feed secrets on **stdin** (`--password-stdin`), never on argv; send logs to stderr (`>&2`).
- Prefix helper vars with `_` to avoid clashing with the dispatcher.
- Read config from the environment (forward it in `action.yml` + the reusable workflow).

## Shipped providers

| name   | registry host                               | needs                                   | status    |
|--------|---------------------------------------------|-----------------------------------------|-----------|
| `ghcr` | `ghcr.io`                                   | `REGISTRY_PASSWORD` (GITHUB_TOKEN/PAT)  | live      |
| `ecr`  | `<acct>.dkr.ecr.<region>.amazonaws.com`     | AWS creds in the job (run `aws-oidc` first) | reference |

`reference` = the plugin proves the seam but isn't exercised in CI. Wire `aws-oidc` before it when
you first push to ECR.
