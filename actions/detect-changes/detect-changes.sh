#!/usr/bin/env sh
# iac-github :: detect which Terraform workspaces changed -> emit a job matrix.
#
# A "workspace" is any directory containing the marker file (default provider.tf)
# under WORKSPACES_ROOT. Maps every changed file to its nearest ancestor workspace,
# then for each workspace reads its tf-ci.env (PARSED, not sourced) to build a matrix
# entry {dir, role_arn, region, environment}. Emits JSON to $GITHUB_OUTPUT (matrix=)
# plus has_changes=true|false.
#
# Selects ALL workspaces when: FORCE_ALL=true, no usable base SHA (first run), or a
# change touches a shared path (SHARED_PATHS). Empty result => downstream job skips.
#
# Env (set by the composite action):
#   WORKSPACES_ROOT   dir to scan (default "envs")
#   WORKSPACE_MARKER  marker file defining a workspace (default provider.tf)
#   FORCE_ALL         "true" => all workspaces regardless of diff
#   SHARED_PATHS      space/comma list; a change under any selects ALL
#   DEFAULT_REGION    fallback region when tf-ci.env omits AWS_REGION
#   BASE_SHA / HEAD_SHA  git diff endpoints (from github.* context)
#
# POSIX sh — no bashisms.
set -eu

log() { printf '%s\n' "$*" >&2; }

ROOT="${WORKSPACES_ROOT:-envs}"; ROOT="${ROOT%/}"
MARKER="${WORKSPACE_MARKER:-provider.tf}"
DEFAULT_REGION="${DEFAULT_REGION:-}"
FORCE_ALL="${FORCE_ALL:-false}"
SHARED="$(printf '%s' "${SHARED_PATHS:-}" | tr -d '[]"' | tr ',' ' ')"
cd "${GITHUB_WORKSPACE:-.}"

list_all() { find "$ROOT" -type f -name "$MARKER" 2>/dev/null | sed "s#/${MARKER}\$##" | sed 's#^\./##' | sort -u; }

# Nearest ancestor dir (within the repo) holding the marker = the workspace.
workspace_of() {
  d="$(dirname "$1")"
  while :; do
    [ -f "$d/$MARKER" ] && { printf '%s\n' "${d#./}"; return 0; }
    case "$d" in ""|"."|"/") return 1 ;; esac
    d="$(dirname "$d")"
  done
}

select_all=0
[ "$FORCE_ALL" = "true" ] && { log "[info] FORCE_ALL=true -> selecting all workspaces"; select_all=1; }

base="${BASE_SHA:-}"; head="${HEAD_SHA:-HEAD}"
case "$base" in
  ""|0000000*) [ "$select_all" -eq 0 ] && { log "[info] no usable base SHA (first run) -> all workspaces"; select_all=1; } ;;
esac

changed=""
if [ "$select_all" -eq 0 ]; then
  log "[info] diffing ${base}..${head}"
  changed="$(git diff --name-only "$base" "$head" 2>/dev/null || true)"
  if [ -n "$SHARED" ] && [ -n "$changed" ]; then
    for sp in $SHARED; do
      if printf '%s\n' "$changed" | grep -q "^${sp%/}/"; then
        log "[info] shared path '${sp}' changed -> selecting all workspaces"; select_all=1; break
      fi
    done
  fi
fi

if [ "$select_all" -eq 1 ]; then
  dirs="$(list_all)"
elif [ -n "$changed" ]; then
  dirs="$(printf '%s\n' "$changed" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in "$ROOT"/*) workspace_of "$f" || true ;; esac
  done | sort -u)"
else
  dirs=""
fi

# Injection guard: reject workspace dir names with chars outside a safe set, since the
# name flows into JSON and later into a job matrix.
safe=""
for d in $dirs; do
  case "$d" in
    "") : ;;
    *[!A-Za-z0-9_/.-]*) log "[warn] skipping unsafe workspace dir name: $d" ;;
    *) safe="${safe}${d}
" ;;
  esac
done
dirs="$(printf '%s' "$safe" | sed '/^$/d')"

# value of KEY from a workspace's tf-ci.env (parsed, NOT sourced).
read_env() {
  f="$1/tf-ci.env"
  [ -f "$f" ] || return 0
  grep -E "^${2}=" "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'
}

json="["; first=1
for d in $dirs; do
  role="$(read_env "$d" AWS_ROLE_ARN)"
  region="$(read_env "$d" AWS_REGION)"; region="${region:-$DEFAULT_REGION}"
  rel="${d#"$ROOT"/}"; env="${rel%%/*}"; [ -n "$env" ] || env="default"
  esc_d="$(printf '%s' "$d" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  obj="{\"dir\":\"${esc_d}\",\"role_arn\":\"${role}\",\"region\":\"${region}\",\"environment\":\"${env}\"}"
  if [ "$first" -eq 1 ]; then json="${json}${obj}"; first=0; else json="${json},${obj}"; fi
done
json="${json}]"

has_changes=true
[ "$first" -eq 1 ] && has_changes=false

log "[info] has_changes=${has_changes} matrix=${json}"
{
  printf 'matrix=%s\n' "$json"
  printf 'has_changes=%s\n' "$has_changes"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
