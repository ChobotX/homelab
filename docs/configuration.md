# Configuration index

Where each tunable lives.

## Layout

| File / dir | Scope | Notes |
|------|------|------|
| `/etc/homelab/config.yml` | host-truth, on the box | Written by `bootstrap.sh`; Ansible slurps it on every run |
| `/etc/homelab/secrets/<name>` | secrets, on the box | One file per credential, mode 0400 root:root |
| `ansible/group_vars/all.yml` | repo-committed globals | timezone, locale |
| `ansible/roles/<role>/defaults/main.yml` | repo-committed per-role defaults | Override via `/etc/homelab/config.yml` if needed |
| `ansible/inventory.yml` | repo-committed | SSH target only; connection user lives in your `~/.ssh/config` |

Rule of thumb:
- **Secret** → `/etc/homelab/secrets/<name>` (never in repo)
- **Host-specific or identifying** → `/etc/homelab/config.yml` (never in repo)
- **Per-role tunable with a sensible default** → `roles/<role>/defaults/main.yml`
- **Truly global** → `group_vars/all.yml`

## Host-truth (`/etc/homelab/config.yml`)

Written by `bootstrap.sh`; loaded into the play via `slurp` + `set_fact` at run time.

| Variable | What |
|----------|------|
| `admin_user` | Sudo user, `AllowUsers` in sshd, owner of `/home/<user>` |
| `homelab_domain` | Base domain — Cloudflare must control it |
| `acme_email` | Let's Encrypt account email |
| `wireguard_address` | Homelab's IP inside the VPN (CIDR form) |
| `wireguard_subnet` | Full VPN subnet (UFW allow rules + fail2ban ignore) |
| `wireguard_listen_port` | UDP listen port on this peer |
| `wireguard_peer_hub_pubkey` | Hub public key |
| `wireguard_peer_hub_endpoint` | `host:port` |
| `wireguard_peer_hub_allowedips` | What routes through the hub (usually the full VPN subnet) |
| `restic_repo_url` | Restic repo URL (`sftp:...`, `b2:...`, `s3:...`) |
| `restic_sftp_host` / `_user` | SFTP host + user (only when using SFTP backend) |
| `homeassistant_host` | Optional — HA `host:port` to scrape `/api/prometheus` (e.g. `10.8.0.5:8123`) |
| `alertmanager_smtp_host` | Optional — SMTP relay `host:port` for email alerts |
| `alertmanager_smtp_from` / `_email_to` | From + destination for alert emails |

## Secrets (`/etc/homelab/secrets/<name>`)

One file per secret, mode 0400 root:root. Generated or prompted during bootstrap.

| File | Source |
|------|--------|
| `cloudflare_dns01_token` | Prompted — Zone:DNS:Edit token |
| `vaultwarden_admin_token` | Generated if absent (64 chars) |
| `traefik_dashboard_basicauth` | Generated from prompted plaintext password (bcrypt via `htpasswd`) |
| `restic_password` | Generated if absent (48 chars) |
| `restic_sftp_private_key` | Generated on box; pubkey printed for you to install on the SFTP provider |
| `grafana_admin_password` | Generated if absent (32 chars) — Grafana `admin` login |
| `alertmanager_smtp_password` | Prompted, optional — SMTP password (skip = no email alerts) |
| `homeassistant_metrics_token` | Prompted, optional — HA long-lived access token (skip = no HA scrape) |
| `restic_sftp_known_hosts` | Populated via `ssh-keyscan` of the SFTP host |
| `restic_b2_account_id` / `_key` | Prompted — only if using B2 backend |
| `restic_aws_access_key_id` / `_secret_access_key` | Prompted — only if using S3 backend |

## Role defaults

`ansible/roles/<role>/defaults/main.yml` — inspect each role for its tunables. Override by setting the same name in `/etc/homelab/config.yml`.

- **common** — package list, journald retention, unattended-upgrades mode/reboot/mail, APT pin list
- **ssh_hardening** — KEX / cipher / MAC / host-key / pubkey algorithm lists
- **ufw** — logging level
- **fail2ban** — bantime, findtime, maxretry, SSH jail mode
- **docker** — Docker GPG fingerprint (pin)
- **wireguard** — MTU, peer keepalive, peer label
- **traefik** — image tag, cert resolver name, dashboard host
- **vaultwarden** — image tag, service host, signup/invitation policy
- **backup** — timer calendar, paths, excludes, retention counts
- **observability** — image tags for 6 containers, retention (Prom 30d / Loki 14d / Tempo 7d), memory caps, UIDs, optional HA + SMTP toggles

## Globals (`ansible/group_vars/all.yml`)

| Variable | What |
|----------|------|
| `ansible_python_interpreter` | Suppresses discovery warnings |
| `timezone` | `timedatectl set-timezone` |
| `locale` | `locale-gen` |

## SSH connection (`ansible/inventory.yml`)

Only `ansible_host` and `ansible_port` live here. Connection user + key come from your `~/.ssh/config` (`Host homelab ...`) or `--user` / `-i` flags. When CI deploys, `deploy.yml` overrides with `ansible_connection: local`.
