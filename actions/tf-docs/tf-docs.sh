#!/usr/bin/env sh
# iac-github :: inject terraform-docs markdown into each Terraform dir's README.
#
# Mirrors the reference catalog's documentation job: `terraform-docs markdown table` in
# inject mode, per module dir. Discovers every directory under WORKING_DIR that contains a
# *.tf file (skipping .terraform) and writes/updates that dir's README between the
# <!-- BEGIN_TF_DOCS --> / <!-- END_TF_DOCS --> markers (created if absent). Static parse —
# no `terraform init`. The workflow handles git add/commit/push.
#
# Env (set by action.yml): WORKING_DIR (default "."), README_NAME (default README.md).
# POSIX sh — no bashisms.
set -eu

ROOT="${WORKING_DIR:-.}"; ROOT="${ROOT%/}"
README="${README_NAME:-README.md}"
cd "${GITHUB_WORKSPACE:-.}"

# Every dir holding a .tf file = a module to document (skip .terraform caches).
dirs="$(find "$ROOT" -type f -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null \
        | sed 's#/[^/]*$##' | sort -u)"
[ -n "$dirs" ] || { echo "[tf-docs] no Terraform dirs under ${ROOT}"; exit 0; }

OLDIFS="$IFS"; IFS='
'
for d in $dirs; do
  [ -n "$d" ] || continue
  [ -f "$d/$README" ] || : > "$d/$README"   # inject needs the target file to exist
  echo "[tf-docs] ${d}/${README}"
  terraform-docs markdown table --output-file "$README" --output-mode inject "$d"
done
IFS="$OLDIFS"
