#!/usr/bin/env bash
# End-to-end smoke test for the homelab stack. Run from your laptop, VPN connected.
#
# Env overrides (all read from ansible/inventory.yml + host_vars by default):
#   HOMELAB_HOST     — SSH target
#   HOMELAB_USER     — SSH user
#   HOMELAB_KEY      — SSH key
#   HOMELAB_DOMAIN   — base domain for Traefik host rules (required for HTTPS checks)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Host + domain come from the homelab itself (not the repo — no config in git).
# Set HOMELAB_HOST / HOMELAB_DOMAIN in env, or configure a `Host homelab` entry
# in ~/.ssh/config and rely on defaults.
command -v yq >/dev/null || { echo "yq required (brew install yq)" >&2; exit 2; }

INV_HOST=$(yq -r '.all.children.homelab_servers.hosts.homelab.ansible_host' \
  "$REPO_ROOT/ansible/inventory.yml")

HOST="${HOMELAB_HOST:-$INV_HOST}"
USER="${HOMELAB_USER:-$(whoami)}"
KEY="${HOMELAB_KEY:-$HOME/.ssh/id_ed25519_homelab}"
DOMAIN="${HOMELAB_DOMAIN:-}"

[ -n "$HOST" ] && [ "$HOST" != "null" ] || { echo "inventory missing ansible_host"; exit 2; }

SSH_OPTS=(-i "$KEY" -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

pass=0; fail=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$name"
    pass=$((pass+1))
  else
    printf '  ✗ %s\n' "$name"
    fail=$((fail+1))
  fi
}

r() { ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" "$@"; }

echo "[smoke] target: ${USER}@${HOST}"

echo "[smoke] SSH + WG"
check "ssh reachable"                r 'true'
check "wg interface up"               r 'sudo wg show wg0 >/dev/null 2>&1'
check "wg handshake fresh (<5min)"    r "test \$(date +%s) -lt \$(( \$(sudo wg show wg0 latest-handshakes | awk '{print \$2}') + 300 ))"

echo "[smoke] system baseline"
check "ufw active"                    r 'sudo ufw status | grep -q "Status: active"'
check "fail2ban running"              r 'systemctl is-active --quiet fail2ban'
check "sshd password auth disabled"   r 'sudo sshd -T | grep -qx "passwordauthentication no"'
check "journald retention set"        r 'test -f /etc/systemd/journald.conf.d/retention.conf'

echo "[smoke] docker"
check "docker running"                r 'systemctl is-active --quiet docker'
check "traefik container running"     r 'docker ps --format "{{.Names}}" | grep -q "^traefik$"'
check "vaultwarden container running" r 'docker ps --format "{{.Names}}" | grep -q "^vaultwarden$"'
check "proxy network exists"          r 'docker network inspect proxy >/dev/null'

echo "[smoke] traefik security"
check "acme.json exists"              r 'test -f /opt/traefik/letsencrypt/acme.json'
check "acme.json mode 0600"           r 'test "$(stat -c %a /opt/traefik/letsencrypt/acme.json)" = "600"'
WG_IP_PREFIX=$(echo "$HOST" | awk -F. '{print $1"."$2"."$3"."}')
check "traefik bound to WG IP only"   r "sudo ss -tlnp | awk '\$4 ~ /:(80|443)\$/ && \$4 !~ /:${WG_IP_PREFIX//./\\.}/ {exit 1}'"

echo "[smoke] backup"
check "restic installed"              r 'command -v restic >/dev/null'
check "backup timer enabled"          r 'systemctl is-enabled --quiet restic-backup.timer'

if [ -n "$DOMAIN" ]; then
  echo "[smoke] HTTPS (requires DNS resolution to WG IP)"
  check "vault.$DOMAIN alive"          curl -sSfL --max-time 10 "https://vault.${DOMAIN}/alive"
else
  echo "[smoke] HTTPS skipped (set HOMELAB_DOMAIN to enable)"
fi

echo
printf '[smoke] %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
