# iac-github :: 'ecr' registry provider (LIVE).
#
# Logs Docker in to Amazon ECR. The provider owns its OWN auth so the reusable workflow stays
# generic: if no ambient AWS creds and AWS_ROLE_ARN is set, it exchanges the GitHub OIDC token for
# temporary role credentials (sts:AssumeRoleWithWebIdentity) entirely in shell, then does the ECR
# login. If AWS creds are already present (e.g. a prior aws-oidc step), it skips straight to login.
#
# The calling job MUST grant `permissions: id-token: write` (so GitHub sets the OIDC request vars).
#
# Env: REGISTRY      <acct>.dkr.ecr.<region>.amazonaws.com  (required)
#      AWS_REGION    region for assume-role + get-login-password (required unless creds are ambient)
#      AWS_ROLE_ARN  role to assume via OIDC (optional if creds already present)
#      ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN  (injected by GitHub when the
#        job has id-token: write; inherited from the job env)
# Needs: aws, docker, jq, curl (present on GitHub-hosted runners).

provider_check() {
  for _t in aws docker jq curl; do
    command -v "$_t" >/dev/null 2>&1 || { echo "[ecr] $_t not found on runner" >&2; return 1; }
  done
  [ -n "${REGISTRY:-}" ] || { echo "[ecr] REGISTRY (<acct>.dkr.ecr.<region>.amazonaws.com) required" >&2; return 1; }
}

# Exchange the GitHub OIDC token for temporary AWS credentials (keyless). Exports AWS_*.
_ecr_assume_role() {
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] || {
    echo "[ecr] no OIDC token — grant 'permissions: id-token: write' on the job" >&2; return 1; }
  [ -n "${AWS_REGION:-}" ]  || { echo "[ecr] AWS_REGION required to assume the role" >&2; return 1; }
  [ -n "${AWS_ROLE_ARN:-}" ] || { echo "[ecr] AWS_ROLE_ARN required to assume a role" >&2; return 1; }

  _jwt="$(curl -sS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -r '.value')"
  [ -n "$_jwt" ] && [ "$_jwt" != "null" ] || { echo "[ecr] failed to fetch GitHub OIDC token" >&2; return 1; }

  _creds="$(aws sts assume-role-with-web-identity \
    --role-arn "$AWS_ROLE_ARN" \
    --role-session-name iac-github-ecr \
    --web-identity-token "$_jwt" \
    --region "$AWS_REGION" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)" || { echo "[ecr] assume-role-with-web-identity failed" >&2; return 1; }

  AWS_ACCESS_KEY_ID="$(printf '%s' "$_creds"  | cut -f1)"
  AWS_SECRET_ACCESS_KEY="$(printf '%s' "$_creds" | cut -f2)"
  AWS_SESSION_TOKEN="$(printf '%s' "$_creds" | cut -f3)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "[ecr] assumed ${AWS_ROLE_ARN} (session iac-github-ecr)" >&2
}

provider_login() {
  # Ambient creds win (e.g. a prior aws-oidc step); otherwise assume the role via OIDC.
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_SESSION_TOKEN:-}" ]; then
    _ecr_assume_role || return 1
  fi
  # shellcheck disable=SC2086
  aws ecr get-login-password ${AWS_REGION:+--region "$AWS_REGION"} \
    | docker login "$REGISTRY" -u AWS --password-stdin
}
