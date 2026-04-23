# Disaster recovery

Rebuild from: new Ubuntu box, restic repo + backend creds, this repo.

## Prerequisites

- Restic repo + backend credentials (lose backend account = backups gone).
- Restic password from bootstrap time (password manager).
- DNS control over `homelab_domain`.

## 1. Bootstrap new box

See [bootstrap.md](bootstrap.md). Differences on rebuild:

- New WG keypair — update hub peer to new pubkey.
- New SFTP key — install pubkey on provider.
- Paste the **existing** restic password, not a new one.

## 2. Restore data BEFORE first Ansible run

```bash
sudo apt install -y restic
export RESTIC_REPOSITORY=$(awk '/^restic_repo_url:/ {print $2}' /etc/homelab/config.yml | tr -d '"')
export RESTIC_PASSWORD=$(sudo cat /etc/homelab/secrets/restic_password)
sudo -E restic snapshots
sudo -E restic restore latest --target /
```

Restic preserves absolute paths — `/etc`, `/opt` land in place.

## 3. Fix perms

```bash
sudo chmod 0600 /opt/traefik/letsencrypt/acme.json
sudo chmod 0600 /etc/wireguard/wg0.conf /etc/wireguard/privatekey
sudo chown -R 472:472 /opt/observability/data/grafana
```

Prometheus/Loki/Tempo data is NOT backed up — rebuilds empty. Dashboards + alerts reprovision from repo.

## 4. Converge + verify

Push trivial commit → `deploy.yml` runs. Then from laptop on WG:

```bash
./tests/smoke.sh
```

## Home Assistant restore

HA backups are HA-native `.tar` on the Storage Box (`backup/homeassistant/`), encrypted, outside restic.

- HA up → Settings → Backups → off-site entry → Restore.
- HA gone → fresh HAOS install → Settings → Backups → Upload:
  ```bash
  scp -P 23 <SB_USER>@<SB_HOST>:backup/homeassistant/<slug>.tar .
  ```
  Paste backup password (from Vaultwarden).

No backup password = tars unrecoverable. Store it in Vaultwarden before anything else.
