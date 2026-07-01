#!/usr/bin/env python3
"""Metrics from run logs — every number in the report is reproducible by:

    python3 harness/report.py <run_dir> [<run_dir2> ...] [--compare BASE_RUN]

Groups by (config, difficulty bucket); never pools buckets in comparisons.
"""

import argparse
import json
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common


def pctl(xs, q):
    if not xs:
        return None
    xs = sorted(xs)
    i = min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))
    return xs[i]


def fmt(x, nd=1):
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:.{nd}f}"
    return str(x)


def load_run(run_dir: Path):
    rows = common.read_jsonl(run_dir / "results.jsonl")
    for r in rows:
        r["_run_dir"] = run_dir
    return rows


def bucket_stats(rows):
    """rows -> dict with per-bucket aggregate metrics."""
    out = {}
    by_bucket = defaultdict(list)
    for r in rows:
        by_bucket[r.get("difficulty", "?")].append(r)
    for bucket, rs in sorted(by_bucket.items()):
        solved = [r for r in rs if r.get("solved")]
        by_problem = defaultdict(list)
        for r in rs:
            by_problem[r["problem_id"]].append(bool(r.get("solved")))
        pass_at_k = st.mean(1.0 if any(v) else 0.0 for v in by_problem.values())
        # per-rep success rates -> variance across reps
        by_rep = defaultdict(list)
        for r in rs:
            by_rep[r.get("rep", 0)].append(bool(r.get("solved")))
        rep_rates = [st.mean(v) for v in by_rep.values() if v]

        def m(key, rows_, scale=1.0, nd=None):
            vals = [r[key] * scale for r in rows_ if isinstance(r.get(key), (int, float))]
            return st.mean(vals) if vals else None

        tool_durs = [d for r in rs for d in (r.get("tool_dur_ms") or [])]
        out[bucket] = {
            "attempts": len(rs),
            "problems": len(by_problem),
            "solved": len(solved),
            "pass@1": st.mean([1.0 if r.get("solved") else 0.0 for r in rs]),
            f"pass@{max(len(v) for v in by_problem.values())}": pass_at_k,
            "rep_rate_std": st.stdev(rep_rates) if len(rep_rates) > 1 else 0.0,
            "turns_mean": m("num_turns", rs),
            "tool_calls_mean": m("tool_calls", rs),
            "tokens_out_mean": st.mean([r["usage"]["output_tokens"] for r in rs if r.get("usage")]) if any(r.get("usage") for r in rs) else None,
            "tokens_in_mean": st.mean(
                [r["usage"]["input_tokens"] + r["usage"]["cache_read_input_tokens"] + r["usage"]["cache_creation_input_tokens"] for r in rs if r.get("usage")]
            ) if any(r.get("usage") for r in rs) else None,
            "cost_usd_mean": m("total_cost_usd", rs),
            "wall_s_mean": m("wall_s", rs),
            "prover_s_mean": m("prover_ms_total", rs, 0.001),
            "call_ms_p50": pctl(tool_durs, 0.5),
            "call_ms_p95": pctl(tool_durs, 0.95),
            # efficiency per solved proof
            "solved_wall_s_mean": m("wall_s", solved),
            "solved_tool_calls_mean": m("tool_calls", solved),
            "solved_tokens_out_mean": st.mean([r["usage"]["output_tokens"] for r in solved if r.get("usage")]) if solved else None,
            "solved_cost_usd_mean": m("total_cost_usd", solved),
            "reject_reasons": dict(
                sorted(
                    (
                        (reason, sum(1 for r in rs if r.get("reject_reason") == reason))
                        for reason in {r.get("reject_reason") for r in rs if r.get("reject_reason")}
                    ),
                    key=lambda kv: -kv[1],
                )
            ),
        }
    return out


METRIC_ORDER = [
    "attempts", "problems", "solved", "pass@1", "rep_rate_std",
    "turns_mean", "tool_calls_mean", "tokens_in_mean", "tokens_out_mean",
    "cost_usd_mean", "wall_s_mean", "prover_s_mean", "call_ms_p50", "call_ms_p95",
    "solved_wall_s_mean", "solved_tool_calls_mean", "solved_tokens_out_mean",
    "solved_cost_usd_mean",
]


def print_table(title, stats):
    buckets = list(stats.keys())
    print(f"\n## {title}\n")
    keys = METRIC_ORDER + sorted(
        k for k in next(iter(stats.values())).keys()
        if k not in METRIC_ORDER and k != "reject_reasons"
    )
    print("| metric | " + " | ".join(buckets) + " |")
    print("|---" * (len(buckets) + 1) + "|")
    for k in keys:
        vals = []
        for b in buckets:
            v = stats[b].get(k)
            nd = 3 if ("pass@" in k or "cost" in k or "std" in k) else 1
            vals.append(fmt(v, nd))
        print(f"| {k} | " + " | ".join(vals) + " |")
    for b in buckets:
        rr = stats[b].get("reject_reasons") or {}
        if rr:
            print(f"- rejects[{b}]: " + ", ".join(f"{k}×{v}" for k, v in rr.items()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dirs", nargs="+")
    ap.add_argument("--compare", default=None, help="baseline run dir for deltas")
    args = ap.parse_args()

    def resolve(d):
        p = Path(d)
        return p if p.exists() else common.LOGS / "runs" / d

    all_stats = {}
    for d in args.run_dirs:
        rd = resolve(d)
        rows = load_run(rd)
        if not rows:
            print(f"(no results in {rd})")
            continue
        cfg = rows[0].get("config_id", rd.name)
        stats = bucket_stats(rows)
        all_stats[rd.name] = stats
        print_table(f"{rd.name} (config={cfg})", stats)

    if args.compare:
        base = bucket_stats(load_run(resolve(args.compare)))
        for name, stats in all_stats.items():
            print(f"\n## Δ {name} vs {args.compare} (per bucket)\n")
            buckets = [b for b in stats if b in base]
            print("| metric | " + " | ".join(buckets) + " |")
            print("|---" * (len(buckets) + 1) + "|")
            for k in METRIC_ORDER:
                row = []
                for b in buckets:
                    a, c = stats[b].get(k), base[b].get(k)
                    if isinstance(a, (int, float)) and isinstance(c, (int, float)):
                        d = a - c
                        pct = f" ({100*d/c:+.0f}%)" if c else ""
                        row.append(f"{d:+.3g}{pct}")
                    else:
                        row.append("-")
                print(f"| {k} | " + " | ".join(row) + " |")


if __name__ == "__main__":
    main()
