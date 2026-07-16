#!/usr/bin/env bash
# 1 Hz system sampler for ailab bench runs. Usage: sampler.sh OUTFILE.csv
# Captures GPU state, load, memory, llama-server queue/token counters and
# top CPU processes so bench phases can be correlated with interference.
set -u
OUT="${1:?usage: sampler.sh OUTFILE.csv}"

echo "ts,gpu_util_pct,gpu_mem_mib,power_w,sm_mhz,temp_c,load1,mem_avail_kb,req_processing,req_deferred,prompt_tok_total,pred_tok_total,top_procs" > "$OUT"

while true; do
  TS=$(date +%s.%N)
  GPU=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw,clocks.sm,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo ",,,,")
  LOAD=$(cut -d' ' -f1 /proc/loadavg)
  MEMAV=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  M=$(curl -sf --max-time 0.8 http://127.0.0.1:8080/metrics 2>/dev/null || true)
  RP=$(awk '$1=="llamacpp:requests_processing"{print $2}' <<<"$M")
  RD=$(awk '$1=="llamacpp:requests_deferred"{print $2}' <<<"$M")
  PT=$(awk '$1=="llamacpp:prompt_tokens_total"{print $2}' <<<"$M")
  GT=$(awk '$1=="llamacpp:tokens_predicted_total"{print $2}' <<<"$M")
  PROCS=$(ps -eo comm,%cpu --sort=-%cpu --no-headers 2>/dev/null | head -3 | awk '{printf "%s:%s;",$1,$2}')
  echo "$TS,$GPU,$LOAD,$MEMAV,${RP:-},${RD:-},${PT:-},${GT:-},$PROCS" >> "$OUT"
  sleep 1
done
