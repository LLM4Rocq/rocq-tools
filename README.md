# rocq-tools — an AI-native tooling layer for the Rocq prover

[![CI](https://img.shields.io/github/actions/workflow/status/LLM4Rocq/rocq-tools/ci.yml?branch=main&style=for-the-badge&label=CI)](https://github.com/LLM4Rocq/rocq-tools/actions/workflows/ci.yml)
[![Dashboard](https://img.shields.io/badge/dashboard-results-2a78d6?style=for-the-badge)](https://llm4rocq.github.io/rocq-tools/)


An **empirically-designed, policy-neutral MCP tool layer** that lets an LLM
agent drive the Rocq (Coq) prover — *and* the controlled experiment that
produced it. Starting from a deliberately-naive control (one tool = a full
`rocq compile`), we profiled where a weak agent loses and iterated the interface
one measured change at a time against per-bucket baselines; every design
decision is backed by numbers and every proof accepted only by an anti-gaming
correctness gate. The layer is a standalone OCaml project linking the installed
Rocq 9.1.1 libraries in-process — **no source changes to Rocq** — and is one
server both a weak and a strong model can use, chosen by a pre-registered
best-worst-case-across-policies criterion.

**Start here**: [`STATUS.md`](STATUS.md) (2-min state) ·
[`docs/REPORT.md`](docs/REPORT.md) (all results) ·
[`docs/DESIGN.md`](docs/DESIGN.md) (per-decision rationale).

## Headline results

All three objectives, per difficulty bucket (easy / medium / hard), dev60.
**$/solve** = mean cost per attempt ÷ pass@1 (expected spend per solved
proof, failures included); **wall** = mean seconds per attempt. SOTA =
[rocq-mcp](https://github.com/LLM4Rocq/rocq-mcp), measured under the
identical harness, problems, gate, and policies (first contact only after
our design freeze; its numbers are a lower bound — some attempts hit an MCP
startup race, see REPORT §8).

| interface | policy | pass@1 | $ / solve | wall s |
|---|---|---|---|---|
| naive whole-file (control) | haiku | .44 / .25 / .30 | .18 / .44 / .49 | 90 / 122 / 157 |
| rocq-mcp (SOTA) | haiku | .45 / .23 / .23 | .12 / .36 / .37 | 56 / 74 / 78 |
| **`universal`** (recommended) | haiku | **.66 / .58 / .40** | .10 / .16 / .23 | 59 / 71 / 74 |
| naive whole-file | sonnet | .93 / .95 / .80 | .09 / .15 / .18 | 61 / 77 / 112 |
| rocq-mcp (SOTA) | sonnet | .83 / .73 / .73 | .11 / .23 / .21 | 60 / 92 / 114 |
| **`universal`** | sonnet | **.95 / 1.00 / .85** | **.07 / .09 / .13** | **36 / 42 / 85** |
| naive whole-file | fable | .95 / 1.00 / .95 | — | (1 rep) |
| **`universal`** | fable | **.95 / 1.00 / 1.00** | — | (1 rep) |
| `frozen` — **held-out** miniF2F test | haiku | .52 / .13 / .04 | — | single logged run |

Readings: `universal` is best-or-tied in every bucket at **all three policy
tiers**; at sonnet it is simultaneously the most accurate *and* the cheapest
per solved proof of anything measured; the SOTA comparison shows heavy
interactive-tool adoption does not convert without turn-compression
(rocq-mcp ≈ naive at haiku, dominated on all three axes at sonnet).

**Ladder (weak policy):** baseline `.44/.25/.30` → winner `.70/.525/.425`
(4 reps) via 6 kept + 4 reverted measured changes, at **−45 % cost, −55 % wall**;
per-interaction prover latency **266 ms → ~1 ms** (persistent in-process
session + O(1) snapshot rollback vs full recompile). Scalability: ~80 %
parallel efficiency at N=8 agents, ≈6× solved-proofs/hour vs the control.

> **The design law, from 10 ablations:** *maximize prover-grounded information
> per model turn, at zero marginal turn cost.* Everything that pushed
> information into existing turns (try, hints, auto_close, did-you-mean,
> preloading) won; everything that spent a turn or lost context to get it
> (a pull search tool, compact rendering, a 3-agent relay) lost.

Honesty notes: haiku universal hard is .400±.14 at 4 reps, .075 below the
haiku-specialized config (its one non-leading cell);
sonnet medium `1.00` is 2/2 reps; the held-out row is a single frozen-config run
(no test problem influenced any decision); strong-policy annexes are 1–2 reps.

## The tools — one policy-neutral MCP server (`rocq`)

The agent talks MCP over stdio to `rocq-mcp`. The whole-proof and
incremental styles are both first-class in **one** server. All tools and
enrichments are ON by default (trim with `ROCQ_ENABLE_TOOLS`, disable
features with `ROCQ_<FEATURE>=0`).

| tool | what it does |
|---|---|
| `build{file}` | Diagnose a whole file in one call: every top-level block executes; a failed proof is `Admitted` in-session so dependents still check — you get **all** broken proofs at once, then fix each via `open`. Purely diagnostic. |
| `open{file, theorem?}` | Open a .v file at runtime and start (or restart) a session on it: targets the named theorem's statement (its old proof/`Admitted` is ignored, and any *earlier* broken proof is auto-`Admitted` so every theorem is reachable — fix holes in any order) or the file's trailing open goal. Project load paths auto-discovered from the file's location. |
| `check{script}` | Submit a **complete** proof (`Proof. … Qed.`) in one call. On success, done; on failure the valid prefix stays committed and you stand at the failing sentence with the live goal — repair or resubmit. |
| `step{text}` | Execute one or more sentences incrementally; each success commits permanently, the first failure reports a structured error and leaves state at the last success. Queries (`Search`/`Check`) run here too. |
| `try{candidates}` | Test up to 8 candidate scripts **speculatively** from the current state; the first that fully succeeds is committed (k ideas, one turn). |
| `auto_close{}` | Run the standard finisher portfolio (lia/lra/nra/nia/ring/…) against the current goal; commits a closer if one succeeds. Cheap — call it freely. |
| `rollback{count}` | Undo the last N committed sentences (O(1) state swap) and show the goal you are back to. |
| `state{}` | Re-render all open goals and the committed proof so far. |

Cross-cutting enrichments (zero extra turns, all default-on; disable with `=0`):
- **error hints** (`ROCQ_HINTS`) — rewrites Lean-isms and common mistakes into
  the Rocq form, inlined into the error payload.
- **did-you-mean** (`ROCQ_SUGGEST`) — near-miss *existing* lemma names appended
  to unknown-reference errors.
- **hint synthesis** (`ROCQ_AUTO2`) — `auto_close` mechanically asserts
  auxiliary facts (e.g. `0 <= (t)²` from goal subterms) and retries the
  nonlinear closers.
- **exemplar retrieval** (`ROCQ_EXEMPLARS=1`, opt-in) — pushes the k most
  statement-similar *proved* lemmas from your project (with their proofs)
  into the first response. Measured neutral at the policies tested (weak
  policies can be distracted by it), so off by default; retrieval quality
  itself is verified and leak-proof.
- **hang safety** — every sentence runs under a checkpoint timeout PLUS
  allocation-triggered interruption (memprof-limits, the coq-lsp mechanism),
  so even `vm_compute`/`native_compute` divergence returns a structured
  TIMEOUT instead of freezing the session (`ROCQ_FORK_PROBE=1` adds a
  fork-isolated belt for zero-state-risk contexts).
- **tactic preloading** (`ROCQ_PRELOAD`) — loads Lia/Lra/Psatz after the
  statement so the standard closers always exist. In a **mathcomp** file,
  additionally preloads `zify`/`algebra-tactics` — this mathcomp tactic
  bridge works only when the optional opam packages `coq-mathcomp-zify` and
  `coq-mathcomp-algebra-tactics` are installed — still `coq-`named
  upstream; these two satellites have not yet followed the mathcomp core
  rename to `rocq-mathcomp-*` (`ROCQ_MC_TACTICS=0` to disable), giving `by lia`/`by ring`/`by lra` real
  power over boolean-reflection and ssralg goals. (`ROCQ_ENV_V2=1`
  additionally *refuses* mid-proof `Require` — a benchmark anti-gaming
  policy, off for normal use.)

## Install & try (2 minutes)

```sh
opam pin add rocq-tools https://github.com/LLM4Rocq/rocq-tools.git
```

installs the `rocq-mcp` binary into your opam switch (`rocq-runtime` 9.1+
is pulled automatically). Then add ONE block to any MCP client config
(Claude Code, `claude` CLI, or anything MCP-speaking):

```json
{ "mcpServers": { "rocq": { "command": "rocq-mcp" } } }
```

That's it — no configuration at all. Then just ask your agent to finish a
proof: it calls `open{file}` (optionally `theorem:<name>` to target an
`Admitted` or any specific statement mid-file), works the proof with the
other tools, and on completion receives the finished script to insert into
your file. One session can open several proofs in the same project — the
import prefix is **replay-memoized**, so even mathcomp-heavy imports are
paid once per session, not once per open (re-open: ~0.4 s).
Everything else is automatic:

- **Project load paths are auto-discovered** — the server walks up from the
  task file to your `_CoqProject`/`_RocqProject` (parsed for `-Q/-R/-I`) or
  `dune-project` (`coq.theory` stanzas, mapped to the `_build/default`
  mirror). Build your project first; no other setup. Override with
  `ROCQ_INIT_ARGS` (newline-separated rocq args) if you need to.
- **Standard tactic modules** (Lia/Lra/Psatz) are preloaded (disable:
  `ROCQ_PRELOAD=0`).
- **All tools are on by default**: `open`, `build` (whole-file diagnosis),
  `check` (whole proof), `step`, `try`, `auto_close` (portfolio + hint
  synthesis), `rollback`, `state` — with error hints and near-miss suggestions.
  Trim with `ROCQ_ENABLE_TOOLS=step,state,...`, disable features with
  `ROCQ_HINTS=0`/`ROCQ_SUGGEST=0`/`ROCQ_AUTO2=0`, opt into project exemplar
  retrieval with `ROCQ_EXEMPLARS=1`.
- On completion the response carries the **finished proof script** (assembled
  from what actually executed — the agent inserts it into your file); a
  standalone `candidate.v` is also written to `ROCQ_WORKDIR`/temp.
- `ROCQ_TASK_FILE` (optional) presets a file at launch — used by the
  benchmark harness; interactive use never needs it.

Quick smoke without any MCP client:

```sh
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open","arguments":{"file":"/path/to/your/File.v","theorem":"my_admitted_lemma"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"auto_close","arguments":{}}}' \
  | rocq-mcp
```

For multi-agent work on one proof, `rocq-mcp-daemon` + `rocq-mcp-shim` are
installed alongside (see docs/DESIGN.md, intra-proof parallelism).

*Developing / reproducing the experiment instead?* `repro/setup.sh` builds
the pinned environment from scratch and `dune build` works in-tree; the
Python `harness/` is ONLY for running the benchmark experiment, never needed
to use the tool.

## Tests

`dune runtest` — integration-level, no mocks; every case spawns a real binary
and asserts on behavior (each cites the incident it regresses; budget ≤ ~4 min).
**109 assertions** across four suites (A:57 · B:35 · C:10 · D:7).
Architecture: [`test/ARCHITECTURE.md`](test/ARCHITECTURE.md).

- **`test_session.ml`** (A, 57) — session-server core contracts: commit-good-prefix,
  auto-Qed handshake, try/auto_close semantics, rollback, env-v2 rejection,
  error hints + did-you-mean, whole-proof `check`, project load-paths, whole-file
  `build` diagnosis (admit-and-continue), runtime `open` (incl. Admitted-targeting
  and A36 reach-any-theorem), prefix-replay memoization with safe re-open, and
  exemplar retrieval (incl. leak-proofing) — plus the failure-atlas regressions
  (auto-Qed, dead-tool purge, Search flip).
- **`test_daemon.ml`** (B, 35) — shared-proof multi-agent daemon: two-agent
  branch/merge, unfocused-agent trunk safety, and the **merge-renumbering**
  regression (a review fix that would corrupt >2-goal merges).
- **`test_perf.ml`** (C, 10) — scalability/latency bounds (generous, CI-stable):
  init < 15 s, step p50 < 250 ms, no deadlock under 8 concurrent clients,
  O(1)-ish 50-sentence rollback.
- **`test_gate.py`** (D, 7) — correctness-gate soundness: legit accept, forbidden
  tokens, prefix tamper, fresh-recompile, and the **comment/string desync
  exploit** `(* "(*" *) Admitted.` (a measurement-review critical finding).

## Repo map

```
src/mcp_core/        MCP stdio server framework + subprocess util
src/baseline_server/ naive control: one `check` tool = full rocq compile
src/session_server/  the iterated interface (this README's server)
src/psession/        shared-proof daemon (k agents, one live proof) + MCP shim
harness/             eval runner, correctness gate, team orchestrator, report,
                     profiler, monitor, dashboard, plots, sweeps, project_args
configs/             one JSON per experimental condition (+ FROZEN.md)
data/manifests/      stratified problem manifests (dev60/dev150/hard70/…)
docs/                report, design rationale, assumptions, failure atlas, task
repro/               pinned package list + one-command environment recreation
test/                dune-driven integration suites (A–D above)
```

Docs: [`docs/REPORT.md`](docs/REPORT.md) ·
[`STATUS.md`](STATUS.md) · [`docs/DESIGN.md`](docs/DESIGN.md) ·
[`docs/FAILURE_ATLAS.md`](docs/FAILURE_ATLAS.md) ·
[`docs/ASSUMPTIONS.md`](docs/ASSUMPTIONS.md) (autonomous-decision log A1–A36) ·
[`docs/TASK.md`](docs/TASK.md) (original brief).

## Reproduce the experiment

```sh
./repro/setup.sh /path/for/new/switch          # switch → pinned deps → build → self-test
python3 harness/run_eval.py --config baseline --manifest smoke5 --reps 1
python3 harness/report.py <run_id> [--compare baseline_dev60]  # EVERY number comes from here
python3 harness/dashboard.py --watch            # live view: logs/dashboard.html
```

Datasets are expected as siblings of this repo (`rocq-workbook/`,
`miniF2F-rocq/`); the policy endpoint is an authenticated `claude` CLI. The
held-out split is guarded — code refuses to read `miniF2F-rocq/test` unless
`FINAL_UNLOCK` + `ROCQ_FINAL_EVAL=1` are set; the single unlock (2026-07-03
13:57:42) is logged in `logs/unlock.log` (see `configs/FROZEN.md`). Method in
one line: one naive control; profile; one change at a time; keep only what
improves per-bucket dev numbers (never pooled); gate every attempt; freeze; then
one logged run on the held-out split.
