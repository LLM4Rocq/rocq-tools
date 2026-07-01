#!/usr/bin/env python3
"""Build the evaluation manifests under <repo>/data/manifests/.

Outputs:
  dev60.jsonl          20 per difficulty, workbook, stdlib only, seed 42
  dev150.jsonl         50 per difficulty, same pools, disjoint from dev60
  smoke5.jsonl         5 easy stdlib problems, seed 7 (debug only, may overlap)
  minif2f_valid.jsonl  all 244 miniF2F valid problems (content stays on disk)

Sampling procedure (deterministic):
  * pool = workbook records with rocq_library == "stdlib", grouped by
    difficulty and sorted by name;
  * one random.Random(42) generator; for each difficulty in
    (easy, medium, hard) order, draw rng.sample(pool, 70) in one pass:
    the first 20 go to dev60, the next 50 to dev150 (hence disjoint);
  * smoke5 = random.Random(7).sample(easy_pool, 5).

Never touches the held-out miniF2F test split (see harness/datasets.py).
"""

import collections
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import datasets

OUT_DIR = os.path.join(datasets.REPO_ROOT, "data", "manifests")


def workbook_record(rec, difficulty):
    return {
        "problem_id": rec["name"],
        "source": "workbook",
        "difficulty": difficulty,
        "theorem_name": datasets.theorem_name(rec["rocq_statement"]),
        "imports": rec["rocq_imports"],
        "preamble": rec["rocq_preamble"],
        "statement": rec["rocq_statement"],
        "rocq_proved": bool(rec["rocq_proved"]),
    }


def write_jsonl(name, records):
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"wrote {path}: {len(records)} records")
    return path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    workbook = datasets.load_workbook()
    stdlib = [r for r in workbook if r["rocq_library"] == "stdlib"]
    pools = {}
    for diff in ("easy", "medium", "hard"):
        pools[diff] = sorted(
            (r for r in stdlib if r["difficulty"] == diff),
            key=lambda r: r["name"],
        )
        print(f"stdlib pool {diff}: {len(pools[diff])} problems")

    # dev60 / dev150: one seed-42 generator, 70 per difficulty in one pass.
    rng = random.Random(42)
    dev60, dev150 = [], []
    for diff in ("easy", "medium", "hard"):
        picked = rng.sample(pools[diff], 70)
        dev60.extend(workbook_record(r, diff) for r in picked[:20])
        dev150.extend(workbook_record(r, diff) for r in picked[20:70])

    # smoke5: 5 easy stdlib problems, seed 7 (may overlap dev60/dev150).
    smoke5 = [
        workbook_record(r, "easy")
        for r in random.Random(7).sample(pools["easy"], 5)
    ]

    # minif2f_valid: all valid problems; content stays on disk.
    minif2f = []
    for p in datasets.load_minif2f("valid"):
        minif2f.append(
            {
                "problem_id": p["problem_id"],
                "source": "minif2f_valid",
                "difficulty": p["source_tier"],  # tier = difficulty proxy
                "source_tier": p["source_tier"],
                "theorem_name": p["theorem_name"],
                "has_shipped_proof": p["proof_status"] == "qed",
                "proof_status": p["proof_status"],
                "path": p["path"],
            }
        )

    write_jsonl("dev60.jsonl", dev60)
    write_jsonl("dev150.jsonl", dev150)
    write_jsonl("smoke5.jsonl", smoke5)
    write_jsonl("minif2f_valid.jsonl", minif2f)

    # ---- summary stats -------------------------------------------------
    print("\n== summary ==")
    for name, recs in (("dev60", dev60), ("dev150", dev150), ("smoke5", smoke5)):
        by_diff = collections.Counter(r["difficulty"] for r in recs)
        proved = sum(r["rocq_proved"] for r in recs)
        print(f"{name}: {len(recs)} problems, by difficulty {dict(by_diff)}, "
              f"rocq_proved={proved}")
    ids60 = {r["problem_id"] for r in dev60}
    ids150 = {r["problem_id"] for r in dev150}
    print(f"dev60 ∩ dev150 = {len(ids60 & ids150)} (must be 0)")
    for name, recs in (("dev60", dev60), ("dev150", dev150),
                       ("smoke5", smoke5), ("minif2f_valid", minif2f)):
        ids = [r["problem_id"] for r in recs]
        assert len(ids) == len(set(ids)), f"duplicate problem_ids in {name}"
    assert not (ids60 & ids150), "dev60 and dev150 overlap"
    tiers = collections.Counter(r["source_tier"] for r in minif2f)
    print(f"minif2f_valid: {len(minif2f)} problems, tiers "
          f"{dict(sorted(tiers.items()))}")
    status = collections.Counter(r["proof_status"] for r in minif2f)
    print(f"minif2f_valid shipped-proof status: {dict(sorted(status.items()))}")


if __name__ == "__main__":
    main()
