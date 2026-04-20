#!/usr/bin/env bash
# Homelab bootstrap — one-time console run on a fresh Ubuntu box.
#
# Unattended. One invocation, one env file. No prompts, no pauses, no flags.
#
# Usage (from the homelab console, with USB mounted at /mnt):
#   sudo ./bootstrap.sh --env /mnt/bootstrap.env
#
# What it does (strictly the minimum needed before Ansible can take over):
#   1. Validates every required env var is present + well-formed.
#   2. Installs the base packages Ansible needs (ssh, wireguard, python3).
#   3. Creates the admin user, authorises your laptop SSH key.
#   4. Applies lockout-safe sshd hardening.
#   5. Installs the pre-generated WireGuard private key (from USB path),
#      derives the pubkey, generates a PSK, writes wg0.conf, brings it up.
#   6. Waits for the first handshake — fails fast if the hub is not configured.
#   7. Writes /etc/homelab/{config.yml,secrets/*} — dumb pipe from env vars.
#   8. Installs the ephemeral JIT GitHub Actions runner.
#   9. Dispatches deploy.yml — Ansible takes over from here.
#
# Everything else (htpasswd hashing, ssh-keyscan, random-secret generation,
# HA scrape + SMTP wiring) is Ansible's job.
#
# Pre-requisites: hub WG peer entry MUST already be in place. See docs/bootstrap.md.

set -euo pipefail
umask 077

### ---------- CLI ----------

ENV_FILE=""
print_help() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nFlags:\n  --env FILE   (required) bash-syntax env file with all inputs\n  -h, --help   show this help\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env)     ENV_FILE="${2:-}"; [ -z "$ENV_FILE" ] && { echo "--env requires FILE arg" >&2; exit 2; }; shift 2 ;;
    --env=*)   ENV_FILE="${1#--env=}"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *)         echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

### ---------- output helpers ----------

