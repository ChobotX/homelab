# Runbook

Common ops tasks, alphabetized.

## Ansible — check vs apply

```bash
# Dry-run with diff
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --check --diff

# Apply everything
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml

# One role only (meta/main.yml dependencies pull prerequisites automatically)
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags traefik
```

## Backup — trigger, inspect, restore

```bash
# Trigger now (runs the same unit the timer fires)
sudo systemctl start restic-backup.service
journalctl -u restic-backup.service -f

# Inspect
sudo systemctl list-timers restic-backup.timer
sudo bash -c '. /etc/restic/restic.env && restic snapshots'
sudo bash -c '. /etc/restic/restic.env && restic stats'

# Restore a single file to /tmp/restored
sudo bash -c '. /etc/restic/restic.env && restic restore latest --target /tmp/restored --include /etc/wireguard/wg0.conf'
```

Full disaster recovery: see [restore.md](restore.md).

## Docker — status, logs, restart

```bash
docker ps
docker compose -f /opt/traefik/docker-compose.yml logs -f
docker compose -f /opt/traefik/docker-compose.yml pull && \
  docker compose -f /opt/traefik/docker-compose.yml up -d
```

## Firewall (UFW) — check

```bash
sudo ufw status verbose
```

**Gotcha:** Docker inserts its own iptables rules that can bypass UFW. Our Traefik compose binds ports to the WG IP only (`${WG_IP}:80:80`). A host port published without the IP prefix would be reachable on any interface regardless of UFW rules.

Sanity:
```bash
sudo ss -tlnp | grep -E ':(80|443)\b'   # should only show LISTEN on 10.8.0.X
```

## Rotate — age / cloudflare / vaultwarden / restic credentials

All credentials live in `/etc/homelab/secrets/`. Overwrite the file, then dispatch a deploy (or push any change to main):

```bash
# On the box
sudo install -m 0400 -T <(printf '%s' NEWVALUE) /etc/homelab/secrets/<name>

# From the repo
gh workflow run deploy.yml --ref main -f tags=<role>
```

Per-service mapping:
- `cloudflare_dns01_token` → `--tags traefik`
- `vaultwarden_admin_token` → `--tags vaultwarden`
- `traefik_dashboard_basicauth` → `--tags traefik`
- `restic_password` / backend creds → `--tags backup`

## Rotate — WG key

```bash
# On the homelab
sudo /opt/homelab/scripts/rotate-wg-key.sh
```

Paste the new pubkey (printed by the script) into the homelab's `[Peer]` entry on the hub, reload the hub's WG, then restart the tunnel locally. See [add-peer.md](add-peer.md) for the hub-side commands.

## Runner — re-register

The ephemeral JIT runner re-registers itself on every job via the PAT in `/etc/homelab/secrets/github_pat`. To force a fresh registration:

```bash
sudo systemctl restart gha-runner-jit.service
```

To replace the PAT itself:

```bash
sudo install -m 0400 -o root -g gha-runner -T \
  <(printf '%s' 'new-pat-here') /etc/homelab/secrets/github_pat
sudo systemctl restart gha-runner-jit.service
```

To stop the runner completely (e.g. suspected compromise):

```bash
sudo systemctl stop gha-runner-jit.service
sudo systemctl disable gha-runner-jit.service
```

## SSH — reload the hardened config safely

```bash
sudo sshd -t                                           # validate first
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags ssh
```

Locked out? Console access on the box → re-run `bootstrap.sh` (resets the minimal passable config).

## Test harness — local Docker

Lightweight local test (no WG / UFW / full stack). For full E2E use a real VM.

```bash
./tests/docker/test.sh check     # lint + syntax
./tests/docker/test.sh apply     # apply common / ssh / fail2ban / docker + asserts
./tests/docker/test.sh shell     # drop into the container
./tests/docker/test.sh clean     # tear down
```

## Vaultwarden — admin panel

URL: `https://vault.<homelab_domain>/admin`. Token is in `/etc/homelab/secrets/vaultwarden_admin_token`.

To disable the admin panel entirely, overwrite the token file with an empty string — Vaultwarden treats an empty `ADMIN_TOKEN` as "disable `/admin`", not "no auth":

```bash
sudo install -m 0400 -T /dev/null /etc/homelab/secrets/vaultwarden_admin_token
gh workflow run deploy.yml --ref main -f tags=vaultwarden
```

## WireGuard — status, restart

```bash
sudo wg show
sudo systemctl restart wg-quick@wg0
journalctl -u wg-quick@wg0 --since -1h
```

Peer config change → edit `/etc/homelab/config.yml` on the box, then:

```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags wireguard
```

The handler reloads via `wg syncconf` (no interface drop), so this is safe to run over SSH through the same tunnel.
