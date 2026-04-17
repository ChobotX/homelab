#!/usr/bin/env bash
# Homelab bootstrap — one-time console run on a fresh Ubuntu box.
#
# Idempotent. Safe to re-run.
#
# What it does:
#   1. Installs base packages, creates the admin user, authorises your laptop SSH key.
#   2. Applies lockout-safe sshd hardening.
#   3. Generates a WireGuard keypair + preshared key. Pauses while you add the
#      resulting pubkey to your hub peer list.
#   4. Prompts for / generates all secrets and writes:
#        /etc/homelab/config.yml          host-truth values (mode 0644)
#        /etc/homelab/secrets/<NAME>      one file per secret (mode 0400)
#      Nothing sensitive ever enters the repo.
#   5. Installs the self-hosted GitHub Actions runner and (optionally) kicks
#      off the first `deploy.yml` run via the provided PAT.
#
# CLI flags: see --help.
set -euo pipefail
umask 077

### ---------- CLI ----------

YES=0; SKIP_RUNNER=0; SKIP_FIRST_RUN=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)         YES=1 ;;
    --skip-runner)    SKIP_RUNNER=1 ;;
    --skip-first-run) SKIP_FIRST_RUN=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

### ---------- output helpers ----------

bold()  { printf '\033[1m%s\033[0m' "$*"; }
ok()    { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
step()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
note()  { printf '    %s\n' "$*"; }
warn()  { printf '\n\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()   { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

pause() {
  [ "$YES" = "1" ] && return 0
  local prompt="${1:-Press Enter to continue (Ctrl-C to abort)}"
  printf '\n%s: ' "$prompt"
  IFS= read -r _ </dev/tty || true
}

trap 'rm -f /tmp/ghrt.json /tmp/ghdispatch.out /tmp/bootstrap.*.$$' EXIT INT TERM

### ---------- validators ----------

valid_user()      { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_cidr()      { python3 -c "import sys, ipaddress; ipaddress.ip_network(sys.argv[1], strict=False)" "$1" 2>/dev/null; }
valid_port()      { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_hostport()  { [[ "$1" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; }
valid_host()      { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }
valid_b64key()    { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$(echo "$1" | base64 -d 2>/dev/null | wc -c)" = 32 ]; }
valid_repo()      { [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }
valid_email()     { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_domain()    { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; }
valid_sshpub()    {
  ssh-keygen -l -f <(printf '%s\n' "$1") >/dev/null 2>&1
}
valid_restic_url() { [[ "$1" =~ ^(sftp:|s3:|b2:|azure:|gs:|rest:|/) ]]; }

### ---------- prompt helper ----------
# ASK VAR "question" [default] [validator_fn] [secret?]
ASK() {
  local var=$1 q=$2 def=${3:-} validator=${4:-} secret=${5:-0}
  local cur; cur="${!var:-}"
  if [ -n "$cur" ]; then
    if [ -z "$validator" ] || "$validator" "$cur"; then
      [ "$secret" = "1" ] && note "$var = (set via env)" || note "$var = $cur"
      return 0
    fi
    warn "$var pre-set but failed validation; re-prompting"
  fi
  if [ "$YES" = "1" ]; then
    die "$var not set and --yes given; export $var before running"
  fi
  local hint="" ans
  [ -n "$def" ] && hint=" [$def]"
  while :; do
    if [ "$secret" = "1" ]; then
      printf '    %s%s: ' "$q" "$hint" >&2
      IFS= read -r -s ans </dev/tty; echo >&2
    else
      printf '    %s%s: ' "$q" "$hint" >&2
      IFS= read -r ans </dev/tty
    fi
    [ -z "$ans" ] && ans="$def"
    if [ -z "$ans" ]; then
      warn "value required"; continue
    fi
    if [ -n "$validator" ] && ! "$validator" "$ans"; then
      warn "invalid value"; continue
    fi
    printf -v "$var" '%s' "$ans"
    export "${var?}"
    return 0
  done
}

# Like ASK but allows empty value (for optional secrets). No default fallback.
ASK_OPT() {
  local var=$1 q=$2 secret=${3:-0}
  local cur; cur="${!var:-}"
  if [ -n "$cur" ]; then return 0; fi
  [ "$YES" = "1" ] && return 0
  local ans
  if [ "$secret" = "1" ]; then
    printf '    %s (blank to skip): ' "$q" >&2
    IFS= read -r -s ans </dev/tty; echo >&2
  else
    printf '    %s (blank to skip): ' "$q" >&2
    IFS= read -r ans </dev/tty
  fi
  printf -v "$var" '%s' "${ans:-}"
  export "${var?}"
}

### ---------- banner ----------

cat <<'BANNER'

 _                    _       _       _                 _       _
| |__   ___  _ __ ___| | __ _| |__   | |__   ___   ___ | |_ ___| |_ _ __ __ _ _ __
| '_ \ / _ \| '_ ` _ \ |/ _` | '_ \  | '_ \ / _ \ / _ \| __/ __| __| '__/ _` | '_ \
| | | | (_) | | | | | | (_| | |_) | | |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
|_| |_|\___/|_| |_| |_|\__,_|_.__/  |_.__/ \___/ \___/ \__|___/\__|_|  \__,_| .__/
                                                                             |_|
BANNER

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./bootstrap.sh)"

### ---------- phase 0: collect host-truth config ----------

step "Phase 0 — collecting host configuration"

note "Press Enter to accept defaults shown in [brackets]. Ctrl-C to abort."
echo

: "${ADMIN_USER:=}"
ASK ADMIN_USER        "admin username on this box" "chobotx" valid_user

ASK LAPTOP_PUBKEY     "laptop SSH public key (one line)" "${LAPTOP_PUBKEY:-}" valid_sshpub

ASK HOMELAB_DOMAIN    "base domain (e.g. homelab.example.com)" "" valid_domain
ASK ACME_EMAIL        "ACME / Let's Encrypt contact email" "" valid_email

ASK WG_ADDRESS        "homelab WG client address (CIDR)" "10.8.0.6/24" valid_cidr
ASK WG_SUBNET         "WG subnet (CIDR)" "10.8.0.0/24" valid_cidr
ASK WG_LISTEN_PORT    "WG listen port" "51820" valid_port
ASK WG_PEER_PUBKEY    "hub public key (wg format, 44 chars ending =)" "" valid_b64key
ASK WG_PEER_ENDPOINT  "hub endpoint (host:port)" "" valid_hostport
ASK WG_PEER_ALLOWED   "subnets routed via hub (CIDR)" "$WG_SUBNET" valid_cidr

### ---------- phase 0b: collect / generate secrets ----------

step "Phase 0b — collecting / generating secrets"

# External-service tokens — must be provided.
ASK CLOUDFLARE_DNS01_TOKEN "Cloudflare DNS-01 API token (Zone:DNS:Edit)" "" "" 1

# Traefik dashboard — prompt for plaintext password, generate htpasswd line.
: "${TRAEFIK_DASHBOARD_USER:=admin}"
ASK TRAEFIK_DASHBOARD_USER "Traefik dashboard username" "admin" valid_user
if [ -z "${TRAEFIK_DASHBOARD_BASICAUTH:-}" ]; then
  ASK TRAEFIK_DASHBOARD_PASSWORD "Traefik dashboard password (will be bcrypt-hashed)" "" "" 1
fi

# Restic repo URL + backend-specific creds.
ASK RESTIC_REPO_URL   "restic repo URL (sftp:/b2:/s3:/ etc.)" "" valid_restic_url

RESTIC_BACKEND=${RESTIC_REPO_URL%%:*}
case "$RESTIC_BACKEND" in
  sftp)
    # SFTP repo → we'll generate an ed25519 key if user doesn't already have one.
    ASK RESTIC_SFTP_HOST "SFTP host for restic (e.g. u1234.storage.example.com)" "" valid_host
    ASK RESTIC_SFTP_USER "SFTP user" "" valid_user
    ;;
  b2)
    ASK_OPT RESTIC_B2_ACCOUNT_ID  "B2 account ID"  1
    ASK_OPT RESTIC_B2_ACCOUNT_KEY "B2 account key" 1
    ;;
  s3)
    ASK_OPT RESTIC_AWS_ACCESS_KEY_ID     "AWS access key id"     1
    ASK_OPT RESTIC_AWS_SECRET_ACCESS_KEY "AWS secret access key" 1
    ;;
esac

if [ "$SKIP_RUNNER" = "0" ]; then
  ASK GITHUB_REPO  "GitHub repo (owner/name)" "" valid_repo

  note "Fine-grained PAT scoped to ${GITHUB_REPO} — required for ephemeral JIT runner registration."
  note "Permissions: Administration: r/w, Actions: r/w, Contents: read."
  note "https://github.com/settings/personal-access-tokens/new"
  ASK GITHUB_TOKEN "GitHub PAT" "" "" 1

  : "${GITHUB_RUNNER_VERSION:=2.321.0}"
  : "${GITHUB_RUNNER_USER:=gha-runner}"
  : "${GITHUB_RUNNER_LABELS:=self-hosted,linux,homelab}"
  : "${GITHUB_RUNNER_DIR:=/opt/actions-runner}"
fi

# Observability — optional Home Assistant scrape + optional alert email.
note "Observability — leave blank to skip HA scrape / email alerts."
ASK_OPT HOMEASSISTANT_HOST         "Home Assistant host:port (e.g. 10.8.0.5:8123)"
ASK_OPT HOMEASSISTANT_METRICS_TOKEN "Home Assistant long-lived access token" 1
ASK_OPT ALERTMANAGER_SMTP_HOST     "SMTP relay host:port for alert emails (e.g. smtp.fastmail.com:587)"
if [ -n "${ALERTMANAGER_SMTP_HOST:-}" ]; then
  ASK ALERTMANAGER_SMTP_FROM       "SMTP From address" "" valid_email
  ASK ALERTMANAGER_EMAIL_TO        "Alert destination email" "" valid_email
  ASK_OPT ALERTMANAGER_SMTP_PASSWORD "SMTP password" 1
fi

echo
ok "configuration captured"

### ---------- phase 1: base install ----------

step "Phase 1 — installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  openssh-server wireguard wireguard-tools sudo curl ca-certificates jq \
  openssh-client apache2-utils openssl python3
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

### ---------- phase 4: WireGuard keys ----------

step "Phase 4 — ensuring WireGuard keypair + PSK"
install -d -m 0700 /etc/wireguard
pkfile=/etc/wireguard/privatekey
pubfile=/etc/wireguard/publickey
pskfile=/etc/wireguard/hub_psk

if [ -s "$pkfile" ]; then
  note "WG private key already exists — keeping it"
  note "To rotate: sudo scripts/rotate-wg-key.sh (then update hub peer)"
else
  wg genkey > "$pkfile"; chmod 0600 "$pkfile"
fi
wg pubkey < "$pkfile" > "$pubfile"; chmod 0644 "$pubfile"

if [ -s "$pskfile" ]; then
  note "WG preshared key already exists — keeping it"
else
  wg genpsk > "$pskfile"; chmod 0600 "$pskfile"
  ok "generated preshared key (must be added on hub too)"
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
ok "WG config written"

### ---------- phase 5: hub manual step ----------

step "Phase 5 — ADD HOMELAB AS PEER ON THE HUB"
cat <<EOF

Append to the hub's /etc/wireguard/wg0.conf:

$(bold '────────── copy this block ──────────')
[Peer]
# homelab
PublicKey = ${HOMELAB_PUBKEY}
PresharedKey = ${HOMELAB_PSK}
AllowedIPs = ${HOMELAB_CLIENT_IP}/32
$(bold '─────────────────────────────────────')

Then reload on the hub:
    sudo wg syncconf wg0 <(sudo wg-quick strip wg0)

Verify on the hub:
    sudo wg show
(should list 'homelab' peer)

EOF
pause "Press Enter once the peer is added on the hub"

### ---------- phase 6: bring tunnel up + verify ----------

step "Phase 6 — bringing up wg0 and verifying handshake"
systemctl start wg-quick@wg0
sleep 2
if ! wg show wg0 >/dev/null 2>&1; then
  die "wg0 interface didn't come up; check 'journalctl -u wg-quick@wg0'"
fi
handshake_ok=0
for i in $(seq 1 15); do
  hs=$(wg show wg0 latest-handshakes | awk 'NR==1{print $2}')
  if [[ -n "${hs:-}" && "$hs" =~ ^[0-9]+$ && "$hs" -gt 0 ]]; then
    ok "handshake established $(( $(date +%s) - hs ))s ago"
    handshake_ok=1
    break
  fi
  sleep 2
  note "... waiting for first handshake (attempt $i/15)"
done
if [ "$handshake_ok" = 0 ]; then
  warn "no handshake yet — check hub's AllowedIPs matches ${HOMELAB_CLIENT_IP}/32"
  [ "$YES" = "1" ] && die "--yes mode: refusing to continue without handshake"
  pause "Investigate, then press Enter to continue anyway"
fi

### ---------- phase 6b: restic SFTP key (if SFTP) ----------

if [ "$RESTIC_BACKEND" = "sftp" ]; then
  step "Phase 6b — generating SFTP key + fetching known_hosts"
  sftp_priv=/tmp/bootstrap.sftp_key.$$
  sftp_pub=${sftp_priv}.pub
  if [ -n "${RESTIC_SFTP_PRIVATE_KEY:-}" ]; then
    note "using RESTIC_SFTP_PRIVATE_KEY from env"
    printf '%s' "$RESTIC_SFTP_PRIVATE_KEY" > "$sftp_priv"
    chmod 0400 "$sftp_priv"
    ssh-keygen -y -f "$sftp_priv" > "$sftp_pub"
  else
    ssh-keygen -t ed25519 -N '' -f "$sftp_priv" -C "homelab->${RESTIC_SFTP_HOST}" >/dev/null
    cat <<EOF

$(bold 'Add this public key to your SFTP provider authorized_keys:')

$(cat "$sftp_pub")

EOF
    pause "Press Enter once the key is added on the SFTP provider"
  fi
  RESTIC_SFTP_PRIVATE_KEY="$(cat "$sftp_priv")"
  RESTIC_SFTP_KNOWN_HOSTS="$(ssh-keyscan -t ed25519,rsa "$RESTIC_SFTP_HOST" 2>/dev/null || true)"
  [ -n "$RESTIC_SFTP_KNOWN_HOSTS" ] || warn "ssh-keyscan returned no host keys for $RESTIC_SFTP_HOST"
  rm -f "$sftp_priv" "$sftp_pub"
  ok "SFTP key + known_hosts ready"
fi

### ---------- phase 7: write /etc/homelab/ ----------

step "Phase 7 — writing /etc/homelab/{config.yml,secrets/}"

install -d -m 0755 -o root -g root /etc/homelab
install -d -m 0700 -o root -g root /etc/homelab/secrets

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
EOF
if [ "$RESTIC_BACKEND" = "sftp" ]; then
  cat >> /etc/homelab/config.yml <<EOF
restic_sftp_host: "${RESTIC_SFTP_HOST}"
restic_sftp_user: "${RESTIC_SFTP_USER}"
EOF
fi
if [ "$SKIP_RUNNER" = "0" ]; then
  cat >> /etc/homelab/config.yml <<EOF

# Self-hosted runner identity — used by the JIT wrapper.
github_repo: "${GITHUB_REPO}"
github_runner_labels: "${GITHUB_RUNNER_LABELS}"
EOF
fi
if [ -n "${HOMEASSISTANT_HOST:-}" ]; then
  cat >> /etc/homelab/config.yml <<EOF

# Observability — Home Assistant scrape target.
homeassistant_host: "${HOMEASSISTANT_HOST}"
EOF
fi
if [ -n "${ALERTMANAGER_SMTP_HOST:-}" ]; then
  cat >> /etc/homelab/config.yml <<EOF

# Observability — alert email routing.
alertmanager_smtp_host: "${ALERTMANAGER_SMTP_HOST}"
alertmanager_smtp_from: "${ALERTMANAGER_SMTP_FROM}"
alertmanager_email_to:  "${ALERTMANAGER_EMAIL_TO}"
EOF
fi
chmod 0644 /etc/homelab/config.yml

write_secret() {
  local name="$1" value="$2"
  [ -z "$value" ] && return 0
  install -m 0400 -o root -g root -T <(printf '%s' "$value") "/etc/homelab/secrets/$name"
}

# Generate what we can; persist what the user typed.
: "${VAULTWARDEN_ADMIN_TOKEN:=$(openssl rand -base64 48 | tr -d '\n=/+' | head -c 64)}"
: "${RESTIC_PASSWORD:=$(openssl rand -base64 48 | tr -d '\n=/+' | head -c 48)}"
: "${GRAFANA_ADMIN_PASSWORD:=$(openssl rand -base64 24 | tr -d '\n=/+' | head -c 32)}"

if [ -z "${TRAEFIK_DASHBOARD_BASICAUTH:-}" ]; then
  # htpasswd -nb generates "user:$2y$...", we double $ for docker-compose env interpolation.
  TRAEFIK_DASHBOARD_BASICAUTH="$(htpasswd -nbB "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')"
fi

write_secret cloudflare_dns01_token       "$CLOUDFLARE_DNS01_TOKEN"
write_secret vaultwarden_admin_token      "$VAULTWARDEN_ADMIN_TOKEN"
write_secret traefik_dashboard_basicauth  "$TRAEFIK_DASHBOARD_BASICAUTH"
write_secret restic_password              "$RESTIC_PASSWORD"
if [ "$RESTIC_BACKEND" = "sftp" ]; then
  write_secret restic_sftp_private_key    "$RESTIC_SFTP_PRIVATE_KEY"
  write_secret restic_sftp_known_hosts    "${RESTIC_SFTP_KNOWN_HOSTS:-}"
fi
write_secret restic_b2_account_id         "${RESTIC_B2_ACCOUNT_ID:-}"
write_secret restic_b2_account_key        "${RESTIC_B2_ACCOUNT_KEY:-}"
write_secret restic_aws_access_key_id     "${RESTIC_AWS_ACCESS_KEY_ID:-}"
write_secret restic_aws_secret_access_key "${RESTIC_AWS_SECRET_ACCESS_KEY:-}"
write_secret grafana_admin_password       "$GRAFANA_ADMIN_PASSWORD"
write_secret alertmanager_smtp_password   "${ALERTMANAGER_SMTP_PASSWORD:-}"
write_secret homeassistant_metrics_token  "${HOMEASSISTANT_METRICS_TOKEN:-}"
[ "$SKIP_RUNNER" = "0" ] && write_secret github_pat "$GITHUB_TOKEN"
ok "/etc/homelab/ populated"

cat <<EOF

$(bold 'Save these somewhere safe — you will need them for first login:')
  Vaultwarden /admin token: ${VAULTWARDEN_ADMIN_TOKEN}
  Traefik dashboard user  : ${TRAEFIK_DASHBOARD_USER}
  (Traefik dashboard password was what you typed)
  restic password         : ${RESTIC_PASSWORD}
  Grafana admin (user: admin): ${GRAFANA_ADMIN_PASSWORD}

EOF
pause "Press Enter when you've recorded them"

### ---------- phase 8: GitHub Actions runner (ephemeral JIT) ----------

if [ "$SKIP_RUNNER" = "1" ]; then
  warn "skipping runner install (--skip-runner)"
else
  step "Phase 8 — installing ephemeral JIT self-hosted GitHub Actions runner"

  if ! id -u "$GITHUB_RUNNER_USER" >/dev/null 2>&1; then
    useradd -r -m -s /bin/bash "$GITHUB_RUNNER_USER"
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
    note "downloading $url"
    curl -fsSL -o "/tmp/$tarball" "$url"
    sudo -u "$GITHUB_RUNNER_USER" tar -xzf "/tmp/$tarball" -C "$GITHUB_RUNNER_DIR"
    rm -f "/tmp/$tarball"
  fi
  [ -x "$GITHUB_RUNNER_DIR/bin/installdependencies.sh" ] && \
    "$GITHUB_RUNNER_DIR/bin/installdependencies.sh" >/dev/null || true

  # Give the runner user read access to the PAT (root:gha-runner 0440).
  # config.yml is already 0644 — runner can read it.
  chown "root:${GITHUB_RUNNER_USER}" /etc/homelab/secrets/github_pat
  chmod 0440 /etc/homelab/secrets/github_pat

  # JIT wrapper — fetches a one-shot JIT config from GitHub, then execs the
  # runner. Runner exits after one job, systemd restarts us, we re-register.
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

# Labels as JSON array
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
# Narrow privileges outside the runner's work dir.
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=false
# Runner workspace must be writable.
ReadWritePaths=${GITHUB_RUNNER_DIR}

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
fi

### ---------- phase 9: optional first-run trigger ----------

if [ "$SKIP_FIRST_RUN" = "1" ]; then
  warn "skipping first-run trigger (--skip-first-run)"
elif [ "$SKIP_RUNNER" = "1" ]; then
  warn "runner not installed → cannot trigger deploy.yml"
elif [ -z "${GITHUB_TOKEN:-}" ]; then
  note "no PAT given → first deploy will fire next time you push to main"
else
  step "Phase 9 — dispatching first deploy.yml run"
  http=$(curl -s -o /tmp/ghdispatch.out -w '%{http_code}' \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GITHUB_REPO}/actions/workflows/deploy.yml/dispatches" \
    -d '{"ref":"main"}')
  if [ "$http" = "204" ]; then
    ok "deploy.yml dispatched"
    note "watch → https://github.com/${GITHUB_REPO}/actions"
  else
    warn "dispatch returned HTTP $http: $(cat /tmp/ghdispatch.out 2>/dev/null)"
  fi
fi

### ---------- final summary ----------

step "Bootstrap complete"
cat <<EOF
  Admin user        : ${ADMIN_USER}
  Homelab WG IP     : ${HOMELAB_CLIENT_IP}
  Homelab WG pubkey : ${HOMELAB_PUBKEY}
  Domain            : ${HOMELAB_DOMAIN}
  Self-hosted runner: $([ "$SKIP_RUNNER" = "1" ] && echo skipped || echo "registered with ${GITHUB_REPO}")

From now on every push to main triggers deploy.yml on this box.
Status → https://github.com/${GITHUB_REPO}/actions

Troubleshooting:
  - tunnel:   sudo wg show
  - sshd:     systemctl status ssh
  - runner:   systemctl status 'actions.runner.*'
  - logs:     journalctl -u wg-quick@wg0 -u 'actions.runner.*'

Editing secrets later:
  sudo $EDITOR /etc/homelab/config.yml
  sudo install -m 0400 -T <(printf '%s' NEWVALUE) /etc/homelab/secrets/NAME
EOF
