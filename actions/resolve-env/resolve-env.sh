#!/usr/bin/env sh
# iac-github :: resolve ${ref} placeholders from a secret provider. Two output modes:
#
#   emit=file        (default) rewrite the file IN PLACE, KEY=${ref} -> KEY=<secret>.
#                    Used for tf-ci.env (identity/backend); downstream code reads the file.
#   emit=github-env  resolve each KEY line and export ${EXPORT_PREFIX}KEY to $GITHUB_ENV
#                    (masked). Used for tf-vars.env -> TF_VAR_* so Terraform reads sensitive
#                    input variables from the environment, NEVER from a file on disk. Mark
#                    such variables `sensitive = true` so Terraform redacts them from output.
#
# The provider is chosen AT THE FILE LEVEL (`SECRETS_PROVIDER=` line), optionally overridden
# by the PROVIDER input. ONE provider per file -- no per-value scheme. A value shaped exactly
# `${REF}` is resolved via providers/<provider>.sh -> provider_resolve REF; every other value
# is a literal. Resolved (from-vault) values are masked; committed literals are not.
#
# The file stays PARSED, never sourced; `${...}` is inert literal text here.
#
# Env (set by action.yml):
#   RESOLVE_DIR      workspace dir containing the file (required)
#   ENV_FILE         file name (default tf-ci.env)
#   EMIT             file | github-env (default file)
#   EXPORT_PREFIX    prefix for github-env keys (e.g. TF_VAR_)
#   PROVIDER_INPUT   overrides the file's SECRETS_PROVIDER when non-empty
#   ONLY_KEYS        comma/space list; when set (file mode), resolve ONLY these keys
# Provider config (read by providers/*.sh): GH_VARS_JSON, GH_SECRETS_JSON, PROVIDER_REGION.
#
# POSIX sh -- no bashisms.
set -eu

log() { printf '[resolve-env] %s\n'         "$*" >&2; }
die() { printf '[resolve-env][error] %s\n'  "$*" >&2; exit 1; }

DIR="${RESOLVE_DIR:?set RESOLVE_DIR}"
FILE="${ENV_FILE:-tf-ci.env}"
EMIT="${EMIT:-file}"
EXPORT_PREFIX="${EXPORT_PREFIX:-}"
unset CDPATH
SELF="$(cd -- "$(dirname -- "$0")" && pwd)"
target="${GITHUB_WORKSPACE:-.}/${DIR%/}/${FILE}"

case "$EMIT" in file|github-env) ;; *) die "invalid EMIT '${EMIT}' (file|github-env)";; esac
[ -f "$target" ] || { log "no ${FILE} in ${DIR}; nothing to resolve"; exit 0; }

# provider precedence: PROVIDER input > file's SECRETS_PROVIDER > none.
file_provider="$(grep -E '^SECRETS_PROVIDER=' "$target" 2>/dev/null | head -1 | cut -d= -f2- || true)"
provider="${PROVIDER_INPUT:-}"; [ -n "$provider" ] || provider="$file_provider"
provider="${provider:-none}"

# file mode with no provider = leave literal (backward compatible). github-env mode with no
# provider still exports the file's literal KEY lines (but any ${ref} then has no resolver).
if [ "$provider" = "none" ] || [ -z "$provider" ]; then
  if [ "$EMIT" = "file" ]; then log "provider=none for ${DIR}/${FILE}; leaving values literal"; exit 0; fi
  provider="none"
else
  case "$provider" in *[!a-z0-9_-]*) die "invalid provider name: ${provider}";; esac
  plugin="${SELF}/providers/${provider}.sh"
  if [ ! -f "$plugin" ]; then
    # shellcheck disable=SC2012  # provider filenames are controlled (no odd chars)
    avail="$(ls "${SELF}/providers" 2>/dev/null | sed 's/\.sh$//' | grep -v '^README$' | tr '\n' ' ')"
    die "unknown provider '${provider}' (no providers/${provider}.sh). available: ${avail}"
  fi
  # shellcheck disable=SC1090
  . "$plugin"
  command -v provider_resolve >/dev/null 2>&1 || die "provider '${provider}' does not define provider_resolve()"
  if command -v provider_check >/dev/null 2>&1; then provider_check || die "provider '${provider}' preflight failed"; fi
