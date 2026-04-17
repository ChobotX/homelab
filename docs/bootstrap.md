# First-time bootstrap

One command on the homelab console. Everything else is prompted or automatic.

## Prerequisites

- Fresh Ubuntu on the homelab (minimal install is fine).
- Access via console or KVM (not SSH — there's no auth yet).
- A WireGuard hub already reachable on a public IP, with admin access.
- A GitHub repo (this one, or a fork).

## Before you start — gather these

| What | How |
|------|-----|
| Laptop SSH pubkey | `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_homelab -N ''` then `cat ~/.ssh/id_ed25519_homelab.pub` |
| Hub public key | `sudo wg show` on the hub |
| Hub endpoint | `host:port` of the hub's public address |
| Base domain | yours, controlled via Cloudflare |
| Cloudflare API token | Dashboard → My Profile → API Tokens → "Edit zone DNS" on your zone |
| ACME email | for Let's Encrypt account |
| Restic repo URL | e.g. `sftp:user@host:/path`, `b2:bucket:/path`, `s3:...`  |
| Backend credentials | depends on restic backend chosen |
| GitHub PAT | fine-grained, scoped to this repo: `Administration: r/w`, `Actions: r/w`, `Contents: read` |

## Run bootstrap

On the homelab console:

```bash
git clone https://github.com/ChobotX/homelab.git /opt/homelab
cd /opt/homelab
sudo ./bootstrap.sh
```

### Prompts

bootstrap.sh walks through three groups:

**Host config** — admin user, laptop pubkey, domain, ACME email, WG addresses, hub details.

**Secrets** — Cloudflare token, Traefik dashboard password (bcrypt-hashed), restic repo URL + backend creds. The Vaultwarden admin token, Traefik basicauth, and restic password are **generated** and printed once — save them somewhere.

**Runner** — GitHub repo + PAT.

### Mid-run pauses

- After WG keys are generated, you paste the homelab's new pubkey into the hub's `wg0.conf` and reload it.
- If you're using an SFTP backend for restic, bootstrap generates an ed25519 keypair and pauses for you to add the pubkey to the provider.

### What gets written

Nothing sensitive ever touches the repo. Bootstrap writes everything to the box:

- `/etc/homelab/config.yml` — non-secret host truth, mode 0644
- `/etc/homelab/secrets/<name>` — one file per credential, mode 0400 root:root
- `/etc/wireguard/privatekey`, `/etc/wireguard/publickey`, `/etc/wireguard/hub_psk` — WG keys
- `/etc/ssh/sshd_config.d/00-bootstrap.conf` — minimal sshd hardening until Ansible takes over
- `/opt/actions-runner/` — self-hosted runner

## From now on

- Every push to `main` touching `ansible/**` or `bootstrap.sh` → `deploy.yml` runs on the homelab runner → Ansible converges.
- Manual deploy: Actions → `deploy` → Run workflow.
- Renovate opens dependency PRs weekly. Patches auto-merge after CI; majors wait for your click.

## Rerunning bootstrap

Idempotent — safe to re-run. Common reasons:

- **Update the admin SSH key**: `export LAPTOP_PUBKEY='...' && sudo -E ./bootstrap.sh --skip-runner --skip-first-run`
- **Re-register a dead runner**: re-run; give a fresh registration token or PAT.
- **Rotate the WG key**: `sudo ./bootstrap.sh --rotate-wg-key` (then update the hub peer).

## Editing secrets later

```bash
sudo $EDITOR /etc/homelab/config.yml
sudo install -m 0400 -T <(printf '%s' NEWVALUE) /etc/homelab/secrets/NAME
```

Re-run Ansible (push any trivial change or `workflow_dispatch`) to propagate.

## If something goes wrong

| Problem | Check |
|---------|-------|
| Script prompts for a value you don't have | Exit, gather it, re-run. Your earlier answers are lost — it always re-prompts. |
| "no handshake yet" warning | Hub's `AllowedIPs` must be `<homelab-ip>/32`, not the whole subnet. |
| Runner fails to register | Registration tokens expire in ~1h — regenerate with the PAT. |
| `deploy.yml` not firing on push | Settings → Actions → General → "Allow all actions and reusable workflows". |
