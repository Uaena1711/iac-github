#!/usr/bin/env sh
# iac-github :: validate the release version (metadata.json <-> CHANGELOG <-> git tags).
#
# Always:
#   1. metadata.json .version is valid SemVer.
#   2. CHANGELOG.md has a matching "## <version>" heading.
# When MODE=release (push to default branch):
#   3. tag v<version> must NOT already exist (i.e. the version was bumped).
# When BASE_REF is set (pull request):
#   4. if any actions/** or .github/workflows/** changed vs BASE_REF AND the version is
#      unchanged vs BASE_REF -> fail (force a bump when behavior changes).
#
# Prints the resolved version to STDOUT (logs go to STDERR) so callers can capture it.
set -eu

log() { printf '%s\n' "$*" >&2; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

VERSION="$(jq -r '.version' metadata.json)"
[ -n "$VERSION" ] && [ "$VERSION" != "null" ] || die "metadata.json has no .version"

# 1. SemVer (MAJOR.MINOR.PATCH, optional -prerelease).
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
  || die "version '$VERSION' is not valid SemVer"

# 2. CHANGELOG heading.
grep -Eq "^##[[:space:]]+${VERSION}([[:space:]]|\$)" CHANGELOG.md \
  || die "CHANGELOG.md has no '## ${VERSION}' heading"

# 3. release: tag must not already exist.
if [ "${MODE:-}" = "release" ]; then
  if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null 2>&1; then
    die "tag v${VERSION} already exists — bump metadata.json"
  fi
  log "[info] release check ok: v${VERSION} is new"
fi

# 4. PR: behavior change must be accompanied by a version bump.
if [ -n "${BASE_REF:-}" ]; then
  changed="$(git diff --name-only "${BASE_REF}"...HEAD 2>/dev/null || true)"
  if printf '%s\n' "$changed" | grep -Eq '^(actions/|\.github/workflows/)'; then
    base_ver="$(git show "${BASE_REF}:metadata.json" 2>/dev/null | jq -r '.version' 2>/dev/null || echo "")"
    if [ -n "$base_ver" ] && [ "$base_ver" = "$VERSION" ]; then
      die "actions/workflows changed but version is still ${VERSION} — bump metadata.json + CHANGELOG"
    fi
    log "[info] bump check ok: ${base_ver:-?} -> ${VERSION}"
  fi
fi

log "[info] version valid: ${VERSION}"
printf '%s\n' "$VERSION"
