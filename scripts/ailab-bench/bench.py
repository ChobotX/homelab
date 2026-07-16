#!/usr/bin/env python3
"""Benchmark harness for ailab llama-server + LiteLLM (stdlib only).

Measures per request: TTFB, TTFT, total wall, prompt/gen token counts,
server-side timings (native endpoint), client-side gen tok/s.
Per phase: llama-server /metrics delta -> flags external traffic that
overlapped the phase (other clients skew numbers).

Run on ailab (direct + LiteLLM) or on a WG peer (LiteLLM only):
  python3 bench.py --out DIR --phases gen1,pp8k,...
  LITELLM_KEY=... python3 bench.py --out DIR --phases lite1,lite4 --no-native

Self-check: python3 bench.py --self-test
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

WORDS = (
    "system kernel packet buffer thread socket vector matrix tensor cache "
    "signal module driver memory branch merge commit deploy metric probe "
    "sensor relay switch router bridge tunnel cipher digest schema index "
    "shard replica quorum leader follower journal segment offset cursor "
    "batch stream window trigger filter reduce map fold scan parse token"
).split()


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def http_json(url, payload=None, headers=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def metrics_snapshot(native_base):
    try:
        req = urllib.request.Request(f"{native_base}/metrics")
        with urllib.request.urlopen(req, timeout=5) as r:
            text = r.read().decode()
    except (urllib.error.URLError, OSError):
        return {}
    out = {}
    for line in text.splitlines():
        if line.startswith("llamacpp:"):
            k, _, v = line.partition(" ")
            try:
                out[k.split(":", 1)[1]] = float(v)
            except ValueError:
                pass
    return out


def wait_idle(native_base, timeout=300):
    """Block until no requests are processing/queued. Returns seconds waited."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        m = metrics_snapshot(native_base)
        if not m:  # metrics unreachable (remote run) -> don't gate
            return 0.0
        if m.get("requests_processing", 0) == 0 and m.get("requests_deferred", 0) == 0:
            return time.time() - t0
        time.sleep(2)
    log(f"WARN: server still busy after {timeout}s, proceeding anyway")
    return time.time() - t0


def parse_sse(resp, on_first_data):
    """Yield parsed JSON objects from an SSE stream; call on_first_data() once."""
    first = True
    for raw in resp:
        line = raw.decode("utf-8", errors="replace").strip()
        if not line.startswith("data: "):
            continue
        if first:
            on_first_data()
            first = False
        body = line[len("data: "):]
        if body == "[DONE]":
            return
        try:
            yield json.loads(body)
        except json.JSONDecodeError:
            continue


def stream_request(url, payload, headers, timeout, extract):
    """POST payload, stream SSE, return timing record. extract(obj, rec) folds chunks."""
    rec = {"ttfb": None, "ttft": None, "gen_chunks": 0, "error": None}
    t0 = time.time()
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for obj in parse_sse(resp, lambda: rec.__setitem__("ttfb", time.time() - t0)):
                extract(obj, rec, t0)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
        rec["error"] = str(e)[:300]
    rec["total"] = time.time() - t0
    return rec


def native_extract(obj, rec, t0):
    if obj.get("content") and rec["ttft"] is None:
        rec["ttft"] = time.time() - t0
    if obj.get("content"):
        rec["gen_chunks"] += 1
    if "id_slot" in obj:
        rec["slot"] = obj["id_slot"]
    if obj.get("stop") and "timings" in obj:
        t = obj["timings"]
        rec["server"] = {k: t.get(k) for k in (
            "prompt_n", "prompt_ms", "prompt_per_second",
            "predicted_n", "predicted_ms", "predicted_per_second")}


def oai_extract(obj, rec, t0):
    for ch in obj.get("choices", []):
        delta = ch.get("delta", {})
        if (delta.get("content") or delta.get("reasoning_content")) and rec["ttft"] is None:
            rec["ttft"] = time.time() - t0
        if delta.get("content") or delta.get("reasoning_content"):
            rec["gen_chunks"] += 1
    if obj.get("usage"):
        rec["usage"] = {k: obj["usage"].get(k) for k in ("prompt_tokens", "completion_tokens")}
    if obj.get("timings"):  # llama-server adds this on its OAI endpoint
        t = obj["timings"]
        rec["server"] = {k: t.get(k) for k in (
            "prompt_n", "prompt_ms", "prompt_per_second",
            "predicted_n", "predicted_ms", "predicted_per_second")}


