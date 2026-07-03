#!/usr/bin/env python3
"""Team eval runner (A12/A13): coordinator -> parallel workers -> finisher,
all attached to ONE shared-proof daemon, under ONE equal-wall budget so team
attempts are directly comparable to solo attempts on the same manifest.

    python3 harness/run_team.py --config team_k3 --manifest hard70 --reps 2

Per attempt:
  phase A  coordinator agent decomposes the goal (shared trunk)
  phase B  up to k worker agents, one per unowned open subgoal, CONCURRENTLY
  phase C  finisher agent mops up remaining goals + Qed
The daemon writes candidate.v on completion; the standard gate applies.
Records use the standard results.jsonl schema + team extras (n_workers,
phase_walls, goals_after_coordinator, per-phase usage)."""

import argparse
import hashlib
import json
import os
import signal
import socket as socketlib
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common
import datasets
import gate
from run_eval import CLAUDE_BIN, aggregate_usage, build_task, kill_attempt_tree


def daemon_rpc(sock_path, **kw):
    s = socketlib.socket(socketlib.AF_UNIX)
    s.settimeout(20)
    s.connect(sock_path)
    s.sendall((json.dumps(kw) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.decode(errors="replace"))


def run_agent(cfg, adir, mcp_cfg_path, agent_id, system_prompt, task_prompt,
              max_turns, wall_budget_s, klog):
    """One policy agent attached to the daemon via the shim. Returns usage dict."""
    out = adir / f"transcript_{agent_id}.jsonl"
    cmd = [
        CLAUDE_BIN, "-p", task_prompt,
        "--model", cfg["model"],
        "--system-prompt", system_prompt,
        "--strict-mcp-config", "--mcp-config", str(mcp_cfg_path),
        "--tools", "",
        "--allowedTools", ",".join(cfg["allowed_tools"]),
        "--max-turns", str(max_turns),
        "--output-format", "stream-json", "--verbose",
    ]
    t0 = time.time()
    with open(out, "w") as tf, open(adir / f"stderr_{agent_id}.log", "w") as ef:
        p = subprocess.Popen(cmd, stdout=tf, stderr=ef, stdin=subprocess.DEVNULL,
                             cwd=adir, start_new_session=True)
        try:
            p.wait(timeout=max(5.0, wall_budget_s))
        except subprocess.TimeoutExpired:
            klog(f"{agent_id}: wall budget {wall_budget_s:.0f}s exhausted, killing")
            kill_attempt_tree(p, klog)
            p.wait()
    events = common.read_jsonl(out)
    result_event = next((e for e in reversed(events) if e.get("type") == "result"), None)
    u = aggregate_usage(events, result_event)
    u["wall_s"] = round(time.time() - t0, 1)
    u["num_turns"] = (result_event or {}).get("num_turns")
    u["result_text"] = ((result_event or {}).get("result") or "")[:80]
    return u


def make_mcp_cfg(cfg, adir, sock_path, agent_id, server_log, meta):
    shim = cfg["shim_command"].replace("{repo}", str(common.REPO))
    mcp = {
        "mcpServers": {
            "rocq": {
                "command": shim,
                "args": [],
                "env": {
                    "ROCQ_SOCKET": sock_path,
                    "ROCQ_AGENT_ID": agent_id,
                    "ROCQ_LOG_FILE": str(server_log),
                    "ROCQ_LOG_META": json.dumps({**meta, "agent_id": agent_id}),
                },
            }
        }
    }
    p = adir / f"mcp_{agent_id}.json"
    p.write_text(json.dumps(mcp, indent=1))
    return p


def run_attempt(cfg, rec, rep, run_dir, run_id):
    prefix, thm = build_task(rec)
    bucket = datasets.bucket_of(rec)
    aid = f"{rec['problem_id']}__rep{rep}"
    adir = run_dir / "attempts" / aid
    work = adir / "work"
    work.mkdir(parents=True, exist_ok=True)
    (adir / "task_prefix.v").write_text(prefix)
    server_log = adir / "server.jsonl"
    kill_log = adir / "kill.log"

    def klog(msg):
        with open(kill_log, "a") as f:
            f.write(msg + "\n")

    meta = {"run_id": run_id, "config_id": cfg["config_id"],
            "problem_id": rec["problem_id"], "difficulty": bucket,
            "source": rec["source"], "rep": rep}
    sock_path = f"/tmp/rocqd_{hashlib.md5((run_id + aid).encode()).hexdigest()[:10]}.sock"
    daemon_cmd = cfg["server"]["command"].replace("{repo}", str(common.REPO))
    denv = {
        "PATH": f"{common.OPAM_BIN}:/usr/bin:/bin",
        "HOME": os.environ.get("HOME", ""),
        "ROCQ_TASK_FILE": str(adir / "task_prefix.v"),
        "ROCQ_WORKDIR": str(work),
        "ROCQ_SOCKET": sock_path,
        "ROCQ_LOG_FILE": str(server_log),
        "ROCQ_LOG_META": json.dumps(meta),
        **cfg["server"].get("env", {}),
    }
    if rec.get("rocq_args"):
        denv["ROCQ_INIT_ARGS"] = "\n".join(rec["rocq_args"])
    t0 = time.time()
    total_budget = cfg["attempt_timeout_s"]
    daemon = subprocess.Popen([daemon_cmd], env=denv,
                              stdout=subprocess.DEVNULL,
                              stderr=open(adir / "daemon.err", "w"),
                              start_new_session=True)
    phase_walls, usages = {}, {}
    n_workers = 0
    goals_after_coord = None
    try:
        # wait for socket
        for _ in range(120):
            if daemon.poll() is not None:
                raise RuntimeError("daemon died at startup")
            try:
                daemon_rpc(sock_path, op="status")
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.5)
        else:
            raise RuntimeError("daemon socket never came up")

        budgets = cfg["team"]["phase_budgets_s"]
        remaining = lambda: total_budget - (time.time() - t0)

        # phase A: coordinator
        pa = time.time()
        mcp = make_mcp_cfg(cfg, adir, sock_path, "coord", server_log, meta)
        usages["coord"] = run_agent(
            cfg, adir, mcp, "coord", cfg["coordinator_system"],
            cfg["coordinator_prompt"].format(prefix=prefix),
            cfg["team"]["coordinator_max_turns"],
            min(budgets["coordinator"], remaining()), klog)
        phase_walls["coordinator"] = round(time.time() - pa, 1)

        status = daemon_rpc(sock_path, op="status")
        if not status.get("complete") and remaining() > 15:
            goals = daemon_rpc(sock_path, op="goals").get("goals", [])
            open_goals = [g for g in goals if not g.get("owner")]
            goals_after_coord = len(open_goals)
            k = min(cfg["team"]["k_workers"], len(open_goals))
            # phase B: workers in parallel
            pb = time.time()
            wb = min(budgets["workers"], remaining())
            if k > 0 and wb > 10:
                with ThreadPoolExecutor(max_workers=k) as ex:
                    futs = {}
                    for i, g in enumerate(open_goals[:k]):
                        agid = f"w{i+1}"
                        mcp = make_mcp_cfg(cfg, adir, sock_path, agid, server_log, meta)
                        futs[ex.submit(
                            run_agent, cfg, adir, mcp, agid,
                            cfg["worker_system"],
                            cfg["worker_prompt_template"].format(
                                goal_id=g["id"], concl=g.get("concl", "?")),
                            cfg["team"]["worker_max_turns"], wb, klog)] = agid
                    for fut in as_completed(futs):
                        usages[futs[fut]] = fut.result()
                n_workers = k
            phase_walls["workers"] = round(time.time() - pb, 1)

        status = daemon_rpc(sock_path, op="status")
        if not status.get("complete") and remaining() > 10:
            # phase C: finisher
            pc = time.time()
            mcp = make_mcp_cfg(cfg, adir, sock_path, "fin", server_log, meta)
            usages["fin"] = run_agent(
                cfg, adir, mcp, "fin", cfg["finisher_system"],
                cfg["finisher_prompt"], cfg["team"]["finisher_max_turns"],
                min(budgets["finisher"], remaining()), klog)
            phase_walls["finisher"] = round(time.time() - pc, 1)
    finally:
        try:
            os.killpg(os.getpgid(daemon.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        daemon.wait()
        try:
            os.remove(sock_path)
        except OSError:
            pass
    wall_s = time.time() - t0

    candidate = work / "candidate.v"
    if candidate.exists():
        gate_res = gate.check(candidate.read_text(), prefix, thm)
    else:
        gate_res = {"solved": False, "reason": "no_candidate", "axioms": None,
                    "recompile_s": None, "detail": None}

    daemon_ops = [r for r in common.read_jsonl(server_log) if r.get("kind") == "daemon_op"]
    def tot(key, skip_none=False):
        vals = [u.get(key) for u in usages.values() if isinstance(u, dict)]
        if skip_none:
            vals = [v for v in vals if v is not None]
        return sum(v or 0 for v in vals) if vals else None
    record = {
        "ts": t0, "run_id": run_id, "config_id": cfg["config_id"],
        "model": cfg["model"], "problem_id": rec["problem_id"],
        "source": rec["source"], "difficulty": bucket, "rep": rep, "seed": rep,
        "solved": gate_res["solved"], "reject_reason": gate_res["reason"],
        "gate": {k: v for k, v in gate_res.items() if k != "detail"},
        "wall_s": round(wall_s, 2),
        "attempt_timed_out": wall_s > total_budget,
        "machine_slept": False,
        "num_turns": tot("num_turns", skip_none=True),
        "tool_calls": len(daemon_ops),
        "usage": {
            "input_tokens": tot("input_tokens"),
            "output_tokens": tot("output_tokens"),
            "cache_read_input_tokens": tot("cache_read_input_tokens"),
            "cache_creation_input_tokens": tot("cache_creation_input_tokens"),
            "estimated": any(u.get("estimated") for u in usages.values()),
        },
        "total_cost_usd": sum((u.get("total_cost_usd") or 0) for u in usages.values()) or None,
        "prover_ms_total": round(sum(r.get("dur_ms", 0) for r in daemon_ops), 1),
        "tool_dur_ms": [round(r.get("dur_ms", 0), 1) for r in daemon_ops],
        "permission_denials": 0,
        # team extras
        "team": {
            "n_workers": n_workers,
            "goals_after_coordinator": goals_after_coord,
            "phase_walls": phase_walls,
            "per_agent": {k: {kk: v.get(kk) for kk in
                              ("wall_s", "num_turns", "total_cost_usd", "result_text")}
                          for k, v in usages.items()},
        },
        "attempt_dir": str(adir.relative_to(common.LOGS)),
    }
    common.append_jsonl(run_dir / "results.jsonl", record)
    return record


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--parallel", type=int, default=2,
                    help="concurrent TEAM attempts (each spawns 1+k agents)")
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--run-id", default=None)
    args = ap.parse_args()

    cfg = common.load_config(args.config)
    problems = common.load_manifest(args.manifest)
    if args.limit:
        problems = problems[: args.limit]
    run_id = args.run_id or f"{cfg['config_id']}__{Path(args.manifest).stem}__{time.strftime('%m%d_%H%M%S')}"
    run_dir = common.LOGS / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    done = {(r["problem_id"], r["rep"]) for r in common.read_jsonl(run_dir / "results.jsonl")}
    todo = [(rec, rep) for rep in range(args.reps) for rec in problems
            if (rec["problem_id"], rep) not in done]
    (run_dir / "run_meta.json").write_text(json.dumps({
        "run_id": run_id, "config": cfg, "manifest": args.manifest,
        "n_problems": len(problems), "reps": args.reps, "parallel": args.parallel,
        "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "git_rev": subprocess.run(["git", "rev-parse", "HEAD"], cwd=common.REPO,
                                  capture_output=True, text=True).stdout.strip(),
    }, indent=1))
    print(f"[team run {run_id}] {len(todo)} attempts, parallel={args.parallel}", flush=True)
    n_done = n_solved = 0
    with ThreadPoolExecutor(max_workers=args.parallel) as ex:
        futs = {ex.submit(run_attempt, cfg, rec, rep, run_dir, run_id): (rec, rep)
                for rec, rep in todo}
        for fut in as_completed(futs):
            rec, rep = futs[fut]
            try:
                r = fut.result()
                n_done += 1
                n_solved += r["solved"]
                tw = r["team"]["phase_walls"]
                print(f"  [{n_done}/{len(todo)}] {r['problem_id']} rep{rep} "
                      f"{'SOLVED' if r['solved'] else 'no (' + str(r['reject_reason']) + ')'} "
                      f"workers={r['team']['n_workers']} phases={tw} "
                      f"wall={r['wall_s']}s cost=${(r['total_cost_usd'] or 0):.3f}", flush=True)
            except Exception as e:
                n_done += 1
                print(f"  [{n_done}/{len(todo)}] {rec['problem_id']} rep{rep} HARNESS-ERROR {e!r}", flush=True)
                common.append_jsonl(run_dir / "results.jsonl", {
                    "ts": time.time(), "run_id": run_id, "config_id": cfg["config_id"],
                    "problem_id": rec["problem_id"], "difficulty": datasets.bucket_of(rec),
                    "source": rec["source"], "rep": rep, "solved": False,
                    "reject_reason": f"harness_error:{type(e).__name__}",
                    "harness_error": repr(e)})
    print(f"[team run {run_id}] done: {n_solved}/{n_done}")


if __name__ == "__main__":
    main()
