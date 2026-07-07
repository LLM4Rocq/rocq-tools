# rocq-tools — an AI-native tooling layer for the Rocq prover

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

pass@1, easy / medium / hard. Weak policy = `claude-haiku-4-5`, strong =
`claude-sonnet-5` (annex, never used for keep/revert decisions).

| interface | policy | easy / medium / hard | note |
|---|---|---|---|
| naive whole-file `check` (control) | haiku | .44 / .25 / .30 | |
| **`universal`** (recommended) | haiku | **.662 / .575 / .40** | 4 reps; ≥ naive every bucket; hard trails the haiku-tuned config by .075 |
| naive whole-file `check` | sonnet | .925 / .95 / .80 | |
| **`universal`** | sonnet | **.95 / 1.00 / .85** | beats naive in **every** bucket, −40 % wall |
| `frozen` config — **held-out** miniF2F test | haiku | **.519 / .127 / .043** | single logged run; pass@2 .569/.165/.057 |

**Ladder (weak policy):** baseline `.44/.25/.25` → winner `.70/.525/.425`
(4 reps) via 6 kept + 4 reverted measured changes, at **−45 % cost, −55 % wall**;
per-interaction prover latency **266 ms → ~1 ms** (persistent in-process
session + O(1) snapshot rollback vs full recompile).

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

The agent talks MCP over stdio to `rocq_agent_session.exe`. The whole-proof and
incremental styles are both first-class in **one** server; a neutral prompt
offers both. Tools enabled by `ROCQ_ENABLE_TOOLS`, enrichments by the flags shown.

| tool | what it does |
|---|---|
| `check{script}` | Submit a **complete** proof (`Proof. … Qed.`) in one call. On success, done; on failure the valid prefix stays committed and you stand at the failing sentence with the live goal — repair or resubmit. |
| `step{text}` | Execute one or more sentences incrementally; each success commits permanently, the first failure reports a structured error and leaves state at the last success. Queries (`Search`/`Check`) run here too. |
| `try{candidates}` | Test up to 8 candidate scripts **speculatively** from the current state; the first that fully succeeds is committed (k ideas, one turn). |
| `auto_close{}` | Run the standard finisher portfolio (lia/lra/nra/nia/ring/…) against the current goal; commits a closer if one succeeds. Cheap — call it freely. |
| `rollback{count}` | Undo the last N committed sentences (O(1) state swap) and show the goal you are back to. |
| `state{}` | Re-render all open goals and the committed proof so far. |

Cross-cutting enrichments (zero extra turns):
- **error hints** (`ROCQ_HINTS=1`) — rewrites Lean-isms and common mistakes into
  the Rocq form, inlined into the error payload.
- **did-you-mean** (`ROCQ_SUGGEST=1`) — near-miss *existing* lemma names appended
  to unknown-reference errors.
- **hint synthesis** (`ROCQ_AUTO2=1`) — `auto_close` mechanically asserts
  auxiliary facts (e.g. `0 <= (t)²` from goal subterms) and retries nra/psatz.
- **env-v2 preloading** (`ROCQ_ENV_V2=1`) — preloads Lia/Lra/Psatz after the
  statement so closers are always available, and refuses mid-proof `Require`
  (an anti-gaming trap) with guidance.

> Config note: the shipped `configs/universal.json` sets `HINTS`/`SUGGEST`/`AUTO2`;
> the held-out `configs/frozen.json` sets `HINTS`/`SUGGEST`/`ENV_V2`. The
> try-it block below enables the full set.

## Install & try (2 minutes)

```sh
opam pin add rocq-tools https://github.com/LLM4Rocq/rocq-tools.git
```

installs the `rocq-mcp` binary into your opam switch (needs `rocq-runtime`
>= 9.1, pulled automatically). Then add ONE block to any MCP client config
(Claude Code, `claude` CLI, or anything MCP-speaking):

```json
{ "mcpServers": { "rocq": {
    "command": "rocq-mcp",
    "env": { "ROCQ_TASK_FILE": "/path/to/your/project/proofs/goal.v" } } } }
```

That's it. `goal.v` is any file ending with an unproven statement (your
imports + `Theorem my_goal : ...`). Everything else is automatic:

- **Project load paths are auto-discovered** — the server walks up from the
  task file to your `_CoqProject`/`_RocqProject` (parsed for `-Q/-R/-I`) or
  `dune-project` (`coq.theory` stanzas, mapped to the `_build/default`
  mirror). Build your project first; no other setup. Override with
  `ROCQ_INIT_ARGS` (newline-separated rocq args) if you need to.
- **Standard tactic modules** (Lia/Lra/Psatz) are preloaded (disable:
  `ROCQ_PRELOAD=0`).
- **All tools are on by default**: `check` (whole proof), `step`, `try`,
  `auto_close` (portfolio + hint synthesis), `rollback`, `state` — with
  error hints, near-miss suggestions, and project exemplar retrieval.
  Trim with `ROCQ_ENABLE_TOOLS=step,state,...` or disable features with
  `ROCQ_HINTS=0`, `ROCQ_SUGGEST=0`, `ROCQ_AUTO2=0`, `ROCQ_EXEMPLARS=0`.
- The completed proof is written to `candidate.v` (in `ROCQ_WORKDIR`, or the
  temp dir) — assembled by the server from what actually executed.

Quick smoke without any MCP client:

```sh
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"auto_close","arguments":{}}}' \
  | ROCQ_TASK_FILE=/path/to/goal.v rocq-mcp
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
Architecture: [`test/ARCHITECTURE.md`](test/ARCHITECTURE.md).

- **`test_session.ml`** (A) — session-server core contracts: commit-good-prefix,
  auto-Qed handshake, try/auto_close semantics, rollback, env-v2 rejection,
  error hints + did-you-mean, whole-proof `check`, project load-paths — plus the
  failure-atlas regressions (auto-Qed, dead-tool purge, Search flip).
- **`test_daemon.ml`** (B) — shared-proof multi-agent daemon: two-agent
  branch/merge, unfocused-agent trunk safety, and the **merge-renumbering**
  regression (a review fix that would corrupt >2-goal merges).
- **`test_perf.ml`** (C) — scalability/latency bounds (generous, CI-stable):
  init < 15 s, step p50 < 250 ms, no deadlock under 8 concurrent clients,
  O(1)-ish 50-sentence rollback.
- **`test_gate.py`** (D) — correctness-gate soundness: legit accept, forbidden
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
[`docs/ASSUMPTIONS.md`](docs/ASSUMPTIONS.md) (autonomous-decision log A1–A25) ·
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
