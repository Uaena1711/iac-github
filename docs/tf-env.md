# `tf-env.yml` — per-environment Terraform pipeline

Reusable workflow for a standardized **detect → plan → apply** flow for **one environment**,
with per-stack keyless OIDC and GitHub-Environment approval gating. Call it once per env.

```
secret_scan ─┐
lint ────────┼─▶ resolve ─▶ plan ─▶ apply ─▶ check     (one env per call)
             ┘
```

- secret-scan (gitleaks) + lint (`terraform fmt` + tflint) gate before any cloud access.
- `apply` runs **only when the plan has changes**, so an unchanged env never fires its gate.
- **Gating = the env's GitHub Environment**: `dev` (no reviewers) applies automatically;
  `prod` (required reviewers) waits for approval. A waiting `prod` never blocks `dev`, because
  each env is a separate `tf-env.yml` call (its own job graph).
- Identity (role/region/state) is read per-stack from `tf-ci.env` — no static cloud keys.

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
    uses: Uaena1711/iac-github/.github/workflows/tf-env.yml@v2
    secrets: inherit   # only needed for the `github` secret provider
    with: { dir: envs/dev,  environment: dev,  mode: ${{ inputs.mode || 'deploy' }} }
  prod:
    uses: Uaena1711/iac-github/.github/workflows/tf-env.yml@v2
    secrets: inherit
    with: { dir: envs/prod, environment: prod, mode: ${{ inputs.mode || 'deploy' }} }
```

- **PR** → plan preview per env. **Push to `main`** → each env plans; `dev` applies
  automatically; `prod` applies only after its Environment reviewer approves (and only if prod
  actually changed).
- **Destroy** → run manually with `mode: destroy`: a reviewed destroy-plan → Environment gate →
  teardown (no blind `terraform destroy -auto-approve`).

Pre-create the GitHub **Environments** (`dev`, `prod`, …) and add **required reviewers** to the
ones you want gated. To deploy just one env, keep only that env's job.

👉 **Full working consumer:** [Uaena1711/iac-github-terraform-example](https://github.com/Uaena1711/iac-github-terraform-example).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `dir` | *(required)* | The env workspace, e.g. `envs/dev`. |
| `environment` | *(required)* | GitHub Environment used for the apply gate. |
| `mode` | `deploy` | `deploy` or `destroy` (reviewed destroy-plan behind the gate). |
| `secrets_provider` | `""` | Override each env's file-level `SECRETS_PROVIDER` (`github` \| `awssm` \| `none`). |
| `container_image` | `""` | Run the jobs inside this image (empty = the runner host). See [Running in a container](#running-in-a-container). |
| `tf_version` | `1.15.7` | Terraform version (used only when installing on the host / an image without terraform). |
| `default_region` | `""` | Fallback AWS region when a stack's `tf-ci.env` omits `AWS_REGION`. |
| `runs_on` | `ubuntu-latest` | Runner label. |
| `lint_path` | `.` | Directory linted (fmt + tflint). |
| `var_file` | `""` | Optional `-var-file` (relative to the workspace). |
| `tf_init_options` / `tf_plan_options` / `tf_apply_options` / `tf_destroy_options` | `""` | Extra flags appended to the respective Terraform command. |

## Running in a container

By default jobs run on the runner host (`ubuntu-latest`) and each tool is installed at its
pinned version. Set `container_image` to run every job inside your own image instead:

```yaml
jobs:
  dev:
    uses: Uaena1711/iac-github/.github/workflows/tf-env.yml@v2
    with:
      dir: envs/dev
      environment: dev
      container_image: ghcr.io/you/tf-toolbox:1.15.7   # your pinned toolchain
