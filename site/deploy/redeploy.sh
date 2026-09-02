#!/usr/bin/env bash
# Publish site/ to the edge stack.
#
#   ./site/deploy/redeploy.sh
#
# This ships CONTENT ONLY. untofu no longer runs a web server: nginx, the
# Cloudflare tunnel and the routing all belong to the `edge` stack (CT 136, repo
# elusive-edge), which is owned by no single project. Publishing a page here
# writes into one directory and cannot touch routing — which is the point, since
# the arrangement this replaced let one project's deploy take another project's
# site off the internet.
#
# If the *routing* needs changing — a new hostname, different headers — that is
# elusive-edge's redeploy.sh, not this one.
#
# House pattern: everything goes through the PVE host with `pct exec`. Never ssh
# into the container directly; the CTs are not on a route from here.
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
REMOTE_DIR="${REMOTE_DIR:-/opt/edge/sites/untofu}"
PUBLIC_URL="${PUBLIC_URL:-https://untofu.elusive.net/}"

ASSETS="index.html untofu-icon.svg untofu-favicon.ico untofu-apple-touch-icon.png untofu-og.jpg robots.txt sitemap.xml"

echo "==> rebuilding icons from untofu-icon.svg"
"$SITE/make-icons.sh" >/dev/null

for f in $ASSETS; do
  [ -s "$SITE/$f" ] || { echo "✗ missing $SITE/$f" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# shellcheck disable=SC2086
tar -czf "$WORK/html.tgz" -C "$SITE" $ASSETS

# Which node is the container actually on?
#
# CT 136 was on bb2 when this was written and is on bb1 now. A migration turns
# the deploy into `can only push files to a running CT` — loud, correctly
# non-zero, but only after release.sh has already tagged, notarised and
# published, so the site is the one artifact left pointing at the old version.
# PVE_HOST is therefore just an entry point into the cluster; the cluster is
# asked where the container lives.
PVE_USER="${PVE_HOST%%@*}"
NODE=$(ssh -o ConnectTimeout=10 "$PVE_HOST" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
      | python3 -c "
import json,sys
try:
    for r in json.load(sys.stdin):
        if str(r.get('vmid')) == '$CTID' and r.get('status') == 'running':
            print(r.get('node','')); break
except Exception:
    pass
" 2>/dev/null) || NODE=""

if [ -n "$NODE" ] && [ "$PVE_USER@$NODE" != "$PVE_HOST" ]; then
  echo "==> CT $CTID has moved to $NODE (deploy.env says ${PVE_HOST#*@})"
  PVE_HOST="$PVE_USER@$NODE"
elif [ -z "$NODE" ]; then
  echo "==> could not ask the cluster where CT $CTID is; trying $PVE_HOST as configured"
fi

echo "==> shipping to CT $CTID via $PVE_HOST"
scp -q "$WORK/html.tgz" "$PVE_HOST:/tmp/untofu-html.tgz"
ssh "$PVE_HOST" "pct push $CTID /tmp/untofu-html.tgz /tmp/untofu-html.tgz &&
  pct exec $CTID -- sh -c '
    mkdir -p $REMOTE_DIR/html &&
    rm -rf $REMOTE_DIR/html/* &&
    tar -xzf /tmp/untofu-html.tgz -C $REMOTE_DIR/html &&
    rm -f /tmp/untofu-html.tgz
  ' && rm -f /tmp/untofu-html.tgz"

# No restart. nginx serves the directory directly, so new files are live the
# moment they land; recreating anything would be someone else's container.

echo "==> verifying by content, not status code"
# A 200 with the wrong bytes is the exact failure that produced the edge stack,
# so compare hashes rather than trusting the response code.
LOCAL_SHA=$(shasum -a 256 "$SITE/index.html" | cut -d' ' -f1)
LIVE_SHA=$(curl -sSf --max-time 30 "$PUBLIC_URL" | shasum -a 256 | cut -d' ' -f1)
if [ "$LOCAL_SHA" = "$LIVE_SHA" ]; then
  echo "   $PUBLIC_URL serves this exact index.html ✓"
else
  echo "   ✗ live page differs from the local one." >&2
  echo "     local $LOCAL_SHA" >&2
  echo "     live  $LIVE_SHA" >&2
  echo "     If the hostname is not routed to edge yet, add a Public Hostname on" >&2
  echo "     the edge tunnel: ${PUBLIC_URL%/}  ->  http://nginx:80" >&2
  exit 1
fi

for f in $ASSETS; do
  [ "$f" = "index.html" ] && continue
  code=$(curl -sS -o /dev/null --max-time 20 -w '%{http_code}' "${PUBLIC_URL%/}/$f")
  printf "   %-32s %s\n" "$f" "$code"
  [ "$code" = "200" ] || { echo "   ✗ $f is not being served" >&2; exit 1; }
done

echo "✓ deployed"
