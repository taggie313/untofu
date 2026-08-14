#!/usr/bin/env bash
# Publish site/ to the fontfetch CT.
#
#   ./site/deploy/redeploy.sh
#
# House pattern, same as elusive-web and clickgraft: everything goes *through*
# the PVE host with `pct exec`. Never ssh into the container directly — the CTs
# are not on a route from here and are not meant to be.
#
# Configure by copying deploy.env.example to deploy.env.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SITE="$(cd "$HERE/.." && pwd)"

[ -f "$HERE/deploy.env" ] || {
  echo "✗ $HERE/deploy.env not found. Copy deploy.env.example and fill it in." >&2
  exit 1
}
# shellcheck disable=SC1091
. "$HERE/deploy.env"

: "${PVE_HOST:?set PVE_HOST in deploy.env}"
: "${CTID:?set CTID in deploy.env}"
REMOTE_DIR="${REMOTE_DIR:-/opt/fontfetch}"
PUBLIC_URL="${PUBLIC_URL:-https://fontfetch.elusive.net/}"

echo "==> rebuilding icons from icon.svg"
"$SITE/make-icons.sh" >/dev/null

for f in index.html icon.svg favicon.ico apple-touch-icon.png og.jpg; do
  [ -s "$SITE/$f" ] || { echo "✗ missing $SITE/$f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/html"
cp "$SITE"/index.html "$SITE"/icon.svg "$SITE"/favicon.ico \
   "$SITE"/apple-touch-icon.png "$SITE"/og.jpg "$WORK/html/"
cp "$HERE/nginx.conf" "$HERE/docker-compose.yml" "$WORK/"
tar -czf "$WORK/payload.tgz" -C "$WORK" html nginx.conf docker-compose.yml

echo "==> shipping to CT $CTID via $PVE_HOST"
# Through the host: land the tarball on the PVE node, push it into the CT, then
# unpack inside. `pct push` avoids needing any network path to the container.
scp -q "$WORK/payload.tgz" "$PVE_HOST:/tmp/fontfetch-payload.tgz"
ssh "$PVE_HOST" "pct push $CTID /tmp/fontfetch-payload.tgz /tmp/payload.tgz &&
  pct exec $CTID -- sh -c '
    mkdir -p $REMOTE_DIR &&
    tar -xzf /tmp/payload.tgz -C $REMOTE_DIR &&
    rm -f /tmp/payload.tgz
  ' && rm -f /tmp/fontfetch-payload.tgz"

echo "==> restarting compose"
# .env holds only CLOUDFLARE_TUNNEL_TOKEN and lives on the CT at mode 600. It is
# never shipped from here and never committed.
ssh "$PVE_HOST" "pct exec $CTID -- sh -c '
  cd $REMOTE_DIR &&
  test -f .env || { echo \"✗ $REMOTE_DIR/.env missing (needs CLOUDFLARE_TUNNEL_TOKEN)\" >&2; exit 1; }
  docker compose up -d
'"

echo "==> verifying origin"
# From inside the CT, so this never counts as a visit in the access log —
# requests without CF-Connecting-IP are excluded by nginx.conf.
ssh "$PVE_HOST" "pct exec $CTID -- sh -c '
  docker compose -f $REMOTE_DIR/docker-compose.yml exec -T web \
    wget -qO- http://127.0.0.1/ | head -c 200
'" | grep -q "fontfetch" && echo "   origin serving ✓"

echo "==> public URL"
if curl -sSf -o /dev/null -w "   %{http_code} %{url_effective}\n" "$PUBLIC_URL"; then
  echo "✓ deployed"
else
  echo "   public URL not answering yet — check the tunnel's Public Hostname mapping" >&2
fi
