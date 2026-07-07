#!/usr/bin/env python3
"""Counterfactual portfolio replay over recorded failures (zero policy cost).

For every FAILED attempt of the given runs:
  1. reconstruct the final committed proof state (task prefix + the sentences
     the agent successfully committed, mined from server.jsonl),
  2. reload that state in a fresh session server (prover only, no model),
  3. run a candidate finisher set against it,
  4. record which failures a richer portfolio would have closed at zero
     additional model turns.

    python3 harness/replay_counterfactual.py --runs winner_auto2_dev60 ... \
        --out logs/counterfactual.jsonl [--limit N]

Candidate sets are defined in CANDIDATE_SETS below; each failure is tested
against every set, so results decompose per addition. A rescue is only
counted if the full file then passes the standard gate.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common
import gate

SESSION_EXE = str(common.REPO / "_build/default/src/session_server/rocq_agent_session.exe")

# candidate finisher sets, cumulative story: v2 = shipped portfolio (control;
# should rescue ~0 since auto_close already ran in-attempt), then additions.
CANDIDATE_SETS = {
    "v2_shipped": [],  # empty marker: just auto_close with ROCQ_AUTO2
    "v3_intros": ["intros. lra.", "intros. lia.", "intros. nia.",
                  "intros. ring_simplify. nra."],
    "v3_field": ["field_simplify. lra.", "field_simplify. nra.",
                 "intros. field_simplify. nra."],
    "v3_deep_nra": ["ring_simplify. intros. nra.", "intros. ring_simplify. nra."],
}


def committed_sentences(server_log, attempt_meta):
    """Mine the sentences that ended up committed, in order, from server.jsonl.
    Strategy: replay the log's commit/rollback events."""
    committed = []
    for rec in common.read_jsonl(server_log):
        if rec.get("kind") != "tool_call":
            continue
        meta = rec.get("meta") or {}
        if attempt_meta and any(meta.get(k) != v for k, v in attempt_meta.items()):
            continue
        tool, res = rec.get("tool"), rec.get("result") or ""
        args = rec.get("args") or {}
        if tool == "rollback":
            try:
                n = int((json.loads(args) if isinstance(args, str) else args).get("count", 1))
            except (ValueError, AttributeError, json.JSONDecodeError):
                n = 1
            committed = committed[:-n] if n <= len(committed) else []
        elif tool in ("step", "check") and "committed" in res:
            committed.append(("_from_result", rec))
        elif tool == "try" and "COMMITTED" in res:
            committed.append(("_from_result", rec))
        elif tool == "auto_close" and "COMMITTED" in res:
            committed.append(("_from_result", rec))
    return committed


def mine_committed_text(server_log, attempt_meta):
    """Best-effort reconstruction: use the server's own progress reports.
    The step/try/auto_close results include the executed sentences; rather
    than parse them all, we rely on the state line 'committed proof:' from
    the LAST state-bearing result, falling back to None."""
    last = None
    for rec in common.read_jsonl(server_log):
        if rec.get("kind") != "tool_call":
            continue
        meta = rec.get("meta") or {}
        if attempt_meta and any(meta.get(k) != v for k, v in attempt_meta.items()):
            continue
        res = rec.get("result") or ""
        if "committed proof:" in res:
            seg = res.split("committed proof:", 1)[1]
            # the render ends at the goals block
            for stop in ("\ngoals:", "\n(no proof open)"):
                if stop in seg:
                    seg = seg.split(stop, 1)[0]
            seg = seg.strip()
            if seg and seg != "(nothing committed yet)":
                last = seg
    return last


def replay_one(prefix, committed_text, workdir):
    """Load prefix+committed in a fresh server, run auto_close per candidate
    set. Returns {set_name: closed_bool_via_gate}."""
    workdir.mkdir(parents=True, exist_ok=True)
    task = workdir / "task.v"
    task.write_text(prefix)
    out = {}
    for name, extra in CANDIDATE_SETS.items():
        wd = workdir / name
        wd.mkdir(exist_ok=True)
        env = {
            "PATH": f"{common.OPAM_BIN}:/usr/bin:/bin",
            "HOME": str(Path.home()),
            "ROCQ_TASK_FILE": str(task),
            "ROCQ_WORKDIR": str(wd),
            "ROCQ_ENV_V2": "1",
            "ROCQ_AUTO2": "1",
            "ROCQ_ENABLE_TOOLS": "step,auto_close",
        }
        if extra:
            env["ROCQ_PORTFOLIO_EXTRA"] = "\n".join(extra)
        msgs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        ]
        mid = 2
        if committed_text:
            msgs.append({"jsonrpc": "2.0", "id": mid, "method": "tools/call",
                         "params": {"name": "step",
                                    "arguments": {"text": committed_text}}})
            mid += 1
        msgs.append({"jsonrpc": "2.0", "id": mid, "method": "tools/call",
                     "params": {"name": "auto_close", "arguments": {}}})
        inp = "".join(json.dumps(m) + "\n" for m in msgs)
        try:
            subprocess.run([SESSION_EXE], input=inp, env=env, timeout=120,
                           capture_output=True, text=True)
        except subprocess.TimeoutExpired:
            out[name] = False
            continue
        cand = wd / "candidate.v"
        if cand.exists():
            r = gate.check(cand.read_text(), prefix, theorem_name_of(prefix))
            out[name] = bool(r.get("solved"))
        else:
            out[name] = False
    return out


def theorem_name_of(prefix):
    import re
    m = re.search(r"\b(?:Theorem|Lemma)\s+([A-Za-z0-9_']+)", prefix)
    return m.group(1) if m else "goal"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", nargs="+", required=True)
    ap.add_argument("--out", default=str(common.LOGS / "counterfactual.jsonl"))
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    outp = Path(args.out)
    done = {(r["run"], r["attempt"]) for r in common.read_jsonl(outp)} if outp.exists() else set()
    n = 0
    for run in args.runs:
        rdir = common.LOGS / "runs" / run
        for rec in common.read_jsonl(rdir / "results.jsonl"):
            if rec.get("solved"):
                continue
            aid = f"{rec['problem_id']}__rep{rec.get('rep', 0)}"
            if (run, aid) in done:
                continue
            adir = rdir / "attempts" / aid
            slog = adir / "server.jsonl"
            tpf = adir / "task_prefix.v"
            if not slog.exists() or not tpf.exists():
                continue
            committed = mine_committed_text(slog, None)
            t0 = time.time()
            res = replay_one(tpf.read_text(), committed,
                             Path("/tmp") / "cfr" / run / aid)
            row = {"run": run, "attempt": aid, "bucket": rec.get("difficulty"),
                   "committed_mined": bool(committed),
                   "rescued": res, "wall_s": round(time.time() - t0, 1)}
            with open(outp, "a") as f:
                f.write(json.dumps(row) + "\n")
            n += 1
            print(f"[{n}] {run}/{aid} rescued={ {k: v for k, v in res.items() if v} or '{}' }")
            if args.limit and n >= args.limit:
                return
    print(f"done: {n} failures replayed -> {outp}")


if __name__ == "__main__":
    main()
