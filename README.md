# Homelab

IaC for a single-node homelab server. Reachable only via WireGuard VPN (hub lives elsewhere).

## Stack

- **Ansible** — configuration management
- **WireGuard** — client-only on this box
- **UFW + fail2ban** — baseline firewall & intrusion prevention
- **Docker + Compose** — application services
- **Traefik** — reverse proxy, Let's Encrypt via Cloudflare DNS-01
- **Vaultwarden** — self-hosted Bitwarden (runtime/personal secrets)
- **Homepage** — signpost at `home.<homelab_domain>` linking every UI with live status tiles
- **Observability** — Grafana + Prometheus + Loki + Tempo + Alertmanager + Alloy
- **restic** — encrypted offsite backups

## Design

- **No secrets in git** — host-truth + credentials live on the box under `/etc/homelab/`, generated or entered during bootstrap. The repo is code + defaults only.
- **Self-hosted CI** — a GitHub Actions runner on the homelab applies Ansible on every push to `main`. No inbound port.
- **One-shot bootstrap** — `bootstrap.sh` prepares the box; thereafter every change is a git push.

## Quick start

```bash
git clone <your-fork-of-this-repo> /opt/homelab
cd /opt/homelab
cp docs/bootstrap.env.example bootstrap.env   # fill in + put on USB
sudo ./bootstrap.sh --env /mnt/bootstrap.env
```

See [docs/bootstrap.md](docs/bootstrap.md) for the full flow.

## Docs

- [bootstrap.md](docs/bootstrap.md) — first-time setup
- [bootstrap.env.example](docs/bootstrap.env.example) — required vars
- [restore.md](docs/restore.md) — disaster recovery
- [add-peer.md](docs/add-peer.md) — new WG peer
- [add-service.md](docs/add-service.md) — new service behind Traefik
- [github-settings.md](docs/github-settings.md) — one-time repo settings

## Testing

```bash
./tests/docker/test.sh apply   # throwaway container, applies kernel-independent roles
```

Full end-to-end (WG, UFW, Traefik) needs a real VM.
