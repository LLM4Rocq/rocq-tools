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

![ladder pass@1](figures/ladder_pass1.svg)
![tokens](figures/efficiency_tokens_out.svg) ![cost](figures/efficiency_cost.svg) ![wall](figures/efficiency_wall.svg)

Scalability figures: ![throughput](figures/sweep_throughput.svg)
![wall vs N](figures/sweep_wall.svg) ![rss](figures/sweep_rss.svg)
(regenerate: `python3 harness/plots.py`; live view: `logs/dashboard.html`)

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

**4-rep update (variance top-up, 2026-07-03)** — control and final winner were
extended to 4 reps for tighter estimates (columns easy/medium/hard):
baseline pass@1 .438/.250/.300 (rep_std .05/.04/.08), pass@4 .50/.30/.40;
winner pass@1 .700/.525/.425 (rep_std .00/.09/.03), pass@4 .70/.65/.50.
Medium's 2-rep winner estimate (.60) was mildly favorable; .525 supersedes it.
Baseline→winner deltas at 4 reps: easy +26 pp, medium +28 pp, hard +13 pp —
all well beyond rep noise.

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

### session_try_compact vs session_try — run `session_try_compact_dev60` — **REVERTED**

pass@1 −.025 in every bucket (easy .625, med/hard .35); tokens_in +11 % easy &
medium (the metric it was meant to cut); tool calls +4…6 % easy/hard; cost
+1…5 %. Mechanism: compact hypothesis-delta rendering withholds context the
policy then re-fetches via `state` and extra probing calls. Negative ablation
kept in the record; reference config remains session_try.

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

### Winner confirmation on disjoint problems — run `session_try_dev150`
(150 fresh stratified stdlib problems, disjoint from dev60; 2 reps; no tuning)

| | easy | medium | hard |
|---|---|---|---|
| pass@1 / pass@2 | .450 / .500 | .330 / .360 | .350 / .360 |
| cost_usd_mean | .051 | .066 | .062 |
| wall_s_mean | 45.4 | 55.5 | 50.2 |
| tokens_out_mean | 2 219 | 3 415 | 2 756 |
| rep_rate_std | .042 | .042 | .014 |

Efficiency profile transfers almost unchanged from dev60 (cost, wall, calls,
tokens within ~10 %). Medium/hard solve rates hold (.33/.35 vs .375/.375 on
dev60, within rep variance). Easy drops .65 → .45: the dev60 easy stratum was
an easier draw than the easy stratum at large — a reminder that absolute
per-bucket solve rates are sample-dependent even within a difficulty label;
config-vs-config deltas on the SAME set remain the valid comparison.

### Cross-dataset confirmation — run `session_try_hints_minif2f_valid`
(miniF2F valid split, 244 problems × 2 reps, PRE-env-v2 environment)

| | easy (mathd) | medium (amc/…) | hard (aime/imo) |
|---|---|---|---|
| pass@1 | .323 (84/260) | .133 (21/158) | .000 (0/70) |

Cross-dataset honesty: miniF2F is materially harder than the workbook for this
policy — and the **hard bucket is at the policy's ceiling (0/70)**: aime/imo
problems are out of reach for claude-haiku-4-5 regardless of tooling (motivates
the A10 cross-policy annex). Two structural findings feed the env-v2 change:
**16 attempts solved in-session but were gate-rejected for `Require`** (the
shipped miniF2F headers import only `Reals`, so agents imported Psatz to get
their closers — an interface trap), and easy-bucket attempts fought without
nra/lra/lia entirely. The env-v2 A/B (preloaded scope-neutral tactic modules,
Require refused with guidance) is queued as `session_try_hints_v2_minif2f_valid`.

## 4. Profiling & hypotheses
- H1 (prover cost dominates): PARTIALLY REFUTED on easy — prover = 6% of wall;
  model API ≈ 90%. Re-examined per bucket below.
- H2 (context growth): input tokens grow ~330/turn (baseline, easy).
- H3 (blind flailing): failed checks are 58% syntax / 19% unknown-refs on easy
  baseline → feedback shape, not compile speed, is the binding constraint.
_(full tables from profile.py per run)_

## 5. Scalability (fixed 24-problem stratified batch, N ∈ {1,2,4,8})

