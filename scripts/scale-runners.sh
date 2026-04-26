#!/usr/bin/env bash
# Scale GitHub Actions JIT runner instances up or down without re-running
# the full bootstrap. Mirrors bootstrap.sh's phase-7 install + downscale
# loops; no GITHUB_TOKEN needed (JIT registration happens per-job at runtime).
#
# Usage (on the homelab host, as root):
#   sudo scripts/scale-runners.sh [N]
#   N defaults to 12 — matches bootstrap.sh's GITHUB_RUNNER_INSTANCES default.
#
# Idempotent. Adds @N services and install dirs that don't exist; removes any
# @N service whose index exceeds N.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (uses systemctl + chown)" >&2
  exit 1
fi

TARGET="${1:-12}"
[[ "$TARGET" =~ ^[0-9]+$ ]] || { echo "N must be integer, got '$TARGET'" >&2; exit 1; }

GITHUB_RUNNER_USER="${GITHUB_RUNNER_USER:-gha-runner}"
GITHUB_RUNNER_DIR="${GITHUB_RUNNER_DIR:-/opt/actions-runner}"
GITHUB_RUNNER_VERSION="${GITHUB_RUNNER_VERSION:-2.333.1}"

case "$(dpkg --print-architecture)" in
  amd64) arch=x64 ;;
  arm64) arch=arm64 ;;
  *) echo "unsupported arch: $(dpkg --print-architecture)" >&2; exit 1 ;;
esac

tarball="actions-runner-linux-${arch}-${GITHUB_RUNNER_VERSION}.tar.gz"

# Download once into /tmp; reused across new instances.
if [ ! -s "/tmp/$tarball" ]; then
  echo "downloading runner $GITHUB_RUNNER_VERSION" >&2
  curl -fsSL -o "/tmp/$tarball" \
    "https://github.com/actions/runner/releases/download/v${GITHUB_RUNNER_VERSION}/${tarball}"
fi

# Provision per-instance install dirs 1..TARGET. Bootstrap's logic, copied:
# extract as root (umask-friendly), then chown the tree to the runner user.
for i in $(seq 1 "$TARGET"); do
  dir="${GITHUB_RUNNER_DIR}-${i}"
  install -d -o "$GITHUB_RUNNER_USER" -g "$GITHUB_RUNNER_USER" -m 0750 "$dir"
  if [ ! -x "$dir/run.sh" ]; then
    echo "extracting runner into $dir" >&2
    tar -xzf "/tmp/$tarball" -C "$dir"
    chown -R "${GITHUB_RUNNER_USER}:${GITHUB_RUNNER_USER}" "$dir"
  fi
done
rm -f "/tmp/$tarball"

# Downscale: stop + drop any @N beyond TARGET. Mirrors bootstrap's loop.
for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
            | awk '/^gha-runner-jit@[0-9]+\.service/ {print $1}'); do
  n=$(echo "$u" | sed -E 's/^gha-runner-jit@([0-9]+)\.service$/\1/')
  if [ "$n" -gt "$TARGET" ]; then
    echo "downscaling: stopping + removing $u" >&2
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    rm -rf "${GITHUB_RUNNER_DIR}-${n}"
  fi
done

systemctl daemon-reload
for i in $(seq 1 "$TARGET"); do
  systemctl enable --now "gha-runner-jit@${i}.service"
done

echo "OK ${TARGET}× ephemeral JIT runner service(s) active" >&2
systemctl list-units 'gha-runner-jit@*' --all --no-legend
