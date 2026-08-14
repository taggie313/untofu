# Deploying fontfetch.elusive.net

Static page, nginx origin, cloudflared tunnel. Same shape as `elusive-web` and
`clickgraft`: no published ports, the tunnel is the only ingress, and every
deploy goes *through* the PVE host with `pct exec` rather than into the
container directly.

## Not yet live

This scaffolding is complete but the site has never been deployed, because two
steps are not mine to take:

1. **A Cloudflare tunnel** for `fontfetch.elusive.net`, and its token. Tunnels
   are created in the Cloudflare dashboard; the token then lives only in
   `/opt/fontfetch/.env` on the container at mode 600, and is never committed.
2. **The Public Hostname mapping** `fontfetch.elusive.net` → `http://web:80`
   on that tunnel.

Once those exist, provisioning the container and running the deploy is
mechanical.

## One-time setup

Provision a Debian container on a PVE node, install Docker, then:

```sh
# On the PVE host
pct exec <CTID> -- sh -c 'mkdir -p /opt/fontfetch'
pct exec <CTID> -- sh -c 'printf "CLOUDFLARE_TUNNEL_TOKEN=%s\n" "<token>" > /opt/fontfetch/.env'
pct exec <CTID> -- sh -c 'chmod 600 /opt/fontfetch/.env'
```

Then from a checkout:

```sh
cp site/deploy/deploy.env.example site/deploy/deploy.env
$EDITOR site/deploy/deploy.env      # PVE_HOST and CTID
./site/deploy/redeploy.sh
```

## Deploying

```sh
./site/deploy/redeploy.sh
```

It rebuilds the icon set from `icon.svg`, ships `index.html` plus the artwork,
restarts compose, checks the origin from inside the container, and finally
checks the public URL.

## Two things that will bite again

Both are inherited from `clickgraft` and both are already handled in
`nginx.conf`, but they are easy to reintroduce:

- The `nginx:alpine` image ships `/var/log/nginx/access.log` as a symlink to
  `/dev/stdout`, and a volume mounted over that directory inherits the symlink.
  Logging to that name writes to the container's stdout and leaves the file on
  disk permanently empty. Hence `fontfetch-access.log`.
- `$server_protocol` already contains `HTTP/`. Prefixing it again produces
  `HTTP/HTTP/1.1` in the log format.

## Logging

Addresses are truncated before they are written — IPv4 to its /24, IPv6 to its
/48 — which is enough to tell two visitors apart on a day and not enough to
point at a person. Requests without `CF-Connecting-IP` never came through the
tunnel, so they are ours and are not logged at all.

No GoAccess service here, unlike clickgraft. Add one if the traffic ever
justifies it; the log format is already compatible.

## HSTS

Host-only, `max-age` with no `includeSubDomains` and no `preload`, forever.
Unaffiliated third-party subdomains live under `elusive.net`, and preloading the
apex would break them. Same firm constraint as the brand site.
