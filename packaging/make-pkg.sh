#!/usr/bin/env bash
# Build a signed, notarised installer package.
#
#   ./packaging/make-pkg.sh 0.2.1
#
# Homebrew reaches developers. The people who actually hit a missing-font dialog
# are designers opening a deck, and they do not have Homebrew and are not going
# to install it. This package is how untofu reaches them: double-click, done.
#
# That audience is also why signing is not optional here, unlike the Homebrew
# bottle. Homebrew fetches with curl, which never sets a quarantine attribute,
# so an ad-hoc binary runs fine. A package downloaded in a browser IS
# quarantined, and Gatekeeper refuses anything that is not both Developer
# ID-signed and notarised. An unsigned package would give exactly the audience
# it targets a scary "cannot be opened" wall.
#
# Two credentials are needed, and this script refuses rather than shipping
# something broken if either is missing:
#
#   * A "Developer ID Installer" certificate — distinct from the "Developer ID
#     Application" certificate used for the binary. Create it at
#     developer.apple.com > Certificates, then download and double-click it.
#
#   * A notarytool keychain profile, so the credential lives in the keychain and
#     never in a script, a shell history, or this repository:
#
#       xcrun notarytool store-credentials untofu-notary \
#           --apple-id "you@example.com" \
#           --team-id  "U9U8JC2JT7" \
#           --password "abcd-efgh-ijkl-mnop"   # app-specific password
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>"; exit 1; }

IDENTIFIER=net.elusive.untofu
PROFILE="${NOTARY_PROFILE:-untofu-notary}"
APP_CERT="Developer ID Application"
PKG_CERT="Developer ID Installer"
OUT="dist/untofu-$VERSION.pkg"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/usr/local/bin" "$WORK/root/Library/LaunchAgents" dist

echo "==> building universal binary"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
cp .build/apple/Products/Release/untofu "$WORK/root/usr/local/bin/untofu"

echo "==> signing the binary"
# Hardened runtime is required for notarisation. Signed even in an unsigned
# build, because it costs nothing and makes the artifact honest about its origin.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$APP_CERT"; then
  codesign --force --timestamp --options runtime \
           --sign "$APP_CERT" "$WORK/root/usr/local/bin/untofu"
  echo "    signed with $APP_CERT"
else
  echo "    ✗ no '$APP_CERT' certificate; leaving the linker's ad-hoc signature" >&2
fi

cat > "$WORK/root/Library/LaunchAgents/$IDENTIFIER.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$IDENTIFIER</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/untofu</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/tmp/untofu.log</string>
  <key>StandardErrorPath</key><string>/tmp/untofu.log</string>
</dict>
</plist>
PLIST

echo "==> building the package"
pkgbuild --root "$WORK/root" \
         --scripts packaging/pkg/scripts \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         "$WORK/component.pkg" >/dev/null

if security find-identity -v 2>/dev/null | grep -q "$PKG_CERT"; then
  productbuild --package "$WORK/component.pkg" --sign "$PKG_CERT" "$OUT" >/dev/null
  echo "    signed with $PKG_CERT"
else
  cp "$WORK/component.pkg" "$OUT"
  cat >&2 <<WARN

  ✗ No '$PKG_CERT' certificate found.

    Built $OUT UNSIGNED. Do not publish it: a browser download is
    quarantined, and Gatekeeper will refuse it with "cannot be opened because
    the developer cannot be verified" — worse for a non-technical user than
    having no package at all.

    Create one at developer.apple.com > Certificates > Developer ID Installer,
    download it, double-click to add it to the keychain, and re-run this.

WARN
  exit 2
fi

echo "==> notarising"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "  ✗ no notarytool keychain profile '$PROFILE'. See the header of this script." >&2
  echo "    $OUT is signed but NOT notarised; Gatekeeper will still refuse it." >&2
  exit 3
fi
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"

echo "==> verifying the way Gatekeeper will see it"
spctl -a -vv -t install "$OUT" 2>&1 | sed 's/^/    /'
xcrun stapler validate "$OUT" 2>&1 | sed 's/^/    /'
echo "✓ $OUT  $(du -h "$OUT" | cut -f1)"
