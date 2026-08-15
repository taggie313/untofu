#!/usr/bin/env bash
# Publish site/ to the untofu stack on the clickgraft CT.
#
#   ./site/deploy/redeploy.sh
#
# House pattern, same as elusive-web and clickgraft: everything goes *through*
# the PVE host with `pct exec`. Never ssh into the container directly — the CTs
# are not on a route from here and are not meant to be.
#
# This is a co-tenant of the clickgraft stack. It ships only into /opt/untofu
# and never touches /opt/clickgraft, so a broken deploy here cannot take the
# ClickGraft site down.
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
REMOTE_DIR="${REMOTE_DIR:-/opt/untofu}"
PUBLIC_URL="${PUBLIC_URL:-https://untofu.elusive.net/}"

echo "==> rebuilding icons from untofu-icon.svg"
"$SITE/make-icons.sh" >/dev/null

for f in index.html untofu-icon.svg untofu-favicon.ico untofu-apple-touch-icon.png untofu-og.jpg; do
  [ -s "$SITE/$f" ] || { echo "✗ missing $SITE/$f" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/html"
cp "$SITE"/index.html "$SITE"/untofu-icon.svg "$SITE"/untofu-favicon.ico \
   "$SITE"/untofu-apple-touch-icon.png "$SITE"/untofu-og.jpg "$WORK/html/"
cp "$HERE/nginx.conf" "$HERE/docker-compose.yml" "$WORK/"
tar -czf "$WORK/payload.tgz" -C "$WORK" html nginx.conf docker-compose.yml

echo "==> validating nginx.conf before it can break anything"
# Checked in a throwaway container first. A bad config otherwise leaves the
# service down until someone notices.
scp -q "$WORK/nginx.conf" "$PVE_HOST:/tmp/untofu-nginx.conf"
ssh "$PVE_HOST" "pct push $CTID /tmp/untofu-nginx.conf /tmp/nginx.conf &&
  pct exec $CTID -- docker run --rm -v /tmp/nginx.conf:/etc/nginx/nginx.conf:ro \
    nginx:alpine nginx -t" >/dev/null 2>&1 \
  || { echo "✗ nginx.conf is invalid; nothing was deployed" >&2; exit 1; }

echo "==> shipping to CT $CTID via $PVE_HOST"
scp -q "$WORK/payload.tgz" "$PVE_HOST:/tmp/untofu-payload.tgz"
ssh "$PVE_HOST" "pct push $CTID /tmp/untofu-payload.tgz /tmp/payload.tgz &&
  pct exec $CTID -- sh -c '
    mkdir -p $REMOTE_DIR/html &&
    rm -rf $REMOTE_DIR/html/* &&
    tar -xzf /tmp/payload.tgz -C $REMOTE_DIR &&
    rm -f /tmp/payload.tgz /tmp/nginx.conf
  ' && rm -f /tmp/untofu-payload.tgz /tmp/untofu-nginx.conf"

echo "==> restarting compose"
# nginx.conf is a single-file bind mount and tar replaces the file rather than
# writing through it, so the container keeps the old inode until it is recreated.
# Same trap clickgraft documents. --force-recreate is the cheap fix.
# --remove-orphans: renaming a service leaves the old container behind, still
# holding its network aliases. That is precisely how the `web` collision below
# survived a redeploy.
ssh "$PVE_HOST" "pct exec $CTID -- sh -c '
  cd $REMOTE_DIR && docker compose up -d --force-recreate --remove-orphans
'"

echo "==> checking for network-name collisions"
# Compose registers each service name as an alias on the shared network. If two
# containers claim the same name, Docker DNS round-robins between them and the
# tunnel silently serves the wrong site for half of all requests. Both origins
# stay healthy throughout, so every naive check passes.
DUPES=$(ssh "$PVE_HOST" "pct exec $CTID -- docker network inspect clickgraft_default \
  --format '{{range .Containers}}{{.Name}} {{end}}'" | tr ' ' '\n' | grep -v '^$' | while read -r c; do
    ssh "$PVE_HOST" "pct exec $CTID -- docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{println .}}{{end}}{{end}}' $c" 2>/dev/null
  done | sort | uniq -d)
if [ -n "$DUPES" ]; then
  echo "✗ two containers on clickgraft_default answer to the same name(s):" >&2
  echo "$DUPES" | sed 's/^/     /' >&2
  echo "   Docker DNS will round-robin between them and route traffic wrongly." >&2
  exit 1
fi
echo "   no duplicate names on the shared network ✓"

echo "==> verifying origin"
ssh "$PVE_HOST" "pct exec $CTID -- sh -c '
  docker exec untofu-web-1 wget -qO- http://127.0.0.1/ | head -c 400
'" | grep -q "untofu" && echo "   origin serving ✓"

echo "==> confirming clickgraft is undisturbed"
ssh "$PVE_HOST" "pct exec $CTID -- sh -c '
  docker exec clickgraft-web-1 wget -qO- http://127.0.0.1/ | head -c 400
'" | grep -q "ClickGraft" && echo "   clickgraft still serving ✓"

echo "==> confirming clickgraft's PUBLIC url still serves clickgraft"
# Deliberately checks content, not status. A wrong site returns 200 perfectly
# happily, which is exactly how a routing bug reached production here once.
CG=$(curl -sS --max-time 20 https://clickgraft.elusive.net/ 2>/dev/null | grep -o '<title>[^<]*</title>' | head -1)
case "$CG" in
  *ClickGraft*) echo "   clickgraft public url correct ✓" ;;
  "")           echo "   ! could not read clickgraft's public url (DNS?); check by hand" >&2 ;;
  *)            echo "✗ clickgraft.elusive.net is serving: $CG" >&2
                echo "   Tunnel routing is wrong. Check for duplicate network names." >&2
                exit 1 ;;
esac

echo "==> public URL"
# Resolved against public DNS: this script's own curl is what poisons the local
# resolver's negative cache when a hostname does not exist yet.
HOSTNAME_ONLY=$(echo "${PUBLIC_URL#https://}" | tr -d '/')
IP=$(dig +short @1.1.1.1 "$HOSTNAME_ONLY" 2>/dev/null | head -1)
if [ -n "$IP" ] && curl -sSf -o /dev/null --resolve "$HOSTNAME_ONLY:443:$IP" \
     -w "   %{http_code} %{url_effective}\n" "$PUBLIC_URL"; then
  echo "✓ deployed"
else
  echo "   public URL not answering — add a Public Hostname on the existing tunnel:" >&2
  echo "     $PUBLIC_URL  ->  http://untofu-web:80" >&2
fi
