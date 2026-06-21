# Trilium (notes + ETAPI for AI)

[TriliumNext](https://github.com/TriliumNext/Trilium) — single-user hierarchical
notes with a first-class REST API (ETAPI). Replaces the earlier Joplin attempt:
Joplin Server is sync-only with no note-content API, so an AI agent can't
read/write notes through it. Trilium's ETAPI gives Claude full CRUD.

- **URL:** `https://trilium.<homelab_domain>` (WireGuard-only, via Traefik
  `wg-only@file`).
- **Backend:** single container, SQLite (`document.db`). No DB sidecar.
- **Role:** `ansible/roles/trilium`. Deployed by the `deploy-trilium` CI job on
  push to `main`, or `--tags trilium` manually.

## How Claude reaches it

Claude (terminal + phone, both on WG) talks to Trilium through the **client-side
`triliumnext-mcp`** server, registered at **user scope** so it's available in
every project:

```bash
# On a WG-connected machine. Token + domain come from the host (see below).
export TRILIUM_ETAPI_TOKEN="$(ssh homelab 'sudo cat /etc/homelab/secrets/trilium_etapi_token')"
export HOMELAB_DOMAIN="$(ssh homelab 'sudo awk -F\" /^homelab_domain:/{print \$2}\" /etc/homelab/config.yml')"  # or set manually

claude mcp add -s user trilium \
  -e TRILIUM_API_URL="https://trilium.${HOMELAB_DOMAIN}/etapi" \
  -e TRILIUM_API_TOKEN="${TRILIUM_ETAPI_TOKEN}" \
  -e PERMISSIONS="READ;WRITE" \
  -- npx -y triliumnext-mcp
```

The token never lands in git — it lives only at
`/etc/homelab/secrets/trilium_etapi_token` on the host and in the user-scope MCP
config. The MCP only works over the WG tunnel (matches the `wg-only`
middleware).

## Headless bootstrap (IaC, no UI clicks)

Trilium ships uninitialized with no password and has **no password env var**.
The role drives its HTTP setup once, reaching the container by its proxy-net IP
(Traefik's `wg-only` blocks the CI runner's SNAT):

1. self-mint `/etc/homelab/secrets/trilium_password` (32 chars)
2. `POST /api/setup/new-document` → create `document.db` (204)
3. `POST /set-password` (`password1`/`password2`, pre-init only, no auth) → 302
4. `POST /etapi/auth/login` `{password}` → returns the ETAPI token
5. store it at `/etc/homelab/secrets/trilium_etapi_token` (mode 0400)

Steps 2–5 are guarded on the token file, so re-converges never re-init or
rotate. Both secrets are in the restic backup set.

## Backup / restore

The backup role restics `/opt/trilium/data` directly (SQLite + Trilium's own
rolling `data/backup/` copies). Restore:

```bash
docker compose -f /opt/trilium/docker-compose.yml down
# restic restore /opt/trilium/data from the latest snapshot
chown -R 1000:1000 /opt/trilium/data
docker compose -f /opt/trilium/docker-compose.yml up -d --wait
```

## Note tree (for the /idea skill)

The future user-level `/idea` skill organizes notes/ideas/todos into:
`Inbox` (capture) · `Personal/<project>` · `Work/<project>` · `Archive`.
It auto-guesses Personal/Work + project (defaulting the project to the repo when
run inside one) and asks only when ambiguous.
