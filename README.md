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
| Building blocks (Tier 1) | `actions/{secret-scan,tf-lint,detect-changes,aws-oidc,resolve-env,tf-run}` (composite) | Reusable steps you can compose yourself |
| Per-env flow (Tier 2) | `.github/workflows/tf-env.yml` (reusable workflow) | One environment, end-to-end |

You call `tf-env.yml` **once per environment** and decide gating per env. Each call is its
own job graph:

```
secret_scan ─┐
lint ────────┼─▶ resolve ─▶ plan ─▶ apply ─▶ check     (per env)
             ┘
```

- Secret-scan + lint (fmt + tflint) gate before any cloud access.
- `apply` runs **only when the plan has changes**, so an unchanged env never fires its gate.
- **Gating = the env's GitHub Environment**: `dev` (no reviewers) applies automatically;
  `prod` (required reviewers) waits for approval. A waiting `prod` never blocks `dev`,
  because each env is a separate `tf-env.yml` call.

## Quick start

`.github/workflows/terraform.yml` in your consumer repo — **one job per env**:

```yaml
name: terraform
on:
  pull_request:
  push: { branches: [main] }
  workflow_dispatch:
    inputs:
      mode: { type: choice, options: [deploy, destroy], default: deploy }
permissions:
  id-token: write   # keyless OIDC
  contents: read
jobs:
  dev:
    uses: Uaena1711/iac-github/.github/workflows/tf-env.yml@v1
    with: { dir: envs/dev,  environment: dev,  mode: ${{ inputs.mode || 'deploy' }} }
  prod:
    uses: Uaena1711/iac-github/.github/workflows/tf-env.yml@v1
    with: { dir: envs/prod, environment: prod, mode: ${{ inputs.mode || 'deploy' }} }
```

- **PR** → plan preview per env. **Push to `main`** → each env plans; `dev` applies
  automatically; `prod` applies only after its Environment reviewer approves (and only if
  prod actually changed).
- **Destroy** → run manually with `mode: destroy`: a reviewed destroy-plan → Environment
  gate → teardown (no blind `terraform destroy -auto-approve`).

Pre-create the GitHub **Environments** (`dev`, `prod`, …) and add **required reviewers** to
the ones you want gated. To deploy just one env, keep only that env's job (or gate the others).