class Bench:
    def __init__(self, args):
        self.args = args
        self.out = open(os.path.join(args.out, "results.jsonl"), "a")
        self.tpw = None  # tokens per word

    def emit(self, obj):
        self.out.write(json.dumps(obj) + "\n")
        self.out.flush()

    def tokenize_len(self, text):
        r = http_json(f"{self.args.native}/tokenize", {"content": text}, timeout=120)
        return len(r["tokens"])

    def calibrate(self):
        sample = " ".join(WORDS[i % len(WORDS)] for i in range(1000))
        self.tpw = self.tokenize_len(sample) / 1000.0
        log(f"calibrate: {self.tpw:.3f} tokens/word")

    def make_prompt(self, target_tokens, unique=True):
        prefix = f"ref {uuid.uuid4().hex} " if unique else "ref fixed-cache-probe "
        n_words = max(1, int((target_tokens - 20) / (self.tpw or 1.3)))
        body = " ".join(WORDS[i % len(WORDS)] for i in range(n_words))
        return prefix + body + "\nSummarize the list above in one word:"

    # ---- request kinds ----
    def native_gen(self, prompt, n_predict, cache_prompt):
        payload = {"prompt": prompt, "n_predict": n_predict, "stream": True,
                   "cache_prompt": cache_prompt, "ignore_eos": True}
        return stream_request(f"{self.args.native}/completion", payload, None,
                              self.args.timeout, native_extract)

    def oai_gen(self, base, key, model, max_tokens, prompt=None):
        prompt = prompt or (f"ref {uuid.uuid4().hex}. Count upward from 1 slowly, "
                            "one number at a time, do not stop: 1 2 3")
        payload = {"model": model, "max_tokens": max_tokens, "stream": True,
                   "stream_options": {"include_usage": True},
                   "messages": [{"role": "user", "content": prompt}]}
        headers = {"Authorization": f"Bearer {key}"} if key else None
        return stream_request(f"{base}/chat/completions", payload, headers,
                              self.args.timeout, oai_extract)

    # ---- phase runner ----
    def phase(self, name, thunks, concurrency):
        waited = wait_idle(self.args.native) if not self.args.no_native else 0
        m0 = metrics_snapshot(self.args.native) if not self.args.no_native else {}
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=concurrency) as ex:
            results = [f.result() for f in [ex.submit(t) for t in thunks]]
        t1 = time.time()
        m1 = metrics_snapshot(self.args.native) if not self.args.no_native else {}

        ours_prompt = sum((r.get("server") or {}).get("prompt_n") or
                          (r.get("usage") or {}).get("prompt_tokens") or 0 for r in results)
        ours_gen = sum((r.get("server") or {}).get("predicted_n") or
                       (r.get("usage") or {}).get("completion_tokens") or 0 for r in results)
        delta = {k: m1.get(k, 0) - m0.get(k, 0) for k in
                 ("prompt_tokens_total", "tokens_predicted_total", "n_decode_total")} if m0 else {}
        external = bool(delta) and (
            delta.get("prompt_tokens_total", 0) - ours_prompt > max(50, 0.02 * max(ours_prompt, 1)) or
            delta.get("tokens_predicted_total", 0) - ours_gen > max(20, 0.02 * max(ours_gen, 1)))

        for i, r in enumerate(results):
            self.emit({"type": "request", "phase": name, "i": i, **r})
        self.emit({"type": "phase", "name": name, "t0": t0, "t1": t1, "wall": t1 - t0,
                   "concurrency": concurrency, "idle_wait": round(waited, 1),
                   "our_prompt_tokens": ours_prompt, "our_gen_tokens": ours_gen,
                   "metrics_delta": delta, "external_traffic": external})
        errs = sum(1 for r in results if r.get("error"))
        flag = " EXTERNAL-TRAFFIC" if external else ""
        log(f"phase {name}: wall={t1 - t0:.1f}s errs={errs}{flag}")
        return results

    # ---- phase definitions ----
    def run_phases(self, names):
        a = self.args
        native_ok = not a.no_native
        if native_ok:
            self.calibrate()
        for name in names:
            if name == "idle":
                waited = wait_idle(a.native)
                m0 = metrics_snapshot(a.native); t0 = time.time()
                time.sleep(a.idle_secs)
                m1 = metrics_snapshot(a.native)
                delta = {k: m1.get(k, 0) - m0.get(k, 0) for k in
                         ("prompt_tokens_total", "tokens_predicted_total")}
                self.emit({"type": "phase", "name": "idle", "t0": t0, "t1": time.time(),
                           "idle_wait": round(waited, 1), "metrics_delta": delta,
                           "external_traffic": any(v > 0 for v in delta.values())})
                log(f"phase idle: ambient delta={delta}")
            elif name == "gen1":
                self.phase("gen1", [lambda: self.native_gen(self.make_prompt(64), a.n_predict, False)
                                    for _ in range(a.reps)], 1)
            elif name.startswith("pp") and name[2:].rstrip("k").isdigit():
                nt = int(name[2:-1]) * 1024
                reps = 2 if nt >= 32768 else a.reps
                self.phase(name, [lambda: self.native_gen(self.make_prompt(nt), 16, False)
                                  for _ in range(reps)], 1)
            elif name == "cache8k":
                p = self.make_prompt(8192, unique=False)
                self.phase("cache8k_miss", [lambda: self.native_gen(p, 16, True)], 1)
                self.phase("cache8k_hit", [lambda: self.native_gen(p, 16, True)], 1)
            elif name in ("ctxgen32k", "ctxgen64k"):
                nt = 32768 if name.endswith("32k") else 65536
                self.phase(name, [lambda: self.native_gen(self.make_prompt(nt), 128, False)], 1)
            elif name in ("gen2", "gen4", "queue8"):
                c = {"gen2": 2, "gen4": 4, "queue8": 8}[name]
                self.phase(name, [lambda: self.native_gen(self.make_prompt(64), a.n_predict, False)
                                  for _ in range(c)], c)
            elif name == "pp4x8k":
                self.phase(name, [lambda: self.native_gen(self.make_prompt(8192), 16, False)
                                  for _ in range(4)], 4)
            elif name == "oai1":
                self.phase(name, [lambda: self.oai_gen(a.oai, None, a.model, a.n_predict)
                                  for _ in range(a.reps)], 1)
            elif name in ("lite1", "lite4"):
                key = os.environ.get("LITELLM_KEY")
                if not key:
                    log(f"skip {name}: LITELLM_KEY not set")
                    continue
                c = 1 if name == "lite1" else 4
                reps = a.reps if c == 1 else c
                self.phase(name, [lambda: self.oai_gen(a.litellm, key, a.model, a.n_predict)
                                  for _ in range(reps)], c)
            else:
                log(f"unknown phase {name}, skipping")


