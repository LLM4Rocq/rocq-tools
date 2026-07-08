# Test suite architecture (dune-driven, integration-level)

Philosophy: no unit tests. Every test exercises a REAL binary end-to-end
(spawn → MCP/socket protocol → assert on behavior) and encodes either a core
contract or a regression for a bug this experiment actually found (each cites
its incident). `dune runtest` runs everything; total budget ≤ ~4 minutes.

## Layout
```
test/
  dune              test stanzas; runtest alias runs all
  helpers.ml        shared mini-lib (see contract below)
  fixtures/         .v task files (stdlib-only; keep Requires minimal)
  test_session.ml   suite A: session server core contracts
  test_daemon.ml    suite B: multi-agent daemon (parallelism)
  test_perf.ml      suite C: scalability/latency bounds (generous, CI-stable)
  test_gate.py      suite D: correctness-gate soundness (run via dune rule)
```

## helpers.ml contract (implement first; keep < 150 lines)
- `spawn_server : env:(string*string) list -> string (*exe path*) -> t`
  spawns the binary with stdin/stdout pipes; env is ADDED to a clean base
  (PATH=<repo>/../_opam/bin:/usr/bin:/bin, HOME).
- `rpc : t -> Yojson.Safe.t -> Yojson.Safe.t` — send one JSON-RPC line, read
  one response line (skip notifications), 60 s timeout → failure.
- `call : t -> name:string -> args:Yojson.Safe.t -> string` — tools/call
  wrapper returning the first text content.
- `close : t -> unit` (kill process group).
- `check : bool -> string -> unit` — assertion: print `ok - <name>` /
  `FAIL - <name>`, set exit code; suite main prints summary and exits 1 on
  any failure (TAP-ish, no external test framework).
- Fixture path helper + tmpdir-per-test helper.
- Binaries under test (paths relative to repo root, already built by dune):
  `_build/default/src/session_server/rocq_agent_session.exe`,
  `_build/default/src/psession/rocq_agent_daemon.exe`,
  `_build/default/src/baseline_server/rocq_agent_baseline.exe`.
  In dune, declare them via `(deps ...)` so runtest builds them first.

## Suite A — session core (test_session.ml)
Fixture F1: `From Stdlib Require Import Reals Psatz.\nOpen Scope R_scope.\n\nTheorem t1 (x : R) : (x^6 + 1) / 2 >= x^3.\n`
Fixture F2: `Theorem t2 : forall n : nat, n + 0 = n.\n` (no imports — fast init)
Env for all unless stated: ROCQ_ENV_V2=1, ROCQ_ENABLE_TOOLS as needed,
ROCQ_TASK_FILE=<fixture copy in tmpdir>, ROCQ_WORKDIR=<tmpdir>.

- A1 commit-good-prefix: on F2, step "intros n. bogus_tac." → response
  contains "1 sentence(s) committed" AND "ERROR at `bogus_tac.`"; then step
  "induction n. reflexivity. simpl. rewrite IHn. reflexivity. Qed." →
  "PROOF COMPLETE"; tmpdir/candidate.v exists and contains "intros n."
  exactly once (committed prefix preserved, no duplication).
- A2 auto-Qed handshake (regression: atlas fix 1 / A25): on F1, step
  "Proof. assert (H := pow2_ge_0 (x^3-1)). nra." (NO Qed) → response contains
  "PROOF COMPLETE"; candidate.v exists and ends with "Qed." — the server
  issued Qed itself.
- A3 try semantics: on F1 (fresh server), try candidates
  ["bogus.", "Proof. nra.", "Proof. assert (H := pow2_ge_0 (x^3-1)). nra."]
  → response marks candidate 3 "<< COMMITTED", candidate 1 shows an error;
  after the call, PROOF COMPLETE appears (auto-Qed) and candidate.v exists.
