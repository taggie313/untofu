#!/usr/bin/env bash
# Cut a release: verify, tag, publish a GitHub Release, and update the formula.
#
#   ./scripts/release.sh 0.2.1
#
# Refuses to tag unless Sources/untofu/Version.swift already says the same
# version, so the binary and the formula can never disagree about what they are.
#
# The formula points at an *uploaded release asset*, not at GitHub's
# auto-generated archive/refs/tags tarball. That distinction is the whole reason
# this script builds and uploads a tarball at all: GitHub reports
# `download_count` only for assets somebody uploaded. Auto-generated source
# archives carry no counter, so with those there is no way to tell whether
# anyone has ever installed this. See scripts/downloads.sh.
#
# Building the tarball locally also removes a race: the sha256 is computed from
# the exact bytes uploaded, rather than polling GitHub until its archive
# generator produces something and hoping it is stable.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 0.2.1"; exit 1; }
TAG="v$VERSION"
FORMULA=packaging/homebrew/untofu.rb
REPO=taggie313/untofu
TARBALL="untofu-$VERSION.tar.gz"

DECLARED=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/untofu/Version.swift)
if [ "$DECLARED" != "$VERSION" ]; then
  echo "Version.swift says '$DECLARED' but you asked for '$VERSION'."
  echo "Edit Sources/untofu/Version.swift first."
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit first."; exit 1
fi

echo "==> tests"
./scripts/selftest.sh >/dev/null || { echo "selftest failed"; exit 1; }

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "==> tag $TAG already exists, reusing it"
else
  echo "==> tagging $TAG"
  git tag -a "$TAG" -m "untofu $VERSION"
fi
git push github main --tags
git remote get-url origin >/dev/null 2>&1 && git push origin main --tags || true

echo "==> building source tarball from the tag"
# From the tag, not the working tree: what ships is exactly what was tagged.
# The prefix directory matters — Homebrew strips one leading component, and
# without it the source would unpack across the build directory.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git archive --format=tar.gz --prefix="untofu-$VERSION/" -o "$WORK/$TARBALL" "$TAG"

SHA=$(shasum -a 256 "$WORK/$TARBALL" | cut -d' ' -f1)
echo "    $TARBALL  $(du -h "$WORK/$TARBALL" | cut -f1)  sha256 $SHA"

echo "==> publishing the GitHub Release"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "    release exists; replacing the asset"
  gh release upload "$TAG" "$WORK/$TARBALL" --repo "$REPO" --clobber >/dev/null
else
  gh release create "$TAG" "$WORK/$TARBALL" --repo "$REPO" \
    --title "untofu $VERSION" \
    --notes "Install:

    brew tap taggie313/tap
    brew trust taggie313/tap
    brew install untofu

\`$TARBALL\` is the source the Homebrew formula builds from." >/dev/null
fi

URL="https://github.com/$REPO/releases/download/$TAG/$TARBALL"
echo "==> verifying the asset is fetchable"
curl -sfL -o "$WORK/check.tar.gz" "$URL" || { echo "✗ asset not reachable at $URL"; exit 1; }
[ "$(shasum -a 256 "$WORK/check.tar.gz" | cut -d' ' -f1)" = "$SHA" ] \
  || { echo "✗ downloaded asset does not match what was built"; exit 1; }
echo "    fetched and sha matches ✓"

# BSD sed; the URL contains slashes, so use a different delimiter.
sed -i '' "s|^  url .*|  url \"$URL\"|" "$FORMULA"
sed -i '' "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" "$FORMULA"

echo "==> formula now reads:"
grep -E '^\s+(url|sha256)' "$FORMULA"

cat <<EOS

Next: copy the formula into the tap and push it.

  cp $FORMULA ../homebrew-tap/Formula/untofu.rb
  cd ../homebrew-tap && git commit -am "untofu $VERSION" && git push

Then: brew update && brew upgrade untofu
Downloads so far: ./scripts/downloads.sh
EOS