fi

# optional key allowlist (file mode: pre-OIDC resolve job passes AWS_ROLE_ARN,AWS_REGION).
ONLY="$(printf '%s' "${ONLY_KEYS:-}" | tr ',' ' ')"
in_scope() {
  [ -z "$ONLY" ] && return 0
  for _k in $ONLY; do [ "$_k" = "$1" ] && return 0; done
  return 1
}

# echo the resolved value for a ${ref} value.
resolve_ref() {   # $1=key $2=value(${ref})
  [ "$provider" != "none" ] || die "value for ${1} is a \${ref} placeholder but no provider is set"
  # shellcheck disable=SC2016  # strip the literal ${ and } delimiters
  _ref="${2#'${'}"; _ref="${_ref%'}'}"
  [ -n "$_ref" ] || die "empty placeholder for ${1}"
  provider_resolve "$_ref" || die "failed to resolve ${1} (ref '${_ref}') via ${provider}"
}

# register each line of a value with the log masker (::add-mask:: is per-line).
mask() { printf '%s\n' "$1" | while IFS= read -r _m; do [ -n "$_m" ] && printf '::add-mask::%s\n' "$_m"; done; }

# append KEY<<delim / value / delim to $GITHUB_ENV (multiline-safe, injection-safe delimiter).
export_env() {   # $1=name $2=value
  _dst="${GITHUB_ENV:-/dev/stdout}"
  _delim="EOF_$(head -c 16 /dev/urandom | od -An -tx1 2>/dev/null | tr -d ' \n')"
  [ -n "${_delim#EOF_}" ] || _delim="EOF_resolveenv"
  { printf '%s<<%s\n' "$1" "$_delim"; printf '%s\n' "$2"; printf '%s\n' "$_delim"; } >> "$_dst"
}

nl='
'
log "resolving ${DIR}/${FILE} via '${provider}' (emit=${EMIT}${EXPORT_PREFIX:+, prefix=${EXPORT_PREFIX}}${ONLY:+, keys=${ONLY}})"

tmp="${target}.resolved.$$"; [ "$EMIT" = "file" ] && : > "$tmp"
count=0

while IFS= read -r line || [ -n "$line" ]; do
  # comments / blanks / non-KEY=VAL: copy verbatim in file mode, ignore in env mode.
  case "$line" in
    ''|'#'*) [ "$EMIT" = "file" ] && printf '%s\n' "$line" >> "$tmp"; continue ;;
    *=*) : ;;
    *) [ "$EMIT" = "file" ] && printf '%s\n' "$line" >> "$tmp"; continue ;;
  esac
  key="${line%%=*}"; val="${line#*=}"
  # SECRETS_PROVIDER is config, not a value to emit/resolve.
  if [ "$key" = "SECRETS_PROVIDER" ]; then [ "$EMIT" = "file" ] && printf '%s\n' "$line" >> "$tmp"; continue; fi

  # shellcheck disable=SC2016  # literal ${ ... } placeholder text, not shell expansion
  case "$val" in
    '${'*'}')
      if [ "$EMIT" = "file" ] && ! in_scope "$key"; then printf '%s\n' "$line" >> "$tmp"; continue; fi
      secret="$(resolve_ref "$key" "$val")"
      case "$secret" in *"$nl"*) [ "$EMIT" = "file" ] && die "resolved value for ${key} contains a newline (unsupported in an env file)";; esac
      mask "$secret"                               # keep the from-vault value out of the log
      if [ "$EMIT" = "file" ]; then printf '%s=%s\n' "$key" "$secret" >> "$tmp"
      else export_env "${EXPORT_PREFIX}${key}" "$secret"; fi
      count=$((count + 1))
      ;;
    *)  # literal value: copy verbatim (file) or export unmasked (github-env)
      if [ "$EMIT" = "file" ]; then printf '%s\n' "$line" >> "$tmp"
      else export_env "${EXPORT_PREFIX}${key}" "$val"; count=$((count + 1)); fi
      ;;
  esac
done < "$target"

if [ "$EMIT" = "file" ]; then mv "$tmp" "$target"; log "resolved ${count} placeholder(s)"
else log "exported ${count} ${EXPORT_PREFIX}* variable(s)"; fi
