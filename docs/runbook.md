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

## Dashboards — add or change

Everything in Grafana is provisioned from committed files. UI "Save" is a no-op on restart.

**Add a dashboard:**
1. In Grafana UI, build and test it.
2. Share → Export → "Export for sharing externally" = OFF → Save to file.
3. Commit the JSON to `ansible/roles/observability/files/dashboards/<name>.json`.
4. `git push` — next deploy renders it under the *Homelab* folder.

**Change a dashboard:** same as above, overwrite the existing JSON.

Alert rules are the same story but under `ansible/roles/observability/files/alert-rules.yml`.

## Grafana — login

URL: `https://grafana.<homelab_domain>`. Username `admin`, password in `/etc/homelab/secrets/grafana_admin_password`.

Over WG only (`wg-only@file` middleware rejects anything outside the VPN subnet).

```bash
# Rotate admin password
sudo install -m 0400 -T <(openssl rand -base64 24) /etc/homelab/secrets/grafana_admin_password
gh workflow run deploy.yml --ref main -f tags=observability
```

## Home Assistant — off-site backups (native → CIFS)

HAOS (RPi4) uses its built-in Backup integration writing directly to the Hetzner Storage Box over CIFS. Not in the homelab's restic repo — separate retention, separate restore flow. Chosen because HA state is small (hundreds of MB), native UI is zero-maintenance, and no addon/restic key material needs to live on the HA box.

**HA-side config (one-time, all via HA UI):**

1. Ensure Samba/CIFS is enabled on the Storage Box (Hetzner Robot → Storage Box → Settings → Samba/CIFS).
2. HA → Settings → System → Storage → Add network storage:
   - Name: `hetzner_storage_box`
   - Usage: Backup
   - Server: `u578479.your-storagebox.de`
   - Protocol: Samba/CIFS, version Auto (2.1+)
   - Share: `backup` (or `backup/homeassistant` to land in a subdir)
   - User: `u578479`
   - Password: Storage Box account password (same one used elsewhere; no separate Samba password for the main user)
