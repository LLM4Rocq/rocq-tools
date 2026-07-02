# Results report — AI-native Rocq tooling (DRAFT, filled as runs complete)

Every number here is reproducible from raw logs:
`python3 harness/report.py <run_id> [--compare baseline_dev60]` and
`python3 harness/profile.py <run_id>`. Plots: `harness/plots.py` (report phase).

## 1. Setup
- Substrate: Rocq 9.1.1 OCaml libraries (pinned switch, `repro/`), Apple M3 Max
  14-core / 96 GB, macOS 14.3.
- Policy (fixed for all configs): claude-haiku-4-5 via claude CLI 2.1.198
  headless, MCP tools only, ≤30 turns, ≤300 s/attempt, ≥2 reps.
- Datasets: rocq-workbook (dev; dataset difficulty labels), miniF2F-rocq valid
  (dev; tier→bucket proxy per A9), miniF2F-rocq test (held-out, locked).
- Correctness gate: locked prefix, forbidden-token region scan, fresh-dir
  recompile, Print Assumptions audit. Applied identically to every config.

## 2. Configs (the ladder)
| config | change vs predecessor |
|---|---|
| baseline | control: one `check` tool = full `rocq compile` of the whole file per call |
| session | persistent in-process prover; sentence `step` with commit-good-prefix, structured errors, O(1) rollback, goal rendering, per-sentence timeouts |
| session_try | + `try`: k candidate scripts speculatively evaluated in one call, first success auto-commits |
| (+compact) | + hypothesis-delta goal rendering, token-budgeted |
| (+search) | + budgeted `search` tool over the loaded libraries |

## 3. Efficiency results (dev60, 2 reps, per bucket)
_(tables inserted from report.py output as runs complete)_

### baseline (control) — run `baseline_dev60` (dev60 × 2 reps, parallel=4)

| metric | easy | medium | hard |
|---|---|---|---|
| pass@1 | 0.450 | 0.250 | 0.250 |
| pass@2 | 0.500 | 0.300 | 0.350 |
| rep_rate_std | 0.071 | 0.071 | 0.071 |
| turns_mean | 20.0 | 25.2 | 25.9 |
| tool_calls_mean | 18.9 | 23.6 | 23.4 |
| tokens_in_mean | 94 947 | 146 737 | 187 004 |
| tokens_out_mean | 7 350 | 11 973 | 16 721 |
| cost_usd_mean | 0.078 | 0.111 | 0.154 |
| wall_s_mean | 87.9 | 122.8 | 166.3 |
| prover_s_mean | 12.0 | 6.0 | 6.2 |
| call_ms_p50 / p95 | 239 / 313 | 263 / 292 | 268 / 315 |
| solved: wall_s / calls / out-tokens / $ | 30.0 / 6.2 / 2 946 / .029 | 32.5 / 7.2 / 2 876 / .031 | 82.5 / 11.6 / 9 141 / .080 |

Gate rejections: no_candidate 74, prefix_modified 6, admit/Admitted 2 — the
anti-gaming gate rejected 8 would-be "solves" that in-session compile accepted.
(16 sleep-contaminated attempts quarantined and redone; see incident log.)

### session vs baseline — run `session_dev60` — **KEPT**

pass@1: easy .475 (+.025), medium .325 (+.075, +30 %), hard .325 (+.075, +30 %);
pass@2: .55/.40/.45 vs .50/.30/.35. Rep-rate std halved (.035 vs .071).

| Δ vs baseline | easy | medium | hard |
|---|---|---|---|
| tokens_out_mean | −76 % | −79 % | −83 % |
| tokens_in_mean | −23 % | −30 % | −37 % |
| cost_usd_mean | −36 % | −45 % | −60 % |
| wall_s_mean | −42 % | −62 % | −70 % |
| prover_s_mean | −98 % | −98 % | −99 % |
| call_ms_p50 | 239→0.7 ms | 263→0.9 ms | 268→1.3 ms |
| solved: wall / out-tokens / $ | −37 % / −69 % / −17 % | −47 % / −72 % / −21 % | −82 % / −91 % / −74 % |

Interpretation: eliminating whole-file re-generation (output tokens −80 %) and
whole-file re-compilation (prover ms −98 %) converts directly into cheaper,
faster attempts AND more solves per turn budget — confirming the profiled
bottleneck (turns × output tokens, not compile seconds, dominate cost; but the
interface shape controls both). solved_tool_calls rose on easy (+22 %): calls
became ~free, so the policy takes more, smaller steps — the right trade.

### session_try vs session — run `session_try_dev60` — **KEPT**

pass@1: easy .650 (+.175, +37 %), medium .375 (+.05, +15 %), hard .375 (+.05,
+15 %). pass@2: .70/.40/.45 vs .55/.40/.45. Turns −15 %/−0 %/−8 %; cost flat
(−9 %/+1 %/−3 %); tokens_in +18 %/+25 %/+12 % (k verdicts per try response —
targeted by the next rung). Per-solved medium costs rose (+46 %) — a
composition effect: the marginal solves are harder problems entering the
conditional mean.

Interpretation: converting k model turns into one call with k speculative
verdicts materially raises solve rate at fixed turn budget — the strongest
evidence yet that turns-to-information is the binding constraint.

## 4. Profiling & hypotheses
- H1 (prover cost dominates): PARTIALLY REFUTED on easy — prover = 6% of wall;
  model API ≈ 90%. Re-examined per bucket below.
- H2 (context growth): input tokens grow ~330/turn (baseline, easy).
- H3 (blind flailing): failed checks are 58% syntax / 19% unknown-refs on easy
  baseline → feedback shape, not compile speed, is the binding constraint.
_(full tables from profile.py per run)_

## 5. Scalability (fixed batch, N ∈ {1,2,4,8,...})
PENDING — harness/sweep.py; makespan, attempts/hour, peak RSS, CPU%, per-call
latency degradation, per-bucket success at each N.

## 6. Ablations
_(one row per kept/reverted change, with the deciding numbers)_

## 7. Held-out (miniF2F test, single run of frozen winner)
LOCKED until freeze. Unlock event will be logged in logs/unlock.log.

## 8. Threats to validity
- Policy nondeterminism (no seed control in CLI) → ≥2 reps, variance reported.
- Shared machine: evals run alone under caffeinate; sleep-contaminated attempts
  flagged (`machine_slept`) and excluded from timing aggregates.
- Solve-rate differences shift the "per solved proof" conditioning set across
  configs; per-bucket reporting + identical problem sets mitigate composition
  effects; pass@k on identical reps.
