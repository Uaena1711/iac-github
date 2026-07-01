#!/usr/bin/env sh
# iac-github :: discover CloudFormation templates under a path and lint them with cfn-lint.
#
# cfn-lint is a Python tool (no single static binary), so unlike the Go-binary tools in this
# catalog it is pinned by version and installed via pip if missing (the reusable workflow
# defaults this job to a python image). If the image already ships cfn-lint, the probe reuses it.
#
# Env (set by the composite action):
#   LINT_PATH   directory to scan for templates (default ".")
#   TEMPLATES   optional explicit space-separated template list (skips discovery)
#
# POSIX sh — no bashisms.
set -eu

log() { printf '[info] %s\n' "$*"; }

P="${LINT_PATH:-.}"

if [ -n "${TEMPLATES:-}" ]; then
  # shellcheck disable=SC2086
  set -- ${TEMPLATES}
else
  # Discover CloudFormation templates: *.yaml/*.yml/*.json/*.template that actually look like a
  # template (carry AWSTemplateFormatVersion or a Resources key), so unrelated YAML/JSON is
  # skipped. The regex matches both YAML (`Resources:`) and JSON (`"Resources":`) key forms; the
  # `< file` redirect keeps the while-loop in this shell so `set --` persists (no word-split).
  set --
  _list="$(mktemp)"
  find "$P" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.template' \) 2>/dev/null | sort > "$_list"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if grep -qE '(AWSTemplateFormatVersion|Resources)"?[[:space:]]*:' "$f" 2>/dev/null; then
      set -- "$@" "$f"
    fi
  done < "$_list"
  rm -f "$_list"
fi

if [ "$#" -eq 0 ]; then
  log "no CloudFormation templates found under '${P}' — nothing to lint"
  exit 0
fi

log "linting $# template(s): $*"
cfn-lint "$@"
