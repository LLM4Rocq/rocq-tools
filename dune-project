(lang dune 3.23)
(name rocq-tools)
(generate_opam_files true)
(source (github LLM4Rocq/rocq-tools))
(license MIT)
(authors "LLM4Rocq")
(maintainers "guillaume.baudart@gmail.com")

(package
 (name rocq-tools)
 (synopsis "AI-native MCP tool layer for the Rocq prover")
 (description
  "An empirically-designed, policy-neutral MCP (Model Context Protocol) server that lets LLM agents drive the Rocq prover: persistent in-process sessions, speculative tactic evaluation, a finisher portfolio with hint synthesis, enriched errors, project load-path auto-discovery, and multi-agent shared-proof support.")
 (depends
  (ocaml (>= 4.14))
  dune
  (rocq-runtime (>= 9.1))
  yojson))
