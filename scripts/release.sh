#!/usr/bin/env bash
# Cut a release: verify, tag, push, and update the Homebrew formula.
#
#   ./scripts/release.sh 0.2.0
#
# Refuses to tag unless Sources/untofu/Version.swift already says the same
# version, so the binary and the formula can never disagree about what they are.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   e.g. $0 0.2.0"; exit 1; }
TAG="v$VERSION"
FORMULA=packaging/homebrew/untofu.rb
REPO=taggie313/untofu

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

echo "==> tagging $TAG"
git tag -a "$TAG" -m "untofu $VERSION"
git push github main --tags
git remote get-url origin >/dev/null 2>&1 && git push origin main --tags || true

echo "==> waiting for GitHub to publish the tarball"
URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
for _ in $(seq 1 15); do
  sleep 2
  curl -sfL -o /tmp/untofu-release.tar.gz "$URL" && break
done
[ -s /tmp/untofu-release.tar.gz ] || { echo "tarball never appeared at $URL"; exit 1; }

SHA=$(shasum -a 256 /tmp/untofu-release.tar.gz | cut -d' ' -f1)
echo "==> sha256 $SHA"

# BSD sed; the URL contains slashes, so use a different delimiter.
sed -i '' "s|archive/refs/tags/v[0-9.]*\.tar\.gz|archive/refs/tags/$TAG.tar.gz|" "$FORMULA"
sed -i '' "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" "$FORMULA"

echo "==> formula now reads:"
grep -E '^\s+(url|sha256)' "$FORMULA"

cat <<EOS

Next: copy the formula into the tap and push it.

  cp $FORMULA ../homebrew-tap/Formula/untofu.rb
  cd ../homebrew-tap && git commit -am "untofu $VERSION" && git push

Then: brew update && brew upgrade untofu
EOS
