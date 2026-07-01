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

## A7 — Switch amendments
The dedicated switch lacked `yojson` (JSON for the OCaml server) and the libraries
~10% of dataset files import. Installed and pinned: yojson 3.0.0,
coq-coquelicot, coq-mathcomp-ssreflect (versions in repro/opam-packages.txt).
Installing them is reversible and required for dataset coverage; recorded here and
in repro/.
