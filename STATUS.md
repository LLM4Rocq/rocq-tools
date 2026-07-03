# STATUS — AI-native Rocq tooling experiment

_Last updated: 2026-07-04 01:45 · day 4 of the run (hard stop Jul 7 EOD)_

## ★ Headlines

**Held-out (the protocol number)** — single logged run of the frozen config on
miniF2F test: pass@1 **.519 / .127 / .043** (easy/medium/hard), pass@2
.569/.165/.057. Unlock 2026-07-03 13:57:42; zero test influence on any
decision; 488/488 attempts clean.

**Recommended configuration (A24, pre-registered worst-case criterion)** —
`universal`: ONE policy-neutral server (whole-proof `check` with
repair-from-failure + step/try/auto_close+hint-synthesis + error enrichment +
env-v2), ONE neutral prompt. It equals or beats the naive interface in
**every bucket at both measured policies** (1 rep each):
haiku .650/.600/.500 (best measured) · sonnet **.950/1.000/.800**
(first substrate config to dominate naive; −40 % wall).

**Baseline → best-at-haiku across the ladder**: pass@1 .44/.25/.30 →
.65/.60/.50, cost −45 %, wall −55 %, prover latency 266 ms → ~1 ms/call.

## Scoreboard (dev60 pass@1 easy/med/hard unless noted)
| config | result | verdict |
|---|---|---|
| baseline (naive) @ haiku | .44/.25/.30 (4 reps) | control |
| session | +30 % med/hard, −80 % out-tokens | KEPT |
| + try | easy +37 %, med/hard +15 % | KEPT |
| + compact render | −2.5 pp everywhere | REVERTED |
| + search tool (pull) | adoption w/o rescue | REVERTED |
| + hints | medium +27 % | KEPT |
| + auto_close portfolio | all buckets up | KEPT |
| + did-you-mean (push) | easy +8 %, med +9 % | KEPT |
| env-v2 (miniF2F axis) | .57/.30/.06 vs .32/.13/.00 | KEPT |
| rung 9b hint synthesis | medium +28 %; transfers to sonnet (hard .85 > naive .80) | KEPT |
| rung 10 atlas fixes (auto-Qed, dead tools, search flip) | closed the sonnet medium gap | KEPT |
| **universal (A24)** | ≥ naive everywhere, both policies | **RECOMMENDED** |
| team k=3 (hard70 AND decomposable27) | ~½ of solo at equal wall | REVERTED (infra validated) |
| rocq-mcp SOTA | ≈ baseline @ haiku; trails all @ sonnet | comparison |
| in-project ctx (A20) | lean holds short at 2.8× fewer tokens; full wins medium | both modes shipped |
| ssreflect probe | short .50, medium .07 | regime limit, honest |

## Fable-powered quality artifacts (Jul 3 night)
- **Failure atlas** (docs/FAILURE_ATLAS.md): 43 attempts deep-read; found the
  Qed-handshake hole (= the entire sonnet incremental gap), dead advertised
  tools (psatz/csdp, field_simp), Search direction blindness → all fixed as
  rung 10 and confirmed by measurement within 12 h.
- **Adversarial measurement review**: 31 confirmed findings; critical gate
  soundness hole FIXED (comment/string lexer desync) and audited — **0 of
  2 267 recorded solves affected**; daemon merge-renumbering fixed before it
  could bite; accounting caveats documented in REPORT §7b.
- **Sweep correction in progress**: baseline N=4/8 rows were sleep-
  contaminated AND the old N=1/2 rows carry daytime endpoint load — full
  4-point curve re-measuring in one consistent night window now.

## Infrastructure deliverables beyond the benchmark
Real-project support (A23): `_CoqProject`/dune load-path discovery
(`harness/project_args.py`), ROCQ_INIT_ARGS/-Q plumbed through session,
baseline, gate; validated end-to-end on a dune project (proof using a project
lemma, gate-verified). Shared-proof daemon + MCP shim (k agents, one proof).
Dashboard (`logs/dashboard.html`), one-command repro (`repro/setup.sh`).

## Budget
Policy spend ≈ $220 total (ladder+confirmations+annexes+SOTA+final).
Fable: 2 workflows ≈ 3.4 M subagent tokens (atlas + review). Machine: ~60 h.
Remaining: sweep rerun (running), optional universal 2nd rep, consolidation.

## Plan to close (Jul 4–7)
Jul 4: finish sweep correction → REPORT §5 rewrite; full report coherence
pass; DESIGN final read. Jul 5: universal 2nd rep (if pool allows), figures,
report freeze. Jul 6–7: buffer + final push, clean end.

## Needs your input
_(empty — nothing blocking)_
