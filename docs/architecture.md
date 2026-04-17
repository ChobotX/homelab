# Architecture

Single-node homelab behind WireGuard. Ansible applies roles via a self-hosted GitHub Actions runner on the box itself.

## Topology

```
 laptop                                          +-----------+
   |                                             |  hub VPS  |
   | (push to main)                              | public IP |
   v                                             +-----------+
 GitHub --HTTPS long-poll-- self-hosted runner        ^
                                  |                   | WG UDP 51820
                             (ansible-playbook)       |
                                  v                   v
                         +-----------------+    +-----------+
                         | homelab         |<-- laptop (WG peer)
                         | Ubuntu + docker |<-- phone / other peers
                         | Traefik, Vault. |
                         | WG 10.8.0.6     |
                         +-----------------+
```

- **Laptop**: writes code, pushes to GitHub. Reaches the homelab over WG only (no public IP).
- **Hub**: WireGuard router. Not managed by this repo. Holds peer list.
- **Homelab**: Ubuntu, runs all services. Firewalled to WG subnet only. Runs the self-hosted runner that applies Ansible.
- **GitHub**: triggers `deploy.yml` on push; runner pulls the job via outbound long-poll.

## Role order

`ansible/playbooks/site.yml` applies roles in this order — each one depends on the previous via `meta/main.yml`:

1. **common** — base packages, timezone, journald retention, unattended-upgrades, sysctl hardening
2. **wireguard** — `wg0.conf` + enable (private key stays where bootstrap put it)
3. **ufw** — firewall: default-deny, allow 22/80/443 from WG subnet only
4. **ssh_hardening** — key-only, modern crypto, `AllowUsers`, no forwarding. Runs AFTER ufw so tightening sshd can't land before the allow rule
5. **fail2ban** — sshd jail, bans via ufw
6. **docker** — Engine + Compose plugin from upstream apt repo, GPG fingerprint asserted
7. **traefik** — reverse proxy bound to WG IP, Cloudflare DNS-01 ACME
8. **vaultwarden** — behind Traefik, hardened container (cap_drop ALL, read-only rootfs)
9. **backup** — restic systemd timer (03:00 daily)

`meta/main.yml` dependencies mean `--tags ssh` still pulls `ufw` first, so you can't accidentally tighten sshd before the firewall allows you in.

## Data flow

**Secrets** live on the box only — `/etc/homelab/secrets/<name>` (mode 0400 root:root). Ansible slurps them at play time via `ansible.builtin.slurp` + `set_fact` in `pre_tasks`. Nothing sensitive ever enters git.

**Host truth** (admin user, domain, WG addresses, hub details) lives in `/etc/homelab/config.yml` — written by `bootstrap.sh`, also slurped at play time.

**Backups** push to whatever backend `restic_repo_url` points at (SFTP / B2 / S3). `/etc/homelab/secrets/` itself is in `backup_paths`, so a restored box can re-read its own credentials.

**Certs** issue via Cloudflare DNS-01 — Traefik calls the CF API with a scoped token from `/etc/homelab/secrets/cloudflare_dns01_token`. Storage: `/opt/traefik/letsencrypt/acme.json` (mode 0600, root).

## Runner — ephemeral JIT

`gha-runner-jit.service` runs a wrapper that:

1. Reads the PAT from `/etc/homelab/secrets/github_pat`.
2. Calls GitHub's `generate-jitconfig` → gets a single-use config.
3. Wipes `_work` / `_diag` from the prior job.
4. `exec ./run.sh --jitconfig ...` — runner processes one job, exits.
5. systemd `Restart=always` → re-registers for the next job.

No persistent runner ID, no stale workspace carryover, no long-lived registration.
