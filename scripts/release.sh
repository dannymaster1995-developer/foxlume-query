#!/bin/bash
# Cut a release locally: write VERSION, turn "## [Unreleased]" in CHANGELOG.md into "## [x.y.z] - date",
# update the version in README.md, commit "Release x.y.z" and create the annotated tag vx.y.z.
# It never pushes; pushing the tag starts .github/workflows/release.yml, which builds and publishes the app.
#
#   scripts/release.sh 0.2.0 [--dry-run]   # --dry-run checks everything and prints the diff, changes nothing
set -euo pipefail

VERSION="${1:?usage: release.sh <x.y.z> [--dry-run]}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
REPO_URL="https://github.com/dannymaster1995-developer/foxlume-query"
cd "$(dirname "$0")/.."

problems=()
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || problems+=("version must look like 1.2.3")
[ "$(git branch --show-current)" = "main" ] || problems+=("not on main")
[ -z "$(git status --porcelain)" ] || problems+=("working tree has uncommitted changes")
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && problems+=("tag v$VERSION already exists")
[ -n "$(scripts/release-notes.sh Unreleased | grep -E '^- ')" ] || problems+=("CHANGELOG [Unreleased] has no entries")
PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ ${#problems[@]} -gt 0 ]; then
  printf 'release.sh: %s\n' "${problems[@]}" >&2
  [ "$DRY_RUN" -eq 1 ] || exit 1
fi

DATE="$(date +%Y-%m-%d)"
if [ -n "$PREVIOUS_TAG" ]; then VERSION_LINK="$REPO_URL/compare/$PREVIOUS_TAG...v$VERSION"; else VERSION_LINK="$REPO_URL/releases/tag/v$VERSION"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fq-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

awk -v version="$VERSION" -v date="$DATE" -v unreleased_link="$REPO_URL/compare/v$VERSION...HEAD" -v version_link="$VERSION_LINK" '
  $0 == "## [Unreleased]" { print; print ""; print "## [" version "] - " date; next }
  /^\[Unreleased\]: / { print "[Unreleased]: " unreleased_link; print "[" version "]: " version_link; next }
  { print }
' CHANGELOG.md >"$WORK/CHANGELOG.md"
printf '%s\n' "$VERSION" >"$WORK/VERSION"
sed -E "s/(early alpha \()[0-9]+\.[0-9]+\.[0-9]+\)/\1$VERSION)/" README.md >"$WORK/README.md"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run for $VERSION (previous tag: ${PREVIOUS_TAG:-none}); nothing is changed."
  for f in VERSION CHANGELOG.md README.md; do diff -u "$f" "$WORK/$f" || true; done
  echo "Release notes:"
  scripts/release-notes.sh Unreleased
  exit 0
fi

cp "$WORK/CHANGELOG.md" "$WORK/VERSION" "$WORK/README.md" .
git add VERSION CHANGELOG.md README.md
git commit -q -m "Release $VERSION"
git tag -a "v$VERSION" -m "Foxlume Query $VERSION"
echo "Committed and tagged v$VERSION. Publish with: git push origin main && git push origin v$VERSION"