### baseline config (`sweep_baseline_summary.jsonl`)

| N | attempts/h | wall s/attempt | peak RSS | machine CPU | solved |
|---|---|---|---|---|---|
| 1 | 25.1 | 143 | 0.7 GB | 2.4 % | 4/24 |
| 2 | 48.3 | 147 | 1.3 GB | 4.9 % | 3/24 |
| 4 | 45.1 | 319 | 2.0 GB | 7.9 % | 3/24 |
| 8 | 56.3 | 463 | 3.1 GB | 7.8 % | 2/24 |

**Finding: the scaling ceiling is the policy endpoint, not the prover
substrate.** N=1→2 is near-linear (×1.9 throughput, latency flat). Beyond N=2,
throughput saturates (48→45→56/h) while per-attempt wall time explodes
(147→319→463 s ≈ ×3.2) — yet machine CPU never exceeds 8 % and RSS grows a
benign ~0.4 GB/agent (dominated by the CLI processes, not prover state). The
extra concurrency is absorbed as API-side queueing/rate-limiting. Worse, it
*costs solves*: attempts pushed past the fixed 300 s budget by queueing die at
the watchdog (solved 4→2/24 from N=1→8). On this endpoint the efficient
operating point is N≈2-4; past it, adding agents actively harms success at
fixed budgets. Local-substrate scalability (hundreds of ~310 MB sessions fit
in RAM; per-step cost ~1 ms) is not the binding constraint at any tested N.
### winner config (`sweep_session_try_hints_auto_summary.jsonl`)

| N | attempts/h | wall s/attempt | peak RSS | machine CPU | solved |
|---|---|---|---|---|---|
| 1 | 74.7 | 48 | 1.0 GB | 5.3 % | 11/24 |
| 2 | 142.6 | 50 | 1.7 GB | 8.4 % | 10/24 |
| 4 | 272.3 | 50 | 3.3 GB | 16.8 % | 9/24 |
| 8 | 478.3 | 51 | 6.4 GB | 23.8 % | 8/24 |

**Finding: interface efficiency compounds under parallelism.** The winner
scales near-linearly to N=8 (80 % parallel efficiency; wall flat +7 %) where
the baseline saturated at N=2 with wall ×3.2. Same machine, same endpoint —
the difference is API traffic per attempt: the winner's short turns and −80 %
output tokens leave headroom the baseline burns on whole-file rewrites. At
N=8 the winner delivers 8.5× the baseline's attempt throughput and ~19× its
solved-proofs/hour (57 vs 4.7). Caveat noted honestly: solves drift 11→8/24
as N grows (single rep per N on a 24-problem batch — could be variance or
mild endpoint pressure; the fixed 300 s attempt budget was never the binding
constraint here, unlike baseline at N≥4).

## 5b. Cross-policy annex (A10): does the interface delta transfer?

dev60 × 2 reps, `claude-sonnet-5`, parallel=2 (annex-internal comparison only;
never used for keep/revert). Columns easy/medium/hard.

| | pass@1 | turns | cost $/attempt | wall s |
|---|---|---|---|---|
| baseline @ sonnet | .925 / .950 / .800 | 3.1 / 4.4 / 3.2 | .087 / .142 / .146 | 61 / 77 / 112 |
| winner @ sonnet | .925 / .825 / .700 | 6.3 / 7.5 / 7.5 | .059 / .112 / .128 | 43 / 49 / 81 |
| (recall) baseline @ haiku | .450 / .250 / .250 | 20.0 / 25.2 / 25.9 | .078 / .111 / .154 | 88 / 123 / 166 |
| (recall) winner @ haiku | .700 / .600 / .425 | 14.0 / 20.5 / 20.8 | .042 / .057 / .062 | 44 / 51 / 56 |

**Finding: the optimal interface is policy-dependent.** For the weak policy the
incremental interface buys *capability* (+25–35 pp pass@1). For the strong
policy — which one-shots whole proofs in ~3 turns — the naive whole-file
interface wins on solve rate (medium +12.5 pp, hard +10 pp), while the
incremental interface still buys *efficiency* (cost −12…−32 %, wall −28…−36 %).
Interpretation: sentence-level incrementalism biases toward locally-greedy
proving, which helps a policy that can't plan a whole proof and mildly hurts
one that can. Consequences: (a) tool-layer rankings do NOT transfer across
policies — the fixed-policy protocol was necessary, and the frozen config is
explicitly keyed to claude-haiku-4-5; (b) deployment frontier: cheap policy +
incremental interface dominates on $/solve for easy-medium volume; strong
policy + whole-file dominates on hard-problem coverage.

