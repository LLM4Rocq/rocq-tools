# Original task brief (verbatim)

This is the initial prompt that defined the experiment, reproduced verbatim for
reference. Operational interpretations and autonomous decisions derived from it
are logged in `ASSUMPTIONS.md`; running state in `../STATUS.md`.

---

# Task: Design and evaluate an AI-native tooling layer for the Rocq prover

## Context
Your task: design, build, and empirically evaluate the tooling interface that an
LLM agent uses to interact with the Rocq prover — a set of tools purpose-built for
an AI agent rather than a human — and prove with hard numbers that your design is
good. You'll build it as a standalone OCaml project layered on Rocq's installed
OCaml libraries, establish a naive baseline, then iterate against grounded
efficiency and scalability metrics on real proof datasets.

Rocq is already installed in the current opam switch — link against its installed
OCaml libraries directly (via ocamlfind/dune; discover the exact package names).
The working directory contains three sibling directories:
- `rocq-workbook/`  — dataset (dev/tuning)
- `minif2f/`        — dataset (train = dev, test = held-out)
- `rocq-tools/`     — an already-initialized empty git repo; BUILD HERE

Build your project in `rocq-tools/` as a self-contained OCaml project that depends
on the installed Rocq libraries — the same ones its interactive core is built from.

The novelty must live in the *agent-facing interface*: how an LLM discovers proof
state, issues commands, gets feedback, manages its context, and coordinates
parallel work. You link against the installed Rocq libraries as substrate — the
prover already runs and checks proofs, so you do NOT need to reimplement that
proof-checking machinery. Do NOT make source-level changes to Rocq: treat it as a
fixed, installed dependency and build entirely on its public library API. Beyond
that, the connection architecture is entirely yours to derive — the process model,
where state lives, how interaction is batched or streamed, the granularity of a
call. Don't assume any particular structure; work out from first principles what an
LLM agent actually needs and justify every choice with numbers. I'm genuinely
curious what route you take. Do not copy existing Rocq/Lean MCP servers or IDEs.
Every design decision must be justified by a measured delta, not intuition.

## Autonomy and cadence
Run this end to end on your own. I check in roughly once a day; the rest of the
time you're unsupervised. Optimize for that: keep making progress between my
check-ins, and make each check-in cheap for me by keeping one status file current.
- Keep a `STATUS.md` at the repo root that I can read in two minutes to know
  exactly where things stand. Update it at least once per experimental step (and
  whenever something notable happens). It should always show: what's done, what's
  in progress, the latest metrics vs. baseline, decisions/assumptions made since
  the last update, anything that failed and how you handled it, and — in a clearly
  marked section — anything you want my input on. Keep that section empty unless
  something genuinely needs me.
- Make every reasonable decision yourself. When something is ambiguous or
  underspecified, choose the most sensible option, record the assumption and
  reasoning (commit message + STATUS.md), and proceed. Prefer a documented
  assumption over waiting.
- Never sit idle. If one line of work is blocked, flag it in STATUS.md and switch
  to another useful task rather than stopping the whole run — a blocker should cost
  me one decision at the next check-in, not a day of lost progress. Only fully halt
  if truly everything is blocked, and then leave the repo clean, committed, and
  summarized so I can unblock you in one read.
- Recover from failures yourself. Build breaks, flaky runs, timeouts, and prover
  crashes are expected — diagnose, retry, work around, and log it. A single failure
  never ends the run.
- Never do something irreversible and consequential on a guessed default; that's
  the one class of thing worth parking in STATUS.md for me. Everything reversible,
  just decide and note it.
- Your git history, logs, monitoring view, STATUS.md, and final report are my whole
  window into the work. Make them good enough that a daily glance is all I ever
  need.

## Version control
Work in the existing `rocq-tools/` git repo — it's already initialized, so don't
re-init it or start a new tree; just create a dedicated branch and work there, not
on main/master. Commit progress incrementally with clear messages — at minimum one
commit per experimental step (baseline, each kept or reverted change, each
ablation), so the git history is a readable audit trail of the iteration loop. A
reverted change should still leave a commit trail showing it was tried and why it
was dropped. Do not squash the history. Never commit large logs or generated
artifacts you can regenerate; commit code, configs, and the report, and keep raw
logs out of the tree (e.g. via .gitignore) unless they're small enough to matter.

## What you're optimizing
An LLM agent (the "policy") drives Rocq through your tool layer to close goals.
You optimize the tool layer while holding the policy and proof set fixed. Two axes:
1. Efficiency, per solved proof: wall-clock latency per tool call, total tokens
   (prompt+completion), number of tool calls, prover compile/check time.
2. Scalability: throughput and resource use scaling from 1 to N parallel agents on
   the same or different goals — peak memory, CPU-seconds, and how each efficiency
   metric degrades with N.
