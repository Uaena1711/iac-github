# iac-github :: 'github' secret provider.
#
#   ref  = the NAME of a GitHub Actions variable or secret (e.g. TF_STATE_BUCKET_DEV).
#   form = KEY=${TF_STATE_BUCKET_DEV}
#
# A composite action can't read `vars`/`secrets` by name at runtime, so the reusable
# workflow forwards them as JSON (`${{ toJSON(vars) }}` / `${{ toJSON(secrets) }}`) into
# GH_VARS_JSON / GH_SECRETS_JSON. Secrets take precedence over variables. Needs no cloud
# credentials, so it can run in the pre-OIDC resolve job (including for AWS_ROLE_ARN).
#
# Requires: jq (present on GitHub-hosted runners).

provider_check() {
  command -v jq >/dev/null 2>&1 || { echo "[github] jq not found on runner" >&2; return 1; }
  [ -n "${GH_SECRETS_JSON:-}" ] || [ -n "${GH_VARS_JSON:-}" ] || {
    echo "[github] neither GH_SECRETS_JSON nor GH_VARS_JSON is set (forward toJSON(secrets)/toJSON(vars))" >&2
    return 1
  }
}

# echo the value of the variable/secret named $1, or fail.
provider_resolve() {
  _name="$1"
  case "$_name" in
    ''|*[!A-Za-z0-9_]*) echo "[github] invalid variable/secret name: '${_name}'" >&2; return 1 ;;
  esac
  for _src in "${GH_SECRETS_JSON:-}" "${GH_VARS_JSON:-}"; do   # secrets first, then vars
    [ -n "$_src" ] || continue
    _v="$(printf '%s' "$_src" | jq -er --arg k "$_name" '.[$k] // empty' 2>/dev/null)" || continue
    if [ -n "$_v" ]; then printf '%s' "$_v"; return 0; fi
  done
  echo "[github] no variable or secret named '${_name}'" >&2
  return 1
}
