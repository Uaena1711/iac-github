# iac-github

Reusable **GitHub Actions** for keyless **Terraform and CloudFormation** CI/CD. A consumer repo
calls one reusable workflow (or composes the building-block actions) and gets a standardized
**detect → plan → apply** flow with per-stack OIDC federation and environment-based approval
gating. For CloudFormation the **change set is the plan** — `apply` executes the exact change
set a reviewer approved.

> Generic and vendor-neutral by design — no organization, product, or account values are baked
> into this catalog. Identity lives per-stack in your repo's `tf-ci.env` / `cfn-ci.env` files.

## Layered design

| Layer | Artifact | Purpose |
|-------|----------|---------|
| Building blocks (Tier 1) | `actions/*` (composite) | Reusable steps you can compose yourself |
| Reusable pipelines (Tier 2) | `.github/workflows/*.yml` (reusable workflows) | End-to-end flows you call from a consumer repo |

Each reusable pipeline is documented on its own page — the root stays an index. You typically
call `tf-env.yml` once per environment; each call is its own job graph, so a `prod` awaiting
approval never blocks `dev`.

## Reusable pipelines

| Pipeline | What it does | Docs |
|----------|--------------|------|
| `tf-env.yml` | Per-environment Terraform **detect → plan → apply** (+ manual destroy). Keyless per-stack OIDC, GitHub-Environment approval gating, secret-vault resolution, sensitive `TF_VAR_*` injection. | **[docs/tf-env.md](docs/tf-env.md)** |
| `cfn-env.yml` | Per-environment CloudFormation **change-set plan → gated apply** (+ manual destroy). Same keyless OIDC + Environment gating; the change set is the plan; sensitive `NoEcho` params via `cfn-params.env`. | **[docs/cfn-env.md](docs/cfn-env.md)** |
| `tf-docs.yml` | Regenerate terraform-docs on merge and commit the READMEs back (with a `[skip ci]` loop guard). | **[docs/tf-docs.md](docs/tf-docs.md)** |

👉 **Full working consumer:** [Uaena1711/iac-github-terraform-example](https://github.com/Uaena1711/iac-github-terraform-example)
— copy its layout (`envs/<env>/{provider.tf,main.tf,tf-ci.env}`, a shared `modules/`, the callers).

## Building blocks (Tier 1)

Composite actions you can compose into your own workflow. Each has its own `action.yml`
(inputs/outputs documented inline).

| Action | Purpose |
|--------|---------|
| [`checkout-artifact`](actions/checkout-artifact) | Share the checked-out source across jobs via an artifact (upload/download) — lets deploy jobs run in a minimal image |
| [`secret-scan`](actions/secret-scan) | gitleaks secret scan (pinned + checksum) — gate before cloud access |
| [`tf-lint`](actions/tf-lint) | `terraform fmt -check` + tflint (pinned) |
| [`detect-changes`](actions/detect-changes) | Map changed files to Terraform/CloudFormation stacks → job matrix (configurable `marker`/`env_file`) |
| [`aws-oidc`](actions/aws-oidc) | Federate a GitHub OIDC token to an AWS role (keyless) |
| [`resolve-env`](actions/resolve-env) | Resolve `${REF}` placeholders from a secret vault; pluggable providers ([providers/](actions/resolve-env/providers)) |
| [`tf-run`](actions/tf-run) | `terraform plan` \| `apply` \| `destroy-plan` for one workspace |
| [`tf-docs`](actions/tf-docs) | terraform-docs generation (pinned + checksum) |
| [`cfn-lint`](actions/cfn-lint) | Lint CloudFormation templates with cfn-lint (pinned; static, no credentials) |
| [`cfn-run`](actions/cfn-run) | CloudFormation change-set `plan` \| `apply` \| `destroy-plan` \| `destroy` for one stack |

## Tool images

The deploy/lint jobs default to pinned **GHCR** images that bake the heavy tools (terraform,
tflint, terraform-docs, aws-cli, cfn-lint) so nothing heavy installs at runtime and there's no
Docker Hub rate-limit exposure. Built in a dedicated repo,
[`Uaena1711/iac-github-images`](https://github.com/Uaena1711/iac-github-images). See
**[docs/images.md](docs/images.md)** — override any `*_image` input (or set `""` for the host).

## Versioning & pinning

SemVer git tags; `metadata.json` `version` is the source of truth. Released automatically on
merge to `main` (tag + GitHub release + floating tags moved). Pin at the precision you want:

- `@v2` — latest major (floating, recommended); `@tf-env/v2` also tracks that component's major
- `@v2.0.0` — exact release
- `@<sha>` — pin to a specific commit

Majors don't move across each other: `@v1` stays on the 1.x line, `@v2` on 2.x — upgrading is
an explicit ref change.

## License

[MIT](LICENSE) — use it however you like.
