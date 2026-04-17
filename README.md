# Homelab

IaC for a single-node homelab server. Reachable only via WireGuard VPN (hub lives elsewhere).

## Stack

- **Ansible** — configuration management
- **WireGuard** — client-only on this box
- **UFW + fail2ban** — baseline firewall & intrusion prevention
- **Docker + Compose** — application services
- **Traefik** — reverse proxy, Let's Encrypt via Cloudflare DNS-01
- **Vaultwarden** — self-hosted Bitwarden (runtime/personal secrets)
- **Observability** — Grafana + Prometheus + Loki + Tempo + Alertmanager + Alloy (logs, metrics, traces, alerts for this host + Home Assistant on the VPN)
- **restic** — encrypted offsite backups

## Design

- **No secrets in git** — host-truth + credentials live on the box under `/etc/homelab/`, generated or entered during bootstrap. The repo is just code + defaults.
- **Self-hosted CI** — a GitHub Actions runner on the homelab applies Ansible on every push to `main`. No inbound port; runner long-polls out.
- **One-shot bootstrap** — `bootstrap.sh` on the console prepares the box; thereafter every change is a git push.

## Quick start

### Homelab console (once)

```bash
git clone https://github.com/ChobotX/homelab.git /opt/homelab
cd /opt/homelab
sudo ./bootstrap.sh
```

Interactive — prompts for admin user, WG config, hub details, Cloudflare token,
restic settings, GitHub PAT. Generates passwords + keypairs itself where it can
(Vaultwarden admin token, Traefik basicauth, restic password, WG keypair, SFTP
keypair when needed) and writes them to `/etc/homelab/secrets/` on the box.

Pauses once so you can add the homelab as a peer on the hub. Finishes by
registering the runner and (optionally) dispatching the first deploy.

From then on: every push to `main` → `deploy.yml` → Ansible converges locally.

### Laptop prerequisites

- `git`, `gh`, `yq` (tests only)
- A dedicated SSH key for the homelab (`ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_homelab`)
- A GitHub PAT for bootstrap — fine-grained, scoped to this repo: `Administration: r/w`, `Actions: r/w`, `Contents: read`

## Daily ops

- Architecture + role order → [docs/architecture.md](docs/architecture.md)
- Configuration index → [docs/configuration.md](docs/configuration.md)
- Security / threat model → [docs/security.md](docs/security.md)
- CI / CD flow → [docs/ci.md](docs/ci.md)
- Updates (auto-patches, Renovate, approve majors) → [docs/updates.md](docs/updates.md)
- Add a service → [docs/add-service.md](docs/add-service.md)
- Add a WG peer → [docs/add-peer.md](docs/add-peer.md)
- Common tasks → [docs/runbook.md](docs/runbook.md)
- Disaster recovery → [docs/restore.md](docs/restore.md)

## Testing

Before committing:

```bash
./tests/docker/test.sh apply
```

Spins up a throwaway container, stubs `/etc/homelab/`, applies the roles that
don't need kernel features, and verifies the result. Cleanup: `clean`.

Full end-to-end (WireGuard, UFW, Traefik, Vaultwarden, backup) needs a real
VM — Multipass, Vagrant, or equivalent.

## Repo structure

```
ansible/              # playbook + roles with defaults/ + meta/
bootstrap.sh          # one-time console bootstrap, idempotent
docs/                 # operational docs
tests/smoke.sh        # post-deploy verification (run from laptop, WG connected)
tests/docker/         # container-based Ansible harness
```
