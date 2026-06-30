# CHANGELOG

This file lists changes to the iac-github Actions catalog. Versioning follows SemVer;
`metadata.json` `version` is the source of truth and drives the auto-release on `main`.

## 1.0.0

- Initial release: Terraform run flow (detect → plan → apply).
- Composite actions: `detect-changes`, `aws-oidc`, `tf-plan`, `tf-apply`.
- Reusable workflow `terraform.yml` (detect → plan → apply → check) with per-stack OIDC
  and GitHub Environments gating.
- Self-CI (actionlint + version validation + secret scan) and metadata-driven auto-release.
