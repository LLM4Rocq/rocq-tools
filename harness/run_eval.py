#!/usr/bin/env python3
"""Eval runner.

For each problem in a manifest, spawns the pinned policy — `claude` CLI in
headless mode, MCP tools only — against the tool-layer config under test,
then verifies the outcome with the correctness gate (gate.py) and appends one
structured record per attempt to <run_dir>/results.jsonl.

Contract with tool servers (all configs): the server must write the current
best complete .v to $ROCQ_WORKDIR/candidate.v whenever a full check passes.
The gate re-verifies candidate.v from scratch; the in-session result is never
trusted.
"""

import argparse
import json
import os
import platform
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common
import datasets
import gate

CLAUDE_BIN = os.environ.get("CLAUDE_BIN", os.path.expanduser("~/.local/bin/claude"))


def build_task(rec):
    """(file prefix the agent must extend, theorem name)."""
    if rec["source"] == "workbook":
        prefix = datasets.workbook_problem_to_vfile(
            {
                "rocq_imports": rec["imports"],
                "rocq_preamble": rec["preamble"],
                "rocq_statement": rec["statement"],
            }
        )
    else:
        content = (common.WORKROOT / rec["path"]).read_text()
        prefix = datasets.statement_prefix(content)
        if not prefix.endswith("\n"):
            prefix += "\n"
    return prefix, rec["theorem_name"]


def aggregate_usage(events, result_event):
    """Token accounting; falls back to per-message events for killed runs."""
    if result_event is not None:
        u = result_event.get("usage", {})
        return {
            "input_tokens": u.get("input_tokens", 0),
            "output_tokens": u.get("output_tokens", 0),
            "cache_read_input_tokens": u.get("cache_read_input_tokens", 0),
            "cache_creation_input_tokens": u.get("cache_creation_input_tokens", 0),
            "total_cost_usd": result_event.get("total_cost_usd"),
            "estimated": False,
        }
    seen_msg, out_tok, in_last = set(), 0, 0
    for ev in events:
        if ev.get("type") != "assistant":
            continue
        msg = ev.get("message", {})
        mid = msg.get("id")
        u = msg.get("usage", {})
        if mid in seen_msg:
            continue
        seen_msg.add(mid)
        out_tok += u.get("output_tokens", 0)
        in_last = max(
            in_last,
            u.get("input_tokens", 0)
            + u.get("cache_read_input_tokens", 0)
            + u.get("cache_creation_input_tokens", 0),
        )
    return {
        "input_tokens": in_last,
        "output_tokens": out_tok,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "total_cost_usd": None,
        "estimated": True,
    }


