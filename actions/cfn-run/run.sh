#!/usr/bin/env sh
# iac-github :: CloudFormation change-set core (one stack per job). Self-contained POSIX sh
# (no sibling sourcing — composite actions only get their OWN directory on the runner).
#
# The change-set IS the plan: `plan` creates+describes a change set (no execution); `apply`
# executes the exact change set the plan saved. So you deploy only what a reviewer approved,
# never a blind immediate `aws cloudformation deploy`.
#
# Usage: run.sh plan|apply|destroy-plan|destroy
#   plan         - create a change set (CREATE for a new stack, UPDATE for an existing one) and
#                  describe it. Empty change set -> delete it, status=nochanges (apply skips).
#   apply        - execute the saved change set; ERROR if it was expected but missing (artifact
#                  expired) — never a silent no-op.
#   destroy-plan - preview: status=changed if the stack exists (so a gated delete can run), else
#                  nochanges. Deletes nothing.
#   destroy      - delete-stack + wait. Executed only after the destroy-plan gate (env approval).
#
# Keyless auth is already done by the aws-oidc step. Identity/config come from the stack's
# cfn-ci.env, which is PARSED (allowlist), never sourced.
#
# Env (set by the composite action):
#   COMMAND            plan | apply | destroy-plan | destroy
#   CFN_WORKSPACE_DIR  stack directory (relative to repo root)
#   TEMPLATE_BUCKET    optional S3 bucket -> `aws cloudformation package` before deploy
#   CFN_PARAM_*        optional sensitive parameters (from resolve-env cfn-params.env), merged
#                      into the parameter set in memory — never written to disk.
#
# POSIX sh — no bashisms.
set -eu

log_error()   { printf '[error] %s\n' "$1" >&2; }
log_info()    { printf '[info] %s\n'  "$1"; }
log_warning() { printf '[warn] %s\n'  "$1"; }
die()         { log_error "$1"; exit 1; }

JQ_VERSION="1.7.1"   # needed to parse describe-change-set JSON + merge sensitive params
JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"

# Ensure jq is on PATH (a minimal container image may not have it). Pinned + checksum-verified.
ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log_info "jq not found — installing pinned jq ${JQ_VERSION}"
  _b="${RUNNER_TEMP:-/tmp}/iac-github-bin"; mkdir -p "$_b"
  _u="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$_b/jq" "$_u"; else wget -qO "$_b/jq" "$_u"; fi
  printf '%s  %s\n' "$JQ_SHA256" "$_b/jq" | sha256sum -c - >&2 || die "jq checksum mismatch"
  chmod +x "$_b/jq"; PATH="$_b:$PATH"; export PATH
  command -v jq >/dev/null 2>&1 || die "jq install failed"
}

# Parse an allowlist of KEY=VALUE lines from cfn-ci.env (never dot-source it: it is
# PR-editable repo content and this job holds assumed-role credentials).
load_workspace_env() {
  f="${1:-cfn-ci.env}"
  [ -f "$f" ] || return 0
  for key in AWS_ROLE_ARN AWS_REGION STACK_NAME TEMPLATE PARAMETERS \
             CAPABILITIES TAGS; do
    val="$(grep -E "^${key}=" "$f" 2>/dev/null | head -1 | cut -d= -f2-)"
    [ -n "$val" ] && export "${key}=${val}"
  done
  return 0   # never let the loop's final test (a false `[ -n ]`) trip `set -e` in the caller
}

