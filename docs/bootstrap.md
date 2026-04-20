# First-time bootstrap

Unattended. One env file on USB, one command on the homelab console, zero prompts.

## Prerequisites

- Fresh Ubuntu 24 on the homelab (minimal install is fine). Console or KVM access.
- A WireGuard hub reachable on a public IP, with admin access.
- A GitHub repo (this one, or a fork) + a fine-grained PAT.
- A Cloudflare API token for DNS-01.
- An SFTP target for restic (e.g. Hetzner Storage Box).
- Home Assistant reachable over the tunnel + a long-lived access token.
- An SMTP relay for alert emails.

## 1. On your Mac — prepare the USB

### Generate the WireGuard keypair

```bash
wg genkey | tee homelab_wg_privkey | wg pubkey > homelab_wg_pubkey
chmod 0400 homelab_wg_privkey
```

### Add the homelab as a [Peer] on the hub

SSH into the hub and append:

```ini
[Peer]
# homelab
PublicKey = <contents of homelab_wg_pubkey>
AllowedIPs = 10.8.0.6/32
```

Reload:

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
sudo wg show
```

You should see the new peer listed.

### Fill in `bootstrap.env`

```bash
cp docs/bootstrap.env.example bootstrap.env
${EDITOR:-vi} bootstrap.env
```

Every variable is required and non-empty. The file is gitignored — keep it on your laptop + USB.

### Copy everything to the USB

```bash
cp bootstrap.env homelab_wg_privkey ~/.ssh/id_ed25519_homelab_sb /Volumes/USB/
```

Three files on the stick: the env file, the WG private key, the SFTP private key (path in env file must match).

## 2. On the homelab console — one command

```bash
git clone https://github.com/ChobotX/homelab.git /opt/homelab
cd /opt/homelab
sudo mount /dev/sdb1 /mnt
sudo ./bootstrap.sh --env /mnt/bootstrap.env
```

That's it. Bootstrap runs through 8 phases with no prompts, no pauses. If any required variable is empty or malformed the script fails fast with a precise error naming the variable.

## What bootstrap does

| Phase | What |
|-------|------|
| 0 | Load + validate `bootstrap.env` |
| 1 | Install base packages (`openssh-server`, `wireguard`, `python3`, …) |
| 2 | Create admin user, authorise the laptop SSH key |
| 3 | Lockout-safe sshd hardening |
| 4 | Install WG private key from USB, write `wg0.conf`, bring up `wg0` |
| 5 | Wait for the first handshake (fails fast if the hub peer is missing) |
| 6 | Write `/etc/homelab/config.yml` + `/etc/homelab/secrets/*` |
| 7 | Install ephemeral JIT GitHub Actions runner (systemd unit) |
| 8 | Dispatch `deploy.yml` — Ansible takes over |

## What Ansible does (everything else)

Bootstrap is a dumb pipe. The actual setup happens on the first Ansible deploy:

- Generates internal secrets (`vaultwarden_admin_token`, `restic_password`, `grafana_admin_password`) and caches them in `/etc/homelab/secrets/`.
- Hashes `traefik_dashboard_password` via `htpasswd -nbB` into a Traefik basicauth line.
- `ssh-keyscan`s the SFTP host and writes `/root/.ssh/known_hosts_sb`.
- Wires up Prometheus scrape for Home Assistant and the Alertmanager email receiver.
- Everything else (docker, ufw, fail2ban, observability stack, Traefik, Vaultwarden, backup timer).

## Files written by bootstrap

| Path | Mode | Purpose |
|------|------|---------|
| `/etc/homelab/config.yml` | 0644 | Non-secret host truth, slurped by Ansible |
| `/etc/homelab/secrets/*` | 0400 root:root | One file per externally-provided secret |
| `/etc/wireguard/{privatekey,publickey,hub_psk,wg0.conf}` | 0600 / 0644 | WG state |
| `/etc/ssh/sshd_config.d/00-bootstrap.conf` | 0644 | Baseline sshd hardening |
| `/opt/actions-runner/` | 0750 gha-runner | Self-hosted runner |
| `/etc/systemd/system/gha-runner-jit.service` | 0644 | Runner systemd unit |
| `/opt/homelab/bin/gha-runner-jit.sh` | 0755 | JIT registration wrapper |

## From now on

- Every push to `main` touching `ansible/**` or `bootstrap.sh` → `deploy.yml` runs on the homelab runner → Ansible converges.
- Manual deploy: Actions → `deploy` → Run workflow.
- Renovate opens dependency PRs weekly. Patches auto-merge after CI; majors wait for your click.

## Re-running bootstrap

Idempotent — safe to re-run with the same (or updated) env file. Common reasons:

- Update the admin SSH key → edit `LAPTOP_PUBKEY` in `bootstrap.env`, re-run.
- Rotate the WG key → run `sudo ./scripts/rotate-wg-key.sh` (then update the hub peer).
- Re-register a dead runner → bump `GITHUB_TOKEN` if expired, re-run.

## Editing secrets later

```bash
sudo $EDITOR /etc/homelab/config.yml
sudo install -m 0400 -T <(printf '%s' NEWVALUE) /etc/homelab/secrets/NAME
```

Re-run Ansible (push any trivial change or `workflow_dispatch`) to propagate.

## If something goes wrong

| Problem | Check |
|---------|-------|
| `empty/missing required vars in <file>: …` | Fill those variables in `bootstrap.env` and re-run. |
| `no WG handshake` after 30 s | Hub must have the homelab's pubkey with `AllowedIPs = 10.8.0.6/32`. Confirm on the hub with `sudo wg show`. |
| Runner fails to register | PAT expired or missing `Administration: r/w` — regenerate at https://github.com/settings/personal-access-tokens. |
| `deploy.yml` not firing | Settings → Actions → General → "Allow all actions and reusable workflows". |
