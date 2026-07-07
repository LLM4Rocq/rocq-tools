# WORK PAUSED (user instruction, Jul 7 ~13:00)

## Valid results collected before the pause (not yet in REPORT)
- universal_fable_dev60 (60/60): pass@1 .95 easy / 1.00 medium / 1.00 hard
- baseline_fable_dev60 (60/60): .95 / 1.00 / .95
  -> Fable row of the cross-policy matrix: universal >= naive at the
     strongest tier too (hard +5pp, rest tied at ceiling). To record in
     REPORT/dashboard/STATUS on resume.
- Counterfactual replay: 272 failures replayed (logs/counterfactual.jsonl),
  resumable (done-set skip); analysis pending.
- A27 exemplar retrieval: BUILT, committed, suite-tested (87 checks green),
  retrieval quality verified on mathcomp targets. A/B NOT yet run.

## Poisoned and deleted (quota: session limit hit, resets 14:20 Paris)
All four mathcomp runs (ctx_full_fable, ctx_lean_fable, ctx_lean_ex_fable,
winner_ctx_lean_ex) died instantly on the session limit — deleted, must be
re-run after reset. These carry the .07 decomposition answer AND the A27
exemplar A/B.

## Resume checklist (after 14:20 Paris, or when user says go)
1. run_eval ctx_full_fable + ctx_lean_fable on mathcomp60 (1 rep, par 3)
2. run_eval ctx_lean_ex_fable + winner_ctx_lean_ex on mathcomp60 (A27 A/B)
3. finish replay_counterfactual (same command, resumes); analyze rescue rates
4. record everything (fable matrix row, .07 decomposition, A27 verdict,
   portfolio v3 verdict); commit+push