# TEMPLATE / PARAMETERS come from the PR-editable cfn-ci.env and become a `file://` read, so a
# crafted `../../etc/x` or absolute path could read an arbitrary runner file into the CFN API
# (and leak it via a parse-error StatusReason). Require a repo-relative, traversal-free path.
require_safe_path() {
  case "$1" in
    /*)                die "${2} '${1}' must be a path relative to the stack dir (no leading /)" ;;
    ..|../*|*/..|*/../*) die "${2} '${1}' must not traverse with '..'" ;;
    *[!A-Za-z0-9_/.-]*) die "${2} '${1}' has unsafe characters" ;;
  esac
}

# Build the full parameter set as ONE inline JSON array (accepted by --parameters): the
# committed PARAMETERS file (non-secret) merged with any CFN_PARAM_* sensitive values. jq does
# all escaping; the sensitive values live only in argv/memory, never on disk.
build_parameters() {
  base='[]'
  if [ -n "${PARAMETERS:-}" ]; then
    require_safe_path "$PARAMETERS" PARAMETERS
    [ -f "$PARAMETERS" ] || die "PARAMETERS file '${PARAMETERS}' not found in $(pwd) — fix the path in cfn-ci.env"
    base="$(cat "$PARAMETERS")"
  fi
  extra='[]'
  # The name is re-derived charset-safe by the sed below (resolve-env does NOT constrain param
  # key charset), and the `case` guard re-checks it, so eval only ever expands a CFN_PARAM_ name
  # of [A-Za-z0-9_] — never attacker shell. The VALUE is fetched by expansion, escaped by jq.
  for var in $(env | sed -n 's/^\(CFN_PARAM_[A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$var" in CFN_PARAM_[A-Za-z0-9_]*) ;; *) continue ;; esac
    eval "val=\${$var}"
    name="${var#CFN_PARAM_}"
    extra="$(printf '%s' "$extra" | jq --arg k "$name" --arg v "$val" '. + [{"ParameterKey":$k,"ParameterValue":$v}]')"
  done
  # Merge base + extra; on a duplicate ParameterKey the sensitive (extra) value wins (kept last).
  printf '%s' "$base" | jq -c --argjson extra "$extra" '. + $extra | group_by(.ParameterKey) | map(.[-1])'
}

# cfn-ci.env is PR-editable repo content, and CAPABILITIES/TAGS are word-split onto the
# `aws` command line (they are lists). Validate every token so a crafted value can't smuggle
# an extra `aws` flag (e.g. --endpoint-url to exfil resolved parameter values during PR plan).
validate_capabilities() {
  for _c in $1; do
    case "$_c" in
      CAPABILITY_IAM|CAPABILITY_NAMED_IAM|CAPABILITY_AUTO_EXPAND) ;;
      *) die "invalid CAPABILITIES token '${_c}' (allowed: CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND)" ;;
    esac
  done
}
validate_tags() {
  for _t in $1; do
    case "$_t" in
      Key=*,Value=*) ;;   # a single argv token, never starts with '-'
      *) die "invalid TAGS token '${_t}' (expected Key=<k>,Value=<v>, whitespace-free)" ;;
    esac
  done
}

# Current stack status ("NONE" only when the stack genuinely doesn't exist). Fail CLOSED on any
# other error (AccessDenied, throttling, transient 5xx) so we never misread an existing stack as
# absent and try to CREATE over it.
stack_status() {
  _out="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
          --query 'Stacks[0].StackStatus' --output text 2>&1)" && { printf '%s\n' "$_out"; return 0; }
  case "$_out" in
    *"does not exist"*) echo NONE ;;
    *) die "describe-stacks failed for ${STACK_NAME}: ${_out}" ;;
  esac
}

ACTION="${COMMAND:?usage: run.sh plan|apply|destroy-plan|destroy}"
: "${CFN_WORKSPACE_DIR:?missing CFN_WORKSPACE_DIR}"
STATUS_FILE="changeset.status"
NAME_FILE="changeset.name"
TYPE_FILE="changeset.type"

cd "${GITHUB_WORKSPACE:-.}/${CFN_WORKSPACE_DIR}"
# TEMPLATE_BUCKET comes ONLY from the base-branch workflow input (set as env by the action),
# never from the PR-editable cfn-ci.env — so a PR can't redirect `package` uploads to another
# bucket. It is therefore NOT in load_workspace_env's allowlist.
load_workspace_env cfn-ci.env
: "${STACK_NAME:?set STACK_NAME in the stack cfn-ci.env}"
: "${AWS_REGION:?set AWS_REGION in the stack cfn-ci.env}"
aws --version

case "$ACTION" in
  plan)
    ensure_jq
    : "${TEMPLATE:?set TEMPLATE in the stack cfn-ci.env}"
    require_safe_path "$TEMPLATE" TEMPLATE
    tmpl="$TEMPLATE"
    # Optional: package nested templates / inline Lambda to S3, then deploy the rewritten root.
    # TEMPLATE_BUCKET is the base-branch workflow input only (never the PR-editable env file).
    if [ -n "${TEMPLATE_BUCKET:-}" ]; then
      log_info "packaging ${tmpl} -> s3://${TEMPLATE_BUCKET}"
      aws cloudformation package --template-file "$tmpl" --s3-bucket "$TEMPLATE_BUCKET" \
        --region "$AWS_REGION" --output-template-file packaged.yaml
      tmpl="packaged.yaml"
    fi

    # Reject any injected `aws` flag hiding in the PR-editable list fields before they word-split.
    [ -n "${CAPABILITIES:-}" ] && validate_capabilities "$CAPABILITIES"
    [ -n "${TAGS:-}" ] && validate_tags "$TAGS"

    # Choose CREATE vs UPDATE. A stack stuck in a rollback state can only be recreated (deleted
    # first). We do NOT auto-delete it here: that delete would be an un-gated MUTATION in the plan
    # job (before any environment approval) and, if the following create failed, could leave the
    # stack gone. Fail closed and make the operator tear it down deliberately (reviewed) first.
    st="$(stack_status)"
    case "$st" in
      NONE|REVIEW_IN_PROGRESS) cstype=CREATE ;;
      ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|DELETE_FAILED)
        die "stack ${STACK_NAME} is in ${st} and cannot be updated in place — CloudFormation requires it be deleted first. Re-run this pipeline with mode=destroy (reviewed) or delete the stack manually, then deploy again." ;;
      *) cstype=UPDATE ;;
    esac

    cs="cs-$(printf %.12s "${GITHUB_SHA:-manual}")"
    log_info "change set ${cs} (${cstype}) for stack ${STACK_NAME}"
    # Drop any leftover same-name change set from a prior run of this SHA.
    aws cloudformation delete-change-set --stack-name "$STACK_NAME" --change-set-name "$cs" \
      --region "$AWS_REGION" >/dev/null 2>&1 || true

    params="$(build_parameters)"

    set -- --stack-name "$STACK_NAME" --change-set-name "$cs" --change-set-type "$cstype" \
           --template-body "file://${tmpl}" --parameters "$params" --region "$AWS_REGION"
    # CAPABILITIES / TAGS are space-separated lists -> intentional word-split (validated above).
    # shellcheck disable=SC2086
    [ -n "${CAPABILITIES:-}" ] && set -- "$@" --capabilities ${CAPABILITIES}
    # shellcheck disable=SC2086
    [ -n "${TAGS:-}" ] && set -- "$@" --tags ${TAGS}
    aws cloudformation create-change-set "$@"

    # An empty change set makes the waiter exit non-zero — don't let that kill the script;
    # describe-change-set below is the source of truth.
    aws cloudformation wait change-set-create-complete \
      --stack-name "$STACK_NAME" --change-set-name "$cs" --region "$AWS_REGION" 2>/dev/null || true

    desc="$(aws cloudformation describe-change-set --stack-name "$STACK_NAME" \
            --change-set-name "$cs" --region "$AWS_REGION")"
    status="$(printf '%s' "$desc" | jq -r '.Status')"
    reason="$(printf '%s' "$desc" | jq -r '.StatusReason // ""')"

    if [ "$status" = "FAILED" ]; then
      case "$reason" in
        *"didn't contain changes"*|*"No updates are to be performed"*|*"No changes to deploy"*)
          log_info "no changes for ${STACK_NAME}; deleting empty change set so apply skips"
          aws cloudformation delete-change-set --stack-name "$STACK_NAME" --change-set-name "$cs" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
          printf 'nochanges\n' > "$STATUS_FILE" ;;
        *)
          die "change set for ${STACK_NAME} failed: ${reason}" ;;
      esac
    else
      log_info "changes detected for ${STACK_NAME}; change set ${cs} saved"
      printf '%s\n' "$cs"     > "$NAME_FILE"
      printf '%s\n' "$cstype" > "$TYPE_FILE"
      printf 'changed\n'      > "$STATUS_FILE"
    fi
    ;;

  apply)
    if [ -f "$NAME_FILE" ] && [ -s "$NAME_FILE" ]; then
      cs="$(cat "$NAME_FILE")"
      cstype="$(cat "$TYPE_FILE" 2>/dev/null || echo UPDATE)"
      log_info "executing change set ${cs} for ${STACK_NAME}"
      aws cloudformation execute-change-set --stack-name "$STACK_NAME" --change-set-name "$cs" \
        --region "$AWS_REGION"
      case "$cstype" in
        CREATE) aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION" ;;
        *)      aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$AWS_REGION" ;;
      esac
      log_info "stack ${STACK_NAME} is $(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" --query 'Stacks[0].StackStatus' --output text)"
    elif [ -f "$STATUS_FILE" ] && [ "$(cat "$STATUS_FILE")" = "nochanges" ]; then
      log_warning "no changes for ${STACK_NAME}; skipping apply"
    else
      die "expected change set for ${STACK_NAME} is missing (artifact expired or download failed) — refusing to silently skip"
    fi
    ;;

  destroy-plan)
    # Preview only — deletes nothing. The teardown runs later via `destroy`, after approval.
    st="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" \
          --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
    if [ "$st" = "NONE" ]; then
      log_info "stack ${STACK_NAME} does not exist; nothing to destroy"
      printf 'nochanges\n' > "$STATUS_FILE"
    else
      log_info "stack ${STACK_NAME} (${st}) will be deleted on apply"
      printf 'changed\n' > "$STATUS_FILE"
    fi
    ;;

  destroy)
    log_info "deleting stack ${STACK_NAME}"
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$AWS_REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"
    log_info "stack ${STACK_NAME} deleted"
    ;;

  *)
    die "unknown command: ${ACTION} (expected plan|apply|destroy-plan|destroy)" ;;
esac