3. HA → Settings → System → Backups → ⋮ → Automatic backups:
   - Schedule: daily at a fixed time (e.g. `02:30`). `time: null` = HA picks a random slot and backups land mid-day — set it explicitly.
   - Retention: `Copies to keep` = 7 (or matches homelab's 7d).
   - Encryption: ON. **Save the backup password in Vaultwarden immediately** — lose it, tars decrypt is impossible.
   - Locations: tick `hetzner_storage_box` + `This system` (one local copy for fast restore).
   - Include: HA config + all add-ons + folders (`share`, `ssl` as needed).

**Verify a backup landed on the box:**

```bash
ssh -p 23 u578479@u578479.your-storagebox.de 'ls -la backup/homeassistant/ 2>/dev/null | tail'
# or just backup/ if no subdir
```

Expect at least one `.tar`. Cross-check in HA: `ssh homeassistant 'cat /mnt/data/supervisor/homeassistant/.storage/backup'` — look at `last_completed_automatic_backup`.

**The homelab's restic repo is untouched by HA.** No host-scoping interaction, no shared locks, no shared retention.

## Home Assistant — ship logs + metrics

HA (HAOS on RPi4) is a first-class homelab observability citizen via WireGuard. Metrics are pulled; logs are pushed.

### Metrics (Prometheus pulls)

1. On the HA box, enable the [Prometheus integration](https://www.home-assistant.io/integrations/prometheus/) in `/config/configuration.yaml`:
   ```yaml
   prometheus:
     namespace: hass
   ```
   Restart HA (`ha core restart`). Without this, `/api/prometheus` returns 404 and the scrape shows `health=down`.
2. Create a Long-Lived Access Token (HA → Profile → Security → Long-Lived Access Tokens).
3. On the homelab, put the token in `/etc/homelab/secrets/homeassistant_metrics_token` and add `homeassistant_host: "<ip>:8123"` to `/etc/homelab/config.yml` (WG IP like `10.8.0.7:8123` once HA is a WG peer at host level, or a LAN IP routed via WG).
4. Deploy — Prometheus scrape kicks in on next reload.

Dashboard: Grafana auto-provisions **Home Assistant** (folder *Homelab*) — up status, entity count, sensor temps/humidity/battery/kWh, and a live error/warn log panel. PromQL assumes `namespace: hass`.

### Logs (Alloy on HAOS pushes to Loki)

HA Core does not forward logs natively. Run Grafana Alloy on HAOS itself — it reads journald (which captures HA Core, add-ons, supervisor, host) and pushes to the homelab's Loki push endpoint over WG.

**Pre-req — HAOS is a WG peer at host level (not inside the add-on):**

1. Generate keypair + PSK on HAOS (use the WG add-on container's `wg` binary, e.g. `docker exec addon_a0d7b954_wireguard wg genkey | tee priv | wg pubkey`).
2. Add a peer entry on the Hetzner hub (`tauri-hetzner:/etc/wireguard/wg0.conf`) with the new pubkey and a free `10.8.0.X/32` AllowedIP, then `wg syncconf wg0 <(wg-quick strip wg0)`.
3. Drop a NetworkManager connection on HAOS at `/etc/NetworkManager/system-connections/wg0.nmconnection`:
   ```ini
   [connection]
   id=wg0
   type=wireguard
   interface-name=wg0
   autoconnect=true

   [wireguard]
   private-key=<HAOS private key>
   listen-port=51821
   mtu=1420

   [wireguard-peer.cqwla9881cTaocDouZZacygTDEOYXztyR+BL8EVdOxw=]
   endpoint=159.69.40.75:51820
   preshared-key=<PSK>
   preshared-key-flags=0
   persistent-keepalive=25
   allowed-ips=10.8.0.0/24;

   [ipv4]
   method=manual
   address1=10.8.0.X/32
   route-metric=50
   never-default=true

   [ipv6]
   method=disabled
   ```
   `chmod 600` the file, then `nmcli connection reload && nmcli connection up wg0`.
4. Verify from HA Core container: `docker exec homeassistant ping 10.8.0.6`.

Note: listen port `51821` avoids clashing with the legacy WG add-on (`51820`) during migration. Decommission the add-on peer once host-level WG is stable.

**Alloy container on HAOS** (unmanaged docker, not a supervisor add-on):

Config at `/mnt/data/alloy/config/config.alloy`:
```alloy
logging { level = "warn", format = "logfmt" }

loki.write "default" {
  endpoint { url = "http://10.8.0.6:3100/loki/api/v1/push" }
}

loki.source.journal "hass" {
  path          = "/var/log/journal"
  max_age       = "12h"
  forward_to    = [loki.relabel.hass.receiver]
  labels        = { job = "homeassistant", host = "haos" }
  relabel_rules = loki.relabel.journal_meta.rules
}

loki.relabel "journal_meta" {
  forward_to = []
  rule { source_labels = ["__journal__systemd_unit"]       target_label = "unit" }
  rule { source_labels = ["__journal_container_name"]      target_label = "container" }
  rule { source_labels = ["__journal_priority_keyword"]    target_label = "level" }
  rule { source_labels = ["__journal__hostname"]           target_label = "host" }
}

loki.relabel "hass" { forward_to = [loki.write.default.receiver] }
```

Start:
```bash
ssh homeassistant 'docker run -d --name alloy --restart unless-stopped --network host --user 0:0 \
  -v /var/log/journal:/var/log/journal:ro \
  -v /run/log/journal:/run/log/journal:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  -v /mnt/data/alloy/config/config.alloy:/etc/alloy/config.alloy:ro \
  -v /mnt/data/alloy/data:/var/lib/alloy \
  grafana/alloy:v1.5.1 \
  run --server.http.listen-addr=10.8.0.7:12345 --storage.path=/var/lib/alloy /etc/alloy/config.alloy'
```

The HTTP server binds to the HAOS host WG IP (10.8.0.7) so homelab Prom can scrape Alloy at `http://10.8.0.7:12345/metrics` — job `homeassistant-alloy`. `HomeAssistantAlloyDown` alert fires if this scrape goes to 0 for 10m (dead container, dead tunnel, dead HAOS).

Loki push endpoint is published on `10.8.0.6:3100` by the observability compose (`${WG_IP}:3100:3100/tcp`) — WG-only, no extra auth needed. Query: `{job="homeassistant"}` in the Loki datasource.

**Caveat**: HA supervisor flags this as `unsupported: ["software"]` because `grafana/alloy` is not a supervisor-managed add-on. It's a banner only — HA Core + add-ons + HA Cloud all keep working. Tried packaging as a local add-on: failed because HA's add-on sandbox blocks bind-mounting `/var/log/journal` (and `docker_api: true` only exposes supervisor's REST proxy, not the Docker socket). Accepted trade-off for journald coverage.

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

## Observability — logs, metrics, traces, alerts

Everything is in Grafana at `https://grafana.<homelab_domain>`.

| Question | Where to look |
|---|---|
| "Is the host OK?" | Home dashboard (CPU / Mem / Disk stats at top) |
| "Which containers are heavy right now?" | Home dashboard → Container CPU / Memory panels |
| "What did Vaultwarden log at 02:17?" | Explore → Loki → `{container="vaultwarden"}` |
| "Show me every 5xx Traefik served today" | Explore → Loki → `{job="traefik"} \| json \| status >= 500` |
| "Why was that request slow?" | Click any Traefik log → `TraceID` derived field → Tempo trace |
| "Is Home Assistant alive?" | `up{job="homeassistant"}` in Prometheus |
| "What's currently alerting?" | Grafana → Alerting menu (reads from Alertmanager) |

CLI:
```bash
# Alert state
curl -s http://localhost:9093/api/v2/alerts | jq '.[] | {alertname: .labels.alertname, state: .status.state}'

# Silence something for 2h
amtool alert add --alertmanager.url=http://localhost:9093 silence \
  --comment="investigating" --duration=2h alertname=HostHighCpuLoad

# Prometheus quick query
curl -sG http://localhost:9090/api/v1/query --data-urlencode 'query=up' | jq
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
