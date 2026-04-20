#!/usr/bin/env bash
# Managed by Ansible — emits per-container state as Prometheus textfile metrics.
# Scraped by Alloy's node_exporter textfile collector (see alloy-config.alloy:17-19).
# Auto-discovers every container Docker knows about — no allow-list to maintain.
set -euo pipefail

out_dir=/var/lib/node_exporter/textfile
tmp=$(mktemp "${out_dir}/docker_state.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT

{
  echo "# HELP docker_container_running Whether a docker container is in the running state (1) or not (0)."
  echo "# TYPE docker_container_running gauge"
  echo "# HELP docker_container_health Docker healthcheck state per status label (1 = currently in that status)."
  echo "# TYPE docker_container_health gauge"
  echo "# HELP docker_container_restarts Docker-reported restart count of the container."
  echo "# TYPE docker_container_restarts counter"

  # One inspect per container, formatted to a single pipe-delimited line so we
  # don't shell out N×3 times.
  docker ps -a --format '{{.Names}}' | while read -r name; do
    [ -z "$name" ] && continue
    line=$(docker inspect \
      --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' \
      "$name" 2>/dev/null) || continue
    status=${line%%|*}
    rest=${line#*|}
    health=${rest%%|*}
    restarts=${rest#*|}

    running=0
    [ "$status" = "running" ] && running=1
    printf 'docker_container_running{name="%s"} %s\n' "$name" "$running"

    for s in healthy unhealthy starting none; do
      v=0
      [ "$health" = "$s" ] && v=1
      printf 'docker_container_health{name="%s",status="%s"} %s\n' "$name" "$s" "$v"
    done

    printf 'docker_container_restarts{name="%s"} %s\n' "$name" "$restarts"
  done
} > "$tmp"

# Atomic publish — node_exporter's textfile collector reads whole files, so a
# partial write would produce a malformed scrape.
mv "$tmp" "${out_dir}/docker_state.prom"
trap - EXIT
