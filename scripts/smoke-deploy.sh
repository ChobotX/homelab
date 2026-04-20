#!/usr/bin/env bash
# Post-deploy smoke checks — runs on the homelab itself after Ansible converges.
# Each assertion fails loud on the first problem.
set -euo pipefail

fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

domain=$(awk -F'"' '/^homelab_domain:/ {print $2; exit}' /etc/homelab/config.yml)
[ -n "$domain" ] || domain=$(awk '/^homelab_domain:/ {print $2; exit}' /etc/homelab/config.yml)

# Traefik only port-publishes on the WG IP (not 0.0.0.0), so loopback gets
# ECONNREFUSED. Read it straight from the wg0 interface the host already has.
wg_ip=$(ip -4 addr show wg0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
[ -n "$wg_ip" ] || fail "could not determine wg0 IP"

systemctl is-active --quiet ssh                 || fail "ssh inactive"
ok "ssh active"

systemctl is-active --quiet fail2ban            || fail "fail2ban inactive"
ok "fail2ban active"

sudo ufw status | grep -q "Status: active"      || fail "ufw not active"
ok "ufw active"

# Containers — check they exist AND are healthy. Resolve by compose-service
# label rather than container name: alertmanager runs under docker-rollout,
# which drops container_name to allow scale=2 during blue/green swaps.
for svc in traefik vaultwarden grafana prometheus loki tempo alertmanager alloy; do
  cid=$(sudo docker ps --filter "label=com.docker.compose.service=${svc}" --format '{{.ID}}' | head -n1)
  [ -n "$cid" ] || fail "service $svc not running"
  # Without the {{if}} guard, Go template errors on containers with no
  # healthcheck (e.g. alloy) — it prints a stray newline to stdout and
  # exits 1, so `|| echo "none"` would capture "\nnone" and fail the
  # case match below.
  health=$(sudo docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "none")
  case "$health" in
    healthy) ok "$svc healthy" ;;
    none)    ok "$svc running (no healthcheck defined)" ;;
    *)       fail "$svc container status: $health" ;;
  esac
done

# Traefik must NOT be serving the default (self-signed) cert — that means ACME failed.
if command -v openssl >/dev/null; then
  issuer=$(openssl s_client -connect "${wg_ip}:443" \
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
# `sudo test ... $(stat ...)` puts stat outside the sudo scope so it fails
# with EACCES on a 0600 root-owned file — wrap stat in sudo instead.
mode=$(sudo stat -c %a /opt/traefik/letsencrypt/acme.json)
[ "$mode" = "600" ] || fail "/opt/traefik/letsencrypt/acme.json perms != 600 (got $mode)"
ok "acme.json mode 600"

systemctl is-enabled --quiet restic-backup.timer \
  || fail "restic-backup.timer not enabled"
ok "restic-backup.timer enabled"

# Observability stack sanity.
if command -v openssl >/dev/null; then
  issuer=$(openssl s_client -connect "${wg_ip}:443" \
    -servername "grafana.${domain}" </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)
  [ -n "$issuer" ] || fail "TLS handshake to grafana.${domain} failed"
  echo "$issuer" | grep -qiE "let's encrypt|r[0-9]" \
    || fail "grafana.${domain} serving non-LE cert: $issuer"
  ok "grafana.${domain} serves LE cert"
fi

sudo docker exec prometheus wget -qO- http://localhost:9090/-/ready 2>/dev/null | grep -qi "ready" \
  || fail "prometheus not ready"
ok "prometheus ready"

targets_up=$(sudo docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null \
  | grep -c '"health":"up"' || true)
[ "${targets_up:-0}" -ge 1 ] || fail "no prometheus targets up"
ok "prometheus targets up (${targets_up})"

# Alertmanager ready — reach it via its compose service name (no container_name
# after the docker-rollout migration).
am_cid=$(sudo docker ps --filter "label=com.docker.compose.service=alertmanager" --format '{{.ID}}' | head -n1)
sudo docker exec "$am_cid" wget -qO- http://localhost:9093/-/ready 2>/dev/null \
  || fail "alertmanager not ready"
ok "alertmanager ready"

# End-to-end HTTPS reachability via Traefik — catches drift between
# loadbalancer healthcheck wiring, backend ports, and cert resolution.
# --resolve pins to the WG IP (traefik's actual bind) so we don't depend on Cloudflare DNS here.
for endpoint in \
  "grafana.${domain}|/api/health" \
  "vault.${domain}|/alive"
do
  host="${endpoint%%|*}"
  path="${endpoint##*|}"
  curl -fsS -m 5 --resolve "${host}:443:${wg_ip}" "https://${host}${path}" >/dev/null \
    || fail "HTTPS ${host}${path} not reachable via Traefik"
  ok "HTTPS ${host}${path} reachable"
done

# Alertmanager is behind basic-auth middleware — a 401 proves Traefik
# routed + applied the middleware correctly; a 200 proves the whole chain
# (router + backend). Either is a pass; anything else (502, timeout) fails.
code=$(curl -sS -m 5 --resolve "alertmanager.${domain}:443:${wg_ip}" \
  -o /dev/null -w "%{http_code}" "https://alertmanager.${domain}/-/ready" || echo 0)
case "$code" in
  200|401) ok "HTTPS alertmanager.${domain} reachable (${code})" ;;
  *)       fail "HTTPS alertmanager.${domain} returned ${code}" ;;
esac

ok "all smoke checks passed"
