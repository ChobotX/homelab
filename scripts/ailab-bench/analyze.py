#!/usr/bin/env python3
"""Summarize a bench run: per-phase rates + sampler correlation.

Usage: python3 analyze.py RUN_DIR
Self-check: python3 analyze.py --self-test
"""
import csv
import json
import statistics
import sys


def load(run_dir):
    reqs, phases = [], []
    with open(f"{run_dir}/results.jsonl") as f:
        for line in f:
            o = json.loads(line)
            if o["type"] == "request":
                reqs.append(o)
            elif o["type"] == "phase":
                phases.append(o)
    samples = []
    try:
        with open(f"{run_dir}/system.csv") as f:
            for row in csv.DictReader(f):
                samples.append(row)
    except OSError:
        pass
    return reqs, phases, samples


def fnum(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def req_rates(r):
    """Return (prompt_tps, gen_tps, prompt_n, gen_n) preferring server timings."""
    s = r.get("server") or {}
    if s.get("predicted_per_second"):
        return s.get("prompt_per_second"), s.get("predicted_per_second"), s.get("prompt_n"), s.get("predicted_n")
    u = r.get("usage") or {}
    gen_n = u.get("completion_tokens") or r.get("gen_chunks") or 0
    gen_time = (r.get("total") or 0) - (r.get("ttft") or 0)
    gen_tps = gen_n / gen_time if gen_time > 0 and gen_n else None
    return None, gen_tps, u.get("prompt_tokens"), gen_n


def phase_window_stats(ph, samples):
    win = [s for s in samples if ph["t0"] <= (fnum(s["ts"]) or 0) <= ph["t1"]]
    if not win:
        return {}
    def col(name):
        vals = [fnum(s.get(name)) for s in win]
        return [v for v in vals if v is not None]
    out = {}
    for name, agg in (("gpu_util_pct", "mean"), ("power_w", "mean"), ("sm_mhz", "mean"),
                      ("temp_c", "max"), ("load1", "max"), ("req_deferred", "max"),
                      ("req_processing", "max")):
        vals = col(name)
        if vals:
            out[name + "_" + agg] = round(statistics.mean(vals) if agg == "mean" else max(vals), 1)
    return out


def summarize(run_dir):
    reqs, phases, samples = load(run_dir)
    by_phase = {}
    for r in reqs:
        by_phase.setdefault(r["phase"], []).append(r)

    print(f"{'phase':<14}{'n':>3}{'err':>4}{'ttft_s':>8}{'pp_tps':>9}{'gen_tps':>9}"
          f"{'agg_gen':>9}{'wall_s':>8}  flags")
    for ph in phases:
        name = ph["name"]
        rs = by_phase.get(name, [])
        errs = sum(1 for r in rs if r.get("error"))
        ok = [r for r in rs if not r.get("error")]
        rates = [req_rates(r) for r in ok]
        ttfts = [r["ttft"] for r in ok if r.get("ttft")]
        pp = [x[0] for x in rates if x[0]]
        gen = [x[1] for x in rates if x[1]]
        gen_n = sum(x[3] or 0 for x in rates)
        wall = ph.get("wall") or (ph["t1"] - ph["t0"])
        agg = gen_n / wall if wall and gen_n else None
        w = phase_window_stats(ph, samples)
        flags = []
        if ph.get("external_traffic"):
            flags.append("EXTERNAL-TRAFFIC")
        if w.get("req_deferred_max", 0) > 0:
            flags.append(f"deferred_max={w['req_deferred_max']:.0f}")
        if w.get("gpu_util_pct_mean") is not None:
            flags.append(f"gpu={w['gpu_util_pct_mean']:.0f}% {w.get('power_w_mean', 0):.0f}W {w.get('sm_mhz_mean', 0):.0f}MHz")
        if w.get("load1_max") is not None and w["load1_max"] > 4:
            flags.append(f"load1_max={w['load1_max']}")
        fmt = lambda v, p=1: f"{v:.{p}f}" if v is not None else "-"
        print(f"{name:<14}{len(rs):>3}{errs:>4}{fmt(statistics.mean(ttfts), 2) if ttfts else '-':>8}"
              f"{fmt(statistics.mean(pp)) if pp else '-':>9}{fmt(statistics.mean(gen)) if gen else '-':>9}"
              f"{fmt(agg):>9}{fmt(wall):>8}  {' '.join(flags)}")

    ext = [p["name"] for p in phases if p.get("external_traffic")]
    if ext:
        print(f"\nWARN external traffic overlapped: {', '.join(ext)} — treat those numbers as contaminated")


def self_test():
    r = {"server": {"prompt_per_second": 400.0, "predicted_per_second": 8.0,
                    "prompt_n": 100, "predicted_n": 50}}
    assert req_rates(r) == (400.0, 8.0, 100, 50)
    r2 = {"usage": {"prompt_tokens": 10, "completion_tokens": 20}, "ttft": 1.0, "total": 5.0}
    pp, gen, pn, gn = req_rates(r2)
    assert pp is None and abs(gen - 5.0) < 1e-9 and gn == 20
    ph = {"t0": 10.0, "t1": 12.0}
    samples = [{"ts": "10.5", "gpu_util_pct": "50", "power_w": "40", "sm_mhz": "2400",
                "temp_c": "60", "load1": "1.0", "req_deferred": "2", "req_processing": "4"},
               {"ts": "11.5", "gpu_util_pct": "70", "power_w": "60", "sm_mhz": "2400",
                "temp_c": "62", "load1": "1.2", "req_deferred": "0", "req_processing": "4"}]
    w = phase_window_stats(ph, samples)
    assert w["gpu_util_pct_mean"] == 60.0 and w["req_deferred_max"] == 2.0
    print("self-test OK")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
    else:
        summarize(sys.argv[1])
