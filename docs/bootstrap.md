# First-time bootstrap

Unattended. One env file on USB, one command on the homelab console.

## Prerequisites

- Fresh Ubuntu 24 on the homelab, console/KVM access.
- WG hub reachable on a public IP, admin access.
- GitHub repo (this, or a fork) + fine-grained PAT (Admin r/w, Actions r/w, Contents r).
- Cloudflare API token (Zone:DNS:Edit).
- SFTP target for restic.
- SMTP relay (optional — email alerts).

## 1. On your Mac

Generate WG keypair:

```bash
wg genkey | tee homelab_wg_privkey | wg pubkey > homelab_wg_pubkey
chmod 0400 homelab_wg_privkey
```

Add homelab as `[Peer]` on the hub (see [add-peer.md](add-peer.md)).

Fill env:

```bash
cp docs/bootstrap.env.example bootstrap.env
${EDITOR:-vi} bootstrap.env
```

Required vars are flagged in the example. Optional extras (homepage tiles, reverse-uptime targets) leave empty to hide. File is gitignored.

Copy to USB: `bootstrap.env`, WG privkey, SFTP privkey.

## 2. On the homelab console

```bash
git clone <repo-url> /opt/homelab
cd /opt/homelab
sudo mount /dev/sdb1 /mnt
sudo ./bootstrap.sh --env /mnt/bootstrap.env
```

8 phases, no prompts. Fails fast with precise error on bad env.

## What Ansible does (first deploy)

- Generates internal secrets (vaultwarden admin token, restic password, grafana admin password, ntfy bridge webhook).
- Hashes Traefik dashboard password via `htpasswd -nbB`.
- `ssh-keyscan`s SFTP host → `/root/.ssh/known_hosts_sb`.
- Wires Prometheus HA scrape + Alertmanager SMTP.
- Full stack: docker, ufw, fail2ban, observability, Traefik, Vaultwarden, backup timer.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `empty/missing required vars` | Fill the named var in `bootstrap.env`, re-run. |
| `no WG handshake` after 30s | Hub missing homelab pubkey. Verify on hub: `sudo wg show`. |
| Runner fails to register | PAT expired or missing Admin r/w. |
| `deploy.yml` not firing | Settings → Actions → "Allow all actions and reusable workflows". |

Bootstrap is idempotent — safe to re-run.
