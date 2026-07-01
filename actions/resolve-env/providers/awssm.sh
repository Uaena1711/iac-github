# iac-github :: 'awssm' secret provider (AWS Secrets Manager).
#
#   ref  = <secret-id>[#<json-field>]   (secret-id may be a name or a full ARN)
#   form = KEY=${iac-github/demo/state-bucket}
#          KEY=${iac-github/demo/creds#password}   # extract one field from a JSON secret
#
# Uses the AMBIENT OIDC credentials, so it can only run in a job that has already assumed
# the role (i.e. AFTER aws-oidc). It therefore CANNOT supply the OIDC identity fields
# themselves -- keep AWS_ROLE_ARN / AWS_REGION literal (or use the github provider for
# them), and let awssm resolve the remaining backend secrets in plan/apply.
#
# Requires: aws CLI + jq (both present on GitHub-hosted runners) and assumed-role creds.
# Region: PROVIDER_REGION if set, else the ambient AWS_REGION from aws-oidc.

provider_check() {
  command -v aws >/dev/null 2>&1 || { echo "[awssm] aws CLI not found on runner" >&2; return 1; }
  command -v jq  >/dev/null 2>&1 || { echo "[awssm] jq not found on runner" >&2; return 1; }
  [ -n "${PROVIDER_REGION:-}" ] && { AWS_REGION="$PROVIDER_REGION"; export AWS_REGION; }
  return 0
}

# echo the SecretString for <secret-id> (or its .<field>), or fail.
provider_resolve() {
  _ref="$1"; _id="${_ref%%#*}"; _field=""
  case "$_ref" in *'#'*) _field="${_ref#*#}" ;; esac
  [ -n "$_id" ] || { echo "[awssm] empty secret-id" >&2; return 1; }

  if ! _json="$(aws secretsmanager get-secret-value --secret-id "$_id" \
                  --query SecretString --output text 2>/dev/null)"; then
    echo "[awssm] get-secret-value failed for '${_id}' (permissions / region / not found?)" >&2
    return 1
  fi

  if [ -n "$_field" ]; then
    if ! _v="$(printf '%s' "$_json" | jq -er --arg f "$_field" '.[$f] // empty' 2>/dev/null)"; then
      echo "[awssm] secret '${_id}' is not JSON or field '${_field}' missing" >&2; return 1
    fi
    [ -n "$_v" ] || { echo "[awssm] field '${_field}' empty in secret '${_id}'" >&2; return 1; }
    printf '%s' "$_v"
  else
    printf '%s' "$_json"
  fi
}
