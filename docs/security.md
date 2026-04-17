# Security / threat model

What's trusted, what isn't, what breaks on compromise.

## Trust boundaries

| Entity | Trust level | Attacker gets on compromise |
|--------|-------------|------------------------------|
| Upstream WG hub | Semi-trusted router | Traffic metadata. WG is end-to-end encrypted between peers, so no plaintext. Can attempt rogue peers. |
| GitHub account | Fully trusted | Root on homelab via push-to-main → deploy.yml. 2FA mandatory. |
| GitHub Actions infra | Fully trusted | Secrets (only a runner registration token lives there) pass through. |
| Self-hosted runner on homelab | Fully trusted | Scoped sudo for Ansible-required binaries. |
| Laptop | Fully trusted | SSH private key to homelab. Disk encryption + 2FA. |
| `admin_user` on homelab | Fully trusted | sudo NOPASSWD. |
| `gha-runner` user on homelab | Fully trusted | sudo (scoped). Runs whatever's on main. |
| Any other LAN device | **Untrusted** | Cannot reach homelab — firewalled to WG subnet only. |
| Random attacker on internet | **Untrusted** | No open ports on homelab. |

## How the runner works

Self-hosted runner = outbound long-poll HTTPS to GitHub. No inbound port required:

1. `Runner.Listener` connects out to `pipelines.actions.githubusercontent.com:443`.
2. Holds the TCP connection open.
3. When a matching job queues, GitHub pushes the spec over that connection.
4. Runner executes, streams logs back up.

UFW default-deny-in is unaffected — egress-only. Compromised GitHub credentials = remote execution on the homelab. 2FA and SSH commit signing are not optional.

## No secrets in git

Everything sensitive (Cloudflare token, Vaultwarden admin, restic password, SFTP key, Traefik basic-auth) lives under `/etc/homelab/secrets/` on the box. Ansible slurps them at play time. The repo contains templates and defaults only.

Implications:
- Nothing to decrypt — no SOPS vault, no age key.
- DR depends on restic restoring `/etc/homelab/secrets/` — see [restore.md](restore.md).
- Rotating a credential = ssh in, rewrite the file, re-run Ansible.

## Public-repo + self-hosted runner: the fork-PR footgun

GitHub docs warn: public repo + self-hosted runner = untrusted fork code can execute on your infra. Architected so that never happens:

| Workflow | `runs-on:` | Trigger |
|----------|-----------|---------|
| `ci.yml` | GitHub-hosted `ubuntu-24.04` | `pull_request`, `push` |
| `deploy.yml` | `[self-hosted, linux, homelab]` | `push: branches: [main]` + manual `workflow_dispatch` |

A fork PR only triggers `ci.yml` — ephemeral GitHub infra, no secrets. It cannot trigger `deploy.yml` because `pull_request` events don't push to any branch and `workflow_dispatch` requires write access to the base repo.

`deploy.yml` also has a belt-and-suspenders check at step 0: refuses to run unless `github.ref == refs/heads/main`.

## Required GitHub repository settings

These must be set manually once.

### Branch protection (Settings → Branches → `main`)

- ☑ Require a pull request before merging
  - ☑ Require approvals — `1` (yourself if solo; 2+ with others)
  - ☑ Dismiss stale pull request approvals when new commits are pushed
- ☑ Require status checks to pass before merging
  - Required: `lint`, `docker-test`
- ☑ Require conversation resolution before merging
- ☑ Require linear history
- ☑ Restrict who can push to matching branches (nobody — everything via PR)
- ☑ Require signed commits (if you've set up commit signing)

### Actions settings (Settings → Actions → General)

- Actions permissions → **Allow select actions** — allowlist the ones used.
- Fork PR workflows from outside collaborators → **Require approval for all outside collaborators**.
- Workflow permissions → **Read repository contents and packages permissions**.

### Code security

- ☑ Dependabot alerts
- ☑ Dependabot security updates
- ☑ Secret scanning + push protection

### Account-level

- ☑ 2FA (TOTP + WebAuthn)
- ☑ SSH commit signing

## Hardening already in place

- `bootstrap.sh` minimises console-time work. Everything beyond WG + user + SSH is Ansible.
- `ssh_hardening` role: key-only, modern KEX/cipher/MAC, `AllowUsers`, `MaxAuthTries=3`.
- `common` role sysctl: rp_filter, syncookies, no redirects/source-route, kptr/dmesg restrict.
- UFW default-deny-in; allow-list covers only WG subnet on 22/80/443.
- fail2ban sshd jail.
- Docker daemon.json: `no-new-privileges`, log caps, separate address pool.
- Traefik ports bound to `${WG_IP}`, not `0.0.0.0`.
- Docker GPG key fingerprint pinned + asserted during install.

## Runner: ephemeral JIT

The GitHub Actions runner registers via **JIT config** (single-use), not a persistent registration. On each job:

1. A systemd service (`gha-runner-jit.service`) invokes `/opt/homelab/bin/gha-runner-jit.sh`.
2. The wrapper reads `/etc/homelab/secrets/github_pat` + `github_repo` from `config.yml`.
3. It POSTs to `/repos/<owner>/<repo>/actions/runners/generate-jitconfig` → gets a one-shot config.
4. Wipes `_work` + `_diag` from prior run.
5. Execs `./run.sh --jitconfig <cfg>` — runner processes one job, exits.
6. systemd `Restart=always` → re-registers for the next job.

Effect: no persistent runner ID, no stale workspace between jobs, no long-lived registration that can be hijacked. PAT never leaves the box.

## Deferred (intentionally)

- **Per-service fail2ban** — only sshd jail today. Add Vaultwarden once logs warrant.
- **auditd** — adds log volume; skipped until needed.
- **WG hub IaC in this repo** — hub stays manual.

## Incident response

| Scenario | Immediate action |
|----------|------------------|
| Suspected GitHub compromise | Rotate password + 2FA. Revoke all PATs. Re-register the runner. |
| Suspected runner compromise | Stop the runner service. Audit `/opt/actions-runner/_work` and `/_diag`. Wipe and re-run bootstrap. |
| Cloudflare token leaked | Rotate in Cloudflare dashboard; `sudo install -m 0400 -T <(printf '%s' NEW) /etc/homelab/secrets/cloudflare_dns01_token`; re-run Ansible. |
| Hub compromise | Remove its pubkey from homelab's `/etc/wireguard/wg0.conf` + `wg syncconf`. Homelab is still unreachable from internet. Rebuild hub from scratch. |
| Vaultwarden compromise | Stop container, restore `/opt/vaultwarden/data` from the last clean restic snapshot, restart, force-logout all sessions via `/admin`. |
