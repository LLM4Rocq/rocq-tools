# Autonomous decisions & assumptions log

Every decision made without user input, with reasoning. Numbered, append-only.

## A1 — Agent policy = `claude` CLI headless
No raw API key is present in the environment; the `claude` CLI (2.1.198) is the
only configured, authenticated LLM endpoint. Policy runs use
`claude -p --output-format json --strict-mcp-config --mcp-config <cfg>` with all
built-in tools disabled, so the ONLY actions available to the policy are the tools
under test. Token usage and cost are read from the CLI JSON result. Model is
pinned per run and held fixed across configs.

## A2 — Policy model: `claude-haiku-4-5`
Reasoning: hundreds of proof attempts across configs/ablations/repetitions make a
small-fast model the only affordable fixed policy; Haiku 4.5 is tool-use capable.
Risk: low solve rate on hard bucket → mitigated by reporting per-bucket numbers
and efficiency metrics that are defined for failures too (tokens/calls/latency per
attempt). Will be revisited ONLY if the easy bucket solves ≈0 on the baseline
(would make deltas unmeasurable); any change would be recorded and all configs
re-run — the policy is held fixed across every comparison in the report.

## A3 — Tool layer implemented as an OCaml MCP stdio server
The agent-facing interface is the deliverable, so it is implemented in OCaml as a
first-class binary (`rocq-agent-mcp`) speaking MCP JSON-RPC over stdio, linking
rocq-runtime libraries in-process where the config calls for it. MCP is chosen
because it is the native tool protocol of the fixed policy endpoint (claude CLI);
the protocol adapter is thin and identical across configs, so measured deltas come
from the tool semantics, not transport differences. No existing Rocq MCP server
code is used or consulted.

## A4 — Working-directory layout interpretation
The task says the working dir contains `rocq-workbook/`, `minif2f/`, `rocq-tools/`.
Actual names: `rocq-workbook/`, `miniF2F-rocq/` (test+valid splits), `rocq-tools/`
(the empty git repo, where this project lives). `miniF2F-rocq/valid` = the "train"
split used as dev; `miniF2F-rocq/test` = held-out (the dataset ships no separate
train, valid is the conventional dev split for miniF2F).

## A5 — Difficulty labels
- rocq-workbook: use the dataset's own `difficulty` field (easy/medium/hard).
- miniF2F: no explicit difficulty label in the .v files; proxy = problem source
  tier extracted from the filename (amc → easy-tier, aime → medium-tier,
  imo → hard-tier, mathd_* → course-tier easy) — documented in the report; both
  splits contain the same source families so stratification holds by construction.

## A6 — Budgets
Fixed 2026-07-01, printed in STATUS.md: run ends 2026-07-06 EOD; per proof attempt
≤ 16 policy turns and ≤ 300 s; dev60 iteration set (20/20/20 stratified,
stdlib-only, seed 42); ≥ 2 reps for kept changes. Rationale: keeps a full dev60
eval under ~1 h so several ablation cycles fit per day, while leaving the final
day for the frozen run + report.

## A7 — Switch amendments (and a Rocq downgrade)
The dedicated switch lacked `yojson` (JSON for the OCaml server) and the libraries
~10% of dataset files import. Installed and pinned: yojson 3.0.0,
coq-coquelicot 3.4.4, (rocq-)mathcomp-ssreflect 2.5.0 (repos `rocq-released` +
`coq-released` added, scoped to this switch). Side effect: the opam solver
**downgraded Rocq 9.2.0 → 9.1.1** (the coq-* compat shims Coquelicot needs cap at
9.1.1). Accepted: verified datasets still compile identically and the project
builds; Coquelicot coverage is worth more than the newer point release. The
experiment substrate is therefore **Rocq 9.1.1 / OCaml 5.3.0**, pinned in
repro/opam-packages.txt.

## A10 — Cross-policy robustness annex (user-requested, 2026-07-02)
The ladder is selected under the fixed policy (A2, claude-haiku-4-5) per the
brief. As a robustness annex — not a selection criterion — baseline and the
final winner are additionally measured once with a stronger policy
(`claude-sonnet-5`, 2 reps, dev60) to report whether the interface deltas
transfer across policy strength. Hypothesis: structural wins (session/try)
transfer; the hints delta shrinks (it targets Haiku-specific Lean-isms).
Runs tagged `*_sonnet`; never used for keep/revert decisions or the freeze.

