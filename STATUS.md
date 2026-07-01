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
- [x] Environment scouted (switch, Rocq 9.2 OCaml libs, datasets, hardware, policy endpoint)
- [x] Branch `agent-tooling` created; scaffold committed
- [x] Probe: miniF2F .v compiles under Rocq 9.2 (deprecation warning only, exit 0)

## In progress
- [ ] Naive baseline: OCaml MCP server exposing a single `check` tool = full file
  `rocq compile` per call; JSONL instrumentation; eval harness
- [ ] coq-coquelicot + mathcomp install (background)

## Metrics vs baseline
_None yet — baseline being built._

## Decisions / assumptions since last check-in
See `docs/ASSUMPTIONS.md` (A1–A7): policy = claude CLI headless; tool layer = OCaml
MCP server on rocq-runtime libs; dev sampling stratified by dataset difficulty
labels; budgets above.

## Failures / recoveries
_None yet._

## Needs your input
_(empty — nothing blocking)_
