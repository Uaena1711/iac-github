# iac-github :: 'ghcr' registry provider.
#
# Logs Docker in to GitHub Container Registry with GITHUB_TOKEN (or a PAT). No cloud creds needed.
# The password is fed on stdin (never argv). Username defaults to the GitHub actor.
#
# Env: REGISTRY (default ghcr.io), REGISTRY_USERNAME (default $GITHUB_ACTOR), REGISTRY_PASSWORD.

provider_check() {
  command -v docker >/dev/null 2>&1 || { echo "[ghcr] docker not found on runner" >&2; return 1; }
  [ -n "${REGISTRY_PASSWORD:-}" ] || { echo "[ghcr] REGISTRY_PASSWORD is empty (pass GITHUB_TOKEN)" >&2; return 1; }
}

provider_login() {
  _registry="${REGISTRY:-ghcr.io}"
  _user="${REGISTRY_USERNAME:-${GITHUB_ACTOR:-}}"
  [ -n "$_user" ] || { echo "[ghcr] no username (set username or run in Actions with GITHUB_ACTOR)" >&2; return 1; }
  printf '%s' "$REGISTRY_PASSWORD" | docker login "$_registry" -u "$_user" --password-stdin
}
