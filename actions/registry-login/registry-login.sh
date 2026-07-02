#!/usr/bin/env sh
# iac-github :: log Docker in to a container registry via a pluggable provider.
#
# The provider (PROVIDER, default ghcr) selects providers/<provider>.sh, which is SOURCED and
# must define provider_login (optionally provider_check). Adding a registry = drop a new
# providers/<name>.sh; this dispatcher and every workflow stay untouched.
#
# Env (set by action.yml):
#   PROVIDER            provider name -> providers/<PROVIDER>.sh (required)
#   REGISTRY            registry host (e.g. ghcr.io)
#   REGISTRY_USERNAME   registry username (provider may default it)
#   REGISTRY_PASSWORD   registry password/token (passed to `docker login --password-stdin`)
#   AWS_REGION          region for the ecr provider
#
# Provider contract (providers/<name>.sh):
#   provider_login   (required) perform the `docker login`; return non-zero on failure.
#   provider_check   (optional) preflight deps/config; return non-zero to abort before login.
#
# POSIX sh -- no bashisms.
set -eu

log() { printf '[registry-login] %s\n'         "$*" >&2; }
die() { printf '[registry-login][error] %s\n'  "$*" >&2; exit 1; }

: "${PROVIDER:?PROVIDER not set}"

# Restrict to a safe filename so PROVIDER can't traverse or escape the providers dir.
case "$PROVIDER" in
  ''|*[!a-z0-9_-]*) die "invalid provider name: '$PROVIDER' (allowed: a-z 0-9 _ -)" ;;
esac

_script="$GITHUB_ACTION_PATH/providers/${PROVIDER}.sh"
[ -f "$_script" ] || die "unknown provider '$PROVIDER' (no providers/${PROVIDER}.sh)"

# shellcheck source=/dev/null
. "$_script"

command -v provider_login >/dev/null 2>&1 || die "provider '$PROVIDER' defines no provider_login"

if command -v provider_check >/dev/null 2>&1; then
  provider_check || die "provider '$PROVIDER' preflight failed"
fi

provider_login || die "docker login failed via provider '$PROVIDER'"
log "logged in to '${REGISTRY:-<default>}' via provider '$PROVIDER'"
