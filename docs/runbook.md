# Runbook

Common ops tasks. Alphabetized.

## Docker-based test harness

Ephemeral Ubuntu 24 container, applies kernel-independent roles:

```bash
./tests/docker/test.sh check     # lint + syntax only
./tests/docker/test.sh apply     # apply common + ssh + fail2ban + docker, run sanity asserts
./tests/docker/test.sh shell     # drop into the running container
./tests/docker/test.sh clean     # tear down
```

For full E2E (WG + UFW + Traefik + Vaultwarden + backup) use a real Ubuntu 24
VM — Multipass, Vagrant, or a throwaway cloud instance.

## Ansible — check vs apply

```bash
# Dry-run with diff
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --check --diff

# Apply everything
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml

# Apply one role only
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags traefik

# Run against a single host (we only have one, but habit-forming)
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --limit homelab
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
docker compose -f /opt/traefik/docker-compose.yml pull && docker compose -f /opt/traefik/docker-compose.yml up -d
```

## Firewall (UFW) — check

```bash
sudo ufw status verbose
```

**Critical gotcha:** Docker inserts its own iptables rules that can bypass UFW. Our Traefik compose binds ports to the **WG IP only** (`${WG_IP}:80:80` in `roles/traefik/files/docker-compose.yml`). If you ever publish a container port without the IP prefix, it WILL be reachable on any interface regardless of UFW rules.

Sanity check:
```bash
sudo ss -tlnp | grep -E ':(80|443)\b'     # should only show LISTEN on 10.8.0.X
```

## Secrets — edit on the box

```bash
# On the homelab
sudo $EDITOR /etc/homelab/config.yml                   # non-secret host truth
sudo install -m 0400 -T <(printf '%s' NEWVALUE) /etc/homelab/secrets/NAME
```

Rotating the Cloudflare token? Overwrite the file, then dispatch a deploy (or push any change):
```bash
# From the repo
gh workflow run deploy.yml --ref main -f tags=traefik
```
Traefik picks up the new token on restart.

## SSH — reload the hardened config safely

```bash
# Validate first
sudo sshd -t

# Apply via Ansible (preferred)
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags ssh
```

If you ever lock yourself out: console access on the box → re-run `bootstrap.sh` (it resets the minimal passable config).

## Vaultwarden — admin panel

URL: `https://vault.<homelab_domain>/admin`. Token is `vaultwarden_admin_token` from the vault.

Disable after initial setup if you want to minimize attack surface — set `ADMIN_TOKEN=` (empty) in the `.env` and redeploy.

## WireGuard — status, restart

```bash
sudo wg show
sudo systemctl restart wg-quick@wg0
journalctl -u wg-quick@wg0 --since -1h
```

Change peer config → edit `/etc/homelab/config.yml` on the box, then:
```bash
ansible-playbook -i ansible/inventory.yml ansible/playbooks/site.yml --tags wireguard
```

## Why did the playbook change nothing? (debugging idempotency)

```bash
ansible-playbook ... --check --diff -v
```
`-v` shows skipped tasks and why. If something looks wrong on the box but Ansible says "no changes", someone edited files manually — re-run **without** `--check` to force Ansible's version.
