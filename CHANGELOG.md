# CHANGELOG

This file lists changes to the iac-github Actions catalog. Versioning follows SemVer;
`metadata.json` `version` is the source of truth and drives the auto-release on `main`.

## 2.3.0

- `cfn-run` **prints the change-set resource diff** in the `plan` job (Add/Modify/Remove per
  resource, with `[REPLACEMENT]` and scope) to the log **and renders it as a table on the run's
  Summary page** — so a reviewer sees what apply will change before approving the gate (the
  `terraform plan` / GitLab `view_changes` equivalent).
- `cfn-run` resolves `TEMPLATE` and `PARAMETERS` **from the repo root** (not the stack dir), so all
  environments can **share ONE template** (`templates/app.yaml`) instead of copying it per env;
  per-env differences live in `parameters.json` / `cfn-params.env`. Paths are still validated
  (no `/`, no `..`) so nothing escapes the repo.
- Add [`checkout-artifact`](actions/checkout-artifact) (Tier 1): a shared building block that
  uploads the checked-out source as a per-env artifact (`mode: upload`) and restores it in later
  jobs (`mode: download`). One place for the source-passing policy (artifact naming, hidden-file
  exclusion, retention).
- **`cfn-env.yml` and `tf-env.yml` are now container-portable.** Both gained a standalone `checkout`
  job (via `checkout-artifact`); `resolve`/`plan`/`apply` fetch the source with `download-artifact`
  (a Node action — no git/tar), so the deploy jobs run in a minimal image (e.g. the pinned official
  `amazon/aws-cli`, which lacks git/tar). This makes the pipelines **self-hostable with only Docker**
  on the runner — the CLI comes from the image, not tools you maintain on the host. New
  `checkout_image` input on both; `cfn-env` deploy jobs default to `amazon/aws-cli:2.35.13` (set
  `*_image` to `""` for the host).

## 2.2.1

- `cfn-env.yml`: the deploy jobs (`resolve`/`plan`/`apply`) now default to the **runner host**
  instead of `amazon/aws-cli`. GitHub runners preinstall the AWS CLI + jq + git, and the minimal
  aws-cli image lacks `git`/`tar` so `actions/checkout` failed inside it. Point the `*_image`
  inputs at an AWS-capable image (with git or tar) to containerize.

## 2.2.0

- Add a **CloudFormation pipeline** alongside the Terraform one. `cfn-env.yml` is a
  per-environment reusable workflow with the same 6-job graph as `tf-env.yml`
  (secret_scan → lint → resolve → plan → apply → check), where the **change set is the plan**:
  `plan` creates+describes a change set, `apply` executes the exact saved one after the
  Environment gate. New building blocks: [`cfn-run`](actions/cfn-run) (change-set
  create/execute/delete engine — CREATE-vs-UPDATE, empty-change-set no-op, optional
  `aws cloudformation package`, `destroy` = delete-stack) and [`cfn-lint`](actions/cfn-lint)
  (pinned cfn-lint, static, no credentials). Deploy jobs default to `amazon/aws-cli`, the lint
  job to `python` (cfn-lint auto-installs). Single-stack scope; StackSets not included.
- Identity + stack config live per-stack in `cfn-ci.env` (mirrors `tf-ci.env`); sensitive
  `NoEcho` parameters come from an optional `cfn-params.env` as `Name=${REF}`, resolved +
  masked + merged in memory, never written to disk (mirrors `tf-vars.env`).
- `detect-changes` gains `env_file` input (default `tf-ci.env`) so the one action serves both
  `provider.tf`/`tf-ci.env` and `cfn-ci.env` stacks. Backward-compatible.

## 2.1.0

- Optional **container execution**. `tf-env.yml` takes a shared `container_image` plus
  **per-job overrides** (`secret_scan_image`, `lint_image`, `resolve_image`, `plan_image`,
  `apply_image`), each falling back to `container_image`. Each job runs in its OWN image and
  only needs the tools its steps use, so a terraform job stays a terraform image instead of
  one huge image. `tf-docs.yml` takes `container_image`. Default `""` = run on the runner host.
