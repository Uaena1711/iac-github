#!/usr/bin/env sh
# iac-github :: resolve ${ref} placeholders in a workspace tf-ci.env from a secret provider.
#
# The provider is chosen AT THE FILE LEVEL (a `SECRETS_PROVIDER=` line in tf-ci.env),
# optionally overridden by the PROVIDER input. ONE provider per env -- no per-value scheme.
# A value shaped exactly `${REF}` is resolved via providers/<provider>.sh -> provider_resolve
# REF; every other value passes through literally. Resolved values are masked
# (`::add-mask::`) and written back IN PLACE (job-local checkout -- never persisted as an
# artifact, so secrets don't travel between jobs).
#
# tf-ci.env stays PARSED, never sourced; `${...}` is inert literal text here.
#
# Adding a provider = drop one providers/<name>.sh defining provider_resolve() (and an
# optional provider_check()). Nothing else changes.
#
# Env (set by action.yml):
#   RESOLVE_DIR      workspace dir containing the env file (required)
#   ENV_FILE         env file name (default tf-ci.env)
#   PROVIDER_INPUT   overrides the file's SECRETS_PROVIDER when non-empty
#   ONLY_KEYS        comma/space list; when set, resolve ONLY these keys
# Provider config is read by providers/*.sh: GH_VARS_JSON, GH_SECRETS_JSON, PROVIDER_REGION.
#
# POSIX sh -- no bashisms.
set -eu

log() { printf '[resolve-env] %s\n'         "$*" >&2; }
die() { printf '[resolve-env][error] %s\n'  "$*" >&2; exit 1; }

DIR="${RESOLVE_DIR:?set RESOLVE_DIR}"
FILE="${ENV_FILE:-tf-ci.env}"
unset CDPATH
SELF="$(cd -- "$(dirname -- "$0")" && pwd)"
target="${GITHUB_WORKSPACE:-.}/${DIR%/}/${FILE}"

[ -f "$target" ] || { log "no ${FILE} in ${DIR}; nothing to resolve"; exit 0; }

# provider precedence: PROVIDER input > file's SECRETS_PROVIDER > none.
file_provider="$(grep -E '^SECRETS_PROVIDER=' "$target" 2>/dev/null | head -1 | cut -d= -f2- || true)"
provider="${PROVIDER_INPUT:-}"; [ -n "$provider" ] || provider="$file_provider"
provider="${provider:-none}"

case "$provider" in
  none|"") log "provider=none for ${DIR}/${FILE}; leaving values literal"; exit 0 ;;
  *[!a-z0-9_-]*) die "invalid provider name: ${provider}" ;;   # it becomes a file path
esac

plugin="${SELF}/providers/${provider}.sh"
if [ ! -f "$plugin" ]; then
  # shellcheck disable=SC2012  # provider filenames are controlled (no odd chars)
  avail="$(ls "${SELF}/providers" 2>/dev/null | sed 's/\.sh$//' | grep -v '^README$' | tr '\n' ' ')"
  die "unknown provider '${provider}' (no providers/${provider}.sh). available: ${avail}"
fi

# shellcheck disable=SC1090
. "$plugin"
command -v provider_resolve >/dev/null 2>&1 || die "provider '${provider}' does not define provider_resolve()"
if command -v provider_check >/dev/null 2>&1; then
  provider_check || die "provider '${provider}' preflight failed"
fi

# optional key allowlist (pre-OIDC resolve job passes AWS_ROLE_ARN,AWS_REGION).
ONLY="$(printf '%s' "${ONLY_KEYS:-}" | tr ',' ' ')"
in_scope() {
  [ -z "$ONLY" ] && return 0
  for _k in $ONLY; do [ "$_k" = "$1" ] && return 0; done
  return 1
}

log "resolving placeholders in ${DIR}/${FILE} via '${provider}'${ONLY:+ (keys: ${ONLY})}"

nl='
'
tmp="${target}.resolved.$$"
: > "$tmp"
count=0

# Rewrite only lines shaped KEY=${REF}; copy comments, literals and SECRETS_PROVIDER verbatim.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
    *=*) : ;;
    *)   printf '%s\n' "$line" >> "$tmp"; continue ;;
  esac
  key="${line%%=*}"
  val="${line#*=}"
  # shellcheck disable=SC2016  # literal ${ ... } placeholder text, not shell expansion
  case "$val" in
    '${'*'}')
      if ! in_scope "$key"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
      # shellcheck disable=SC2016  # strip the literal ${ and } delimiters
      ref="${val#'${'}"; ref="${ref%'}'}"
      [ -n "$ref" ] || die "empty placeholder for ${key}"
      if ! secret="$(provider_resolve "$ref")"; then
        die "failed to resolve ${key} (ref '${ref}') via ${provider}"
      fi
      case "$secret" in *"$nl"*) die "resolved value for ${key} contains a newline (unsupported in an env file)";; esac
      printf '::add-mask::%s\n' "$secret"          # keep the value out of the build log
      printf '%s=%s\n' "$key" "$secret" >> "$tmp"
      count=$((count + 1))
      ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$target"

mv "$tmp" "$target"
log "resolved ${count} placeholder(s)"
