# STATUS — AI-native Rocq tooling experiment

_Last updated: 2026-07-02 11:15_

## TL;DR
**First kept change is a rout.** The persistent in-process session interface
beats the naive control on every metric in every difficulty bucket:
pass@1 +30 % on medium & hard (.25→.325), output tokens −76…−83 %, cost
−36…−60 %, wall −42…−70 %, per-interaction prover latency 266 ms → ~1 ms.
Full A/B in docs/REPORT.md; decision + numbers in DESIGN.md. `session_try`
(batched speculative tactics) is measuring now (~1.5 h left). No blockers.

## Ladder scoreboard (dev60, 2 reps, per-bucket pass@1 easy/med/hard)
| config | pass@1 | Δ vs predecessor | verdict |
|---|---|---|---|
| baseline | .45 / .25 / .25 | — | control |
| session | .475 / .325 / .325 | +30 % med & hard, −80 % out-tokens | **KEPT** |
| session_try | .65 / .375 / .375 | easy +37 %, med/hard +15 %, cost flat | **KEPT** |
| session_try_compact | .625 / .35 / .35 | −2.5 pp everywhere, tokens_in +11 % | REVERTED |
| session_try_search | .60 / .35 / .40 | noise-level pass@1 (−/−/+), cost −5 %; heavy adoption (324 calls) but zero rescue: 15 % solve with search vs 81 % without (selection) | REVERTED |
| session_try_hints | queued | error payloads get Lean-ism→Rocq rewrites (targets the 1151× `[ltac_use_default]` parse-error class + Lean tactic names) | — |

**Now running:** `session_try_dev150` — confirmation of the winner on the
disjoint dev150 set (300 attempts, ~3 h); hints A/B auto-starts after.
**Today's remaining plan:** hints keep/revert → miniF2F-valid confirmation run
(overnight if needed) → scalability sweep tomorrow → freeze + held-out + report
day 4-5.

Live view: `logs/dashboard.html` (auto-refreshing; regenerate with
`python3 harness/dashboard.py --watch`). Task brief: `docs/TASK.md`.

## Environment (recorded)
- Apple M3 Max, 14 cores, 96 GB RAM, macOS 14.3 · dedicated local opam switch
- OCaml 5.3.0 · **Rocq 9.1.1** (downgraded from 9.2.0 by the Coquelicot install —
  accepted, pinned; see A7) · Coquelicot 3.4.4 · mathcomp 2.5.0 · yojson 3.0.0
- Policy (fixed across all configs): claude CLI 2.1.198 headless,
  `claude-haiku-4-5`, MCP tools only, ≤30 turns, ≤300 s/attempt
- Repro: `repro/setup.sh` (fresh switch → pinned install → build → self-test)

## Where things stand
- [x] MCP server framework (OCaml, JSON-RPC stdio) + JSONL instrumentation
- [x] Naive baseline config (control): one `check` tool = full `rocq compile`
- [x] Harness: runner (wall-clock watchdog), layered anti-gaming gate,
  per-bucket report, monitor, profiler; manifests dev60/dev150/minif2f_valid;
  held-out test mechanically locked
- [x] **Session server** (`src/session_server`): prover embedded in-process on
  the public rocq-runtime API. Sentence-level `step` (good prefix commits,
  failing sentence reported structurally with goals after last success), O(1)
  `rollback` (Vernacstate snapshots), `state`, per-sentence timeouts, queries
  (Search/Check) execute without polluting the proof. Measured: init 215 ms
  once; 0.4–2 ms per step; ~310 MB RSS per session.
- [x] **try tool** (`session_try` config): up to 8 candidate scripts evaluated
  speculatively from the same snapshot in one call; first success auto-commits;
  per-candidate verdicts + remaining-goal digests.
- [ ] RUNNING: `baseline_dev60` control (2 reps × 60, parallel=4, caffeinated)
- [ ] NEXT: session and session_try A/Bs on dev60; then compact-state and
  search ladder rungs; scalability sweep; freeze; held-out.

## Profiling so far (easy bucket, first control attempt — full numbers when run completes)
- Prover time = 6% of wall; model API ≈ 90%. **Turns and output tokens are the
  bottleneck, not compile seconds** (H1 partially refuted — timeouts did not
  bite on easy; recheck on medium/hard).
- Failed-check taxonomy: syntax 128 / unknown_ref 43 / other 59 → the policy
  burns whole turns learning one token was invalid Rocq. Sentence-level
  feedback + batched try target exactly this.
- Input tokens grow ~330/turn (quadratic-ish context growth confirmed, small in
  absolute terms on easy).

## Incidents (all diagnosed, fixed, logged)
1. **rocqworker leak**: `rocq compile`'s worker re-groups itself → escaped
   group-kill on timeout, pinned a core for 19 min. Fix: descendant-tree kill.
2. **"Timeout that never fired" = laptop sleep**: monotonic clocks pause during
   macOS sleep; wall clock doesn't. Fix: wall-clock watchdog + `machine_slept`
   flag; evals run under `caffeinate`.
3. Coquelicot not in default opam repo → repos added switch-scoped; solver
   downgraded Rocq 9.2→9.1.1 (accepted, pinned).
4. **Lid-close sleep beat caffeinate mid-control**: 16 easy-rep1 attempts
   killed on wake; detected by the sleep flag, quarantined
   (results.quarantine.jsonl), redone via resumable repair (harness/repair_run.py).
5. **UTF-8 truncation bug**: OCaml `truncate` split codepoints in logged agent
   text (Lean-isms like `⟨?_⟩`) → a few session_try attempts crashed record
   parsing. Fixed both sides (codepoint-safe truncate, byte-tolerant reader);
   affected slots will be repaired after the run.

## Budget tracking
- Spend so far: ≈ $21 (control $11.7 incl. repair, session $6.8, smokes/probes
  ~$1.5, session_try in flight). Well within reason for the value.
- Wall-clock: mid day 2 of 5, ahead of plan (first kept change already locked).

## Decisions / assumptions since last check-in
A7 updated (Rocq 9.1.1), A8 (proof-region discipline), A9 (miniF2F tier→bucket
mapping). Query sentences excluded from committed proofs (session semantics).
Efficiency metrics measured at parallel=4 for every config (fixed); scalability
axis varies N separately.

## Needs your input
_(empty — nothing blocking)_