DEFAULT_PHASES = ("idle,gen1,oai1,lite1,pp2k,pp8k,pp32k,cache8k,ctxgen32k,ctxgen64k,"
                  "gen2,gen4,pp4x8k,queue8,lite4")


def self_test():
    # SSE parse + extract fold
    class FakeResp:
        def __iter__(self):
            return iter([
                b'data: {"content":"a","id_slot":2}\n',
                b'data: {"content":"","stop":false}\n',
                b'data: {"content":"b","stop":true,"timings":{"prompt_n":10,"prompt_ms":20.0,'
                b'"prompt_per_second":500.0,"predicted_n":2,"predicted_ms":100.0,"predicted_per_second":20.0}}\n',
            ])
    rec = {"ttfb": None, "ttft": None, "gen_chunks": 0}
    hits = []
    for obj in parse_sse(FakeResp(), lambda: hits.append(1)):
        native_extract(obj, rec, time.time())
    assert hits == [1], "on_first_data fired once"
    assert rec["gen_chunks"] == 2 and rec["slot"] == 2
    assert rec["server"]["predicted_per_second"] == 20.0
    # OAI extract
    rec2 = {"ttfb": None, "ttft": None, "gen_chunks": 0}
    oai_extract({"choices": [{"delta": {"content": "x"}}]}, rec2, time.time())
    oai_extract({"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 7}}, rec2, time.time())
    assert rec2["ttft"] is not None and rec2["usage"]["completion_tokens"] == 7
    print("self-test OK")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=".")
    p.add_argument("--native", default="http://127.0.0.1:8080")
    p.add_argument("--oai", default="http://127.0.0.1:8080/v1")
    p.add_argument("--litellm", default="http://10.8.0.9:4000/v1")
    p.add_argument("--model", default="thinkingcap-qwen3.6-27b")
    p.add_argument("--phases", default=DEFAULT_PHASES)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--n-predict", type=int, default=256)
    p.add_argument("--idle-secs", type=int, default=60)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--no-native", action="store_true", help="remote run: skip native endpoint + metrics gating")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args()
    if args.self_test:
        self_test()
        return
    os.makedirs(args.out, exist_ok=True)
    b = Bench(args)
    b.emit({"type": "meta", "t": time.time(), "host": os.uname().nodename, "args": vars(args)})
    b.run_phases([s.strip() for s in args.phases.split(",") if s.strip()])
    log("bench done")


if __name__ == "__main__":
    main()