👉 **Full working consumer:** [Uaena1711/iac-github-terraform-example](https://github.com/Uaena1711/iac-github-terraform-example)
— copy its layout (`envs/<env>/{provider.tf,main.tf,tf-ci.env}`, a shared `modules/`, and the caller).

## Per-stack contract: `tf-ci.env`

Each Terraform stack is a directory under `workspaces_root` that contains the marker file
`provider.tf` and a `tf-ci.env` carrying its identity:

```sh
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>   # role this stack's jobs assume (keyless OIDC)
AWS_REGION=us-east-1
AWS_STATE_BUCKET=<s3-bucket>                          # Terraform S3 backend (native lockfile)
AWS_STATE_KMS_KEY=<kms-key-arn>                       # SSE-KMS for state
```

`tf-env` reads these (role/region) to federate that env's jobs to its own role. No static
cloud keys, ever.

### Resolving values from a secret vault (optional)

Any `tf-ci.env` value can be a `${REF}` placeholder pulled from a secret store instead of
being committed. Pick the provider **at the file level** with `SECRETS_PROVIDER=` (or
override per-run with the `secrets_provider` workflow input); plain values are left alone.

```sh
SECRETS_PROVIDER=github                       # github | awssm | none (default)
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>
AWS_REGION=us-east-1
AWS_STATE_BUCKET=${TF_STATE_BUCKET_DEV}        # ← resolved from the vault
```

The `resolve-env` action fetches each placeholder, **masks** it, and rewrites the file in
place (job-local — resolved secrets are never uploaded as artifacts). Shipped providers:

| `SECRETS_PROVIDER` | `${REF}` means | Source | Notes |
|--------------------|----------------|--------|-------|
| `github` | a variable/secret **name** | `vars`/`secrets` (needs `secrets: inherit` on the caller) | resolves any field, incl. `AWS_ROLE_ARN` |
| `awssm` | a Secrets Manager `secret-id[#json-field]` | AWS Secrets Manager | runs **after** OIDC → keep `AWS_ROLE_ARN`/`AWS_REGION` literal (or use `github` for them) |

Add your own by dropping one `actions/resolve-env/providers/<name>.sh` — see that dir's
`README.md`. Legacy literal `tf-ci.env` files (no `SECRETS_PROVIDER`) keep working unchanged.

### Passing Terraform input variables (normal & sensitive)

Non-sensitive variables are just committed HCL — a literal in `main.tf`, a `*.auto.tfvars`,
or the `var_file` input. For **sensitive** variables, don't put them on disk: add an
optional `tf-vars.env` to the stack and the pipeline injects each entry as `TF_VAR_<name>`
(masked, never written to a file), which Terraform reads natively.

```sh
# envs/dev/tf-vars.env — picks a provider like tf-ci.env; ${REF} is pulled from the vault.
SECRETS_PROVIDER=github
db_password=${DB_PASSWORD_DEV}        # -> TF_VAR_db_password (from a GitHub secret)
```

Declare the variable `sensitive = true` so Terraform redacts it from plan/apply output:

```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```

Caveat (inherent to Terraform): a sensitive value still ends up **inside the saved plan
and the state**. That's why the plan artifact is uploaded only on the default branch with
short retention, and state must be an encrypted backend (SSE-KMS). `sensitive = true` keeps
it out of the **logs**, not out of state.

### One-time AWS trust policy (per role, set up outside this catalog)

> ⚠️ **Security — read this.** The `plan` job runs on **pull requests** with
> `id-token: write` and assumes the role named in that workspace's `tf-ci.env` — a file
> that is editable within a PR. Pin each role's trust-policy `sub` to your default branch
> and/or a GitHub **Environment**, and **do not** trust the `pull_request` subject — or a
> pull request could assume the role against live state / production.

Apply role (pinned to `main` + Environments — recommended):

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": [
        "repo:<owner>/<repo>:ref:refs/heads/main",
        "repo:<owner>/<repo>:environment:prod"
      ]
    }
  }
}
```

> ⚠️ **Bind to specific environments — do NOT use `environment:*`.** The apply job's
> Environment is the workspace dir's first path segment, and GitHub auto-creates any
> referenced Environment **without protection**. With a wildcard, someone could add a dir
> `envs/unguarded/` (→ unprotected Environment `unguarded`) whose `tf-ci.env` names the prod
> role and prod state, and apply it with no reviewer. Binding each role's trust to its own
> `environment:<name>` means a stray environment can't assume the prod role.

**Environment gating is your control plane:** pre-create every apply Environment
(`dev`, `prod`, …) in repo settings and add **required reviewers** to the protected ones.
An Environment that doesn't exist is created on first use with no protection.

For **PR plan previews** against real state, point `tf-ci.env`'s `AWS_ROLE_ARN` at a
**separate least-privilege read/plan role** whose trust policy allows
`repo:<owner>/<repo>:pull_request`, and keep the apply-capable role pinned as above.
Note: `terraform plan` executes provider/data-source code from the PR, so the plan role
must be read-only and PRs from outside contributors should require approval to run.

### State bucket hardening (BYO)

The S3 state bucket is yours to provision. Enable: **Block Public Access**, **versioning**,
default **SSE-KMS** (set `AWS_STATE_KMS_KEY` so state uses a customer-managed key, not
SSE-S3), and a **TLS-only** bucket policy. Plan artifacts (uploaded only on the default
branch, 5-day retention) can contain state-derived secrets in cleartext — keep the repo
private and restrict who can download Actions artifacts.

## Versioning & pinning

SemVer git tags; `metadata.json` `version` is the source of truth. Released automatically
on merge to `main`. Pin at the precision you want:

- `@v1` — latest major (floating, recommended); `@tf-env/v1` also tracks the workflow major
- `@v2.0.0` — exact release
- `@<sha>` — pin to a specific commit

## License

[MIT](LICENSE) — use it however you like.
