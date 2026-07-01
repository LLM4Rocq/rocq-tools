# STATUS — AI-native Rocq tooling experiment

_Last updated: 2026-07-01 23:15 (run start)_

## TL;DR
Run just started. Environment scouted, repo scaffolded, plan and budgets fixed.
Building the naive baseline (full `rocq compile` per tool call) next.

## Environment (recorded)
- Hardware: Apple M3 Max, 14 cores, 96 GB RAM, macOS 14.3
- Dedicated opam switch: `/Users/gbaudart/Project/llm4rocq/rocq-tools` (local switch)
- OCaml 5.3.0 · Rocq 9.2.0 (rocq-runtime/rocq-core 9.2.0, rocq-stdlib 9.1.0) · dune 3.23.1
- Extra deps installed for this experiment: `yojson 3.0.0`; `coq-coquelicot` +
  `coq-mathcomp-ssreflect` install in progress (needed by ~10% of dataset files)
- Agent policy: `claude` CLI 2.1.198, headless (`claude -p --output-format json`),
  MCP tools only, model pinned (exact model recorded in configs once first run executes)

## Datasets
- Dev/tuning: `../rocq-workbook/rocq_workbook_10k.jsonl` (10k problems, has
  `difficulty` ∈ {easy, medium, hard} and `rocq_library` labels; 8,936 stdlib-only)
- Dev also: `../miniF2F-rocq/valid` (244 .v files)
- HELD-OUT: `../miniF2F-rocq/test` (244 .v) — **locked**; a mechanical guard will
  refuse harness access until a `final_unlock` flag is set; unlock will be logged.

## Budgets (HARD limits, fixed 2026-07-01)
- Wall-clock: run ends 2026-07-06 EOD; final day reserved for frozen-config
  held-out eval + report.
- Per proof attempt: ≤ 16 policy turns, ≤ 300 s wall-clock (fixed across configs).
- Iteration eval set: "dev60" = 60 stratified workbook problems (20 easy / 20
  medium / 20 hard, stdlib-only), fixed seed; kept changes re-validated on a
  larger stratified set + miniF2F valid subset.
- ≥ 2 repetitions per config for mean/variance on kept changes.

## Done
- [x] Environment scouted; branch `agent-tooling`; scaffold committed
- [x] OCaml MCP server framework (JSON-RPC stdio + JSONL instrumentation) + naive
  baseline server (`check` = full `rocq compile` per call) — smoke-tested
- [x] claude CLI headless contract probed empirically (flags, token accounting,
  silent-permission-denial gotcha → harness asserts `permission_denials == []`;
  custom `--system-prompt` cuts ~70k cached tokens/turn ≈ 10× cost)
- [x] Dataset manifests: dev60 / dev150 (disjoint, stratified stdlib-only, seed
  42), smoke5, minif2f_valid; mechanical held-out guard on miniF2F test
  (FINAL_UNLOCK file + ROCQ_FINAL_EVAL=1, unlock logged) — verified locked
- [x] Correctness gate (layered anti-gaming): locked prefix, forbidden-token scan
  on comment-stripped agent region, fresh recompile, Print Assumptions audit.
  Unit-tested incl. tamper cases
- [x] Eval harness + report + monitor; smoke run: 4/5 easy solved, $0.018/attempt

## In progress
- [ ] **baseline_dev60_r1**: naive baseline on dev60 × 2 reps (120 attempts,
  parallel=4) — running in background
- [ ] rocq-runtime 9.1 OCaml API mapping (for the in-process session server)

## Pre-registered bottleneck hypotheses (to test in profiling step)
- H1: prover time = flat re-`Require` overhead per call + runaway tactics hitting
  the 60 s compile timeout (smoke: call p95 = 60.6 s = timeout ceiling)
- H2: token cost = agent re-sends the full file every call; input tokens grow
  ~quadratically over a session
- H3: failures = blind flailing; agent can't see intermediate goal state after a
  partial failure, so it rewrites whole proofs

## Metrics vs baseline
Baseline being measured now (see logs/runs/baseline_dev60_r1; monitor:
`python3 harness/monitor.py baseline_dev60_r1 --once`).
Smoke (5 easy, 1 rep): 4/5 solved, mean $0.018, mean 7 tool calls, prover 38 s
of 74 s wall (dominated by one timeout-looping attempt).

## Decisions / assumptions since last check-in
See `docs/ASSUMPTIONS.md` A1–A8. Notable: **Rocq downgraded 9.2.0 → 9.1.1** by
the Coquelicot install (compat shims cap at 9.1.1) — accepted, recorded, pinned;
policy budget clarified to ≤30 CLI turns (≈14 tool round-trips) per attempt.

## Failures / recoveries
- coq-coquelicot/mathcomp not in default opam repo → added rocq-released +
  coq-released repos (switch-scoped); solver then downgraded Rocq (see above).

## Needs your input
_(empty — nothing blocking)_
