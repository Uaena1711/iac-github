#!/usr/bin/env sh
# iac-github :: Terraform plan/apply core (one workspace per job). POSIX sh.
#
# Usage: run.sh plan|apply
#   plan  - init + validate + `plan -out=plan.tfplan`. If there are no changes the plan
#           file is removed so the downstream apply skips cleanly (-detailed-exitcode).
#   apply - `apply plan.tfplan` if a non-empty plan file exists (from the plan job via
#           artifacts), else no-op.
#
# Keyless auth is already done by the aws-oidc step (configure-aws-credentials exported
# SDK creds into the job env). tf_backend_init() injects the S3 backend via -backend-config.
#
# Env:
#   TF_WORKSPACE_DIR  workspace dir relative to repo root [required]
#   GITHUB_WORKSPACE  repo root (provided by the runner)
#   TF_PLAN_FILE      plan artifact name (default plan.tfplan)
#   + backend vars from the workspace tf-ci.env (sourced below)
set -eu

DIR="$(dirname -- "$0")"
# shellcheck source=/dev/null
. "$DIR/lib.sh"

ACTION="${1:?usage: run.sh plan|apply}"
: "${TF_WORKSPACE_DIR:?missing TF_WORKSPACE_DIR}"
PLAN_FILE="${TF_PLAN_FILE:-plan.tfplan}"
STATUS_FILE="${TF_PLAN_STATUS_FILE:-plan.status}"

cd "${GITHUB_WORKSPACE:-.}/${TF_WORKSPACE_DIR}"

# Per-workspace identity / backend config. PARSED (allowlist), never dot-sourced —
# tf-ci.env is PR-editable repo content and the plan job already holds assumed-role creds,
# so executing it would be an RCE/credential-exfil primitive. See load_workspace_env().
load_workspace_env tf-ci.env

terraform --version

case "$ACTION" in
  plan)
    tf_backend_init
    terraform validate
    set +e
    # shellcheck disable=SC2086
    terraform plan -input=false -detailed-exitcode -out="$PLAN_FILE" ${TF_PLAN_OPTIONS:-}
    code=$?
    set -e
    # -detailed-exitcode: 0 = no changes, 2 = changes present, 1 = error.
    # Write an explicit status marker so the apply job can distinguish "plan had no
    # changes" from "the expected plan artifact is missing/expired" (the latter must NOT
    # silently no-op). The marker is always uploaded alongside the (optional) plan file.
    case "$code" in
      0) log_info "no changes for ${TF_WORKSPACE_DIR}; removing plan so apply skips"
         rm -f "$PLAN_FILE"; printf 'nochanges\n' > "$STATUS_FILE" ;;
      2) log_info "changes detected for ${TF_WORKSPACE_DIR}; plan saved -> ${PLAN_FILE}"
         printf 'changed\n' > "$STATUS_FILE" ;;
      *) log_error "terraform plan failed for ${TF_WORKSPACE_DIR} (exit ${code})"; exit "$code" ;;
    esac
    ;;
  apply)
    tf_backend_init
    if [ -f "$PLAN_FILE" ] && [ -s "$PLAN_FILE" ]; then
      log_info "applying saved plan for ${TF_WORKSPACE_DIR}"
      # shellcheck disable=SC2086
      terraform apply -input=false ${TF_APPLY_OPTIONS:-} "$PLAN_FILE"
    elif [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE")" = "nochanges" ]; then
      log_warning "no changes for ${TF_WORKSPACE_DIR}; skipping apply"
    else
      log_error "expected plan for ${TF_WORKSPACE_DIR} is missing (artifact expired or download failed) — refusing to silently skip"
      exit 1
    fi
    ;;
  *)
    log_error "unknown action: ${ACTION} (expected plan|apply)"; exit 1 ;;
esac
