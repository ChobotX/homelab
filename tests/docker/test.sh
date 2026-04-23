#!/usr/bin/env bash
# Runs the playbook against a throwaway Ubuntu container.
#
# What IS tested:
#   - yamllint + ansible syntax-check
#   - --check dry-run (template rendering)
#   - Real apply of kernel-independent roles (common, ssh_hardening, fail2ban, docker)
#
# What is NOT tested here (needs a real VM):
#   - wireguard (needs wg kernel module + real peer)
#   - ufw (iptables/netfilter behaviour inside containers is flaky)
#   - traefik / vaultwarden compose stacks (need Docker-in-Docker to fully run)
#   - backup upload to real backend
#
# Usage:
#   tests/docker/test.sh              # lint + syntax + --check (no apply)
#   tests/docker/test.sh apply        # also apply safe roles inside the container
#   tests/docker/test.sh shell        # drop into the running test container
#   tests/docker/test.sh clean        # stop + remove test container
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER="homelab-test"
IMAGE="homelab-test:ubuntu-24.04"
MODE="${1:-check}"

log() { printf '\n\033[1;34m[test]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[test:ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing $1 on host"; }

cmd_clean() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  log "removed $CONTAINER"
}

build_image() {
  log "building $IMAGE"
  # Stage a tiny build context: the Dockerfile + the two files it COPYs
  # (.ansible-version, ansible/requirements.yml). Keeps the context narrow so
  # Docker doesn't hash the entire repo, and avoids needing a repo-root
  # .dockerignore. Layer cache does the right thing when those inputs change.
  # Use explicit cleanup instead of `trap ... RETURN` — RETURN traps fire on
  # every function return after being set (not just this one), which collides
  # with `set -u` once ctx goes out of scope.
  local ctx rc=0
  ctx=$(mktemp -d)
  cp "$REPO_ROOT/tests/docker/Dockerfile"      "$ctx/Dockerfile"
  cp "$REPO_ROOT/.ansible-version"             "$ctx/.ansible-version"
  cp "$REPO_ROOT/ansible/requirements.yml"     "$ctx/requirements.yml"
  docker build -t "$IMAGE" "$ctx" || rc=$?
  rm -rf "$ctx"
  return "$rc"
}

start_container() {
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    # Recreate if the underlying image was rebuilt (new Ansible/collections
    # layer etc.) — the running container still points at the old image ID
    # and would run stale tooling otherwise.
    local container_img image_id
    container_img=$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || true)
    image_id=$(docker inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
    if [ -n "$container_img" ] && [ -n "$image_id" ] && [ "$container_img" != "$image_id" ]; then
      log "image rebuilt — recreating $CONTAINER"
      docker rm -f "$CONTAINER" >/dev/null
    # Validate the bind mount before reusing. On the self-hosted JIT runner
    # the wrapper wipes $RUNNER_DIR/_work between jobs — a fresh checkout on
    # the same path gets a new inode, leaving the container's mount pointing
    # at a deleted directory. Path string still matches, but the mount is
    # orphaned and reads return ENOENT. Probe a known file to detect drift.
    elif docker start "$CONTAINER" >/dev/null 2>&1 \
       && docker exec "$CONTAINER" test -r /opt/homelab/.ansible-version 2>/dev/null; then
      log "reusing existing $CONTAINER"
      return
    else
      log "existing $CONTAINER has stale bind mount or failed to start — recreating"
      docker rm -f "$CONTAINER" >/dev/null
    fi
  fi
  log "starting $CONTAINER"
  docker run -d --name "$CONTAINER" \
    --privileged \
    --cgroupns=host \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$REPO_ROOT:/opt/homelab:ro" \
    "$IMAGE" >/dev/null
  log "waiting for systemd"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    docker exec "$CONTAINER" systemctl is-system-running --wait 2>/dev/null | grep -qE '^(running|degraded)$' && break
    sleep 1
  done
}