Break every metric down by difficulty bucket, never report only pooled aggregates:
proofs vary widely in difficulty, so pooled numbers can hide regressions and make
an easier-subset win look like a real improvement. Report per-bucket success and
per-bucket efficiency, and hold the difficulty mix fixed when comparing configs so
a delta reflects the tooling, not a shift in which proofs got solved.

## Grounding data
Use the local dataset directories; do not re-download.
- `rocq-workbook/` — dev/tuning, iterate freely.
- `minif2f/`       — use its train split as dev, hold out its test split.
Tuning / dev (iterate freely here): `rocq-workbook/` and the minif2f train split.
Held-out test (touch once, at the very end): the minif2f test split.
The datasets contain proofs of different difficulty levels. Detect and record a
difficulty label per proof (use the dataset's own labels/structure if present;
otherwise define a difficulty proxy and document it). Any split you make must be
stratified so dev and held-out test span the same difficulty range — don't let
test end up all-easy or all-hard. Iterate the tool layer only on the dev sets.
HELD-OUT DISCIPLINE (enforce this yourself, since no one is watching): treat the
test split as locked for the entire iteration phase — do not read, run, profile,
inspect, cache, or tune against it. Access it exactly once, for the final
evaluation of the already-frozen winning config. Prefer to enforce this
mechanically (e.g. a guard that refuses test access until a "final" flag is set)
and log the single moment test is unlocked. Never tune the tool layer against
specific test proofs. Keep the train/test separation strict — if the local data
doesn't cleanly separate them, split it yourself and log exactly how.

## Required method
1. Establish a deliberately-naive baseline as a control (e.g. raw CLI, one command
   per call, full recompile each interaction). Measure it on the dev sets, per
   difficulty bucket.
2. Profile to find the real bottleneck; state a hypothesis.
3. Implement one change addressing it. Measure. Keep it only if the numbers
   improve, else revert. Record the ablation.
4. Repeat until the iteration/time budget is exhausted.
5. Freeze the winning configuration, then run it once on the held-out test split.
Report deltas against the baseline at every step, broken down by difficulty.

## Correctness gate (anti-gaming)
A proof counts as solved only if the whole file re-checks cleanly in a fresh
environment: no `admit`/`Admitted`, no added `Axiom`/`Parameter`, all goals closed
by `Qed`, and no change to the theorem statement. Log a rejection reason for any
failure; rejected proofs never count toward success.

## Instrumentation
Emit structured JSONL per interaction: timestamps, latency, token counts, tool
name+args, prover response, proof id, difficulty, agent id, run/config id, seed.
Build a monitoring view over these logs. Every number in the final report must be
reproducible from the raw logs by a single command.

## Reproducibility
The experiment must run in a dedicated opam switch, not depend on ambient global
packages. Record the installed Rocq version and OCaml compiler version, and pin
them: the reproduction must recreate an equivalent switch from scratch (create
switch → `opam install` the pinned Rocq + deps → build → run → report) via one
command, end to end. (If the current switch already is your dedicated experiment
switch, just capture its exact package versions so the recreate step matches it.)
Log full environment, hardware, and seeds. Run each configuration enough times to
report mean and variance, not a single sample.

## Deliverables
- The tool-layer implementation and evaluation harness (self-contained project).
- Config files defining each experimental condition.
- Raw + structured logs and the monitoring tool.
- A current STATUS.md (see Autonomy).
- Results report: metric tables and plots, all stratified by difficulty (efficiency
  + scalability curves vs N), baseline deltas, ablations, variance, and
  pass@1/pass@k on the held-out test split per difficulty bucket.
- Design-rationale doc: for each interface decision, the number that justifies it,
  plus a log of the assumptions you made autonomously and why.

## Parameters (choose sensible defaults, document them, proceed)
Nothing here should block the run. If a value isn't given, pick a reasonable one,
record it in STATUS.md and the report, and continue. Suggested starting points:
- Hardware: detect it (cores, RAM, GPU) and log it; scale the parallelism sweep to
  what the machine can actually sustain.
- Agent policy at eval time: use whatever capable model/endpoint is configured and
  available in this environment; record exactly which, and hold it fixed across all
  configs so comparisons are valid.
- Parallelism sweep for the scalability axis: e.g. N ∈ {1, 4, 16, 48}, capped at
  what the hardware sustains; log where you capped and why.
- Budget (HARD stop): bound the run by wall-clock and/or token/$ cost and/or max
  iterations. Pick concrete limits up front, print them at start, track against
  them in STATUS.md, and stop cleanly when hit — emitting all deliverables from work
  completed. Default if unsure: a fixed wall-clock budget with a modest per-step
  timeout, sized to leave time to run the final held-out eval and write the report.

## North star
Build a self-contained experiment as a separate OCaml project on top of the
installed rocq libraries. Run it autonomously between daily check-ins. Build what
AI thinks is best for AI, and back every claim with hard numbers.
