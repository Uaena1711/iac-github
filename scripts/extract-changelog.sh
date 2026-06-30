#!/usr/bin/env sh
# iac-github :: print the CHANGELOG.md section for a given version (release notes body).
# Usage: extract-changelog.sh <version>
set -eu

VERSION="${1:?usage: extract-changelog.sh <version>}"

awk -v ver="$VERSION" '
  $0 ~ "^##[[:space:]]+" ver "([[:space:]]|$)" { grab=1; next }
  grab && /^##[[:space:]]/ { exit }
  grab { print }
' CHANGELOG.md
