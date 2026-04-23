#!/usr/bin/env bash
# Weekly safe docker prune — images + build cache older than 7 days only.
# Never touches volumes (could delete intended data) or running/stopped
# containers (compose manages lifecycle; stopped containers may be kept on
# purpose for diagnostics). Logs via journal (logger) and writes a textfile
# metric for Prometheus at /var/lib/node_exporter/textfile.
set -euo pipefail

LOG_TAG=docker-prune
TEXTFILE=/var/lib/node_exporter/textfile/docker_prune.prom
THRESHOLD=168h   # 7 days — matches Renovate cadence; anything touched more
                 # recently than this is likely still part of an active stack

log() { logger -t "$LOG_TAG" "$@"; }

before=$(docker system df --format '{{.Size}}' | head -n1 2>/dev/null || echo "unknown")
log "starting prune (before: images=$before, threshold=until=$THRESHOLD)"

# --filter "until=168h" only removes items not USED in the last 7 days, so
# images that are currently referenced by a running container are kept even
# if pulled weeks ago. -a removes untagged + dangling too.
reclaimed_images=$(docker image prune -af --filter "until=$THRESHOLD" 2>&1 \
  | awk '/Total reclaimed space/ {print $NF}' || true)
reclaimed_builder=$(docker builder prune -f --filter "until=$THRESHOLD" 2>&1 \
  | awk '/Total:/ {print $NF}' || true)

log "images reclaimed: ${reclaimed_images:-0B}, builder reclaimed: ${reclaimed_builder:-0B}"

# Emit a textfile metric for node_exporter. Value = unix timestamp of last
# successful run (so stale runs show up via `time() - ...` in alerts if we
# want one later).
tmp=$(mktemp -p /var/lib/node_exporter/textfile .docker_prune.XXXXXX.prom)
cat >"$tmp" <<EOF
# HELP docker_prune_last_run_timestamp_seconds Unix time of last docker prune completion.
# TYPE docker_prune_last_run_timestamp_seconds gauge
docker_prune_last_run_timestamp_seconds $(date +%s)
EOF
chmod 0644 "$tmp"
mv -f "$tmp" "$TEXTFILE"

log "done"
