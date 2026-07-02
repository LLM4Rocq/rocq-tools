# Design rationale — an AI-native tooling layer for Rocq

Working doc. Every interface decision gets: the alternative considered, the
measured delta that justified it, and the config/ablation id that produced the
number. Decisions without numbers yet are marked [PENDING-MEASUREMENT].

## First-principles requirements (what an LLM agent actually needs)

Derived before building anything, to be validated/falsified by measurement:

1. **Feedback, not files.** A human watches a goal buffer evolve; an LLM pays
   tokens for every character it re-reads. The unit of feedback should be the
   *delta* caused by a command, rendered compactly, not the full buffer.
2. **Cheap backtracking.** LLM proof search is trial-heavy. If undo costs a full
   recompile, the agent is punished for exploring. Backtracking should be O(state
   swap), not O(replay).
3. **Errors as data.** Prover errors must arrive structured (location, kind,
   suggestion) so the policy can react without parsing prose.
4. **Batched hypotheses.** An LLM can propose k candidate tactics in one
   completion; a round-trip per candidate wastes latency and turns. The interface
   should accept a set and return which succeeded (first-success or all-results).
5. **Context is a budget.** Every tool result competes with the proof itself for
   context. Results need token budgets, truncation with explicit elision markers,
   and stable ids to re-fetch elided detail on demand.
6. **Parallelism is the norm.** Many agents will hammer the same prover install;
   session state must be isolated, cheap to create, and cheap to snapshot.

## Substrate decision

Link against installed Rocq 9.2 OCaml libraries (`rocq-runtime.*`), no source
changes to Rocq. The interaction core is built directly on the public vernac /
proof-engine API. [Baseline deliberately ignores all of the above requirements:
one `check(file)` tool, full `rocq compile` per call.]

## Interface iterations

(one section per kept/reverted change, with numbers — appended as measured)

### Profiling: the measured bottleneck (control run baseline_dev60, all buckets)

Wall decomposition (40 attempts/bucket): prover 4–6 % of wall; model API 76–90 %.
Prover per-call p50 = 262–267 ms across buckets — the flat cost of re-executing
`Require` + statement on every whole-file check. **Zero prover timeouts in 1 882
medium+hard calls**: the runaway-tactic hypothesis (H1's second half) is refuted
on this problem mix — the policy's failing tactics fail fast instead of hanging.

Failed-check taxonomy is stable across buckets: ~62 % syntax, ~14 % unknown
reference (hallucinated lemma names), ~10 % other. The policy pays a full model
turn (≈4 s API + a complete file rewrite of output tokens) to learn that one
token was wrong. Input tokens grow linearly per turn (~330/turn easy, ~550/turn
hard); with ~24 calls per failed attempt that compounds to 147–187 k prompt
tokens per failed attempt on medium/hard.

**Formal hypothesis for changes 2–3**: solve-rate and cost are bound by (a) the
number of model turns needed to find a working tactic sequence and (b) the
output tokens burned re-generating the whole file each turn. An interface that
(1) persists partial progress at sentence granularity, (2) reports the failing
sentence structurally, and (3) evaluates k candidate tactics per turn will cut
turns-per-solve, output-tokens-per-solve, and wall-per-solve, and should raise
per-bucket solve rate at fixed turn budget. Prover-side latency is a secondary
effect (266 ms → ~1 ms/interaction measured in the session smoke).

### Planned change ladder (each = one config, measured on dev60 vs predecessor)

1. `baseline` — control (naive whole-file check).
2. `session` — persistent in-process interpreter on rocq-runtime:
   sentence-level `step` (commit good prefix, report failing sentence
   structurally), O(1) `rollback` via Vernacstate snapshots, `state` rendering
   of open goals, per-sentence tactic timeout ≪ 60 s. Kills: whole-file
   re-generation (output tokens), whole-file re-compilation (prover ms), full
   context re-reads. **[KEPT — session_dev60 vs baseline_dev60: pass@1 +30 %
   on medium & hard, tokens_out −76…−83 %, cost −36…−60 %, wall −42…−70 %,
   call p50 266 ms → ~1 ms; every bucket, every metric]**
3. `session+try` — `try {candidates:[...]}`: k tactic candidates from ONE
   completion, evaluated speculatively against the same snapshot in-process;
   returns per-candidate verdict + resulting-goal digest. Converts k model
   turns into 1. **[KEPT — session_try_dev60 vs session_dev60: pass@1
   easy +37 %, medium/hard +15 %, cost flat, turns −8…−15 %; regression:
   tokens_in +12…25 % (bigger responses), addressed by rung 4]**
4. `+compact-state` — goal-delta rendering with token budgets + stable ids to
   re-fetch elided detail. [PENDING-MEASUREMENT]
5. `+search` — token-budgeted `Search`/`About` over the loaded environment,
   targeting the unknown_ref failure class. [PENDING-MEASUREMENT]

Order rationale: 2 unlocks 3-5 mechanically; 3 targets the measured dominant
cost (turns); 4 targets token growth; 5 targets the #2 error class.