## A13 — Team experiments are first-class experiment citizens (user steer)
The multi-agent workstream follows the exact same discipline as the solo
ladder: (a) problems come from the dev manifests (team manifest = the hard
bucket of dev60+dev150, 70 problems, both configs run the SAME problems);
(b) the daemon emits the standard JSONL instrumentation (ts, latency, op,
agent id, prover ms, run/config/problem metadata); (c) team attempts produce
standard results.jsonl records (schema-compatible + team extras: n_workers,
phase walls, per-agent usage) so report.py/monitor.py/dashboard work
unchanged; (d) the correctness gate applies identically to the composed
candidate.v; (e) the solo-vs-team comparison is a config A/B at EQUAL total
wall-clock, reported per bucket like every other ablation.

## A12 — Intra-proof parallelism directive (user steer, 2026-07-02 evening)
The tool layer must generalize to large-scale projects: parallel agents working
on DIFFERENT PARTS of the SAME proof (multi-agent workflows for hard problems).
Plan: (1) rung: fork-based `parallel_close` — attack all open subgoals
simultaneously in COW child processes; (2) architecture: shared session daemon
(Unix socket) + thin MCP shims so multiple policy agents attach to one live
proof with goal-scoped focus/commit; (3) experiment: coordinator + k workers
vs solo agent at EQUAL wall-clock budget on the hard bucket (pass@equal-budget
is the honest metric). Enabling primitive already in place: immutable
Vernacstate snapshots make any subgoal shippable to any worker.

## A9 — miniF2F difficulty buckets from source tiers
Filename-prefix tiers map to buckets: mathd_algebra + mathd_numbertheory → easy
(course problems, 130/244 per split); amc12* + algebra + numbertheory +
induction → medium (79); aime* + imo* + imosl → hard (35). Rationale:
competition tier is the only difficulty signal in miniF2F and is standard
practice; both splits contain the same families, so dev/test stay comparable.
Recorded per-record as `source_tier`; the mapping lives in
`datasets.MINIF2F_TIER_TO_BUCKET` and is applied at record-writing time.

## A8 — Proof-region discipline (anti-gaming)
The agent may only append content AFTER the shipped theorem statement; the file
prefix (imports + preamble + statement) must match the dataset file exactly
(whitespace-normalized). Rationale: inserting imports/scopes/notations before the
statement can silently change what the statement means (e.g. `Open Scope`
re-parsing `+`), which is unauditable at scale. Helper facts remain expressible
via `assert`/`have` inside the proof. Uniform across all configs, so it cannot
bias comparisons.

## A14 — Pipeline acceleration (user steer, 2026-07-03)
(1) parallel=8 adopted as the standard for winner-family dev runs, justified by
the measured sweep (wall +7 %, CPU 24 % at N=8; near-linear throughput); any
compared pair must share N. (2) The held-out run is pulled forward: freeze
committed (FROZEN.md); unlock+final chained behind the 4-rep variance top-up
the same day. The one-shot discipline is sequence-based (frozen before
unlock), not calendar-based. Final runs at parallel=4 per the frozen protocol.

## A15 — Policy-robustness objective (user steer, 2026-07-03)
The tool layer must serve multiple policies including the strongest, not be a
Haiku-specialized artifact. Design response: the Sonnet regression traces to
the prompted interaction STYLE, not the tools — `step` already accepts whole
proof scripts with commit-good-prefix semantics (strictly more informative
than a whole-file check at identical turn cost). New `unified` config =
frozen toolset + draft-first/repair-from-failure prompting; measured on dev60
vs all four existing controls (haiku/sonnet × naive/winner). Test split is
already spent on the frozen config per the brief's freeze-then-test sequence;
unified evidence is dev-only and framed as the recommended config going
forward.

## A16 — SOTA comparison against rocq-mcp (user-requested, 2026-07-03 ~16:45)
First contact with github.com/LLM4Rocq/rocq-mcp (local checkout inspected)
happened ONLY NOW, after the ladder closed, the config froze, and the held-out
run completed — the commit history (through the freeze at configs/FROZEN.md)
proves design independence per the brief's "do not copy existing Rocq/Lean MCP
servers". Comparison protocol: rocq-mcp runs as an external config through the
SAME harness — same policy (claude-haiku-4-5), same dev manifests, same turn/
wall budgets, same correctness gate on a submitted candidate (a minimal
`submit` sidecar tool writes the artifact; the gate re-verifies from scratch,
so submission is not trusted). Never run on the test split. Reported as a
dev-set comparison.

## A17 — Rung 9 from residual-failure mining (2026-07-03 evening)
User challenge ("no additional tools would make a difference?") answered by
mining the winner's 130 hard-bucket failures: 123 had already exhausted the
auto_close portfolio; residual goals are 41 % nonlinear inequalities; agents'
last-ditch pattern is assert(154)+nra(94) — hunting the auxiliary square/
product fact that lets nra close. Rung 9 = server-side HINT-TERM SYNTHESIS
(auto_close2): harvest R-variables, mechanically assert pow2_ge_0/product
facts, run nra/psatz on the enriched context; bounded trials, zero model
turns. Dev-evidence only (test spent); measured on dev60 + hard bucket.

