# Disaster recovery

Full rebuild: new Ubuntu box, restic repo + backend creds, this repo.

## Prerequisites (must still exist)

- The **restic repo** and backend credentials. If the backend account is lost, backups are gone.
- The **restic password** you were given at bootstrap time (and, ideally, saved in a password manager).
- DNS control over `homelab_domain` via Cloudflare (re-create API token if needed).

## Step 1 — provision a new homelab box

Install Ubuntu minimal. Get console / KVM access. Note the LAN / static config.

## Step 2 — run bootstrap.sh

Same as first-time bootstrap ([bootstrap.md](bootstrap.md)) — but:

- The new box generates a **new WG keypair**; update the hub peer entry to the new pubkey.
- The new box generates a **new SFTP key** (if using SFTP); add the pubkey to the provider.
- Bootstrap prompts for the restic password. Paste the one you saved previously — not generate a new one — otherwise you won't be able to decrypt existing snapshots.

## Step 3 — restore data BEFORE Ansible touches services

If you let the `vaultwarden` / `traefik` / `backup` roles run first, they create empty data dirs and your restore step has to stop them first. Order:

```bash
# On the new homelab, as root
sudo apt install -y restic
# Source the env restic expects
set -a; . /etc/restic/restic.env 2>/dev/null || true; set +a
# If restic.env doesn't exist yet (Ansible hasn't run), build it from /etc/homelab/
export RESTIC_REPOSITORY=$(awk '/^restic_repo_url:/ {print $2}' /etc/homelab/config.yml | tr -d '"')
export RESTIC_PASSWORD=$(sudo cat /etc/homelab/secrets/restic_password)

# Verify repo is reachable
sudo -E restic snapshots

# Restore everything — restic preserves absolute paths, so /etc, /opt land in place.
sudo -E restic restore latest --target /
```

## Step 4 — fix perms (restic restores ownership, but verify)

```bash
sudo chmod 0600 /opt/traefik/letsencrypt/acme.json
sudo chmod 0600 /etc/wireguard/wg0.conf /etc/wireguard/privatekey
sudo chown -R root:root /opt/traefik /opt/vaultwarden
sudo chown -R 472:472 /opt/observability/data/grafana      # Grafana UID
```

Metrics/logs/traces (`data/prometheus`, `data/loki`, `data/tempo`) are **not** in the backup — they rebuild from scratch after redeploy. Grafana dashboards, datasources, and alert rules come back immediately via provisioning from the committed repo.

## Step 5 — Ansible converge

Push a trivial commit, or Actions → `deploy` → Run workflow. The homelab runner catches it and `ansible-playbook` runs.

## Step 6 — verify

From your laptop (WG connected):

```bash
./tests/smoke.sh
```

Check Vaultwarden: open `https://vault.<domain>`, log in with your existing Bitwarden account (data is in the restored `/opt/vaultwarden/data`).

## Testing the DR plan

Do a restore drill at least once on a throwaway VM. Walk steps 1-6. If it takes more than an hour or hits any blocker, fix the runbook *before* you need it for real.