def run_attempt(cfg, rec, rep, run_dir, run_id):
    prefix, thm = build_task(rec)
    aid = f"{rec['problem_id']}__rep{rep}"
    adir = run_dir / "attempts" / aid
    work = adir / "work"
    work.mkdir(parents=True, exist_ok=True)
    server_log = adir / "server.jsonl"
    meta = {
        "run_id": run_id,
        "config_id": cfg["config_id"],
        "problem_id": rec["problem_id"],
        "difficulty": rec["difficulty"],
        "source": rec["source"],
        "rep": rep,
        "agent_id": aid,
    }
    server_env = {
        "PATH": f"{common.OPAM_BIN}:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.environ.get("HOME", ""),
        "ROCQ_WORKDIR": str(work),
        "ROCQ_LOG_FILE": str(server_log),
        "ROCQ_LOG_META": json.dumps(meta),
    }
    server_env.update(cfg["server"].get("env", {}))
    server_cmd = cfg["server"]["command"].replace("{repo}", str(common.REPO))
    mcp_cfg = {
        "mcpServers": {
            cfg.get("mcp_server_name", "rocq"): {
                "command": server_cmd,
                "args": cfg["server"].get("args", []),
                "env": server_env,
            }
        }
    }
    (adir / "mcp.json").write_text(json.dumps(mcp_cfg, indent=1))
    task_prompt = cfg["task_prompt_template"].format(prefix=prefix)
    (adir / "task_prefix.v").write_text(prefix)
    cmd = [
        CLAUDE_BIN,
        "-p", task_prompt,
        "--model", cfg["model"],
        "--system-prompt", cfg["system_prompt"],
        "--strict-mcp-config", "--mcp-config", str(adir / "mcp.json"),
        "--tools", "",
        "--allowedTools", ",".join(cfg["allowed_tools"]),
        "--max-turns", str(cfg["max_turns"]),
        "--output-format", "stream-json", "--verbose",
    ]
    t0 = time.time()
    timed_out = False
    with open(adir / "transcript.jsonl", "w") as tf, open(adir / "stderr.log", "w") as ef:
        p = subprocess.Popen(
            cmd,
            stdout=tf,
            stderr=ef,
            stdin=subprocess.DEVNULL,
            cwd=adir,
            start_new_session=True,
        )
        try:
            p.wait(timeout=cfg["attempt_timeout_s"])
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
    wall_s = time.time() - t0

    events = common.read_jsonl(adir / "transcript.jsonl")
    result_event = next((e for e in reversed(events) if e.get("type") == "result"), None)
    usage = aggregate_usage(events, result_event)
    denials = (result_event or {}).get("permission_denials", [])

    server_records = common.read_jsonl(server_log)
    calls = [r for r in server_records if r.get("kind") == "tool_call"]
    prover_ms = sum(r.get("prover_ms", 0.0) for r in calls)
    tool_durs = [round(r.get("dur_ms", 0.0), 1) for r in calls]

    candidate_path = work / "candidate.v"
    if candidate_path.exists():
        gate_res = gate.check(candidate_path.read_text(), prefix, thm)
    else:
        gate_res = {"solved": False, "reason": "no_candidate", "axioms": None,
                    "recompile_s": None, "detail": None}

    record = {
        "ts": t0,
        "run_id": run_id,
        "config_id": cfg["config_id"],
        "model": cfg["model"],
        "problem_id": rec["problem_id"],
        "source": rec["source"],
        "difficulty": rec["difficulty"],
        "rep": rep,
        "seed": rep,
        "solved": gate_res["solved"],
        "reject_reason": gate_res["reason"],
        "gate": {k: v for k, v in gate_res.items() if k != "detail"},
        "wall_s": round(wall_s, 2),
        "attempt_timed_out": timed_out,
        "num_turns": (result_event or {}).get("num_turns"),
        "stop_reason": (result_event or {}).get("stop_reason"),
        "duration_ms": (result_event or {}).get("duration_ms"),
        "duration_api_ms": (result_event or {}).get("duration_api_ms"),
        "usage": usage,
        "total_cost_usd": usage.get("total_cost_usd"),
        "tool_calls": len(calls),
        "prover_ms_total": round(prover_ms, 1),
        "tool_dur_ms": tool_durs,
        "permission_denials": len(denials),
        "result_text": ((result_event or {}).get("result") or "")[:200],
        "attempt_dir": str(adir.relative_to(common.LOGS)),
    }
    if gate_res.get("detail"):
        (adir / "gate_reject.txt").write_text(gate_res["detail"])
    common.append_jsonl(run_dir / "results.jsonl", record)
    return record


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--run-id", default=None)
    ap.add_argument("--buckets", default=None, help="comma-separated difficulty filter")
    args = ap.parse_args()

    cfg = common.load_config(args.config)
    problems = common.load_manifest(args.manifest)
    if args.buckets:
        keep = set(args.buckets.split(","))
        problems = [p for p in problems if p["difficulty"] in keep]
    if args.limit:
        problems = problems[: args.limit]

    run_id = args.run_id or f"{cfg['config_id']}__{Path(args.manifest).stem}__{time.strftime('%m%d_%H%M%S')}"
    run_dir = common.LOGS / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    done = {(r["problem_id"], r["rep"]) for r in common.read_jsonl(run_dir / "results.jsonl")}
    todo = [
        (rec, rep)
        for rep in range(args.reps)
        for rec in problems
        if (rec["problem_id"], rep) not in done
    ]

    git_rev = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=common.REPO, capture_output=True, text=True
    ).stdout.strip()
    run_meta = {
        "run_id": run_id,
        "config": cfg,
        "manifest": args.manifest,
        "n_problems": len(problems),
        "reps": args.reps,
        "parallel": args.parallel,
        "git_rev": git_rev,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "cpu_count": os.cpu_count(),
        },
        "claude_bin": CLAUDE_BIN,
        "resumed_skipping": len(done),
    }
    (run_dir / "run_meta.json").write_text(json.dumps(run_meta, indent=1))
    print(f"[run {run_id}] {len(todo)} attempts (skipping {len(done)} done), "
          f"parallel={args.parallel}, model={cfg['model']}", flush=True)

    t0 = time.time()
    n_done = n_solved = 0
    with ThreadPoolExecutor(max_workers=args.parallel) as ex:
        futs = {
            ex.submit(run_attempt, cfg, rec, rep, run_dir, run_id): (rec, rep)
            for rec, rep in todo
        }
        for fut in as_completed(futs):
            rec, rep = futs[fut]
            try:
                r = fut.result()
                n_done += 1
                n_solved += r["solved"]
                print(
                    f"  [{n_done}/{len(todo)}] {r['problem_id']} rep{rep} "
                    f"{'SOLVED' if r['solved'] else 'no (' + str(r['reject_reason']) + ')'} "
                    f"turns={r['num_turns']} calls={r['tool_calls']} "
                    f"wall={r['wall_s']}s cost=${r['total_cost_usd'] or 0:.4f}",
                    flush=True,
                )
            except Exception as e:
                n_done += 1
                print(f"  [{n_done}/{len(todo)}] {rec['problem_id']} rep{rep} HARNESS-ERROR {e!r}", flush=True)
                common.append_jsonl(
                    run_dir / "results.jsonl",
                    {
                        "ts": time.time(), "run_id": run_id, "config_id": cfg["config_id"],
                        "problem_id": rec["problem_id"], "difficulty": rec["difficulty"],
                        "source": rec["source"], "rep": rep, "solved": False,
                        "reject_reason": f"harness_error:{type(e).__name__}",
                        "harness_error": repr(e),
                    },
                )
    print(f"[run {run_id}] done: {n_solved}/{n_done} solved in {time.time()-t0:.0f}s")


if __name__ == "__main__":
    main()
