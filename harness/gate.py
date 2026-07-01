"""Correctness gate (anti-gaming). A proof counts as solved ONLY if this
module says so; the in-session compiler result is never trusted.

Layers (docs/ASSUMPTIONS.md A8):
 1. prefix lock  — the candidate must reproduce the shipped file prefix
                   (imports + preamble + statement) exactly, modulo whitespace.
                   Nothing may be inserted before or into the statement, so the
                   statement cannot be re-interpreted via scopes/notations.
 2. region lock  — the agent-written region (everything after the prefix, with
                   comments stripped) must not contain assumption-introducing or
                   state-escaping commands: admit/Admitted, Axiom(s),
                   Parameter(s), Hypothesis/es, Variable(s), Conjecture,
                   Declare, Abort, Unset, Require, Load, Symbol(s),
                   Print Assumptions.
 3. fresh recompile — the candidate alone, in a clean directory, must compile
                   with exit code 0 (standard flags, hard timeout).
 4. assumption audit — `Print Assumptions <thm>` is appended and its output
                   parsed: any `***` line (unsafe flags, e.g. type-in-type)
                   rejects; the axiom list is logged for audit. Library axioms
                   (classical R, functional extensionality, ...) are accepted:
                   with layers 1-2 the agent cannot have introduced new ones.

Every rejection carries a machine-readable reason.
"""

import re
import subprocess
import tempfile
import time
from pathlib import Path

from common import prover_env

FORBIDDEN = [
    (re.compile(r"\badmit\b"), "admit"),
    (re.compile(r"\bAdmitted\b"), "Admitted"),
    (re.compile(r"\bAxioms?\b"), "Axiom"),
    (re.compile(r"\bParameters?\b"), "Parameter"),
    (re.compile(r"\bHypothes[ei]s\b"), "Hypothesis"),
    (re.compile(r"\bVariables?\b"), "Variable"),
    (re.compile(r"\bConjecture\b"), "Conjecture"),
    (re.compile(r"\bDeclare\b"), "Declare"),
    (re.compile(r"\bAbort\b"), "Abort"),
    (re.compile(r"\bUnset\b"), "Unset"),
    (re.compile(r"\bRequire\b"), "Require"),
    (re.compile(r"\bLoad\b"), "Load"),
    (re.compile(r"\bSymbols?\b"), "Symbol"),
    (re.compile(r"\bPrint\s+Assumptions\b"), "PrintAssumptions"),
]


def strip_comments(src: str) -> str:
    """Remove (possibly nested) Rocq comments and string literals."""
    out = []
    i, n = 0, len(src)
    depth = 0
    in_string = False
    while i < n:
        c = src[i]
        if in_string:
            if c == '"':
                if i + 1 < n and src[i + 1] == '"':  # escaped quote
                    i += 2
                    continue
                in_string = False
            i += 1
            continue
        if depth > 0:
            if src.startswith("(*", i):
                depth += 1
                i += 2
            elif src.startswith("*)", i):
                depth -= 1
                i += 2
            else:
                i += 1
            continue
        if src.startswith("(*", i):
            depth += 1
            i += 2
            continue
        if c == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def split_at_prefix(candidate: str, prefix: str):
    """Index in candidate where the whitespace-normalized prefix ends, or None."""
    ci, n = 0, len(candidate)
    for ch in prefix:
        if ch.isspace():
            continue
        while ci < n and candidate[ci].isspace():
            ci += 1
        if ci >= n or candidate[ci] != ch:
            return None
        ci += 1
    return ci


def _run_rocq(vfile: Path, timeout_s: float) -> tuple[int, str, float]:
    t0 = time.monotonic()
    try:
        p = subprocess.run(
            ["rocq", "compile", vfile.name],
            cwd=vfile.parent,
            env=prover_env(),
            capture_output=True,
            text=True,
            timeout=timeout_s,
        )
        return p.returncode, p.stdout + p.stderr, time.monotonic() - t0
    except subprocess.TimeoutExpired:
        return -1, "GATE TIMEOUT", time.monotonic() - t0


def parse_assumptions(output: str):
    """Parse the LAST Print Assumptions block of compiler output."""
    closed = "Closed under the global context"
    idx_closed = output.rfind(closed)
    idx_axioms = output.rfind("Axioms:")
    if idx_closed > idx_axioms:
        return [], False
    if idx_axioms == -1:
        return None, False  # no block found at all
    axioms, unsafe = [], False
    for line in output[idx_axioms + len("Axioms:"):].splitlines():
        if line.startswith("***"):
            unsafe = True
        m = re.match(r"^(\S+)\s*:", line)
        if m:
            axioms.append(m.group(1))
    return axioms, unsafe


def check(candidate: str, prefix: str, theorem_name: str, timeout_s: float = 120.0) -> dict:
    res = {
        "solved": False,
        "reason": None,
        "axioms": None,
        "recompile_s": None,
        "detail": None,
    }
    split = split_at_prefix(candidate, prefix)
    if split is None:
        res["reason"] = "prefix_modified"
        return res
    region = strip_comments(candidate[split:])
    for pat, label in FORBIDDEN:
        if pat.search(region):
            res["reason"] = f"forbidden_token:{label}"
            return res
    with tempfile.TemporaryDirectory(prefix="rocq_gate_") as td:
        vfile = Path(td) / "proof.v"
        vfile.write_text(candidate if candidate.endswith("\n") else candidate + "\n")
        code, out, dur = _run_rocq(vfile, timeout_s)
        res["recompile_s"] = round(dur, 3)
        if code != 0:
            res["reason"] = "recompile_failed"
            res["detail"] = out[-2000:]
            return res
        # assumption audit
        pa = Path(td) / "proof_audit.v"
        pa.write_text(
            vfile.read_text() + f"\nPrint Assumptions {theorem_name}.\n"
        )
        code2, out2, _ = _run_rocq(pa, timeout_s)
        if code2 != 0:
            res["reason"] = "assumption_audit_failed"
            res["detail"] = out2[-2000:]
            return res
        axioms, unsafe = parse_assumptions(out2)
        res["axioms"] = axioms
        if axioms is None:
            res["reason"] = "assumption_parse_failed"
            res["detail"] = out2[-2000:]
            return res
        if unsafe:
            res["reason"] = "unsafe_flags"
            return res
    res["solved"] = True
    return res
