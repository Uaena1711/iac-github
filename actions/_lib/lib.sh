#!/usr/bin/env sh
# iac-github :: shared Terraform helpers (sourced by run.sh). POSIX sh, no bashisms.
# AWS-only for now (Azure/auto deferred). Functions whose stdout is captured log to stderr.

log_error()   { printf '[error] %s\n' "$1" >&2; }
log_info()    { printf '[info] %s\n'  "$1"; }
log_warning() { printf '[warn] %s\n'  "$1"; }

# Load a workspace's tf-ci.env by PARSING an allowlist of KEY=VALUE lines — never by
# dot-sourcing it. tf-ci.env is repo content (PR-editable); sourcing it would execute
# arbitrary shell in a job that holds assumed-role credentials. We export only the keys
# the backend/run logic needs; anything else in the file is ignored.
load_workspace_env() {
  f="${1:-tf-ci.env}"
  [ -f "$f" ] || return 0
  for key in AWS_ROLE_ARN AWS_REGION AWS_STATE_BUCKET AWS_STATE_REGION \
             AWS_STATE_KMS_KEY AWS_STATE_ENCRYPTION_KEY AWS_STATE_LOCK_TABLE \
             TF_STATE_KEY TF_STATE_PREFIX TF_STATE_ENABLED; do
    val="$(grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$val" ] && export "${key}=${val}"
  done
}

# Remote-state object key for THIS workspace (S3). Partitions state per repo + workspace
# so one bucket holds many workspaces. Override TF_STATE_KEY (in tf-ci.env) to pin.
resolve_tf_state_key() {
  _slug="$(printf '%s' "${GITHUB_REPOSITORY:-tfstate}" | tr '/' '-')"
  TF_STATE_PREFIX="${TF_STATE_PREFIX:-${_slug}/${TF_WORKSPACE_DIR:-root}}"
  TF_STATE_KEY="${TF_STATE_KEY:-${TF_STATE_PREFIX}/terraform.tfstate}"
  export TF_STATE_PREFIX TF_STATE_KEY
}

# Terraform S3 backend init via CI-injected -backend-config. The workspace ships an empty
# `backend "s3" {}`; values come from its tf-ci.env (sourced by run.sh) or the env:
#   AWS_STATE_BUCKET  (required) S3 bucket holding state
#   AWS_STATE_REGION  (default AWS_REGION) bucket region
#   TF_STATE_KEY      (auto) object key per workspace
#   AWS_STATE_KMS_KEY (optional) KMS key id/arn -> SSE-KMS
# Locking: native S3 lockfile (use_lockfile=true, Terraform >= 1.10) — no DynamoDB.
# Set TF_STATE_ENABLED=false to use the backend exactly as declared in the .tf.
tf_backend_init() {
  if [ "${TF_STATE_ENABLED:-true}" = "false" ]; then
    log_warning "TF_STATE_ENABLED=false -> backend as declared in .tf"
    # shellcheck disable=SC2086
    terraform init -input=false ${TF_INIT_OPTIONS:-}; return
  fi
  : "${AWS_STATE_BUCKET:?set AWS_STATE_BUCKET (e.g. in the workspace tf-ci.env)}"
  resolve_tf_state_key
  set -- -backend-config="bucket=${AWS_STATE_BUCKET}" \
         -backend-config="key=${TF_STATE_KEY}" \
         -backend-config="region=${AWS_STATE_REGION:-${AWS_REGION:?set AWS_STATE_REGION or AWS_REGION}}" \
         -backend-config="encrypt=true" \
         -backend-config="use_lockfile=true"
  if [ -n "${AWS_STATE_KMS_KEY:-}" ]; then
    log_info "state encryption: SSE-KMS"
    set -- "$@" -backend-config="kms_key_id=${AWS_STATE_KMS_KEY}"
  else
    log_warning "default SSE-S3 — set AWS_STATE_KMS_KEY for a customer-managed key"
  fi
  log_info "S3 backend initialised (state key: ${TF_STATE_KEY})"
  # shellcheck disable=SC2086
  terraform init -input=false ${TF_INIT_OPTIONS:-} "$@"
}
