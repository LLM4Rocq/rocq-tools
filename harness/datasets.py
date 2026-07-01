"""Dataset access layer for the rocq-tools evaluation harness.

Datasets (siblings of this repo, under the same parent directory):

  ../rocq-workbook/rocq_workbook_10k.jsonl   -- 10,000 workbook problems
  ../miniF2F-rocq/valid/*.v                  -- 244 problems (dev split)
  ../miniF2F-rocq/test/*.v                   -- 244 problems (HELD OUT)

HELD-OUT DISCIPLINE
===================
The miniF2F *test* split is held out for the final evaluation. The ONLY
code path in this repository that is allowed to touch (list, open, read)
the test directory is the guarded branch inside ``load_minif2f("test")``
in this module. That guard refuses to run -- raising
``RuntimeError("held-out test split is locked")`` -- unless BOTH:

  1. the file ``<repo>/FINAL_UNLOCK`` exists, and
  2. the environment variable ``ROCQ_FINAL_EVAL`` equals ``"1"``.

When (and only when) both conditions hold, an audit line with an ISO
timestamp and the calling PID is appended to ``<repo>/logs/unlock.log``
*before* any test data is returned. Do not add any other code that
constructs or dereferences a path into ``miniF2F-rocq/test``. Tooling may
at most count test *filenames* (e.g. ``ls`` for tier statistics); it must
never read file contents outside the guard.

Python 3 stdlib only.
"""

import datetime
import json
import os
import re

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

# <repo> = .../rocq-tools/rocq-tools (this file lives in <repo>/harness/).
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Parent directory that also contains the sibling dataset checkouts.
DATASETS_ROOT = os.path.dirname(REPO_ROOT)

WORKBOOK_JSONL = os.path.join(DATASETS_ROOT, "rocq-workbook", "rocq_workbook_10k.jsonl")
MINIF2F_ROOT = os.path.join(DATASETS_ROOT, "miniF2F-rocq")

# --------------------------------------------------------------------------
# rocq-workbook
# --------------------------------------------------------------------------


def load_workbook(path=WORKBOOK_JSONL):
    """Load the workbook jsonl as a list of dicts (one per line)."""
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def workbook_problem_to_vfile(rec):
    """Assemble the statement-only .v content for a workbook record.

    Replicates EXACTLY the assembly in
    ``rocq-workbook/provenance/materialize.py`` (which is verified to
    produce 10,000/10,000 type-checking files), minus the provenance
    header comment and the trailing proof/``Proof. Admitted.`` block:

        body  = imports + "\\n"
        body += preamble + "\\n"        # only if preamble is non-blank
        body += "\\n" + statement + "\\n"

    i.e. imports + blank line + statement when there is no preamble, and
    imports / preamble / blank line / statement when there is one.
    """
    imports = rec.get("rocq_imports", "") or ""
    preamble = rec.get("rocq_preamble", "") or ""
    stmt = rec.get("rocq_statement", "") or ""
    body = imports + "\n"
    if preamble.strip():
        body += preamble + "\n"
    body += "\n" + stmt + "\n"
    return body


# --------------------------------------------------------------------------
# Theorem-statement parsing (shared by both datasets)
# --------------------------------------------------------------------------

# First identifier after a theorem-introducing keyword. Rocq identifiers
# may contain apostrophes (e.g. imo_1966_p5' in the miniF2F valid split).
_THEOREM_RE = re.compile(
    r"\b(?:Theorem|Lemma|Fact|Corollary|Proposition|Remark)\s+"
    r"([A-Za-z_][A-Za-z0-9_']*)"
)

# Same keywords, anchored at the start of a line (used to locate the
# *last* theorem in a miniF2F file; helper Definitions/Fixpoints and, in
# one file, an earlier Theorem may precede it).
_THEOREM_LINE_RE = re.compile(
    r"^[ \t]*(?:Theorem|Lemma|Fact|Corollary|Proposition|Remark)\s+"
    r"[A-Za-z_][A-Za-z0-9_']*",
    re.MULTILINE,
)

# End of a Rocq sentence: a '.' followed by whitespace or end-of-file.
# ('.' inside qualified names such as Nat.eqb is followed by a letter and
# therefore not matched; no decimal literals occur in either dataset.)
_SENTENCE_END_RE = re.compile(r"\.(?=\s|$)")


def theorem_name(statement_text):
    """First identifier after Theorem/Lemma/Fact/Corollary/Proposition/Remark.

    Returns None if no theorem-introducing keyword is found.
    """
    m = _THEOREM_RE.search(statement_text)
    return m.group(1) if m else None


def _last_theorem_span(content):
    """(start, end) span of the LAST theorem statement sentence, or None.

    start = offset of the keyword; end = offset just past the final '.'
    of that statement sentence.
    """
    matches = list(_THEOREM_LINE_RE.finditer(content))
    if not matches:
        return None
    start = matches[-1].start()
    end_m = _SENTENCE_END_RE.search(content, matches[-1].end())
    if end_m is None:
        return None
    return start, end_m.end()


def statement_prefix(content):
    """Everything in the file up to and including the final '.' of the
    sentence stating the target theorem (= the LAST Theorem/Lemma in the
    file; helper Definitions/Fixpoints before it are kept).

    Raises ValueError if no theorem statement can be located.
    """
    span = _last_theorem_span(content)
    if span is None:
        raise ValueError("no theorem statement found in content")
    return content[: span[1]]


