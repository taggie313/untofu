# Deploying untofu.elusive.net

Static page served by its own nginx, running as a **co-tenant of the clickgraft
stack** on CT 117 (`bb2`). It shares that stack's cloudflared rather than running
a second tunnel.

## Shape

```
CT 117 ─┬─ /opt/clickgraft   compose project "clickgraft"
        │     web, cloudflared, report, stats
        │
        └─ /opt/untofu    compose project "untofu"
              web  ──► joins network clickgraft_default as "untofu-web"
```

The tunnel is **token-managed**, so its ingress rules live in the Cloudflare
dashboard and are pushed to cloudflared, which hot-reloads them. Adding a site is
one dashboard entry and needs no restart and no token handling:

```
untofu.elusive.net  ->  http://untofu-web:80
```

## Why a separate compose project

Not a service bolted onto `/opt/clickgraft/docker-compose.yml`. ClickGraft's own
`redeploy.sh` stages its compose file and `nginx.conf`, `rsync --delete`s the
staging directory and re-tars it into the container — so anything added to that
file is erased the next time ClickGraft ships. A separate project in its own
directory is immune to that, and a broken deploy here cannot take ClickGraft
down.

`redeploy.sh` checks both sites after every deploy for exactly that reason.

## One coupling to know about

`networks.shared` is `external: true` pointing at `clickgraft_default`, which the
clickgraft project owns. A `docker compose down` in `/opt/clickgraft` removes
that network; bring the clickgraft stack back up and then restart this one:

```sh
pct exec 117 -- sh -c 'cd /opt/untofu && docker compose up -d'
```

## Deploying

```sh
cp site/deploy/deploy.env.example site/deploy/deploy.env   # already points at CT 117
./site/deploy/redeploy.sh
```

It rebuilds the icon set, validates `nginx.conf` in a throwaway container before
anything is replaced, ships the payload through the PVE host with `pct exec`,
recreates the container, then checks that untofu serves, that **clickgraft
still serves**, and finally that the public URL answers.

## Two things that will bite again

Both inherited from clickgraft, both already handled:

- The `nginx:alpine` image ships `/var/log/nginx/access.log` as a symlink to
  `/dev/stdout`, and a volume mounted over that directory inherits the symlink.
  Logging to that name writes to the container's stdout and leaves the file on
  disk permanently empty. Hence `untofu-access.log`.
- `nginx.conf` is a single-file bind mount and `tar` replaces the file rather
  than writing through it, so the container keeps the old inode. Hence
  `--force-recreate` rather than a plain `up -d`.

Also: `$server_protocol` already contains `HTTP/`.

## Logging

Addresses are truncated before they are written — IPv4 to its /24, IPv6 to its
/48 — enough to tell two visitors apart on a day, not enough to point at a
person. Requests without `CF-Connecting-IP` never came through the tunnel, so
they are ours and are not logged.

No GoAccess service here, unlike clickgraft. Add one if traffic ever justifies
it; the log format is already compatible.

## HSTS

Host-only, `max-age` with no `includeSubDomains` and no `preload`, forever.
Unaffiliated third-party subdomains live under `elusive.net`. Same firm
constraint as the brand site.
