#!/bin/bash
# Print the CHANGELOG.md section of one version (without its heading), for GitHub release notes.
#
#   scripts/release-notes.sh 0.2.0        # the "## [0.2.0] - date" section
#   scripts/release-notes.sh Unreleased   # what the next release will contain
set -euo pipefail

VERSION="${1:?usage: release-notes.sh <version|Unreleased>}"
CHANGELOG="$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md"

awk -v version="$VERSION" '
  /^## \[/ { if (found) exit; if (index($0, "## [" version "]") == 1) { found = 1; next } }
  /^\[[^]]+\]: / { if (found) exit }
  found { print }
' "$CHANGELOG" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
