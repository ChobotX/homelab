# Adding a new service behind Traefik

Pattern: each service = one Ansible role + one docker-compose stack in `/opt/<svc>/` on the box, joined to the external `proxy` network, configured via Traefik labels.

## Steps

### 1. Pick the service name + host

Say you want to add Nextcloud at `cloud.<homelab_domain>`.

- Role directory: `ansible/roles/nextcloud/`
- Stack directory on box: `/opt/nextcloud/`
- Host: `nextcloud_host: "cloud.{{ homelab_domain }}"` in `roles/nextcloud/defaults/main.yml`

### 2. Role scaffold

Copy the structure from `roles/vaultwarden/` — it is the canonical minimal example:

```
ansible/roles/nextcloud/
├── tasks/main.yml
├── handlers/main.yml
├── files/docker-compose.yml
└── templates/env.j2
```

`tasks/main.yml` only does:
1. Ensure `/opt/nextcloud` + data dirs exist.
2. Template `.env` (mode 0600).
3. Copy `docker-compose.yml`.
4. `community.docker.docker_compose_v2` up.

### 3. docker-compose.yml

Required:
- `networks: { proxy: { external: true } }`
- Container joined to `proxy` only (no host port bindings — Traefik handles ingress).
- Traefik labels:

```yaml
labels:
  traefik.enable: "true"
  traefik.docker.network: "proxy"
  traefik.http.routers.nextcloud.rule: "Host(`${NEXTCLOUD_HOST}`)"
  traefik.http.routers.nextcloud.entrypoints: "websecure"
  traefik.http.routers.nextcloud.tls: "true"
  traefik.http.routers.nextcloud.tls.certresolver: "cloudflare"
  traefik.http.routers.nextcloud.middlewares: "wg-only@file,security-headers@file"
  traefik.http.services.nextcloud.loadbalancer.server.port: "80"
```

`wg-only@file` + `security-headers@file` come from `roles/traefik/templates/dynamic-middlewares.yml.j2`. Reuse, don't duplicate.

### 4. Secrets

Anything sensitive lives on the box under `/etc/homelab/secrets/`:

```bash
# On the homelab
sudo install -m 0400 -T <(openssl rand -base64 32) /etc/homelab/secrets/nextcloud_db_password
```

Add the name to `homelab_secret_names` in `ansible/playbooks/site.yml` so the slurp step picks it up.

### 5. Register the role

Append to `ansible/playbooks/site.yml`, **after** `traefik`:

```yaml
- role: nextcloud
  tags: [nextcloud, services]
```

### 6. DNS

Add a DNS A record in Cloudflare: `cloud.<domain>` → homelab's public IP? No — **the homelab has no public IP**. Two options:

- **Split-horizon DNS**: configure your laptop / phone to resolve `*.<homelab_domain>` to the homelab WG IP. Easiest via Pi-hole / AdGuard Home on the homelab itself, then point VPN clients at it as DNS. Or `/etc/hosts` entries.
- **Public CNAME / A record to WG IP**: works but leaks the internal IP to the public internet. Avoid.

ACME DNS-01 doesn't need the hostname to resolve — only the `_acme-challenge.cloud.<domain>` TXT record, which Cloudflare handles via API. So Let's Encrypt issues certs regardless of A-record presence.

### 7. Deploy

```bash
ansible-playbook -i inventory.yml playbooks/site.yml --tags nextcloud
```

### 8. Verify

```bash
curl -k https://cloud.<homelab_domain>      # from VPN, should return Nextcloud
docker ps | grep nextcloud
docker compose -f /opt/nextcloud/docker-compose.yml logs
```

## Gotchas

- **Bind ports only to WG IP** if the service also needs host-exposed ports for some reason. Default: no host ports, Traefik is the only ingress.
- **Data persistence**: use a named volume or bind mount under `/opt/<svc>/data/`, and add the path to `backup_paths` in `roles/backup/defaults/main.yml`.
- **Traefik label escaping**: under docker-compose, `${...}` gets interpolated at compose-up time. If you need a literal `$`, double it (`$$`).
