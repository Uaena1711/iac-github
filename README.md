# iac-github

Reusable **GitHub Actions** for keyless Terraform CI/CD. A consumer repo includes one
reusable workflow (or composes the building-block actions) and gets a standardized
**detect → plan → apply** flow with per-stack OIDC federation and environment-based
approval gating.

> Generic and vendor-neutral by design — no organization, product, or account values are
> baked into this catalog. Identity lives per-stack in your repo's `tf-ci.env` files.

## Layered design

| Layer | Artifact | Purpose |
|-------|----------|---------|
| Building blocks | `actions/{detect-changes,aws-oidc,tf-plan,tf-apply}` (composite) | Reusable steps you can compose yourself |
| Paved road | `.github/workflows/terraform.yml` (reusable workflow) | The whole standardized flow, wired |

Use the paved road for the standard flow; compose the actions directly when you need to
override behavior. Both share the same building blocks (DRY, no lock-in).

## Quick start (paved road)

`.github/workflows/terraform.yml` in your consumer repo:

```yaml
name: terraform
on:
  pull_request:
  push: { branches: [main] }
permissions:
  id-token: write
  contents: read
jobs:
  terraform:
    uses: Uaena1711/iac-github/.github/workflows/terraform.yml@terraform/v1
    with:
      workspaces_root: envs
      default_region: us-east-1
    secrets: inherit
```

- **Pull request** → plan only (preview).
- **Push to `main`** → plan + apply. Stacks mapped to a protected GitHub **Environment**
  (one with required reviewers) pause for approval before apply.

See [`examples/`](examples/) for the paved-road and full-override (composed) callers.

## Per-stack contract: `tf-ci.env`

Each Terraform stack is a directory under `workspaces_root` that contains the marker file
`provider.tf` and a `tf-ci.env` carrying its identity:

```sh
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>   # role this stack's jobs assume (keyless OIDC)
AWS_REGION=us-east-1
AWS_STATE_BUCKET=<s3-bucket>                          # Terraform S3 backend (native lockfile)
AWS_STATE_KMS_KEY=<kms-key-arn>                       # SSE-KMS for state
```

`detect-changes` reads these to build the job matrix; each matrix leg federates to its own
role. No static cloud keys, ever.

### One-time AWS trust policy (per role, set up outside this catalog)

Roles must trust GitHub's OIDC provider. Template (replace placeholders):

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:*" }
  }
}
```

## Versioning & pinning

SemVer git tags; `metadata.json` `version` is the source of truth. Released automatically
on merge to `main`. Pin at the precision you want:

- `@terraform/v1` — latest v1.x of the reusable workflow (floating major, recommended)
- `@v1.2.3` — exact release
- `@<sha>` — during bootstrapping, before the first release

## License

[PolyForm Noncommercial License 1.0.0](LICENSE) — free for any noncommercial use
(personal, hobby, research, evaluation). Commercial use is not granted.
