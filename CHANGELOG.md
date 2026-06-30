# CHANGELOG

This file lists changes to the iac-github Actions catalog. Versioning follows SemVer;
`metadata.json` `version` is the source of truth and drives the auto-release on `main`.

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