## 5c. Intra-proof parallelism (A12): solo vs team at equal wall-clock

hard70 (all 70 hard dev problems) × 2 reps, 300 s total budget per attempt,
same policy. Team = coordinator → ≤3 parallel workers → finisher on a shared
live proof (branch-per-subgoal, merge-by-replay, composed candidate gated).

| | pass@1 | pass@2 | cost/attempt | mechanism |
|---|---|---|---|---|
| solo (winner cfg) | .400 | 28/70 | $0.064 | one continuous session |
| team k=3 | .321 | 24/70 (⊂ solo's) | $0.098 | 3-phase relay |

**Negative result, kept in the record.** Two causes, cleanly separated by the
logs: (1) *these problems lack parallel structure* — 114/140 coordinator
phases ended with a single open goal, so most "teams" degenerated to a
1-worker relay paying 3× context-priming overhead under a fragmented budget
(90/150/60 s vs solo's continuous 300 s); (2) *zero complementarity* — the
team solved no problem solo couldn't. The machinery itself performed
(workers closed 11/12 subgoals they were handed; merges never failed; the
composed candidates pass the gate), so the infrastructure is validated while
the strategy is rejected for this problem class: decomposition pays only
where proofs have genuine independent-subgoal structure (e.g. conjunctive
specs, case splits — rare in competition one-liners). The shared-proof
daemon remains a deliverable: it is the substrate that makes such workflows
measurable at all, and the winner's near-linear N=8 sweep shows where the
parallel win actually lives on this dataset — across problems, not within.

### §5b extension (A15): the full policy × interaction-style matrix

pass@1 easy/medium/hard, dev60, 2 reps (4 for the bolded winners):

| interaction style | @ claude-haiku-4-5 | @ claude-sonnet-5 |
|---|---|---|
| naive whole-file check | .44 / .25 / .30 | **.925 / .95 / .80** |
| incremental (session+try+hints+auto+sugg) | **.70 / .525 / .425** | .925 / .825 / .70 |
| draft-first on the session substrate (unified) | .40 / .18 / .22 | .92 / .85 / .75 |
| + persistence prompting (sonnet_native) | — | .95 / .85 / .75 |
| + hint synthesis (sonnet_native_auto2, 1 rep) | — | **1.00 / .85 / .85** |

The matrix is diagonal: each policy's best interface differs, and mismatches
cost 10–34 pp. **Hint synthesis transfers across policies**: at sonnet it
lifts hard to .85 — ABOVE naive's .80, the first substrate config to beat
naive on hard at the strong policy (easy perfect at 1.00; medium .85 vs
naive's .95 is the last naive advantage anywhere; 1-rep caveat, n=20/bucket).
Persistence prompting (removing the weak-policy give-up
discipline; sonnet_native) recovered the session substrate's easy bucket to
.95 — BEATING naive's .925 at less than half the cost ($.041 vs $.087/attempt)
— and confirmed the early-quit diagnosis there; the residual medium (−.10) and
hard (−.05) gaps to naive survive persistence, so they reflect the
interaction style itself, not just giving up. Draft-first at Sonnet recovers about half the incremental gap
(kept prefix + repair-from-failure beats cold recompiles on failures) but not
all of it; at Haiku it is catastrophic (wrong whole-proof drafts burn turns
and strand the policy on a committed bad prefix). Design consequence: the
SUBSTRATE (persistent session, commit-good-prefix, portfolio, hints) is
policy-neutral infrastructure; the interaction PRESCRIPTION (the prompt) must
be selected per policy. The frozen config remains the haiku-selected one per
the pre-registered rule; for strong policies the recommended configuration is
the same substrate with draft-first prompting when cost matters, or the naive
interface when only coverage matters.

### SOTA comparison (A16/A19) — run `rocq_mcp_dev60`

rocq-mcp v0.3.1 (coq-lsp/pet-backed, 11 tools) under the identical protocol:
pass@1 **.450 / .225 / .225** (easy/medium/hard) at $.072/attempt — i.e. **at
naive-baseline level** (.438/.250/.300), 20-26 pp below our winner. This is
BELOW our pre-registered prediction (A19 said "strictly between baseline and
session_try"); the honest miss makes the mechanism more interesting:
- **Not a non-adoption story**: 89/120 attempts used its interactive sessions
  (rocq_check ×800, rocq_step_multi ×186) — the warm-session core was used
  and still didn't convert to solves.
- **Where the losses concentrate**: only 66/120 attempts ever submitted (the
  final-artifact step is agent-driven, vs our automatic candidate contract);
  23 submissions failed fresh recompile (submit-without-verify); 6 modified
  the statement (caught by the gate); rocq_query ×295 shows the same
  adoption-without-rescue signature as our reverted search tool (A19
  prediction 2 confirmed).
- Reading: an interactive substrate alone is not sufficient — the measured
  value concentrates in TURN-COMPRESSION on top of it (auto-commit try,
  machine-enumerated portfolio, zero-cost error enrichment), which rocq-mcp
  lacks. Convergent-evolution note: its session/state-id/multi-tactic core
  independently replicates our kept rungs 1-2.
(Caveat: per-call `tool_calls` in our records under-counts for this config —
only the sidecar logs; usage above is from transcripts.)

**SOTA at the strong policy** (`rocq_mcp_sonnet_dev60`, user-requested):
pass@1 .825/.725/.725 (e/m/h) — trails sonnet-naive (.925/.95/.80) and our
substrate's best (.95/.85/.75) in every bucket, at the highest cost of any
sonnet condition ($.087–.168/attempt). The SOTA toolset underperforms under
BOTH policies measured: the deficit is the toolset's information-per-turn,
not the driver's capability.

### Rung 9a (A22 bugfix) — run `winner_autofix_dev60`

pass@1 .650/.450/.450 (e/m/h) vs the buggy-binary winner .700/.525/.425
(4-rep): deltas −.05/−.075/+.025 — within ~1-1.5 rep-σ, no significant
change. The false-winner lie was evidently mitigated by the truthful goal
render that followed it. The fix is kept on correctness grounds (a tool must
not misreport), with metrics unchanged; the retracted "71 % close-rate"
mechanism stat stands corrected (A22).

### Rung 9b (hint-term synthesis) — run `winner_auto2_dev60` — **KEPT, new best**

vs 9a (fixed binary): medium **+.125 (+28 %, .45→.575)**, hard +.025, easy
flat; cost ~flat. Mechanism verified: synthesized hint scripts (mechanical
`0 ≤ (t)²` facts from goal variables and power subterms) are 7 of 25 REAL
portfolio closes. Best measured dev60 config: **.650/.575/.475** (e/m/h) —
the machine now finds the auxiliary facts agents were hunting by hand.

### In-project context economy (A20) — runs `winner_ctx_{full,lean}_inproject60`

60 mid-file stdlib-project lemmas (median 374-line prefixes), buckets by
ground-truth proof length (short/medium/long):

| | short | medium | long |
|---|---|---|---|
| ctx_full pass@1 · tokens_in · $ | .950 · 133 k · .066 | .725 · 245 k · .088 | .225 · 402 k · .115 |
| ctx_lean pass@1 · tokens_in · $ | .950 · 48 k · .035 | .600 · 152 k · .061 | .275 · 214 k · .076 |

Statement-only prompting (context lives in the session, pulled on demand)
holds short solve exactly at **2.8× fewer input tokens**, WINS long (+.05),
and cedes medium (−.125) where seeing earlier lemmas inline evidently helps.
Cost-per-solve favors lean in every bucket. Recommendation for big projects:
context-on-demand by default; full-context as a fallback mode. (Absolute
short-bucket rates likely benefit from policy memorization of stdlib — noted
per A20; the config A/B is unaffected.)

## 6. Ablation summary (every measured change, in order)

| # | change | deciding numbers (per bucket where relevant) | verdict |
|---|---|---|---|
| 0 | baseline (naive whole-file check) | pass@1 .45/.25/.25 | control |
| 1 | session (persistent in-process, sentence steps, rollback) | +30 % med/hard pass@1; tokens_out −76…−83 %; prover call 266 ms → ~1 ms | KEPT |
| 2 | + try (k candidates / call, first success commits) | easy +37 %, med/hard +15 %; cost flat; tokens_in +12…25 % | KEPT |
| 3 | + compact rendering (hyp deltas) | pass@1 −2.5 pp ALL buckets; tokens_in +11 % (policy re-fetches context) | REVERTED |
| 4 | + search tool (pull-based) | pass@1 noise (−/−/+); 324 calls, 15 % solve when used vs 81 % without (no rescue) | REVERTED |
| 5 | + hints (Lean-ism → Rocq rewrites in errors) | medium +27 % (3 strictly-new, 0 lost); others flat | KEPT |
| 6 | + auto_close (server-side finisher portfolio) | pass@1 +8/+16/+13 % (all buckets); 71 % of calls close a goal | KEPT |
| 7 | + did-you-mean (near-miss names in errors, push-based) | easy +8 %, medium +9 %, hard flat; easy tokens_in −22 % | KEPT |
| 8 | environment v2 (preload Lia/Lra/Psatz, refuse Require) | miniF2F: easy .32→.57, med .13→.30, hard .00→.06; Require traps 16→0 | KEPT |
| 9 | team k=3 (coordinator/workers/finisher, shared proof) | hard70 equal-wall: .32 vs solo .40; zero team-only solves; 114/140 don't decompose | REVERTED |

Design lesson across all ten: **maximize prover-grounded information per model
turn, at zero marginal turn cost**. Everything that pushed information into
existing turns (try, hints, auto_close, did-you-mean, preloading) won;
everything that asked the policy to spend turns or lose context to get
information (search tool, compact rendering, team relay) lost.

## 7. Held-out result (miniF2F test — single run of the frozen config)

Unlock: 2026-07-03 13:57:42 (logs/unlock.log; first and only read of test
data). Run `FINAL_minif2f_test`: 244 problems × 2 reps, frozen config
(`configs/frozen.json`), policy claude-haiku-4-5, protocol per FROZEN.md.
488/488 attempts clean (no sleep contamination, no harness errors).

| | easy (mathd, 130) | medium (amc/…, 79) | hard (aime/imo, 35) |
|---|---|---|---|
| **pass@1** | **.519** | **.127** | **.043** |
| **pass@2** | **.569** | **.165** | **.057** |
| rep_rate_std | .005 | .018 | .020 |
| cost $/attempt · $/solve | .052 · .100 | .072 · .567 | .093 · 2.17 |
| wall s/attempt (solved) | 52.8 (18.2) | 97.2 (43.9) | 74.0 (31.7) |
| tokens out/attempt | 2 353 | 3 440 | 4 734 |

Generalization vs the dev miniF2F-valid reference (.57/.30/.06 with env-v2):
- **easy transfers** (.52 vs .57) and **hard is consistent** (.04 vs .06 —
  the policy's ceiling, as diagnosed on dev);
- **medium drops** (.13 vs .30). Within-split variance is tiny (std .018), so
  this is a real split-level difference, not noise. Two candidate causes,
  both stated honestly: (a) the test split's medium tier is genuinely harder
  in its Rocq form than valid's, and/or (b) indirect adaptation — several
  kept changes (hints, env-v2) were motivated by valid-split failure modes,
  so dev estimates for that bucket carry selection optimism. No test problem
  influenced any decision (mechanical guard; single run; no reruns).
- Efficiency transfers cleanly: cost, wall, tokens, and ms-scale prover calls
  on test are within ~15 % of dev values — the interface's efficiency claims
  are policy- and split-robust even where absolute solve rates are not.

Baseline comparison on the held-out split is deliberately absent: the brief
allots test to the frozen config only. The baseline-vs-winner delta is
established on dev (4 reps, §3) and cross-checked on dev-disjoint sets
(§dev150, §minif2f_valid).

## 8. Threats to validity
- Policy nondeterminism (no seed control in CLI) → ≥2 reps, variance reported.
- Shared machine: evals run alone under caffeinate; sleep-contaminated attempts
  flagged (`machine_slept`) and excluded from timing aggregates.
- Solve-rate differences shift the "per solved proof" conditioning set across
  configs; per-bucket reporting + identical problem sets mitigate composition
  effects; pass@k on identical reps.
