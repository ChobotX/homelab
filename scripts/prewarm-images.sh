#!/usr/bin/env bash
# Pre-pull every Docker image referenced by role defaults into the local daemon.
#
# Runs as a GitHub Actions job concurrently with lint + docker-test, so by the
# time the `deploy` job's observability / traefik / apps roles fire their
# `docker_compose_v2 pull`, the layers are already on disk.
#
# Soft-fail per image: a single registry blip shouldn't red the whole job —
# Ansible retries its own pulls and would fetch missing layers during deploy.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Every image is declared as `<something>_image: "<ref>@sha256:..."` in its
# role's defaults/main.yml. Grep across all roles and dedupe.
mapfile -t images < <(
  grep -hrEo '^[a-z_]+_image:[[:space:]]*"[^"]+"' \
    "$REPO_ROOT/ansible/roles/"*/defaults/main.yml 2>/dev/null \
    | sed -E 's/.*"([^"]+)"/\1/' \
    | sort -u
)

if [ "${#images[@]}" -eq 0 ]; then
  echo "prewarm: no images discovered — check roles/*/defaults layout" >&2
  exit 1
fi

echo "prewarm: pulling ${#images[@]} image(s) (6-way fan-out)"
printf '  - %s\n' "${images[@]}"

MAX_PARALLEL=6
active=0
for img in "${images[@]}"; do
  (
    if docker pull --quiet "$img" >/dev/null 2>&1; then
      printf '  OK  %s\n' "$img"
    else
      # Soft fail — deploy will retry anyway.
      printf '  SKIP %s (pull failed, deploy will retry)\n' "$img" >&2
    fi
  ) &
  active=$((active + 1))
  if [ "$active" -ge "$MAX_PARALLEL" ]; then
    wait -n 2>/dev/null || wait
    active=$((active - 1))
  fi
done
wait
echo "prewarm: done"
