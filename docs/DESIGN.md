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