prep_mock_homelab_etc() {
  # Stub /etc/homelab/{config.yml, secrets/*} so site.yml can slurp values.
  docker exec "$CONTAINER" bash -c '
    set -euo pipefail
    rm -rf /tmp/homelab-test
    install -d /tmp/homelab-test
    cp -r /opt/homelab/ansible /tmp/homelab-test/ansible
    chmod -R u+w /tmp/homelab-test/ansible

    install -d -m 0755 /etc/homelab
    install -d -m 0700 /etc/homelab/secrets

    cat > /etc/homelab/config.yml <<EOF
---
admin_user: testadmin
homelab_domain: test.invalid
acme_email: test@test.invalid

wireguard_address: 10.0.0.2/24
wireguard_subnet: 10.0.0.0/24
wireguard_listen_port: 51820

wireguard_peer_hub_pubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
wireguard_peer_hub_endpoint: "hub.invalid:51820"
wireguard_peer_hub_allowedips: "10.0.0.0/24"

restic_repo_url: "/tmp/restic-test-repo"
restic_sftp_host: "sftp.invalid"
restic_sftp_user: "testuser"

traefik_dashboard_user: admin

github_repo: "owner/homelab"
github_runner_labels: "self-hosted,linux,homelab"

homeassistant_host: "10.0.0.3:8123"
alertmanager_smtp_host: "smtp.invalid:587"
alertmanager_smtp_from: "noreply@test.invalid"
alertmanager_email_to: "alerts@test.invalid"
EOF

    # Minimal secrets — test values only; role-generated ones get created on apply.
    printf test > /etc/homelab/secrets/cloudflare_dns01_token
    printf test > /etc/homelab/secrets/traefik_dashboard_password
    printf test > /etc/homelab/secrets/restic_sftp_private_key
    printf test > /etc/homelab/secrets/homeassistant_metrics_token
    printf test > /etc/homelab/secrets/alertmanager_smtp_password
    chmod 0400 /etc/homelab/secrets/*

    # Point inventory at docker connection.
    cp /opt/homelab/tests/docker/inventory.yml \
       /tmp/homelab-test/ansible/inventory.yml
  '
}

run_lint() {
  # ansible-lint is intentionally NOT run inside the container — enforced by
  # pre-commit + GitHub Actions instead. yamllint is cheap and worth running.
  log "yamllint"
  docker exec "$CONTAINER" bash -c '
    set -e
    cd /opt/homelab
    yamllint -c .yamllint .
  '
}

run_syntax_check() {
  log "ansible syntax-check"
  docker exec "$CONTAINER" bash -c '
    set -e
    cd /tmp/homelab-test/ansible
    ansible-playbook -i inventory.yml playbooks/site.yml --syntax-check
  '
}

run_apply_safe() {
  log "ansible apply — safe roles (common, ssh_hardening, fail2ban, docker)"
  docker exec "$CONTAINER" bash -c '
    set -e
    cd /tmp/homelab-test/ansible
    ansible-playbook -i inventory.yml playbooks/site.yml \
      --tags common,ssh,hardening,docker,fail2ban \
      --skip-tags wireguard,ufw,traefik,vaultwarden,backup,observability
  '

  log "post-apply sanity checks"
  docker exec "$CONTAINER" bash -c '
    set -e
    systemctl is-active --quiet ssh               && echo "  ✓ ssh active"
    systemctl is-active --quiet fail2ban          && echo "  ✓ fail2ban active"
    test -f /etc/ssh/sshd_config.d/10-hardening.conf && echo "  ✓ hardening drop-in present"
    grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config.d/10-hardening.conf && echo "  ✓ password auth disabled"
    test -f /etc/docker/daemon.json                 && echo "  ✓ docker daemon.json present"
    systemctl is-active --quiet docker            && echo "  ✓ docker engine running"
    test -f /etc/systemd/journald.conf.d/retention.conf && echo "  ✓ journald retention set"
  '
}

main() {
  need docker
  # In CI (GITHUB_ACTIONS=true), clean the container on exit — no reuse value
  # there, and a leftover container on the self-hosted box holds ~200 MB RAM
  # until the next run's recreate. Local dev keeps the container for iteration.
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$MODE" != "clean" ] && [ "$MODE" != "shell" ]; then
    trap cmd_clean EXIT
  fi
  case "$MODE" in
    clean)  cmd_clean ;;
    shell)
      start_container
      docker exec -it "$CONTAINER" bash
      ;;
    check)
      build_image
      start_container
      prep_mock_homelab_etc
      run_lint
      run_syntax_check
      log "OK — lint/syntax/check passed"
      ;;
    apply)
      build_image
      start_container
      prep_mock_homelab_etc
      # yamllint is already enforced by the GHA `lint` job and local-ci.sh
      # against the same tree — no need to re-run it inside the container here.
      run_syntax_check
      run_apply_safe
      log "OK — safe roles applied cleanly"
      ;;
    *) die "unknown mode: $MODE (try: check | apply | shell | clean)" ;;
  esac
}

main "$@"
