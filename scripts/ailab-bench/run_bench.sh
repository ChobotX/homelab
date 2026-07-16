#!/usr/bin/env bash
# Orchestrate a bench run on ailab: env snapshot + sampler + bench.py.
# Usage: run_bench.sh [RUN_DIR] [extra bench.py args...]
# LiteLLM key is read on-box from the container config; never printed.
set -euo pipefail
cd "$(dirname "$0")"

RUN="${1:-$HOME/bench/run-$(date +%Y%m%d-%H%M%S)}"
shift || true
mkdir -p "$RUN"

{
  date
  uname -a
  /opt/llama.cpp/bin/llama-server --version 2>&1 || true
  nvidia-smi
  systemctl list-units --type=service --state=running --no-pager | grep -iE "llama|docker" || true
  docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || true
  ps -eo pid,comm,%cpu,%mem --sort=-%cpu --no-headers | head -10
} > "$RUN/env.txt" 2>&1

KEY_REF="$(docker exec litellm-litellm-1 sh -c "awk '/master_key/{print \$2}' /app/config.yaml" 2>/dev/null || true)"
case "$KEY_REF" in
  os.environ/*) LITELLM_KEY="$(docker exec litellm-litellm-1 sh -c "printf %s \"\$${KEY_REF#os.environ/}\"" 2>/dev/null || true)" ;;
  *) LITELLM_KEY="$KEY_REF" ;;
esac
export LITELLM_KEY

./sampler.sh "$RUN/system.csv" &
SAMPLER_PID=$!
trap 'kill "$SAMPLER_PID" 2>/dev/null || true' EXIT

python3 bench.py --out "$RUN" "$@"

echo "results in $RUN"
