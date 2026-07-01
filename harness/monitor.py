#!/usr/bin/env python3
"""Live monitoring view over run logs.

    python3 harness/monitor.py                 # summarize all runs
    python3 harness/monitor.py <run_id>        # one run, refresh every 5s
    python3 harness/monitor.py <run_id> --once
"""

import argparse
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common


def run_summary(run_dir: Path) -> str:
    rows = common.read_jsonl(run_dir / "results.jsonl")
    meta = {}
    mp = run_dir / "run_meta.json"
    if mp.exists():
        meta = json.loads(mp.read_text())
    total = meta.get("n_problems", 0) * meta.get("reps", 1)
    by_bucket = defaultdict(lambda: [0, 0])
    cost = 0.0
    rejects = defaultdict(int)
    for r in rows:
        b = by_bucket[r.get("difficulty", "?")]
        b[0] += 1
        b[1] += bool(r.get("solved"))
        cost += r.get("total_cost_usd") or 0.0
        if r.get("reject_reason"):
            rejects[r["reject_reason"]] += 1
    lines = [
        f"=== {run_dir.name}  [{meta.get('config', {}).get('config_id', '?')}] "
        f"{len(rows)}/{total or '?'} attempts done  cost=${cost:.2f}"
    ]
    for bucket in sorted(by_bucket):
        n, s = by_bucket[bucket]
        lines.append(f"  {bucket:>8}: {s}/{n} solved ({100*s/max(n,1):.0f}%)")
    if rejects:
        lines.append(
            "  rejects: " + ", ".join(f"{k}×{v}" for k, v in sorted(rejects.items(), key=lambda kv: -kv[1]))
        )
    # attempts started but not finished
    attempts_dir = run_dir / "attempts"
    if attempts_dir.exists():
        done_ids = {f"{r['problem_id']}__rep{r['rep']}" for r in rows if "rep" in r}
        active = []
        now = time.time()
        for d in attempts_dir.iterdir():
            if d.name not in done_ids:
                try:
                    age = now - d.stat().st_mtime
                    active.append(f"{d.name}({age:.0f}s)")
                except OSError:
                    pass
        if active:
            lines.append(f"  in-flight: {', '.join(sorted(active)[:8])}")
    if rows:
        last = sorted(rows, key=lambda r: r.get("ts", 0))[-3:]
        for r in last:
            lines.append(
                f"  last: {r['problem_id']} rep{r.get('rep')} "
                f"{'SOLVED' if r.get('solved') else r.get('reject_reason')} "
                f"wall={r.get('wall_s')}s calls={r.get('tool_calls')}"
            )
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run", nargs="?", default=None)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--interval", type=float, default=5.0)
    args = ap.parse_args()

    runs_root = common.LOGS / "runs"
    if args.run is None:
        for d in sorted(runs_root.iterdir()) if runs_root.exists() else []:
            if d.is_dir():
                print(run_summary(d) + "\n")
        return
    run_dir = Path(args.run) if Path(args.run).exists() else runs_root / args.run
    while True:
        out = run_summary(run_dir)
        if not args.once:
            print("\033[2J\033[H", end="")
        print(out, flush=True)
        if args.once:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