def shipped_proof_status(content):
    """Classify what follows the target theorem statement in a shipped file.

    Returns one of:
      "qed"        -- a completed proof (Qed./Defined.) follows
      "admitted"   -- an Admitted. follows (with or without Proof.)
      "proof_open" -- a bare 'Proof.' follows with no closing sentence
      "tactics"    -- non-empty trailer that is none of the above
                      (e.g. a tactic block without 'Proof.')
      "none"       -- nothing but whitespace follows the statement

    Survey of the shipped valid split (2026-07): 149 files are
    "admitted" ('Proof.' + 'Admitted.'), 95 are "proof_open" (they end
    with a bare 'Proof.'); no file ships a completed proof and no file
    starts a tactic block without 'Proof.'.
    """
    span = _last_theorem_span(content)
    if span is None:
        raise ValueError("no theorem statement found in content")
    trailer = content[span[1]:]
    if re.search(r"\b(?:Qed|Defined)\s*\.", trailer):
        return "qed"
    if re.search(r"\bAdmitted\s*\.", trailer):
        return "admitted"
    if re.search(r"\bProof\s*\.", trailer):
        return "proof_open"
    if trailer.strip():
        return "tactics"
    return "none"


# --------------------------------------------------------------------------
# miniF2F-rocq
# --------------------------------------------------------------------------

# Raw filename prefixes actually present, with counts per split.
# (Test counts were obtained from FILENAMES ONLY -- `ls`; file contents
# were never read, per the held-out discipline above.)
#
#   raw prefix              valid  test    -> source_tier
#   ---------------------   -----  ----    --------------------
#   mathd_algebra_             70    70    mathd_algebra
#   mathd_numbertheory_        60    60    mathd_numbertheory
#   amc12a_                    31    24    amc12
#   amc12b_                     9    15    amc12
#   amc12_                      5     6    amc12
#   aime_                      12    15    aime
#   aimeI_                      1     0    aime
#   aimeII_                     2     0    aime
#   imo_                       20    19    imo
#   imosl_                      0     1    imosl   (IMO shortlist; test only)
#   algebra_                   18    18    algebra
#   numbertheory_               8     8    numbertheory
#   induction_                  8     8    induction
#   ---------------------   -----  ----
#   total                     244   244
_TIER_PREFIXES = [
    ("mathd_algebra_", "mathd_algebra"),
    ("mathd_numbertheory_", "mathd_numbertheory"),
    ("amc12a_", "amc12"),
    ("amc12b_", "amc12"),
    ("amc12_", "amc12"),
    ("aimeII_", "aime"),
    ("aimeI_", "aime"),
    ("aime_", "aime"),
    ("imosl_", "imosl"),
    ("imo_", "imo"),
    ("algebra_", "algebra"),
    ("numbertheory_", "numbertheory"),
    ("induction_", "induction"),
]


def source_tier(problem_id):
    """Map a miniF2F problem id (filename stem) to its source tier."""
    for prefix, tier in _TIER_PREFIXES:
        if problem_id.startswith(prefix):
            return tier
    return "unknown"


def _load_minif2f_dir(split_dir):
    """Read every .v file in split_dir into problem records (sorted by id)."""
    records = []
    for fname in sorted(os.listdir(split_dir)):
        if not fname.endswith(".v"):
            continue
        path = os.path.join(split_dir, fname)
        with open(path, encoding="utf-8") as f:
            content = f.read()
        problem_id = fname[: -len(".v")]
        records.append(
            {
                "problem_id": problem_id,
                # Path relative to DATASETS_ROOT (the dir containing both
                # this repo and the dataset checkouts).
                "path": os.path.relpath(path, DATASETS_ROOT),
                "content": content,
                "theorem_name": theorem_name(_last_theorem_content(content)),
                "source_tier": source_tier(problem_id),
                "proof_status": shipped_proof_status(content),
            }
        )
    return records


def _last_theorem_content(content):
    """The statement sentence of the LAST theorem in the file."""
    span = _last_theorem_span(content)
    if span is None:
        raise ValueError("no theorem statement found in content")
    return content[span[0]: span[1]]


def load_minif2f(split):
    """Load a miniF2F-rocq split.

    split="valid": returns a list of dicts with keys
        problem_id, path (relative to the datasets root), content,
        theorem_name (of the LAST theorem in the file), source_tier,
        proof_status (see shipped_proof_status).

    split="test": HELD OUT. Raises RuntimeError("held-out test split is
    locked") unless <repo>/FINAL_UNLOCK exists AND ROCQ_FINAL_EVAL=1, in
    which case an audit line is appended to <repo>/logs/unlock.log before
    any data is returned. This guard is the ONLY code path in the repo
    allowed to touch the test directory (see module docstring).
    """
    if split == "valid":
        return _load_minif2f_dir(os.path.join(MINIF2F_ROOT, "valid"))
    if split == "test":
        unlock_file = os.path.join(REPO_ROOT, "FINAL_UNLOCK")
        if not (os.path.exists(unlock_file) and os.environ.get("ROCQ_FINAL_EVAL") == "1"):
            raise RuntimeError("held-out test split is locked")
        log_dir = os.path.join(REPO_ROOT, "logs")
        os.makedirs(log_dir, exist_ok=True)
        stamp = datetime.datetime.now().astimezone().isoformat()
        with open(os.path.join(log_dir, "unlock.log"), "a", encoding="utf-8") as f:
            f.write(f"{stamp} pid={os.getpid()} unlocked miniF2F test split\n")
        return _load_minif2f_dir(os.path.join(MINIF2F_ROOT, "test"))
    raise ValueError(f"unknown split: {split!r} (expected 'valid' or 'test')")