- A4 auto_close progress rule (regression: A22 false-winner): fixture F3
  `Theorem t3 : forall n m : nat, n + m = m + n.\n` with
  ROCQ_ENABLE_TOOLS=auto_close: call auto_close → the response must NOT
  claim success via `auto with real arith` when goals remain; accept either
  a real closure (lia can close after intros? auto_close portfolio has no
  intros-prefix for lia... expected outcome: "no finisher applies") — assert
  response contains "no finisher applies" OR ("COMMITTED" AND
  "PROOF COMPLETE"); and if "no finisher applies", assert candidate.v does
  NOT exist. (Guards against no-op tactics counted as wins.)
- A5 auto_close synthesis (rung 9b): on F1 with ROCQ_AUTO2=1: auto_close →
  response contains "COMMITTED" and "PROOF COMPLETE" (the synthesized
  pow2 hint closes it); the winning script in the response mentions
  "assert (0 <=".
- A6 rollback + query non-commit: on F2, step "intros n."; step
  "Search (_ + 0)." (query) → response non-empty; rollback {count:1} →
  "rolled back 1"; then state → "committed proof: (nothing committed yet)"
  AND the candidate (after later completion) must never contain "Search".
- A7 env-v2 Require rejection: on F2 with ROCQ_ENV_V2=1: step
  "Require Import Lia." → response contains "Require is not allowed";
  nothing committed (state shows nothing committed).
- A8 error enrichment: with ROCQ_HINTS=1 ROCQ_SUGGEST=1 on F1: step
  "norm_num." → response contains "hint:" and "Lean"; step
  "apply Rmult_nonneg." → response contains "near-miss".
- A9 check tool (A24 style-agnostic): ROCQ_ENABLE_TOOLS=check,step: check
  {script:"Proof. nra."} → response reports error at `nra.` AND shows the
  live goal ("state"/goal render present, "committed" count 1 for Proof.);
  then check {script:"Proof. assert (H := pow2_ge_0 (x^3-1)). nra. Qed."}
  → "PROOF COMPLETE" (fresh-attempt semantics discarded the prior partial).
- A10 project loadpaths (A23): build a tiny dune project in a tmpdir
  (copy the pattern: dune-project `(lang dune 3.8)(using coq 0.8)`,
  theories/dune `(coq.theory (name TDemo))`, theories/Base.v with
  `Lemma tdemo_add0 : forall n : nat, n + 0 = n. Proof. induction n; simpl; auto. Qed.`),
  run `dune build` in it (PATH must include the opam switch bin), then task
  `From TDemo Require Import Base.\n\nTheorem t10 : forall n : nat, (n + 0) + 0 = n.\n`
  with ROCQ_INIT_ARGS="-Q\n<proj>/_build/default/theories\nTDemo": step
  "Proof. intros n. rewrite tdemo_add0. apply tdemo_add0. Qed." →
  "PROOF COMPLETE". (Skip with `ok - SKIP` if `dune` not on PATH.)

## Suite B — daemon parallelism (test_daemon.ml)
Socket helper: connect AF_UNIX, line-JSON rpc (ops: hello/state/goals/focus/
step/try/auto_close/status). SHORT socket paths (/tmp/rt_test_<pid>.sock —
macOS 104-byte cap; incident log).
Fixture FB: `From Stdlib Require Import Reals Psatz.\nOpen Scope R_scope.\n\nTheorem tb (x : R) (h : 0 < x) : 0 < x * 2 /\\ 0 < x * x.\n`
- B1 two-agent branch/merge (the core A12 contract): agent A: step "split.";
  goals lists 2 with null owners; A focus 1, B focus 2 (separate
  connections); B auto_close → "SUBGOAL 2 CLOSED and merged"; A step "lra."
  → "SUBGOAL 1 CLOSED"; trunk status complete=false with 0 open goals →
  agent C step "Qed." → "PROOF COMPLETE"; candidate.v exists and contains
  both subproof blocks.
- B2 merge renumbering (regression: review fix): same setup, but close
  branch 1 FIRST (A step "lra.") then B's subgoal (auto_close) — B's branch
  was opened as "2: {" but at merge time only one goal remains; assert B's
  merge still succeeds ("CLOSED and merged", not "merge replay failed").
