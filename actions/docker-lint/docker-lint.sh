#!/usr/bin/env sh
# iac-github :: lint Dockerfile(s) with hadolint (pinned + checksum-verified).
#
# Reuses a hadolint already on PATH (baked into the job image); otherwise installs the pin.
# P is a file or a directory (searched recursively for Dockerfiles). A repo .hadolint.yaml is
# auto-loaded by hadolint from the working directory.
#
# Env (set by action.yml): P (path), THRESHOLD (error|warning|info|style), V (version), SHA.
# POSIX sh -- no bashisms.
set -eu

log() { printf '[docker-lint] %s\n' "$*" >&2; }
die() { printf '[docker-lint][error] %s\n' "$*" >&2; exit 1; }

: "${P:=.}"
: "${THRESHOLD:=error}"

dl() { if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$1" "$2"; else wget -qO "$1" "$2"; fi; }

# Resolve hadolint: reuse from image, else install the pinned binary.
if command -v hadolint >/dev/null 2>&1; then
  HADOLINT=hadolint
  log "using hadolint from PATH ($(hadolint --version 2>/dev/null || echo '?'))"
else
  _bin="${RUNNER_TEMP:-/tmp}/iac-github-bin"; mkdir -p "$_bin"
  log "hadolint not found — installing pinned v${V}"
  dl "$_bin/hadolint" "https://github.com/hadolint/hadolint/releases/download/v${V}/hadolint-linux-x86_64"
  echo "${SHA}  $_bin/hadolint" | sha256sum -c -
  chmod +x "$_bin/hadolint"
  HADOLINT="$_bin/hadolint"
fi

# Collect the Dockerfile list: a single file as-is, else search the directory.
_list="${RUNNER_TEMP:-/tmp}/iac-github-dockerfiles.txt"
if [ -f "$P" ]; then
  printf '%s\n' "$P" > "$_list"
elif [ -d "$P" ]; then
  find "$P" -type f \( -name 'Dockerfile' -o -name 'Dockerfile.*' -o -name '*.Dockerfile' \) \
    | sort > "$_list"
else
  die "path not found: $P"
fi

[ -s "$_list" ] || die "no Dockerfile found under: $P"

log "linting (failure-threshold=${THRESHOLD}):"
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  log "  -> $_f"
  "$HADOLINT" --failure-threshold "$THRESHOLD" "$_f"
done < "$_list"
log "ok"