```

- The image **must be glibc-based** (Debian/Ubuntu). Alpine/musl images break GitHub's
  in-container Node, so `actions/checkout` and friends fail.
- Tools are **installed only if missing**: if the image already has `terraform`, `tflint`,
  `gitleaks`, or `terraform-docs`, they're reused (no reinstall); anything absent is
  installed at the pin. `resolve-env` also needs `jq` (and `aws` for the `awssm` provider) —
  include them in your image.
- Consumers of a reusable workflow can't set `container:` on the calling job; the
  `container_image` **input** is the override.

## Per-stack contract: `tf-ci.env`

Each Terraform stack is a directory containing the marker `provider.tf` and a `tf-ci.env`
carrying its identity:

```sh
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>   # role this stack's jobs assume (keyless OIDC)
AWS_REGION=us-east-1
AWS_STATE_BUCKET=<s3-bucket>                          # Terraform S3 backend (native lockfile)
AWS_STATE_KMS_KEY=<kms-key-arn>                       # SSE-KMS for state
```

`tf-env` reads role/region to federate that env's jobs to its own role. The file is **parsed,
never sourced**.

### Resolving values from a secret vault (optional)

Any `tf-ci.env` value can be a `${REF}` placeholder pulled from a secret store instead of being
committed. Pick the provider **at the file level** with `SECRETS_PROVIDER=` (or override per-run
with the `secrets_provider` input); plain values are left alone.

```sh
SECRETS_PROVIDER=github                       # github | awssm | none (default)
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>
AWS_REGION=us-east-1
AWS_STATE_BUCKET=${TF_STATE_BUCKET_DEV}        # ← resolved from the vault
```

The `resolve-env` action fetches each placeholder, **masks** it, and rewrites the file in place
(job-local — resolved secrets are never uploaded as artifacts). Shipped providers:

| `SECRETS_PROVIDER` | `${REF}` means | Source | Notes |
|--------------------|----------------|--------|-------|
| `github` | a variable/secret **name** | `vars`/`secrets` (needs `secrets: inherit` on the caller) | resolves any field, incl. `AWS_ROLE_ARN` |
| `awssm` | a Secrets Manager `secret-id[#json-field]` | AWS Secrets Manager | runs **after** OIDC → keep `AWS_ROLE_ARN`/`AWS_REGION` literal (or use `github` for them) |

Add your own by dropping one `actions/resolve-env/providers/<name>.sh` — see that dir's
`README.md`. Legacy literal `tf-ci.env` files (no `SECRETS_PROVIDER`) keep working unchanged.

### Passing Terraform input variables (normal & sensitive)

Non-sensitive variables are just committed HCL — a literal in `main.tf`, a `*.auto.tfvars`, or
the `var_file` input. For **sensitive** variables, don't put them on disk: add an optional
`tf-vars.env` to the stack and the pipeline injects each entry as `TF_VAR_<name>` (masked, never
written to a file), which Terraform reads natively.

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

Complex types work too: a JSON value (`{"k":"v"}`, `[1,2]`) is parsed by Terraform when the
variable is declared as an `object`/`map`/`list` (multiline/pretty JSON is fine).

Caveat (inherent to Terraform): a sensitive value still ends up **inside the saved plan and the
state**. That's why the plan artifact is uploaded only on the default branch with short
retention, and state must be an encrypted backend (SSE-KMS). `sensitive = true` keeps it out of
the **logs**, not out of state.

## One-time AWS trust policy (per role, set up outside this catalog)

> ⚠️ **Security — read this.** The `plan` job runs on **pull requests** with `id-token: write`
> and assumes the role named in that workspace's `tf-ci.env` — a file editable within a PR. Pin
> each role's trust-policy `sub` to your default branch and/or a GitHub **Environment**, and
> **do not** trust the `pull_request` subject — or a PR could assume the role against production.

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

> ⚠️ **Bind to specific environments — do NOT use `environment:*`.** The apply job's Environment
> is the workspace dir's first path segment, and GitHub auto-creates any referenced Environment
> **without protection**. Binding each role's trust to its own `environment:<name>` means a stray
> environment (e.g. `envs/unguarded/`) can't assume the prod role and apply with no reviewer.

**Environment gating is your control plane:** pre-create every apply Environment (`dev`, `prod`,
…) and add **required reviewers** to the protected ones. An Environment that doesn't exist is
created on first use with no protection.

For **PR plan previews** against real state, point `tf-ci.env`'s `AWS_ROLE_ARN` at a separate
least-privilege read/plan role whose trust allows `repo:<owner>/<repo>:pull_request`, and keep
the apply-capable role pinned as above. `terraform plan` executes provider/data-source code from
the PR, so the plan role must be read-only and outside-contributor PRs should require approval.

## State bucket hardening (BYO)

The S3 state bucket is yours to provision. Enable: **Block Public Access**, **versioning**,
default **SSE-KMS** (set `AWS_STATE_KMS_KEY` for a customer-managed key, not SSE-S3), and a
**TLS-only** bucket policy. Plan artifacts (uploaded only on the default branch, 5-day retention)
can contain state-derived secrets in cleartext — keep the repo private and restrict who can
download Actions artifacts.
