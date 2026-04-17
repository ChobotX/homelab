#!/usr/bin/env bash
# Post-deploy smoke checks — runs on the homelab itself after Ansible converges.
# Each assertion fails loud on the first problem.
set -euo pipefail

fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

domain=$(awk -F'"' '/^homelab_domain:/ {print $2; exit}' /etc/homelab/config.yml)
[ -n "$domain" ] || domain=$(awk '/^homelab_domain:/ {print $2; exit}' /etc/homelab/config.yml)

systemctl is-active --quiet ssh                 || fail "ssh inactive"
ok "ssh active"

systemctl is-active --quiet fail2ban            || fail "fail2ban inactive"
ok "fail2ban active"

sudo ufw status | grep -q "Status: active"      || fail "ufw not active"
ok "ufw active"

# Containers — check they exist AND are healthy.
for name in traefik vaultwarden; do
  docker ps --format '{{.Names}}' | grep -q "^${name}$" || fail "container $name not running"
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "none")
  case "$health" in
    healthy) ok "$name healthy" ;;
    none)    ok "$name running (no healthcheck defined)" ;;
    *)       fail "$name container status: $health" ;;
  esac
done

# Traefik must NOT be serving the default (self-signed) cert — that means ACME failed.
if command -v openssl >/dev/null; then
  issuer=$(openssl s_client -connect "127.0.0.1:443" \
    -servername "vault.${domain}" </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)
  if [ -z "$issuer" ]; then
    fail "TLS handshake to vault.${domain} failed"
  fi
  echo "$issuer" | grep -qiE "let's encrypt|r[0-9]" \
    || fail "vault.${domain} serving non-LE cert: $issuer"
  ok "vault.${domain} serves LE cert ($issuer)"
fi

# Permissions that must stay tight.
sudo test "$(stat -c %a /opt/traefik/letsencrypt/acme.json)" = "600" \
  || fail "/opt/traefik/letsencrypt/acme.json perms != 600"
ok "acme.json mode 600"

systemctl is-enabled --quiet restic-backup.timer \
  || fail "restic-backup.timer not enabled"
ok "restic-backup.timer enabled"

ok "all smoke checks passed"