bold() { printf '\033[1m%s\033[0m' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'rm -f /tmp/ghdispatch.out' EXIT INT TERM

### ---------- validators ----------

valid_user()       { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_cidr()       { python3 -c "import sys, ipaddress; ipaddress.ip_network(sys.argv[1], strict=False)" "$1" 2>/dev/null; }
valid_port()       { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_hostport()   { [[ "$1" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; }
valid_host()       { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }
valid_b64key()     { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(echo "$1" | base64 -d 2>/dev/null | wc -c)" = 32 ]; }
valid_repo()       { [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }
valid_email()      { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_domain()     { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
valid_sshpub()     { ssh-keygen -l -f <(printf '%s\n' "$1") >/dev/null 2>&1; }
valid_restic_url() { [[ "$1" =~ ^(sftp:|s3:|b2:|azure:|gs:|rest:|/) ]]; }

### ---------- banner ----------

cat <<'BANNER'

 _                    _       _       _                 _       _
| |__   ___  _ __ ___| | __ _| |__   | |__   ___   ___ | |_ ___| |_ _ __ __ _ _ __
| '_ \ / _ \| '_ ` _ \ |/ _` | '_ \  | '_ \ / _ \ / _ \| __/ __| __| '__/ _` | '_ \
| | | | (_) | | | | | | (_| | |_) | | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
|_| |_|\___/|_| |_| |_|\__,_|_.__/  |_.__/ \___/ \___/ \__|___/\__|_|  \__,_| .__/
                                                                             |_|
BANNER

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./bootstrap.sh ...)"
[ -n "$ENV_FILE" ]   || die "--env FILE is required (see --help)"
[ -r "$ENV_FILE" ]   || die "env file unreadable: $ENV_FILE"

### ---------- phase 0: load + validate env ----------

step "Phase 0 — loading + validating $ENV_FILE"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

REQUIRED_VARS=(
  ADMIN_USER LAPTOP_PUBKEY HOMELAB_DOMAIN ACME_EMAIL
  WG_ADDRESS WG_SUBNET WG_LISTEN_PORT
  WG_PEER_PUBKEY WG_PEER_ENDPOINT WG_PEER_ALLOWED WG_PRIVATE_KEY_PATH
  CLOUDFLARE_DNS01_TOKEN TRAEFIK_DASHBOARD_USER TRAEFIK_DASHBOARD_PASSWORD
  RESTIC_REPO_URL RESTIC_SFTP_HOST RESTIC_SFTP_USER RESTIC_SFTP_PRIVATE_KEY_PATH
  GITHUB_REPO GITHUB_TOKEN
  HOMEASSISTANT_HOST HOMEASSISTANT_METRICS_TOKEN
  ALERTMANAGER_SMTP_HOST ALERTMANAGER_SMTP_FROM ALERTMANAGER_EMAIL_TO ALERTMANAGER_SMTP_PASSWORD
)
missing=()
for v in "${REQUIRED_VARS[@]}"; do
  [ -z "${!v:-}" ] && missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
  die "empty/missing required vars in $ENV_FILE: ${missing[*]}"
fi

# Format validation — single pass, precise error messages.
valid_user       "$ADMIN_USER"                     || die "ADMIN_USER invalid: $ADMIN_USER"
valid_sshpub     "$LAPTOP_PUBKEY"                  || die "LAPTOP_PUBKEY is not a parseable SSH public key"
valid_domain     "$HOMELAB_DOMAIN"                 || die "HOMELAB_DOMAIN invalid: $HOMELAB_DOMAIN"
valid_email      "$ACME_EMAIL"                     || die "ACME_EMAIL invalid: $ACME_EMAIL"
valid_cidr       "$WG_ADDRESS"                     || die "WG_ADDRESS invalid: $WG_ADDRESS"
valid_cidr       "$WG_SUBNET"                      || die "WG_SUBNET invalid: $WG_SUBNET"
valid_port       "$WG_LISTEN_PORT"                 || die "WG_LISTEN_PORT invalid: $WG_LISTEN_PORT"
valid_b64key     "$WG_PEER_PUBKEY"                 || die "WG_PEER_PUBKEY invalid (expect 44-char base64, ending =)"
valid_hostport   "$WG_PEER_ENDPOINT"               || die "WG_PEER_ENDPOINT invalid: $WG_PEER_ENDPOINT"
[ -r "$WG_PRIVATE_KEY_PATH" ]                      || die "WG_PRIVATE_KEY_PATH unreadable: $WG_PRIVATE_KEY_PATH"
valid_user       "$TRAEFIK_DASHBOARD_USER"         || die "TRAEFIK_DASHBOARD_USER invalid: $TRAEFIK_DASHBOARD_USER"
valid_restic_url "$RESTIC_REPO_URL"                || die "RESTIC_REPO_URL invalid: $RESTIC_REPO_URL"
valid_host       "$RESTIC_SFTP_HOST"               || die "RESTIC_SFTP_HOST invalid: $RESTIC_SFTP_HOST"
valid_user       "$RESTIC_SFTP_USER"               || die "RESTIC_SFTP_USER invalid: $RESTIC_SFTP_USER"
[ -r "$RESTIC_SFTP_PRIVATE_KEY_PATH" ]             || die "RESTIC_SFTP_PRIVATE_KEY_PATH unreadable: $RESTIC_SFTP_PRIVATE_KEY_PATH"
valid_repo       "$GITHUB_REPO"                    || die "GITHUB_REPO invalid: $GITHUB_REPO"
valid_hostport   "$HOMEASSISTANT_HOST"             || die "HOMEASSISTANT_HOST invalid: $HOMEASSISTANT_HOST"
valid_hostport   "$ALERTMANAGER_SMTP_HOST"         || die "ALERTMANAGER_SMTP_HOST invalid: $ALERTMANAGER_SMTP_HOST"
valid_email      "$ALERTMANAGER_SMTP_FROM"         || die "ALERTMANAGER_SMTP_FROM invalid: $ALERTMANAGER_SMTP_FROM"
valid_email      "$ALERTMANAGER_EMAIL_TO"          || die "ALERTMANAGER_EMAIL_TO invalid: $ALERTMANAGER_EMAIL_TO"

# Runner defaults — derived, not user-facing.
: "${GITHUB_RUNNER_VERSION:=2.333.1}"
: "${GITHUB_RUNNER_USER:=gha-runner}"
: "${GITHUB_RUNNER_LABELS:=self-hosted,linux,homelab}"
: "${GITHUB_RUNNER_DIR:=/opt/actions-runner}"

ok "env file validated"

### ---------- phase 1: base install ----------

step "Phase 1 — installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  openssh-server wireguard wireguard-tools sudo curl ca-certificates jq \
  openssh-client python3 ansible-core
ok "packages installed"

### ---------- phase 2: admin user + SSH ----------

step "Phase 2 — creating admin user + authorizing SSH key"
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
else
  usermod -aG sudo "$ADMIN_USER"
fi
install -d -m 0440 /etc/sudoers.d
sudofile=/etc/sudoers.d/90-${ADMIN_USER}
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$sudofile"
chmod 0440 "$sudofile"
visudo -cf "$sudofile" >/dev/null

home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0700 "$home/.ssh"
# Authoritative replace — not append — so rotating LAPTOP_PUBKEY actually rotates.
install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" \
  -T <(printf '%s\n' "$LAPTOP_PUBKEY") "$home/.ssh/authorized_keys"
ok "admin user '$ADMIN_USER' ready"

### ---------- phase 3: minimal SSH hardening ----------

step "Phase 3 — applying lockout-safe SSH hardening"
cat > /etc/ssh/sshd_config.d/00-bootstrap.conf <<EOF
# Managed by bootstrap.sh — superseded by Ansible ssh_hardening role.
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
UsePAM yes
EOF
chmod 0644 /etc/ssh/sshd_config.d/00-bootstrap.conf
sshd -t
systemctl enable --now ssh
systemctl reload ssh
ok "sshd hardened"

### ---------- phase 4: WireGuard ----------

step "Phase 4 — installing WireGuard keypair + PSK"
install -d -m 0700 /etc/wireguard
pkfile=/etc/wireguard/privatekey
pubfile=/etc/wireguard/publickey
pskfile=/etc/wireguard/hub_psk

if [ -s "$pkfile" ]; then
  note "WG private key already exists — keeping it"
else
  install -m 0600 -o root -g root -T "$WG_PRIVATE_KEY_PATH" "$pkfile"
  note "installed pre-generated WG private key from $WG_PRIVATE_KEY_PATH"
fi
wg pubkey < "$pkfile" > "$pubfile"; chmod 0644 "$pubfile"

if [ -s "$pskfile" ]; then
  note "WG preshared key already exists — keeping it"
else
  wg genpsk > "$pskfile"; chmod 0600 "$pskfile"
  note "generated preshared key (must be added on hub too)"
fi

HOMELAB_PUBKEY="$(cat "$pubfile")"
HOMELAB_PSK="$(cat "$pskfile")"
HOMELAB_CLIENT_IP="${WG_ADDRESS%/*}"

cat > /etc/wireguard/wg0.conf <<EOF
# Managed by bootstrap.sh — Ansible wireguard role takes over after first run.
[Interface]
Address = $WG_ADDRESS
ListenPort = $WG_LISTEN_PORT
PrivateKey = $(cat "$pkfile")

[Peer]
# hub
PublicKey = $WG_PEER_PUBKEY
PresharedKey = $HOMELAB_PSK
Endpoint = $WG_PEER_ENDPOINT
AllowedIPs = $WG_PEER_ALLOWED
PersistentKeepalive = 25
EOF
chmod 0600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
ok "wg0 up"

### ---------- phase 5: handshake verify ----------

step "Phase 5 — verifying handshake"
note "homelab pubkey: $HOMELAB_PUBKEY"
note "  (must already be a [Peer] on the hub with AllowedIPs = $HOMELAB_CLIENT_IP/32)"
for i in $(seq 1 15); do
  hs=$(wg show wg0 latest-handshakes | awk 'NR==1{print $2}')
  if [[ -n "${hs:-}" && "$hs" =~ ^[0-9]+$ && "$hs" -gt 0 ]]; then
    ok "handshake established $(( $(date +%s) - hs ))s ago"
    break
  fi
  sleep 2
  note "... waiting for first handshake (attempt $i/15)"
done
hs=$(wg show wg0 latest-handshakes | awk 'NR==1{print $2}')
if [[ -z "${hs:-}" || ! "$hs" =~ ^[0-9]+$ || "$hs" -le 0 ]]; then
  die "no WG handshake — is the homelab peer configured on the hub? (hub must have the pubkey above with AllowedIPs = $HOMELAB_CLIENT_IP/32)"
fi

### ---------- phase 6: write /etc/homelab/ ----------

step "Phase 6 — writing /etc/homelab/{config.yml,secrets/}"

install -d -m 0755 -o root -g root /etc/homelab
# 0701 (traverse-only for others) so the unprivileged gha-runner user can open
# specific secret files (mode 0440 root:gha-runner). 0700 would block traversal
# regardless of per-file perms.
install -d -m 0701 -o root -g root /etc/homelab/secrets

cat > /etc/homelab/config.yml <<EOF
---
# Generated by bootstrap.sh. Edit with care — Ansible slurps this on every run.
admin_user: ${ADMIN_USER}
homelab_domain: ${HOMELAB_DOMAIN}
acme_email: ${ACME_EMAIL}

wireguard_address: ${WG_ADDRESS}
wireguard_subnet: ${WG_SUBNET}
wireguard_listen_port: ${WG_LISTEN_PORT}
wireguard_peer_hub_pubkey: "${WG_PEER_PUBKEY}"
wireguard_peer_hub_endpoint: "${WG_PEER_ENDPOINT}"
wireguard_peer_hub_allowedips: "${WG_PEER_ALLOWED}"

restic_repo_url: "${RESTIC_REPO_URL}"
restic_sftp_host: "${RESTIC_SFTP_HOST}"
restic_sftp_user: "${RESTIC_SFTP_USER}"

traefik_dashboard_user: "${TRAEFIK_DASHBOARD_USER}"

github_repo: "${GITHUB_REPO}"
github_runner_labels: "${GITHUB_RUNNER_LABELS}"

homeassistant_host: "${HOMEASSISTANT_HOST}"
alertmanager_smtp_host: "${ALERTMANAGER_SMTP_HOST}"
alertmanager_smtp_from: "${ALERTMANAGER_SMTP_FROM}"
alertmanager_email_to: "${ALERTMANAGER_EMAIL_TO}"
EOF
chmod 0644 /etc/homelab/config.yml

write_secret() {
  local name="$1" value="$2"
  install -m 0400 -o root -g root -T <(printf '%s' "$value") "/etc/homelab/secrets/$name"
}

write_secret cloudflare_dns01_token      "$CLOUDFLARE_DNS01_TOKEN"
write_secret traefik_dashboard_password  "$TRAEFIK_DASHBOARD_PASSWORD"
write_secret restic_sftp_private_key     "$(cat "$RESTIC_SFTP_PRIVATE_KEY_PATH")"
write_secret github_pat                  "$GITHUB_TOKEN"
write_secret homeassistant_metrics_token "$HOMEASSISTANT_METRICS_TOKEN"
write_secret alertmanager_smtp_password  "$ALERTMANAGER_SMTP_PASSWORD"

# Generate internal passwords (idempotent — never overwrite an existing one).
# These live alongside bootstrap-written secrets so Ansible just slurps them.
# Generated here because the deploy runner (gha-runner) can't write files
# into /etc/homelab/secrets (dir mode 0701), so Ansible lookup('password', …)
# can't self-create them.
gen_secret_if_missing() {
  local name="$1" length="$2"
  local path="/etc/homelab/secrets/$name"
  [ -s "$path" ] && return 0
  install -m 0400 -o root -g root -T \
    <(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length") "$path"
}
gen_secret_if_missing vaultwarden_admin_token 64
gen_secret_if_missing restic_password         48
gen_secret_if_missing grafana_admin_password  32

ok "/etc/homelab/ populated"

### ---------- phase 7: GitHub Actions runner (ephemeral JIT) ----------

step "Phase 7 — installing ephemeral JIT self-hosted GitHub Actions runner"

# Ensure the docker group exists so runner can have docker socket access from
# first boot. Docker package is installed later by Ansible, but the group
# pre-existing is harmless — docker's postinst uses `groupadd -f` too.
groupadd -f docker
if ! id -u "$GITHUB_RUNNER_USER" >/dev/null 2>&1; then
  useradd -r -m -s /bin/bash -G docker "$GITHUB_RUNNER_USER"
else
  usermod -aG docker "$GITHUB_RUNNER_USER"
fi
# NOPASSWD:ALL is required for Ansible become. The wipe-per-job flow below
# bounds blast radius — the runner's workspace is deleted after each job.
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$GITHUB_RUNNER_USER" > "/etc/sudoers.d/91-${GITHUB_RUNNER_USER}"
chmod 0440 "/etc/sudoers.d/91-${GITHUB_RUNNER_USER}"
visudo -cf "/etc/sudoers.d/91-${GITHUB_RUNNER_USER}" >/dev/null

case "$(dpkg --print-architecture)" in
  amd64) arch=x64 ;;
  arm64) arch=arm64 ;;
  *) die "unsupported arch $(dpkg --print-architecture)" ;;
esac

install -d -o "$GITHUB_RUNNER_USER" -g "$GITHUB_RUNNER_USER" -m 0750 "$GITHUB_RUNNER_DIR"
if [ ! -x "$GITHUB_RUNNER_DIR/run.sh" ]; then
  tarball="actions-runner-linux-${arch}-${GITHUB_RUNNER_VERSION}.tar.gz"
  url="https://github.com/actions/runner/releases/download/v${GITHUB_RUNNER_VERSION}/${tarball}"
  if [ ! -s "/tmp/$tarball" ]; then
    note "downloading $url"
    curl -fsSL -o "/tmp/$tarball" "$url"
  fi
  # Extract as root (bootstrap's umask 077 leaves the tarball 0600 and
  # unreadable by gha-runner). Chown the tree afterwards.
  tar -xzf "/tmp/$tarball" -C "$GITHUB_RUNNER_DIR"
  chown -R "${GITHUB_RUNNER_USER}:${GITHUB_RUNNER_USER}" "$GITHUB_RUNNER_DIR"
  rm -f "/tmp/$tarball"
fi
[ -x "$GITHUB_RUNNER_DIR/bin/installdependencies.sh" ] && \
  "$GITHUB_RUNNER_DIR/bin/installdependencies.sh" >/dev/null || true

# Give the runner user read access to the PAT (root:gha-runner 0440).
chown "root:${GITHUB_RUNNER_USER}" /etc/homelab/secrets/github_pat
chmod 0440 /etc/homelab/secrets/github_pat

install -d -m 0755 /opt/homelab/bin
cat > /opt/homelab/bin/gha-runner-jit.sh <<'WRAPPER'
#!/usr/bin/env bash
# Ephemeral JIT runner wrapper — one job per registration, no persistent state.
set -euo pipefail
umask 077

CONFIG=/etc/homelab/config.yml
PAT_FILE=/etc/homelab/secrets/github_pat
RUNNER_DIR=/opt/actions-runner

repo=$(awk -F'"' '/^github_repo:/ {print $2; exit}' "$CONFIG")
labels=$(awk -F'"' '/^github_runner_labels:/ {print $2; exit}' "$CONFIG")
[ -n "$repo" ] && [ -n "$labels" ] || { echo "config.yml missing github_repo or github_runner_labels" >&2; exit 1; }

PAT=$(cat "$PAT_FILE")
[ -n "$PAT" ] || { echo "$PAT_FILE empty" >&2; exit 1; }

IFS=',' read -ra lbl_arr <<<"$labels"
lbl_json=$(printf '"%s",' "${lbl_arr[@]}")
lbl_json="[${lbl_json%,}]"

name="$(hostname -s)-$(date +%s)-$$"

resp=$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $PAT" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${repo}/actions/runners/generate-jitconfig" \
  -d "{\"name\":\"$name\",\"runner_group_id\":1,\"labels\":$lbl_json,\"work_folder\":\"_work\"}")

jit=$(printf '%s' "$resp" | jq -r '.encoded_jit_config // empty')
if [ -z "$jit" ]; then
  echo "JIT config fetch failed: $resp" >&2
  exit 1
fi

# Wipe workspace between jobs — defence in depth against cross-job contamination.
rm -rf "$RUNNER_DIR/_work" "$RUNNER_DIR/_diag" 2>/dev/null || true

cd "$RUNNER_DIR"
exec ./run.sh --jitconfig "$jit"
WRAPPER
chmod 0755 /opt/homelab/bin/gha-runner-jit.sh

cat > /etc/systemd/system/gha-runner-jit.service <<EOF
[Unit]
Description=GitHub Actions ephemeral JIT runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${GITHUB_RUNNER_USER}
Group=${GITHUB_RUNNER_USER}
WorkingDirectory=${GITHUB_RUNNER_DIR}
ExecStart=/opt/homelab/bin/gha-runner-jit.sh
Restart=always
RestartSec=5
KillMode=process
TimeoutStopSec=30
# No systemd sandboxing: this runner's whole job is applying Ansible, which
# needs to write /etc, /usr, /home, etc. ProtectSystem / ProtectHome block
# dpkg post-install scripts (logrotate, rsync, vim-common, …) that write
# under /etc, causing opaque "Sub-process dpkg returned 1" failures.
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF

# Drop any pre-existing persistent registration service.
if systemctl list-units --type=service --no-legend | grep -q 'actions.runner\.'; then
  note "found legacy persistent runner service — stopping + disabling"
  for u in $(systemctl list-units --type=service --no-legend | awk '/actions\.runner\./ {print $1}'); do
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
  done
fi

systemctl daemon-reload
systemctl enable --now gha-runner-jit.service
ok "ephemeral JIT runner service active"

### ---------- phase 8: dispatch first deploy ----------

step "Phase 8 — dispatching first ci.yml run (runs lint + docker-test + deploy in order)"
http=$(curl -s -o /tmp/ghdispatch.out -w '%{http_code}' \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GITHUB_REPO}/actions/workflows/ci.yml/dispatches" \
  -d '{"ref":"main"}')
if [ "$http" != "204" ]; then
  die "dispatch returned HTTP $http: $(cat /tmp/ghdispatch.out 2>/dev/null)"
fi
ok "ci.yml dispatched — watch → https://github.com/${GITHUB_REPO}/actions"

### ---------- final summary ----------

step "Bootstrap complete"
cat <<EOF
  Admin user        : ${ADMIN_USER}
  Homelab WG IP     : ${HOMELAB_CLIENT_IP}
  Homelab WG pubkey : ${HOMELAB_PUBKEY}
  Domain            : ${HOMELAB_DOMAIN}
  Self-hosted runner: registered with ${GITHUB_REPO}

Ansible takes over from here. Every push to main triggers deploy.yml on this box.
Status → https://github.com/${GITHUB_REPO}/actions

Troubleshooting:
  - tunnel:   sudo wg show
  - sshd:     systemctl status ssh
  - runner:   systemctl status gha-runner-jit
  - logs:     journalctl -u wg-quick@wg0 -u gha-runner-jit
EOF
