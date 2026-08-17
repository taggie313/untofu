# Deploying untofu.elusive.net

Content only. untofu does not run a web server.

nginx, the Cloudflare tunnel and all routing belong to the **edge** stack —
CT 136 on bb2, repo `elusive-edge` — which is owned by no single project. This
directory ships files into `/opt/edge/sites/untofu/html` and does nothing else.

```sh
cp site/deploy/deploy.env.example site/deploy/deploy.env   # already points at CT 136
./site/deploy/redeploy.sh
```

## Why it is only this

untofu previously ran its own nginx and its own compose project, as a co-tenant
inside ClickGraft's container — sharing a docker network and a tunnel that
ClickGraft owned. That arrangement failed exactly the way it was shaped to: a
service-name collision routed ClickGraft's hostname to untofu's catch-all nginx,
which answered with untofu's content, and Cloudflare and visitors' browsers
cached the wrong artwork under the wrong hostname. It outlived both the routing
fix and a cache purge, and was only cured by renaming every asset on both sites.

Separating content from routing is the durable fix. Publishing a page now writes
into one directory and **cannot** reach routing, so this script has no way to
take another project's site down.

If routing needs changing — a new hostname, different headers, a new site — that
is `elusive-edge`'s `redeploy.sh`, not this one.

## What it verifies

By content, not status code. The failure that produced the edge stack was a
`200` with the wrong bytes, which a status check passes happily. So the script
compares the live page's sha256 against the local `index.html` and fails if they
differ, then confirms every asset returns 200.

If the hostname is not routed to edge, the content check fails with the exact
Public Hostname to add:

```
untofu.elusive.net  ->  http://nginx:80
```

## Rollback

CT 117 still holds the old untofu stack, stopped but intact. Rolling back is one
change in the Cloudflare dashboard — point `untofu.elusive.net` at ClickGraft's
tunnel again — with no deploy required. Once the edge stack has been quiet for a
day or two, that stack can be removed.