## A18 — Budget extension (user, 2026-07-03 ~17:15)
Hard stop moved from 2026-07-06 EOD to 2026-07-07 EOD. Revised calendar:
Jul 3 eve–Jul 5: continued iteration (rung 9 hint-synthesis; rocq-mcp SOTA
comparison; sonnet-native follow-ups if won; team re-test on a mechanically
detected DECOMPOSABLE-problem manifest — addressing the honest gap in the
team negative result; pass@k scaling on hard at N=8). Jul 6: consolidation +
full report. Jul 7: buffer + clean end. Held-out protocol unchanged (already
executed; one shot, spent on the frozen config).

## A19 — Pre-registered SOTA predictions (written BEFORE rocq_mcp_dev60 ran)
Design analysis of rocq-mcp v0.3.1 against our measured ablations predicts,
for dev60 @ claude-haiku-4-5, identical budgets/gate:
(1) pass@1 strictly between baseline (.44/.25/.30) and session_try
    (.65/.375/.375) in every bucket — warm interactive sessions (their
    rocq_start/rocq_check ≈ our kept session rung) but no machine-enumerated
    portfolio (our largest single gain), no error-payload hints, and
    step_multi requires a commit round-trip (turn cost).
(2) Their pull-based info tools (rocq_query/toc/notations/assumptions/diag)
    show the search-tool signature: meaningful adoption, no rescue effect.
(3) Turns/attempt higher than winner's at similar wall (more round-trips).
Convergences noted for the report: interactive state-id sessions, multi-
tactic testing, goals-at-error — independent replication of 3 of our kept
design pressures. Their workspace/multi-file tools target a regime our
experiment does not measure (honest scope limit).

## A20 — In-project proving benchmark (user steer, 2026-07-03 ~17:45)
Goal extended: tools must be realistically usable in bigger projects. New
benchmark axis: lemmas extracted from MID-FILE positions of the local Rocq
stdlib checkout (a real ~700-file project, builds on this exact switch),
proofs stripped, task = prove in true file context (immutable prefix = all
of the file above the lemma; the target's own installed module is never
Required, so no self-application leakage). Difficulty = ground-truth proof
sentence-count buckets. Interface A/B this benchmark isolates: full-prefix-
in-prompt vs STATEMENT-ONLY prompting with server-side context (the session
already executes the prefix; the agent pulls context on demand) — the
context-economy question that dominates big-project use. Memorization risk
(policy trained on stdlib) affects absolute rates only, not the config A/B
(shared policy); noted in threats-to-validity. Multi-file editing = future
work.

## A21 — Involved-project extension (user steer, 2026-07-03 ~18:00)
In-project benchmark extended beyond stdlib: (i) mathcomp60 — mid-file lemmas
from the local math-comp checkout (boot/order; ssreflect proof language, a
qualitatively different regime for both policy habits and our stdlib-centric
hint tables; Requires resolve against installed rocq-mathcomp 2.5.0, drift
filtered by compile-verification); (ii) mathcomp algebra/field + mathcomp-
analysis installing in background (solver dry-run verified: Rocq untouched)
to unlock analysis-based tasks; (iii) load-path plumbing (-Q/-R via env into
session init + gate) planned as the dune-project infrastructure deliverable,
demonstrated on one dune-built project if time permits. Honest expectation:
absolute solve rates on ssreflect will be low for this policy; the interface
A/Bs (ctx_full vs ctx_lean; vs naive baseline) remain valid comparisons.

## A22 — False-winner bug in auto_close (found by rung-9 smoke, 2026-07-03)
`auto`-style no-op-tolerant tactics "succeed" without progress, so
auto_close's ran-without-error winner check committed useless sentences and
told the agent the goal closed (the truthful goal render followed, limiting
harm). Consequences: the rung-7 mechanism stat ("71 % of calls close a goal",
top winner `auto with real arith` 46/64) was inflated by fake wins and is
retracted in the report; rung-7's KEEP verdict is unaffected (pass@1 measured
end-to-end). Fix: winner requires goal-count decrease or completion, in both
session server and team daemon. Measured as rung 9a (winner_autofix) before
rung 9b (hint synthesis) so the two effects are separable.

