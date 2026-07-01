#!/usr/bin/env sh
# iac-github :: move the floating tags after a release so consumers can pin at any
# precision (multi-precision pinning). Given X.Y.Z, force-move:
#   - vX, vX.Y                         (workflow / whole-catalog majors)
#   - <component>/vX for each action   (directory-scoped pins, e.g. terraform/v1)
#
# The exact X.Y.Z tag is created by the release step; this only manages the floating ones.
# Requires: a git checkout with push rights and tags already fetched. Usage: move-tags.sh X.Y.Z
set -eu

VERSION="${1:?usage: move-tags.sh X.Y.Z}"

# Prereleases (X.Y.Z-rc1) must NOT drag stable floating tags onto themselves.
case "$VERSION" in
  *-*) printf '[info] %s is a prerelease — not moving floating/major tags\n' "$VERSION" >&2; exit 0 ;;
esac

MAJOR="${VERSION%%.*}"
REST="${VERSION#*.}"; MINOR="${REST%%.*}"
SHA="$(git rev-parse HEAD)"

# Floating tag -> reusable workflow / whole catalog.
TAGS="v${MAJOR} v${MAJOR}.${MINOR}"
# Per-component directory-scoped majors (one version stream drives all for now).
for c in tf-env tf-run aws-oidc detect-changes secret-scan tf-lint resolve-env tf-docs cfn-env cfn-run cfn-lint; do
  TAGS="${TAGS} ${c}/v${MAJOR}"
done

for t in $TAGS; do
  git tag -f "$t" "$SHA" >/dev/null
  git push -f origin "refs/tags/${t}" >/dev/null
  printf '[info] moved %s -> %s\n' "$t" "$(git rev-parse --short "$SHA")" >&2
done