- B3 unfocused-agent trunk safety: agent D (no focus) step "idtac." after
  a merge → must succeed against the trunk (response "committed") — guards
  trunk-state threading.

## Suite C — scalability bounds (test_perf.ml) — generous, CI-stable
- C1 session init < 15 s and step p50 < 250 ms: on F2 spawn, time 20
  sequential trivial steps ("idtac." ×20 via separate step calls after
  "intros n."); assert median call round-trip < 250 ms and total < 15 s.
- C2 daemon under load, no deadlock: FB daemon; 8 concurrent socket clients
  (threads), each issuing 10 state/goals ops; all 80 responses well-formed
  JSON with ok=true; total < 30 s.
- C3 snapshot rollback O(1)-ish: on F2 commit 50 sentences ("idtac." — via
  one step call with 50 idtac sentences), then rollback{count:50} completes
  < 2 s.

## Suite D — gate soundness (test_gate.py, run by dune rule)
Uses harness/gate.py directly (import). Cases (each cites its origin):
- D1 legit accept: pow2 proof on F1-prefix → solved=True.
- D2 admit/Admitted/Axiom in region → forbidden_token rejects.
- D3 prefix tamper (change statement) → prefix_modified.
- D4 comment/string desync exploit `(* "(*" *) Admitted.` → REJECTED
  (regression: measurement-review critical finding; must NOT be solved).
- D5 target-is-axiom belt: candidate that Admitted-then-reproves is
  academic — instead assert gate rejects when Print Assumptions lists the
  target name (craft: prefix + `Admitted.` hidden however — if unbuildable,
  directly test parse path by calling check on plain `Admitted.` → any
  rejection reason acceptable as long as solved=False).
- D6 fresh-recompile: candidate referencing an in-SESSION-only fact (e.g.
  proof text "exact H." with H undefined) → recompile_failed.

## dune wiring
- `test/dune`: three `(test (name test_session|test_daemon|test_perf)
  (libraries yojson unix str) (deps <the three exes> fixtures))` stanzas —
  use `%{exe:...}` or explicit path deps so binaries build first; plus
  `(rule (alias runtest) (deps test_gate.py ../harness/gate.py)
  (action (run python3 %{dep:test_gate.py})))`.
- Env: tests must locate the opam switch bin — resolve as
  `Filename.dirname Sys.executable_name` walk-up OR simply require PATH to
  contain rocq (dune runtest inherits the dev shell; assert early with a
  clear message if `rocq` is absent).
- Every test prints TAP-ish lines; exit non-zero on failure.

## Non-goals
No mocking, no unit tests, no coverage of the Python harness beyond the
gate, no network. Time budget hard cap: any single suite > 120 s is a bug.


## Additions after v1 (kept in sync with the suite)

- **A11 exemplar retrieval (A27)**: block delivered once, sibling retrieved,
  the target's own proof (after the prefix in the same file) NOT retrievable
  (leak-proofing), push-once semantics. Requires ROCQ_EXEMPLARS=1 (opt-in
  since the A27 verdict).
- **A12 runtime `open` (A29)**: pre-open tools direct the agent to `open`;
  open at a named Admitted theorem; trailing-goal default; missing-file
  error.
- **A13 prefix replay memoization (A30)**: opening a second file sharing
  leading sentences reuses cached snapshots — correct goal after divergence,
  proving works on a memoized base, both-ways re-open safe.
- **A14 build tool (A33/A36)**: whole-file multi-error diagnosis (broken
  lemma FIRST in the fixture — also the A36 regression: open must reach and
  prove theorems past earlier broken proofs).
- **B4-B6 contention/conflict pack**: double-focus refusal (ownership
  guard), concurrent mutating writes from parallel threads, trunk-mutation-
  under-branch (conclusion-digest renumbering exercised).
- **helpers.ml portability**: base_path falls back to the inherited PATH
  when the sibling _opam layout is absent (CI).
