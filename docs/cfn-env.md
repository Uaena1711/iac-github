# `cfn-env.yml` — per-environment CloudFormation pipeline

Reusable workflow for a standardized **change-set plan → gated apply** flow for **one
environment**, with per-stack keyless OIDC and GitHub-Environment approval gating. Call it once
per env.

```
checkout ────┐  (uploads the source as an artifact)
secret_scan ─┤
lint ────────┼─▶ resolve ─▶ plan ─▶ apply ─▶ check     (one stack per call)
             ┘   (download-artifact + run in an aws image)
```

- secret-scan (gitleaks) + lint (cfn-lint, static — no credentials) gate before any cloud access.
- **The change set is the plan.** `plan` creates and describes a CloudFormation change set (it
  executes nothing); `apply` executes the exact saved change set. You deploy only what a reviewer
  approved — never a blind immediate `aws cloudformation deploy`.
- `apply` runs **only when the change set has changes**, so an unchanged env never fires its gate.
- **Gating = the env's GitHub Environment**: `dev` (no reviewers) applies automatically;
  `prod` (required reviewers) waits for approval. A waiting `prod` never blocks `dev`, because
  each env is a separate `cfn-env.yml` call (its own job graph).
- Identity (role/region) + stack config are read per-stack from `cfn-ci.env` — no static keys.

## Quick start

`.github/workflows/cloudformation.yml` in your consumer repo — **one job per env**:

```yaml
name: cloudformation
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
    uses: Uaena1711/iac-github/.github/workflows/cfn-env.yml@v2
    secrets: inherit   # only needed for the `github` secret provider
    with: { dir: stacks/dev,  environment: dev,  mode: ${{ inputs.mode || 'deploy' }} }
  prod:
    uses: Uaena1711/iac-github/.github/workflows/cfn-env.yml@v2
    secrets: inherit
    with: { dir: stacks/prod, environment: prod, mode: ${{ inputs.mode || 'deploy' }} }
```

- **PR** → change-set preview per env (no execution). **Push to `main`** → each env creates its
  change set; `dev` executes automatically; `prod` executes only after its Environment reviewer
  approves (and only if prod actually changed).
- **Destroy** → run manually with `mode: destroy`: a destroy-plan preview → Environment gate →
  `delete-stack` (no blind deletion).

