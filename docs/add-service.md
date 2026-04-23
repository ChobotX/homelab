# Adding a new service behind Traefik

One Ansible role + one docker-compose stack per service.

Role scaffold: copy `ansible/roles/vaultwarden/` — canonical minimal example.

```
ansible/roles/<svc>/
├── tasks/main.yml
├── handlers/main.yml
├── files/docker-compose.yml
└── templates/env.j2
```

`tasks/main.yml`: ensure dirs, template `.env` (mode 0600), copy compose, `community.docker.docker_compose_v2` up.

## docker-compose requirements

- `networks: { proxy: { external: true } }` — container joined to `proxy` only, no host port bindings.
- Traefik labels must include `wg-only@file,security-headers@file` middlewares. Don't duplicate middlewares — reuse from `roles/traefik/templates/dynamic-middlewares.yml.j2`.

## Secrets

```bash
sudo install -m 0400 -T <(openssl rand -base64 32) /etc/homelab/secrets/<svc>_<name>
```

Add to `homelab_secret_names` in `ansible/playbooks/site.yml`.

## Register the role

Append to `ansible/playbooks/site.yml` **after** `traefik`:

```yaml
- role: <svc>
  tags: [<svc>, services]
```

## DNS

Homelab has no public IP. Two options:

- Split-horizon DNS (Pi-hole / AdGuard / `/etc/hosts`) → `*.<domain>` resolves to WG IP.
- Public CNAME to WG IP — leaks internal IP, avoid.

ACME DNS-01 works regardless — only the `_acme-challenge.<svc>.<domain>` TXT record needs Cloudflare API.

## Data persistence

Named volume or bind mount under `/opt/<svc>/data/`. Add path to `backup_paths` in `roles/backup/defaults/main.yml`.
