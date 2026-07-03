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

| name   | registry host                               | needs                                                       | status |
|--------|---------------------------------------------|-------------------------------------------------------------|--------|
| `ghcr` | `ghcr.io`                                   | `REGISTRY_PASSWORD` (GITHUB_TOKEN/PAT)                       | live   |
| `ecr`  | `<acct>.dkr.ecr.<region>.amazonaws.com`     | `id-token: write` + `aws_role_arn` + `aws_region`; a pre-created repo | live   |

The `ecr` provider owns its auth: it exchanges the GitHub OIDC token for temporary role credentials
(`sts:AssumeRoleWithWebIdentity`) in-script, then `aws ecr get-login-password | docker login` — so the
workflow only grants `id-token: write` and passes `aws_role_arn`. The role's trust policy must allow
the calling repo's OIDC subject, and it needs `ecr:GetAuthorizationToken` + push perms on the repo.
ECR has no push-time repo auto-create, so the repository must exist first. If AWS creds are already in
the job env (e.g. a prior `aws-oidc` step), the provider skips the OIDC exchange.
