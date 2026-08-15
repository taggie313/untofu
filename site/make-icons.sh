#!/usr/bin/env bash
# Render site/icon.svg into the web icon set.
#
#   ./site/make-icons.sh
#
# One SVG is the source of truth so the favicon, the touch icon and the social
# card cannot drift apart.
#
# No .icns here, unlike ClickGraft: untofu is a background agent with nothing
# a user ever launches, so there is no app icon to build. The set is web-only.
#
# Rendered with qlmanage rather than ImageMagick. IM's bundled SVG renderer
# ignores gradients and filters — it turned this artwork into a black square
# with the letterform missing entirely. Quick Look uses the same engine as the
# rest of macOS and gets it right. Everything is rendered once at 1024 and
# downsampled with sips, which resamples better than re-rendering small.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SVG="$HERE/icon.svg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SVG").png"
[ -s "$MASTER" ] || { echo "✗ qlmanage did not render $SVG" >&2; exit 1; }
[ "$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')" = 1024 ] \
  || { echo "✗ master render is not 1024px" >&2; exit 1; }

# apple-touch-icon has a defined size of 180px; anything larger is bytes no
# device asks for.
sips -s format png -z 180 180 "$MASTER" --out "$HERE/apple-touch-icon.png" >/dev/null 2>&1

# Undithered 256-colour quantisation. The artwork is a smooth gradient, which
# is close to worst case for PNG, and dithering scatters exactly the noise PNG
# cannot compress. Undithered is both smaller and closer to the original.
magick "$HERE/apple-touch-icon.png" +dither -colors 256 \
       -define png:compression-level=9 "$HERE/apple-touch-icon.png"

# Favicon carries 16/32/48 so each gets a real render rather than a browser-side
# downscale of one big one.
#
# The 16px slice comes from icon-small.svg instead. At that size the placeholder
# box and the letterform collide into a grey smudge; dropping the box and
# letting a heavier A fill the tile is legible where the full mark is not. ICO
# stores every size as its own image, so 32 and 48 keep the real mark.
qlmanage -t -s 1024 -o "$WORK" "$HERE/icon-small.svg" >/dev/null 2>&1
SMALL="$WORK/icon-small.svg.png"
[ -s "$SMALL" ] || { echo "✗ qlmanage did not render icon-small.svg" >&2; exit 1; }

sips -s format png -z 16 16 "$SMALL"  --out "$WORK/f16.png" >/dev/null 2>&1
sips -s format png -z 32 32 "$MASTER" --out "$WORK/f32.png" >/dev/null 2>&1
sips -s format png -z 48 48 "$MASTER" --out "$WORK/f48.png" >/dev/null 2>&1
magick "$WORK/f16.png" "$WORK/f32.png" "$WORK/f48.png" "$HERE/favicon.ico"

# Social preview as JPEG, not PNG. A smooth gradient over an opaque tile costs
# roughly a megabyte as a 1024px PNG, which every link-preview bot then fetches.
# JPEG at 640px is indistinguishable in a chat bubble.
sips -s format jpeg -s formatOptions 82 -z 640 640 "$MASTER" \
     --out "$HERE/og.jpg" >/dev/null 2>&1

echo "✓ icon set:"
for f in icon.svg favicon.ico apple-touch-icon.png og.jpg; do
  printf '   %-22s %s\n' "$f" "$(du -h "$HERE/$f" | cut -f1)"
done