Pre-create the GitHub **Environments** (`dev`, `prod`, …) and add **required reviewers** to the
ones you want gated. To deploy just one env, keep only that env's job.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `dir` | *(required)* | The stack directory, e.g. `stacks/dev`. |
| `environment` | *(required)* | GitHub Environment used for the apply gate. |
| `mode` | `deploy` | `deploy` or `destroy` (destroy-plan preview behind the gate). |
| `secrets_provider` | `""` | Override each stack's file-level `SECRETS_PROVIDER` (`github` \| `awssm` \| `none`). |
| `container_image` | `""` | Shared fallback image (used when a per-job image is empty). See [Running in a container](#running-in-a-container). |
| `secret_scan_image` | `zricethezav/gitleaks:v8.30.1` | secret-scan job's image. |
| `lint_image` | `python:3.12-slim` | lint job's image (cfn-lint auto-installs via pip). |
| `checkout_image` | `""` (host) | the checkout job's image. Host has git; point at a git image (e.g. `alpine/git`) for a pure-Docker self-hosted runner. |
| `resolve_image` / `plan_image` / `apply_image` | `amazon/aws-cli:2.35.13` | the deploy jobs' image (pinned aws CLI). They fetch source via `download-artifact`, so the image needs no git/tar. Set `""` to run on the host instead. |
| `default_region` | `""` | Fallback AWS region when a stack's `cfn-ci.env` omits `AWS_REGION`. |
| `runs_on` | `ubuntu-latest` | Runner label. |
| `lint_path` | `.` | Directory scanned for templates to cfn-lint. |
| `template_bucket` | `""` | Optional S3 bucket → `aws cloudformation package` runs first (nested templates / inline Lambda / templates over the inline size limit). |

## Where each job runs (and self-hosted runners)

- **The deploy jobs (`resolve`/`plan`/`apply`) run in the pinned `amazon/aws-cli` container by
  default.** They get the source from a **single `checkout` job** via `actions/download-artifact`
  (a Node action — no `git`/`tar` needed), which is exactly why the minimal official aws-cli image
  works even though `actions/checkout` would fail inside it.
- **This is the self-hosted story:** a self-hosted runner only needs **Docker** — the AWS CLI comes
  from the pinned image, not from tools you install and maintain on the host. Set `checkout_image`
  to a git image (e.g. `alpine/git`) if your self-hosted host has no git; otherwise the checkout job
  uses the host (GitHub-hosted and most self-hosted runners have git).
- **`checkout` uploads the source** (minus hidden dirs like `.git`/`.github`) as a per-env artifact
  (`cfn-src-<environment>`, unique so `dev` + `prod` in one run don't collide). `secret_scan` and
  `lint` keep their own checkout (gitleaks needs git history; cfn-lint runs in a `python` image).
- **Prefer the host?** Set `resolve_image`/`plan_image`/`apply_image` to `""` — on a GitHub-hosted
  runner the AWS CLI + jq + git are preinstalled, so the deploy jobs run with zero install.
- Tools **install only if missing** (`curl`/`wget`, or `pip` for cfn-lint); `cfn-run` auto-installs
  a pinned `jq`. Consumers of a reusable workflow can't set `container:` on the calling job — these
  image **inputs** are the override surface.

## Per-stack contract: `cfn-ci.env`

Each CloudFormation stack is a directory containing a `cfn-ci.env` (also the marker that defines
the stack) carrying its identity and deploy config:

```sh
AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/<role>   # role this stack's jobs assume (keyless OIDC)
AWS_REGION=us-east-1
STACK_NAME=my-app-dev                                 # CloudFormation stack name
TEMPLATE=template.yaml                                 # template file (relative to this dir)
PARAMETERS=parameters.json                             # native CFN parameter file (committed, non-secret)
CAPABILITIES=CAPABILITY_NAMED_IAM                      # optional; space-separated list
TAGS=Key=env,Value=dev                                 # optional; space-separated Key=..,Value=.. list
```

`TEMPLATE` and `PARAMETERS` must be **repo-relative, `..`-free paths** inside the stack dir
(validated). To package nested stacks / inline Lambda, set the `template_bucket` **workflow
input** (it is deliberately NOT read from `cfn-ci.env`, so a PR can't redirect uploads).

`cfn-env` reads role/region to federate that stack's jobs to its own role. The file is **parsed,
never sourced**, and its list fields are validated (they word-split onto the `aws` command line):
`CAPABILITIES` tokens must be `CAPABILITY_IAM` / `CAPABILITY_NAMED_IAM` / `CAPABILITY_AUTO_EXPAND`,
and each `TAGS` token must be a whitespace-free `Key=<k>,Value=<v>` (a tag value with a space
belongs in the template). `PARAMETERS` is a standard CloudFormation parameter file:

```json
[
  { "ParameterKey": "Environment", "ParameterValue": "dev" }
]
```

### Resolving values from a secret vault (optional)

Any `cfn-ci.env` value can be a `${REF}` placeholder pulled from a secret store instead of being
committed. Pick the provider **at the file level** with `SECRETS_PROVIDER=` (or override per-run
with the `secrets_provider` input); plain values are left alone.

```sh
SECRETS_PROVIDER=github                        # github | awssm | none (default)
AWS_ROLE_ARN=${DEV_DEPLOY_ROLE_ARN}            # ← resolved from the vault
AWS_REGION=us-east-1
STACK_NAME=my-app-dev
TEMPLATE=template.yaml
```

| `SECRETS_PROVIDER` | `${REF}` means | Source | Notes |
|--------------------|----------------|--------|-------|
| `github` | a variable/secret **name** | `vars`/`secrets` (needs `secrets: inherit` on the caller) | resolves any field, incl. `AWS_ROLE_ARN` |
| `awssm` | a Secrets Manager `secret-id[#json-field]` | AWS Secrets Manager | runs **after** OIDC → keep `AWS_ROLE_ARN`/`AWS_REGION` literal (or use `github` for them) |

Add your own by dropping one `actions/resolve-env/providers/<name>.sh` — see that dir's
`README.md`.

### Passing CloudFormation parameters (normal & sensitive)

Non-sensitive parameters are just committed in `parameters.json` (the native CFN format above).
For **sensitive / `NoEcho`** parameters, don't put them on disk: add an optional `cfn-params.env`
to the stack and the pipeline injects each entry into the parameter set at deploy time (masked,
merged in memory, never written to a file).

```sh
# stacks/dev/cfn-params.env — picks a provider like cfn-ci.env; ${REF} is pulled from the vault.
SECRETS_PROVIDER=github
DbPassword=${DB_PASSWORD_DEV}         # -> parameter DbPassword (from a GitHub secret)
```

Declare the parameter `NoEcho: true` so CloudFormation redacts it from events, the console, and
`describe-stacks`:

```yaml
Parameters:
  DbPassword:
    Type: String
    NoEcho: true
```

Caveat: parameter **values** are passed to the AWS CLI in-memory (argv) and are `::add-mask::`ed
in logs — they are never committed to the repo and never included in the change-set artifact.
(Vault-resolved values do transit `$GITHUB_ENV`, an ephemeral per-job runner file that is masked
and purged at job end.) A value containing a literal comma or space is best kept in the committed
`parameters.json`; the `cfn-params.env` path is for opaque secrets (tokens, passwords).

### Nested stacks & inline Lambda (`template_bucket`)

Set `template_bucket` (input) or `TEMPLATE_BUCKET` (in `cfn-ci.env`) to have the pipeline run
`aws cloudformation package` first — it uploads nested templates and inline function code to S3
and rewrites the URLs before creating the change set. The OIDC role needs write access to that
bucket. A single flat template under the CloudFormation inline size limit needs none of this.

## One-time AWS trust policy (per role, set up outside this catalog)

> ⚠️ **Security — read this.** The `plan` job runs on **pull requests** with `id-token: write`
> and assumes the role named in that stack's `cfn-ci.env` — a file editable within a PR. Pin each
> role's trust-policy `sub` to your default branch and/or a GitHub **Environment**, and **do not**
> trust the `pull_request` subject — or a PR could assume the role against production.

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
> is the stack dir's first path segment, and GitHub auto-creates any referenced Environment
> **without protection**. Binding each role's trust to its own `environment:<name>` means a stray
> environment can't assume the prod role and apply with no reviewer.

**Environment gating is your control plane:** pre-create every apply Environment (`dev`, `prod`,
…) and add **required reviewers** to the protected ones. An Environment that doesn't exist is
created on first use with no protection.

For **PR change-set previews** against real state, point `cfn-ci.env`'s `AWS_ROLE_ARN` at a
separate least-privilege role whose trust allows `repo:<owner>/<repo>:pull_request` and whose
policy can create/describe change sets but not execute them, and keep the apply-capable role
pinned as above.

## Behavior & safety notes

- **Apply/destroy run only on the default branch**, and only when the change set has changes,
  behind the Environment gate. A PR (or feature branch) can preview a plan but can never execute
  or delete a stack. `mode: destroy` is a deliberate `workflow_dispatch` (write-access) run — give
  every destroy-capable Environment **required reviewers**.
- **Rollback-stuck stacks are not auto-deleted.** A stack in `ROLLBACK_COMPLETE` /
  `ROLLBACK_FAILED` / `CREATE_FAILED` / `DELETE_FAILED` fails the plan with a clear message —
  CloudFormation can't update it in place. Tear it down deliberately (`mode: destroy`, reviewed) or
  delete it manually, then deploy again. (This avoids an un-gated delete during a plan and a
  delete-before-recreate window that could leave a stack gone.)
- **`CAPABILITY_AUTO_EXPAND` executes macros at change-set (plan) time**, including on PR previews,
  since capabilities come from the PR-editable `cfn-ci.env`. Only enable it for stacks whose
  macros/transforms you trust, and keep the PR-preview role least-privilege.
- **Supply chain:** third-party actions and container images are pinned by tag (matching the rest
  of the catalog); `jq` is version+sha256 pinned. For stricter integrity you can digest-pin
  (`@sha256:…`) the images and SHA-pin the actions. `cfn-lint` installs via pinned-version `pip`
  in the lint job, which runs with **no AWS credentials** (`contents: read` only).
