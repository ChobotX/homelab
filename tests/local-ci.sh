#!/usr/bin/env bash
# Reproduces the non-deploy jobs of .github/workflows/ci.yml locally.
#
# Mirrors the `lint` and `docker-test` jobs so a green local run ≈ green CI.
# The `deploy` job is intentionally NOT reproducible — it's self-hosted on the
# real homelab and would converge live state.
#
# Usage:
#   tests/local-ci.sh            # full run: guards + lint + docker-test (alias: all)
#   tests/local-ci.sh lint       # guards + lint only
#   tests/local-ci.sh docker     # docker-test only (delegates to tests/docker/test.sh apply)
#   tests/local-ci.sh clean      # remove lint + docker-test containers and the lint image
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Pinned tool versions (keep in sync with .github/workflows/ci.yml and
#    .pre-commit-config.yaml — Renovate watches those files, not this one) ──
YAMLLINT_VERSION="1.38.0"
ANSIBLE_LINT_VERSION="26.4.0"
GITLEAKS_VERSION="8.30.1"
# CI verifies this SHA for the linux/x64 asset; local uses native arch. The
# lint tools that matter for parity (yamllint, ansible-lint, shellcheck, gitleaks)
# are arch-agnostic in behaviour — they just flag the same violations.
GITLEAKS_SHA256_X64="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
SHELLCHECK_IMAGE="koalaman/shellcheck-alpine:stable"
ANSIBLE_CORE_VERSION="$(cat .ansible-version)"

LINT_IMAGE_BASE="homelab-local-lint"
MODE="${1:-all}"

log()  { printf '\n\033[1;34m[local-ci]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[local-ci:OK]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[local-ci:FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || fail "missing $1 on host"; }

# ── Host-side guards — copied verbatim from ci.yml lint job ──────────────
guard_wg_subnets() {
  log "guard: forbid mixed WG subnets"
  local conflicts
  conflicts=$(grep -rEho '10\.[0-9]+\.0\.0/24' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tests . \
    | sort -u | wc -l | tr -d ' ')
  if [ "$conflicts" -gt 1 ]; then
    echo "multiple WG subnets found (non-test files):"
    grep -rEno '10\.[0-9]+\.0\.0/24' \
      --exclude-dir=.git --exclude-dir=tests . | sort -u
    fail "WG subnet drift"
  fi
  ok "single WG subnet"
}

guard_unsafe_triggers() {
  log "guard: forbid pull_request_target / workflow_run"
  if grep -rEn '^[[:space:]]*(pull_request_target|workflow_run):' .github/workflows/; then
    fail "workflow uses pull_request_target or workflow_run — unsafe with self-hosted runner"
  fi
  ok "no unsafe triggers"
}

# ── Lint image — ubuntu:24.04 + pinned tools, cached by deps hash ────────
lint_image_tag() {
  # Tag bumps whenever tooling deps change, forcing a rebuild.
  local h
  h=$({
    echo "$YAMLLINT_VERSION $ANSIBLE_LINT_VERSION $ANSIBLE_CORE_VERSION $GITLEAKS_VERSION"
    cat ansible/requirements.yml
  } | shasum -a 256 | cut -c1-12)
  printf '%s:%s' "$LINT_IMAGE_BASE" "$h"
}

build_lint_image() {
  local tag="$1"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    log "reusing lint image $tag"
    return
  fi
  log "building lint image $tag"
  # Explicit cleanup instead of `trap ... RETURN`: RETURN traps fire on every
  # function return after being set, and `$ctx` is unset by then under `set -u`.
  local ctx rc=0
  ctx=$(mktemp -d)
  cp ansible/requirements.yml "$ctx/requirements.yml"
  cat > "$ctx/Dockerfile" <<EOF
# Native host arch — Ansible-lint/yamllint/shellcheck/gitleaks all behave
# identically across arches, so there's no parity gain from emulating amd64
# on Apple Silicon (which also requires binfmt setup).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \\
 && apt-get install -y --no-install-recommends \\
      ca-certificates curl git python3 python3-pip \\
 && rm -rf /var/lib/apt/lists/*

RUN pip install --break-system-packages --no-cache-dir \\
      "ansible-core==${ANSIBLE_CORE_VERSION}" \\
      "yamllint==${YAMLLINT_VERSION}" \\
      "ansible-lint==${ANSIBLE_LINT_VERSION}"

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install --force -r /tmp/requirements.yml >/dev/null

RUN set -eu \\
 && arch=\$(dpkg --print-architecture) \\
 && case "\$arch" in \\
      amd64) asset=linux_x64  ; sha=${GITLEAKS_SHA256_X64} ;; \\
      arm64) asset=linux_arm64; sha="" ;; \\
      *) echo "unsupported arch: \$arch" >&2; exit 1 ;; \\
    esac \\
 && curl -fsSL -o /tmp/gitleaks.tgz \\
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_\${asset}.tar.gz" \\
 && { [ -z "\$sha" ] || echo "\${sha}  /tmp/gitleaks.tgz" | sha256sum -c -; } \\
 && tar -xzf /tmp/gitleaks.tgz -C /usr/local/bin gitleaks \\
 && rm /tmp/gitleaks.tgz

WORKDIR /repo
EOF
  docker build -t "$tag" "$ctx" >/dev/null || rc=$?
  rm -rf "$ctx"
  [ "$rc" -eq 0 ] || return "$rc"
  # Drop untagged older lint images to keep disk clean.
  docker image ls "$LINT_IMAGE_BASE" --format '{{.Repository}}:{{.Tag}}' \
    | grep -v "^${tag}\$" \
    | xargs -r docker rmi -f >/dev/null 2>&1 || true
}

run_in_lint() {
  local tag
  tag=$(lint_image_tag)
  docker run --rm \
    -v "$REPO_ROOT:/repo:ro" \
    "$tag" \
    bash -euo pipefail -c "$1"
}

run_lint() {
  local tag
  tag=$(lint_image_tag)
  build_lint_image "$tag"

  log "yamllint ."
  run_in_lint 'yamllint .'
  ok "yamllint"

  log "ansible-lint --profile=basic (cwd=ansible)"
  run_in_lint 'cd ansible && ansible-lint --profile=basic'
  ok "ansible-lint"

  log "gitleaks detect"
  run_in_lint 'gitleaks detect --no-banner --redact --verbose --exit-code 1 --source .'
  ok "gitleaks"

  log "shellcheck (severity=warning)"
  # ludeeus/action-shellcheck@v2 default: all *.sh under scandir with severity=warning.
  mapfile -t sh_files < <(find . -type f -name '*.sh' -not -path './.git/*')
  if [ "${#sh_files[@]}" -gt 0 ]; then
    docker run --rm \
      -v "$REPO_ROOT:/repo:ro" -w /repo \
      "$SHELLCHECK_IMAGE" \
      shellcheck --severity=warning "${sh_files[@]}"
  fi
  ok "shellcheck"
}

# ── Docker-test — delegates to the existing, proven harness ──────────────
run_docker_test() {
  log "docker-test: tests/docker/test.sh apply"
  "$REPO_ROOT/tests/docker/test.sh" apply
}

cmd_clean() {
  log "removing lint images ($LINT_IMAGE_BASE:*)"
  docker image ls "$LINT_IMAGE_BASE" --format '{{.Repository}}:{{.Tag}}' \
    | xargs -r docker rmi -f >/dev/null 2>&1 || true
  log "removing docker-test container"
  "$REPO_ROOT/tests/docker/test.sh" clean
  ok "cleaned"
}

main() {
  need docker
  docker info >/dev/null 2>&1 || fail "docker daemon not reachable"

  case "$MODE" in
    all)
      guard_wg_subnets
      guard_unsafe_triggers
      run_lint
      run_docker_test
      ok "full local CI passed — safe to push"
      ;;
    lint)
      guard_wg_subnets
      guard_unsafe_triggers
      run_lint
      ok "lint stage passed"
      ;;
    docker)
      run_docker_test
      ok "docker-test stage passed"
      ;;
    clean)
      cmd_clean
      ;;
    *)
      fail "unknown mode: $MODE (try: all | lint | docker | clean)"
      ;;
  esac
}

main "$@"
