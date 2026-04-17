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
  docker build -t "$IMAGE" "$REPO_ROOT/tests/docker"
}

start_container() {
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "reusing existing $CONTAINER"
    docker start "$CONTAINER" >/dev/null
  else
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
  fi
}

install_ansible_inside() {
  log "installing ansible inside container"
  docker exec "$CONTAINER" bash -c '
    set -euo pipefail
    # Ignore apt release-file date checks — container clocks can skew on macOS hosts.
    cat > /etc/apt/apt.conf.d/99test-no-date-check <<EOF
Acquire::Check-Date "false";
Acquire::Check-Valid-Until "false";
EOF
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      git python3-pip python3-venv yamllint >/dev/null
    core_version=$(cat /opt/homelab/.ansible-version)
    python3 -m pip install --break-system-packages --quiet \
      "ansible-core==${core_version}"
    ansible-galaxy collection install -r /opt/homelab/ansible/requirements.yml >/dev/null
  '
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

wireguard_peer_hetzner_pubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
wireguard_peer_hetzner_endpoint: "hub.invalid:51820"
wireguard_peer_hetzner_allowedips: "10.0.0.0/24"

restic_repo_url: "/tmp/restic-test-repo"
EOF

    # Minimal secrets — test values only.
    printf test > /etc/homelab/secrets/cloudflare_dns01_token
    printf test > /etc/homelab/secrets/vaultwarden_admin_token
    printf "admin:\$\$2y\$\$05\$\$abcdefghijklmnopqrstuv" > /etc/homelab/secrets/traefik_dashboard_basicauth
    printf test-password > /etc/homelab/secrets/restic_password
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

run_check() {
  # --check is of limited use — tasks that install a package then enable its
  # systemd unit fail in check mode because the package was only simulated.
  # We still run it to validate Jinja + task structure.
  log "ansible --check (template validation)"
  docker exec "$CONTAINER" bash -c '
    set -e
    cd /tmp/homelab-test/ansible
    ansible-playbook -i inventory.yml playbooks/site.yml \
      --check --tags common
  '
}

run_apply_safe() {
  log "ansible apply — safe roles (common, ssh_hardening, fail2ban, docker)"
  docker exec "$CONTAINER" bash -c '
    set -e
    cd /tmp/homelab-test/ansible
    ansible-playbook -i inventory.yml playbooks/site.yml \
      --tags common,ssh,hardening,docker,fail2ban \
      --skip-tags wireguard,ufw,traefik,vaultwarden,backup
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
  case "$MODE" in
    clean)  cmd_clean ;;
    shell)
      start_container
      docker exec -it "$CONTAINER" bash
      ;;
    check)
      build_image
      start_container
      install_ansible_inside
      prep_mock_homelab_etc
      run_lint
      run_syntax_check
      run_check
      log "OK — lint/syntax/check passed"
      ;;
    apply)
      build_image
      start_container
      install_ansible_inside
      prep_mock_homelab_etc
      run_lint
      run_syntax_check
      run_check
      run_apply_safe
      log "OK — safe roles applied cleanly"
      ;;
    *) die "unknown mode: $MODE (try: check | apply | shell | clean)" ;;
  esac
}

main "$@"
