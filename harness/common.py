"""Shared paths, config loading, and JSONL helpers for the eval harness."""

import json
import os
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKROOT = REPO.parent  # contains rocq-workbook/, miniF2F-rocq/, _opam/
OPAM_BIN = WORKROOT / "_opam" / "bin"
LOGS = REPO / "logs"
CONFIGS = REPO / "configs"
MANIFESTS = REPO / "data" / "manifests"

_write_lock = threading.Lock()


def load_config(name_or_path: str) -> dict:
    p = Path(name_or_path)
    if not p.exists():
        p = CONFIGS / f"{name_or_path}.json"
    cfg = json.loads(p.read_text())
    assert "config_id" in cfg and "server" in cfg and "model" in cfg, p
    return cfg


def load_manifest(name_or_path: str) -> list[dict]:
    p = Path(name_or_path)
    if not p.exists():
        p = MANIFESTS / f"{name_or_path}.jsonl"
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def append_jsonl(path: Path, record: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    with _write_lock:
        with open(path, "a") as f:
            f.write(json.dumps(record, sort_keys=True) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    if not Path(path).exists():
        return []
    out = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # torn write from a killed process; skip
    return out


def prover_env() -> dict:
    """Environment for processes that must find `rocq`: switch bin first."""
    env = dict(os.environ)
    env["PATH"] = f"{OPAM_BIN}:{env.get('PATH', '')}"
    return env
