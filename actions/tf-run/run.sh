#!/usr/bin/env sh
# iac-github :: Terraform plan/apply core (one workspace per job). Self-contained POSIX sh
# (no sibling sourcing — composite actions only get their OWN directory on the runner).
#
# Usage: run.sh plan|apply
#   plan  - init + validate + `plan -out`. No changes -> remove plan, write status=nochanges.
#   apply - apply the saved plan if present; skip cleanly on nochanges; ERROR if the plan
#           was expected but missing (e.g. artifact expired) — never a silent no-op.
#
# Keyless auth is already done by the aws-oidc step. Backend/identity come from the
# workspace tf-ci.env, which is PARSED (allowlist), never sourced.
set -eu

log_error()   { printf '[error] %s\n' "$1" >&2; }
log_info()    { printf '[info] %s\n'  "$1"; }
log_warning() { printf '[warn] %s\n'  "$1"; }

# Parse an allowlist of KEY=VALUE lines from tf-ci.env (never dot-source it: it is
# PR-editable repo content and this job holds assumed-role credentials).
load_workspace_env() {
  f="${1:-tf-ci.env}"
  [ -f "$f" ] || return 0
  for key in AWS_ROLE_ARN AWS_REGION AWS_STATE_BUCKET AWS_STATE_REGION \
             AWS_STATE_KMS_KEY AWS_STATE_ENCRYPTION_KEY AWS_STATE_LOCK_TABLE \
             TF_STATE_KEY TF_STATE_PREFIX TF_STATE_ENABLED; do
    val="$(grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$val" ] && export "${key}=${val}"
  done
  return 0   # never let the loop's final test (a false `[ -n ]`) trip `set -e` in the caller
}

resolve_tf_state_key() {
  _slug="$(printf '%s' "${GITHUB_REPOSITORY:-tfstate}" | tr '/' '-')"
  TF_STATE_PREFIX="${TF_STATE_PREFIX:-${_slug}/${TF_WORKSPACE_DIR:-root}}"
  TF_STATE_KEY="${TF_STATE_KEY:-${TF_STATE_PREFIX}/terraform.tfstate}"
  export TF_STATE_PREFIX TF_STATE_KEY
}

# S3 backend via CI-injected -backend-config; native lockfile, no DynamoDB.
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

ACTION="${1:?usage: run.sh plan|apply}"
: "${TF_WORKSPACE_DIR:?missing TF_WORKSPACE_DIR}"
PLAN_FILE="${TF_PLAN_FILE:-plan.tfplan}"
STATUS_FILE="${TF_PLAN_STATUS_FILE:-plan.status}"

cd "${GITHUB_WORKSPACE:-.}/${TF_WORKSPACE_DIR}"
load_workspace_env tf-ci.env
terraform --version

case "$ACTION" in
  plan)
    tf_backend_init
    terraform validate
    set +e
    # shellcheck disable=SC2086
    terraform plan -input=false -detailed-exitcode -out="$PLAN_FILE" ${TF_VAR_FILE:+-var-file="$TF_VAR_FILE"} ${TF_PLAN_OPTIONS:-}
    code=$?
    set -e
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
  destroy-plan)
    # Produce a DESTROY plan — this does NOT destroy anything. The teardown is executed
    # later by `apply` applying THIS exact saved plan, after an Environment approval. So you
    # destroy only what the reviewed plan captured (no blind `terraform destroy -auto-approve`).
    tf_backend_init
    set +e
    # shellcheck disable=SC2086
    terraform plan -input=false -destroy -detailed-exitcode -out="$PLAN_FILE" ${TF_VAR_FILE:+-var-file="$TF_VAR_FILE"} ${TF_DESTROY_OPTIONS:-}
    code=$?
    set -e
    case "$code" in
      0) log_info "nothing to destroy in ${TF_WORKSPACE_DIR}"; rm -f "$PLAN_FILE"; printf 'nochanges\n' > "$STATUS_FILE" ;;
      2) log_info "destroy plan saved for ${TF_WORKSPACE_DIR} -> ${PLAN_FILE} (apply it to tear down)"; printf 'changed\n' > "$STATUS_FILE" ;;
      *) log_error "terraform destroy-plan failed for ${TF_WORKSPACE_DIR} (exit ${code})"; exit "$code" ;;
    esac
    ;;
  *)
    log_error "unknown action: ${ACTION} (expected plan|apply|destroy-plan)"; exit 1 ;;
esac
