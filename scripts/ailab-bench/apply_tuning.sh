#!/usr/bin/env bash
# Rewrite llama-server.service tuning flags, restart, wait healthy.
# Usage: sudo apply_tuning.sh "<tuning flags line>"
# Fixed part (model/ctx/slots/sampling) is not parameterized on purpose:
# -c 1048576 --parallel 4 = 4x256k slots, required floor for coding use.
set -euo pipefail
FLAGS="${1:?usage: apply_tuning.sh \"<tuning flags>\"}"
UNIT=/etc/systemd/system/llama-server.service

cp "$UNIT" "$UNIT.bak-$(date +%Y%m%d-%H%M%S)"

cat > "$UNIT" <<EOF
[Unit]
Description=llama-server (ThinkingCap-Qwen3.6-27B Q8_0)
After=network.target

[Service]
Type=simple
# Localhost only — reachable solely via LiteLLM proxy on 10.8.0.9:4000.
Environment=LD_LIBRARY_PATH=/opt/llama.cpp/bin
ExecStart=/opt/llama.cpp/bin/llama-server \\
  -m /opt/models/ThinkingCap-Qwen3.6-27B-Q8_0.gguf \\
  --alias thinkingcap-qwen3.6-27b \\
  --host 127.0.0.1 --port 8080 \\
  -c 1048576 --parallel 4 --cache-type-k q8_0 --cache-type-v q8_0 \\
  ${FLAGS} \\
  -ngl 999 --jinja --metrics \\
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0
# 4 slots x 256k (native max_position_embeddings); Q8_0 weights 29G + q8 KV fit 128G unified.
Restart=on-failure
RestartSec=5
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# don't restart mid-request
for _ in $(seq 1 30); do
  BUSY=$(curl -sf --max-time 2 http://127.0.0.1:8080/metrics 2>/dev/null | awk '$1=="llamacpp:requests_processing"{print $2}')
  [ "${BUSY:-0}" = "0" ] && break
  sleep 2
done

systemctl daemon-reload
systemctl restart llama-server

for _ in $(seq 1 90); do
  if curl -sf --max-time 2 http://127.0.0.1:8080/health >/dev/null 2>&1; then
    echo "HEALTHY after restart with flags: ${FLAGS}"
    journalctl -u llama-server -n 200 --no-pager | grep -E "n_slots|n_ctx_slot|kv_unified|flash_attn|n_ubatch" | tail -5 || true
    exit 0
  fi
  sleep 2
done
echo "NOT HEALTHY after 180s"
journalctl -u llama-server -n 30 --no-pager
exit 1