## A23 — Usage-pool optimization + real-project infra directive (user, Jul 3 ~21:10)
User at 75 % of shared model quota (Max x20), Fable at 30 %. (1) Queued evals
trimmed: rocq_mcp_sonnet finishes (sunk); sonnet_native_auto2 and the
mathcomp probe drop to 1 rep (pass@1 only, noted); decomposable solo/team
pair kept at 2 reps (cheap haiku, n=27); nothing else queued — consolidation
uses existing data. (2) Engineering shifts to Fable-powered infra: dune +
_CoqProject load-path support end-to-end (session init via ROCQ_INIT_ARGS,
gate extra args, manifest plumbing, project-args helper), validated on a real
dune project with a micro-eval.

## A24 — Policy-neutral MCP requirement (user steer, Jul 3 ~22:20)
The deliverable must NOT be Haiku-specialized. Finding to date: all
server-side capabilities are policy-neutral; the Haiku flavor lived in
prompts (style forcing, give-up) and in the Haiku-only selection criterion.
Response: (1) style-agnostic surface — whole-proof `check` added INSIDE the
session server (one-shot submission with repair-from-failure semantics), so
both interaction styles are first-class in ONE server; (2) neutral prompt
(both workflows presented, no give-up); (3) recommended-config criterion =
best worst-case across measured policies (extends A15's pre-registration).
Validation: `universal` (haiku) + `universal_sonnet`, 1 rep each, queued
after the trimmed queue.

## A25 — Atlas-derived fixes (rung 10, Jul 4 ~00:15)
From docs/FAILURE_ATLAS.md: (1) auto-Qed handshake — any tool leaving zero
open goals on an incomplete proof now issues Qed server-side (the missing
handshake cost 13 attempts = the entire sonnet-incremental gap; agents
fabricated "PROOF COMPLETE"); (2) dead tools purged — psatz (requires the
absent csdp binary; ALWAYS failed) and field_simp (Lean-ism, nonexistent)
removed from portfolio and hint texts, replaced with working closers;
(3) Search inequality-direction flip-retry (`_ >= 0` patterns found nothing
though the lemma exists as `0 <= _`). All deterministic, zero-turn. The A24
universal pair (re)runs on this fixed binary; earlier configs' measured
numbers stand as recorded (their binaries documented per run_meta git_rev).


## A26 — ssreflect knowledge-distillation probe (Jul 7)
Evidence-mined from the mathcomp probe corpus (Search-idiom failures x66
dominate; stdlib-tactic habits; name guessing): gated ssreflect hint table
(ROCQ_HINTS_SSR=1) — Search/Check syntax failures get mathcomp naming +
boolean-reflection guidance; stdlib tactics get ssreflect equivalents;
mathcomp-fragment unknown refs get name-fragment search advice — plus
`by []`/`done` portfolio entries. Tests the per-project distillation
mechanism (DESIGN evolution path) with one measured rerun of mathcomp35.


## A27 — server-side exemplar retrieval (Jul 7, large-project axis)
Grounded in A20 (in-project medium wins with adjacent proof BODIES, +12.5pp
full-vs-lean) but full-file context cannot scale to large projects. New
mechanism, gated ROCQ_EXEMPLARS=1: at session start the server scans project
sources (ROCQ_PROJECT_SRC or ROCQ_INIT_ARGS paths), extracts proved
(statement, proof) pairs comment-stripped, ranks by rare-token (IDF) overlap
with the theorem statement, and PUSHES the top-3 with proofs into the first
tool response — zero turns, ~1.5k tokens, any file size, any policy.
Leak-proofing: for the file the task was cut from, only the region BEFORE
the prefix end is admissible (the target's own proof is never retrievable).
Smoke: ltn_exp2r -> {expnI, ltn_pexp2l, leq_pexp2l}. A/B on mathcomp35 at
haiku + fable vs same configs without.

## A28 — productization (Jul 7, from user review of README)
User: "why is install so complicated / why python to use it on a project?"
Root cause: README documented the experiment artifact; project_args.py was
harness leakage into the usage path. Fixed: (1) opam package `rocq-tools`
(public binaries rocq-mcp / rocq-mcp-daemon / rocq-mcp-shim); (2) in-server
load-path auto-discovery (walk up from ROCQ_TASK_FILE to _CoqProject or
dune-project; OCaml, zero external tooling); (3) product defaults: all tools
on, hints/suggest/synthesis/exemplars on (opt-out with =0), tactic preload
split from the Require-refusal policy (preload default-on via ROCQ_PRELOAD,
refusal stays opt-in via ROCQ_ENV_V2). All historical configs pinned with
explicit values so their semantics are unchanged and self-describing.
Verified hermetically: installed binary + ROCQ_TASK_FILE alone proves a
lemma in a fresh dune project (auto-discovery + preload + portfolio).
