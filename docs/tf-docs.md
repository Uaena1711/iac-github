# `tf-docs.yml` — terraform-docs on merge

Reusable workflow that keeps every module's README current automatically. On a push, it
regenerates the terraform-docs table (inject mode) for each dir with `*.tf` and commits the
READMEs back to the branch. Mirrors a classic "documentation" pipeline stage.

## Quick start

```yaml
# .github/workflows/docs.yml (consumer)
name: docs
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write        # commit the regenerated READMEs back
jobs:
  terraform-docs:
    uses: Uaena1711/iac-github/.github/workflows/tf-docs.yml@v2
    permissions: { contents: write }
    with:
      working_dir: .
```

Each dir containing `*.tf` gets its README updated between the
`<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` markers (created if absent). Static parse —
no `terraform init`. It's a **no-op when the docs already match** (nothing to commit).

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `working_dir` | `.` | Root scanned for Terraform dirs to document. |
| `commit_message` | `docs: regenerate terraform-docs [skip ci]` | Message for the doc commit — **keep the `[skip ci]` token**. |
| `version` | `0.24.0` | terraform-docs version (used only when the image/host lacks terraform-docs). |
| `container_image` | `""` | Run the job inside this image (glibc/Debian-based; empty = the runner host). If it ships `terraform-docs`, it's reused. |
| `runs_on` | `ubuntu-latest` | Runner label. |

## The `[skip ci]` loop guard

The doc commit must never re-trigger your pipelines (no accidental `terraform apply`, no docs
loop). Two guards apply, both on by default:

1. The commit message carries **`[skip ci]`** — GitHub skips `push`/`pull_request` runs for that
   commit (`[ci skip]`, `[no ci]`, etc. also work).
2. The push is made with **`GITHUB_TOKEN`**, and GitHub does not trigger new workflow runs from
   `GITHUB_TOKEN` pushes.

The commit is authored by `github-actions[bot]`. If you customize `commit_message`, retain the
`[skip ci]` token.