- Building-block tools **install only if missing**, so an image that already ships `terraform`
  / `tflint` / `gitleaks` / `terraform-docs` is reused instead of reinstalled; the host still
  installs the pins. Actions are now **POSIX sh** and download via **curl or wget**, so minimal
  images (e.g. the official `hashicorp/terraform`, which has no bash/curl) work. Note: GitHub
  mounts its own Node into the job container, so both glibc and Alpine/musl images are fine.
  Backward-compatible. (Verified live: the full flow ran in `hashicorp/terraform:1.15.7`.)

## 2.0.0

- **BREAKING:** replaced the matrix paved-road (`terraform.yml`) with a **per-environment
  reusable workflow** `tf-env.yml`. The consumer calls it once per env and decides gating
  per env (e.g. `dev` auto, `prod` approval). Each call is its own job graph, so a `prod`
  awaiting approval never blocks `dev`. Migrate callers from one `terraform.yml` job to one
  `tf-env.yml` job per env (see the example repo).
- apply runs only when the plan has changes, so an unchanged env never fires its approval
  gate (`tf-run` now exposes a `has_changes` output).
- Add a `resolve-env` building block: an env's `tf-ci.env` picks a secret provider at the
  file level (`SECRETS_PROVIDER=`, overridable by the `secrets_provider` input) and uses
  `${REF}` placeholders that are pulled from a vault, masked, and written back in place
  (job-local, never an artifact). Providers are plugins (`providers/<name>.sh`); `github`
  (vars/secrets) and `awssm` (Secrets Manager) ship in the box. Backward-compatible:
  literal `tf-ci.env` files (no `SECRETS_PROVIDER`) are untouched.
- `resolve-env` also supports `emit: github-env`: it resolves an optional per-stack
  `tf-vars.env` and exports each entry as `TF_VAR_<name>` to `$GITHUB_ENV` (masked,
  multiline-safe), so **sensitive Terraform input variables** are injected as environment
  variables — never written to disk — and Terraform reads them natively. Mark such
  variables `sensitive = true` to redact them from plan output. Wired into `plan`/`apply`;
  a no-op when the stack has no `tf-vars.env`.
- Add a `tf-docs` building block + a `tf-docs.yml` reusable workflow: on a push, regenerate
  each module's README with terraform-docs (pinned + checksum, inject mode) and commit the
  result back to the branch. The doc commit carries a `[skip ci]` token (and is made with
  `GITHUB_TOKEN`), so it never re-triggers a pipeline. No-op when docs are already current.
- Building blocks: `secret-scan`, `tf-lint`, `detect-changes`, `aws-oidc`, `resolve-env`, `tf-run`, `tf-docs`.

## 1.2.0

- Add a `tf-lint` building block (`terraform fmt -check` + tflint, pinned + checksum) and
  wire it into the flow as a gate alongside secret-scan: `secret_scan + lint → plan → apply → check`.
- Fix: nested workspaces (e.g. `envs/<env>/<region>/`) now work in the change-detection
  path — replaced a `case` inside command substitution (parser quirk on older shells) with
  a portable prefix test. Detection maps a changed file to its nearest `provider.tf`
  ancestor at any depth; the GitHub Environment is the first path segment under the root.

## 1.1.0

- Layering: the terraform flow now composes a `secret-scan` (gitleaks) building block as a
  gate before any cloud access — consumers get secret detection automatically.
- Destroy is integrated into the same `terraform.yml` via `mode: destroy` + `dir` (manual
  `workflow_dispatch`), using a reviewed destroy-plan applied behind the Environment gate
  (no blind `destroy -auto-approve`).
- `check` is now terminal (runs after apply) so the required status reflects the whole pipeline.
- Configurable `tf-run` inputs: `var_file`, `tf_{init,plan,apply,destroy}_options`.
- Examples moved out of the catalog into a dedicated consumer repo (linked from the README).

## 1.0.1

- Live end-to-end test on a real runner (OIDC plan/apply, environments, release).

## 1.0.0

- Initial release: Terraform run flow (detect → plan → apply).
- Composite actions: `detect-changes`, `aws-oidc`, `tf-plan`, `tf-apply`.
- Reusable workflow `terraform.yml` (detect → plan → apply → check) with per-stack OIDC
  and GitHub Environments gating.
- Self-CI (actionlint + version validation + secret scan) and metadata-driven auto-release.
