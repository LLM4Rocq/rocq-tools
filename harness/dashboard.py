#!/usr/bin/env python3
"""Final results dashboard over the experiment logs.

    python3 harness/dashboard.py            # write logs/dashboard.html
    python3 harness/dashboard.py --watch    # regenerate every 15 s (live mode)

Open logs/dashboard.html in a browser. Stdlib only; charts are inline SVG.
Colors follow the validated reference palette (light+dark; buckets
easy/med/hard = categorical slots 1-3; per-mark <title> tooltips; every
chart has a table view)."""

import argparse
import html
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import common
from report import bucket_stats

BUCKETS = ["easy", "medium", "hard"]
LADDER_SUFFIX = "_dev60"

# The ladder, in experimental order: config -> (short label, what changed,
# verdict, one-line outcome in plain words). Source of truth: docs/DESIGN.md.
LADDER = [
    ("baseline", "0 naive", "whole-file compile per call (control)",
     "control", "the deliberately-naive starting point"),
    ("session", "1 session", "persistent prover; sentence steps, O(1) undo",
     "KEPT", "medium/hard solve +30 %, output tokens −80 %"),
    ("session_try", "2 +try", "k candidate tactics tested in one call",
     "KEPT", "easy +37 %, medium/hard +15 %"),
    ("session_try_compact", "3 compact", "token-thrifty goal rendering",
     "REVERTED", "−2.5 pp everywhere — agents re-fetch what you elide"),
    ("session_try_search", "4 search", "a Search tool the agent can call",
     "REVERTED", "heavily used, rescued nothing — pull wastes turns"),
    ("session_try_hints", "5 +hints", "errors carry Lean→Rocq rewrite hints",
     "KEPT", "medium +27 %"),
    ("session_try_hints_auto", "6 +auto_close", "server-side finisher portfolio",
     "KEPT", "every bucket up (+8/+16/+13 %)"),
    ("session_try_hints_auto_sugg", "7 +did-you-mean", "unknown names get near-miss suggestions",
     "KEPT", "easy +8 %, medium +9 % — push beats pull"),
    ("unified", "8 draft-first", "whole-proof-first prompt style at haiku",
     "REVERTED", "far below the incremental winner at this policy"),
    ("winner_autofix", "9a fix", "false-winner bug fix (A22)",
     "KEPT", "numbers unchanged; correctness fix"),
    ("winner_auto2", "9b synthesis", "server synthesizes goal-specific hint terms",
     "KEPT", "medium +28 % — new haiku best"),
    ("universal", "10 universal", "style-agnostic check + neutral prompt + atlas fixes",
     "RECOMMENDED", "best worst-case across BOTH policies (A24)"),
]
LADDER_ORDER = [c for c, *_ in LADDER]
LADDER_INFO = {c: (lab, chg, v, why) for c, lab, chg, v, why in LADDER}

CSS = """
:root { color-scheme: light dark; }
body { margin:0 auto; padding:24px; max-width:940px; background:#f9f9f7;
  color:#0b0b0b; font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif; }
svg { max-width:100%; height:auto; }
.viz-root {
  --surface-1:#fcfcfb; --ink-1:#0b0b0b; --ink-2:#52514e; --ink-3:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --ring:rgba(11,11,11,0.10);
  --good:#006300; --bad:#d03b3b;
  --s-easy:#2a78d6; --s-medium:#1baf7a; --s-hard:#eda100;
  --c-baseline:#4a3aa7; --c-winner:#eb6834;
  --track:#cde2fb; --accent:#2a78d6;
}
@media (prefers-color-scheme: dark) {
  body { background:#0d0d0d; color:#ffffff; }
  .viz-root {
    --surface-1:#1a1a19; --ink-1:#ffffff; --ink-2:#c3c2b7; --ink-3:#898781;
    --grid:#2c2c2a; --axis:#383835; --ring:rgba(255,255,255,0.10);
    --good:#0ca30c; --bad:#e66767;
    --s-easy:#3987e5; --s-medium:#199e70; --s-hard:#c98500;
    --c-baseline:#9085e9; --c-winner:#d95926;
    --track:#104281; --accent:#3987e5;
  }
}
h1 { font-size:20px; margin:0 0 2px; }
h2 { font-size:15px; margin:30px 0 4px; color:var(--ink-1); }
.caption { color:var(--ink-3); font-size:12px; margin:0 0 10px; max-width:760px; }
.sub { color:var(--ink-3); font-size:12px; margin-bottom:20px; }
.card { background:var(--surface-1); border:1px solid var(--ring);
  border-radius:10px; padding:16px 18px; }
.tiles { display:flex; gap:12px; flex-wrap:wrap; }
.tile { min-width:150px; flex:1; }
.tile .lbl { color:var(--ink-2); font-size:12px; }
.tile .val { font-size:26px; font-weight:600; margin:2px 0; white-space:nowrap; }
.tile .delta { font-size:12px; color:var(--ink-3); }
.legend { display:flex; gap:16px; font-size:12px; color:var(--ink-2); margin:4px 0 8px; }
.legend .sw { display:inline-block; width:10px; height:10px; border-radius:3px;
  margin-right:5px; vertical-align:-1px; }
table { border-collapse:collapse; font-size:12.5px; width:100%; }
th { text-align:left; color:var(--ink-2); font-weight:600; }
th,td { padding:4px 10px 4px 0; border-bottom:1px solid var(--grid); }
td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; }
details { margin-top:8px; } summary { cursor:pointer; color:var(--ink-3); font-size:12px; }
.badge { display:inline-block; font-size:11px; font-weight:600; border-radius:4px;
  padding:1px 7px; white-space:nowrap; }
.b-kept { color:var(--good); border:1px solid var(--good); }
.b-rev { color:var(--bad); border:1px solid var(--bad); }
.b-rec { color:var(--surface-1); background:var(--good); }
.b-other { color:var(--ink-3); border:1px solid var(--ink-3); }
td.why { color:var(--ink-2); }
.tools code { background:transparent; border:1px solid var(--grid); border-radius:4px;
  padding:0 5px; margin:0 4px 2px 0; font-size:11px; white-space:nowrap; display:inline-block; }
svg text { fill:var(--ink-2); font:11px system-ui,-apple-system,"Segoe UI",sans-serif; }
svg .tick { fill:var(--ink-3); font-variant-numeric:tabular-nums; }
svg .vlab { fill:var(--ink-1); font-weight:600; }
svg .grid { stroke:var(--grid); stroke-width:1; }
svg .axis { stroke:var(--axis); stroke-width:1; }
"""


def esc(s):
    return html.escape(str(s))


def badge(v):
    cls = {"KEPT": "b-kept", "REVERTED": "b-rev",
           "RECOMMENDED": "b-rec"}.get(v, "b-other")
    return f'<span class="badge {cls}">{esc(v)}</span>'


def load_runs():
    root = common.LOGS / "runs"
    out = []
    if not root.exists():
        return out
    for d in sorted(root.iterdir()):
        if not d.is_dir():
            continue
        rows = common.read_jsonl(d / "results.jsonl")
        meta = {}
        mp = d / "run_meta.json"
        if mp.exists():
            try:
                meta = json.loads(mp.read_text())
            except json.JSONDecodeError:
                pass
        out.append((d.name, meta, rows))
    out.sort(key=lambda t: t[1].get("started", ""))
    return out


def stats_for(runs, run_id):
    for rid, _, rows in runs:
        if rid == run_id and rows:
            return bucket_stats(rows)
    return {}


def legend_html(items):
    return ('<div class="legend">'
            + "".join(f'<span><span class="sw" style="background:{c}"></span>{esc(t)}</span>'
                      for t, c in items) + "</div>")


BUCKET_LEGEND = [(b, f"var(--s-{b})") for b in BUCKETS]


# ---------- chart: ladder slope (one compact chart, 3 series) ----------

def ladder_slope(stats_by_cfg):
    cfgs = [c for c in LADDER_ORDER if c in stats_by_cfg]
    if len(cfgs) < 2:
        return ""
    width, height, left, top = 880, 240, 40, 16
    plot_w, plot_h = width - left - 20, height - top - 52
    def sx(i):
        return left + i / (len(cfgs) - 1) * plot_w
    def sy(v):
        return top + plot_h - v * plot_h
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="pass@1 per bucket across the ladder">']
    for gy in (0, 0.25, 0.5, 0.75, 1.0):
        y = sy(gy)
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.0f}" x2="{left + plot_w}" y2="{y:.0f}"/>')
        parts.append(f'<text class="tick" x="{left - 6}" y="{y + 4:.0f}" text-anchor="end">{gy:g}</text>')
    for i, cfg in enumerate(cfgs):
        lab = LADDER_INFO[cfg][0]
        _, _, v, _ = LADDER_INFO[cfg]
        parts.append(f'<text class="tick" x="{sx(i):.0f}" y="{height - 34}" '
                     f'text-anchor="middle">{esc(lab.split(" ", 1)[0])}</text>')
        word = lab.split(" ", 1)[1] if " " in lab else lab
        parts.append(f'<text class="tick" x="{sx(i):.0f}" y="{height - 20}" '
                     f'text-anchor="middle" font-size="9.5">{esc(word[:12])}</text>')
        if v == "REVERTED":
            parts.append(f'<text class="tick" x="{sx(i):.0f}" y="{height - 7}" '
                         f'text-anchor="middle" fill="var(--bad)" font-size="9">reverted</text>')
    for b in BUCKETS:
        col = f"var(--s-{b})"
        pts = []
        for i, cfg in enumerate(cfgs):
            v = (stats_by_cfg[cfg].get(b) or {}).get("pass@1")
            if v is not None:
                pts.append((sx(i), sy(v), cfg, v))
        if len(pts) < 2:
            continue
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y, *_ in pts)
        parts.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2" '
                     f'stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y, cfg, v in pts:
            parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3.5" fill="{col}" '
                         f'stroke="var(--surface-1)" stroke-width="1.5">'
                         f'<title>{esc(LADDER_INFO[cfg][0])} · {b}: pass@1 {v:.3f}</title></circle>')
        x, y, _, v = pts[-1]
        parts.append(f'<text class="tick" x="{x + 7:.0f}" y="{y + 4:.0f}" '
                     f'fill="{col}">{v:.2f}</text>')
    parts.append("</svg>")
    return "".join(parts)


def metric_slope(stats_by_cfg, key, title_txt, fmt, per_solve=True, width=370):
    """Small-multiple: one efficiency metric across ladder steps, 3 bucket lines.
    per_solve divides the per-attempt mean by pass@1 (expected spend per
    solved proof, failed attempts included)."""
    cfgs = [c for c in LADDER_ORDER if c in stats_by_cfg]
    if len(cfgs) < 2:
        return ""
    height, left, top = 210, 52, 26
    plot_w, plot_h = width - left - 20, height - top - 46
    vals, vmax = {}, 0.0
    for b in BUCKETS:
        vs = []
        for cfg in cfgs:
            st = stats_by_cfg[cfg].get(b) or {}
            v = st.get(key)
            p = st.get("pass@1")
            if v is not None and per_solve:
                v = v / p if p else None
            vs.append(v)
            if v is not None:
                vmax = max(vmax, v)
        vals[b] = vs
    if vmax == 0:
        return ""
    def sx(i):
        return left + i / (len(cfgs) - 1) * plot_w
    def sy(v):
        return top + plot_h - (v / vmax) * plot_h
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="{esc(title_txt)} across ladder steps">']
    parts.append(f'<text x="{left}" y="14" class="vlab">{esc(title_txt)}</text>')
    for gy in (0, 0.5, 1.0):
        yy = sy(gy * vmax)
        parts.append(f'<line class="grid" x1="{left}" y1="{yy:.0f}" x2="{left + plot_w}" y2="{yy:.0f}"/>')
        parts.append(f'<text class="tick" x="{left - 6}" y="{yy + 4:.0f}" text-anchor="end">{fmt(gy * vmax)}</text>')
    for i, cfg in enumerate(cfgs):
        parts.append(f'<text class="tick" x="{sx(i):.0f}" y="{height - 8}" '
                     f'text-anchor="middle" font-size="9.5">'
                     f'{esc(LADDER_INFO[cfg][0].split(" ", 1)[0])}</text>')
    for b in BUCKETS:
        col = f"var(--s-{b})"
        pts = [(sx(i), sy(v), cfgs[i], v) for i, v in enumerate(vals[b]) if v is not None]
        if len(pts) < 2:
            continue
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y, *_ in pts)
        parts.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2" '
                     f'stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y, cfg, v in pts:
            parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="{col}" '
                         f'stroke="var(--surface-1)" stroke-width="1.5">'
                         f'<title>{esc(LADDER_INFO[cfg][0])} · {b}: {fmt(v)}</title></circle>')
    parts.append("</svg>")
    return "".join(parts)


# ---------- chart: A24 policy-neutrality comparison ----------

def a24_chart(groups):
    """groups: [(group label, [(series label, color, {bucket: v}), ...])]"""
    width, left = 700, 10
    bar_h, gap = 16, 3
    series_n = max(len(s) for _, s in groups)
    block_h = len(BUCKETS) * (series_n * (bar_h + gap) + 10) + 26
    height = sum(block_h for _ in groups) + 10
    plot_x, plot_w = 170, width - 170 - 60
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="naive vs universal, per policy and bucket">']
    y = 6
    for glabel, series in groups:
        parts.append(f'<text x="{left}" y="{y + 12}" class="vlab">{esc(glabel)}</text>')
        y += 22
        for b in BUCKETS:
            parts.append(f'<text x="{plot_x - 8}" y="{y + bar_h * series_n / 2 + 5}" '
                         f'text-anchor="end" class="tick">{b}</text>')
            for slabel, col, vals in series:
                v = vals.get(b)
                if v is None:
                    y += bar_h + gap
                    continue
                w = v * plot_w
                parts.append(f'<rect x="{plot_x}" y="{y}" width="{w:.1f}" height="{bar_h}" '
                             f'rx="3" fill="{col}"><title>{esc(glabel)} · {esc(slabel)} · '
                             f'{b}: {v:.3f}</title></rect>')
                parts.append(f'<text class="tick" x="{plot_x + w + 6:.1f}" y="{y + bar_h - 4}">'
                             f'{v:.2f}</text>')
                y += bar_h + gap
            y += 10
        y += 4
    parts.append("</svg>")
    return "".join(parts)


def metric_bars(groups, fmt, width=700):
    """Grouped horizontal bars for an arbitrary-scale metric.
    groups: [(group label, [(series label, color, {bucket: v}), ...])]"""
    vmax = 0.0
    for _, series in groups:
        for _, _, vals in series:
            for v in vals.values():
                if v is not None:
                    vmax = max(vmax, v)
    if vmax == 0:
        return ""
    bar_h, gap = 14, 3
    series_n = max(len(sr) for _, sr in groups)
    height = sum(len(BUCKETS) * (series_n * (bar_h + gap) + 8) + 26 for _ in groups) + 8
    plot_x, plot_w = 170, width - 170 - 70
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="metric comparison per policy and bucket">']
    y = 6
    for glabel, series in groups:
        parts.append(f'<text x="10" y="{y + 12}" class="vlab">{esc(glabel)}</text>')
        y += 22
        for b in BUCKETS:
            parts.append(f'<text x="{plot_x - 8}" y="{y + bar_h * series_n / 2 + 5}" '
                         f'text-anchor="end" class="tick">{b}</text>')
            for slabel, col, vals in series:
                v = vals.get(b)
                if v is None:
                    y += bar_h + gap
                    continue
                w = v / vmax * plot_w
                parts.append(f'<rect x="{plot_x}" y="{y}" width="{w:.1f}" height="{bar_h}" '
                             f'rx="3" fill="{col}"><title>{esc(glabel)} · {esc(slabel)} · '
                             f'{b}: {fmt(v)}</title></rect>')
                parts.append(f'<text class="tick" x="{plot_x + w + 6:.1f}" y="{y + bar_h - 3}">'
                             f'{fmt(v)}</text>')
                y += bar_h + gap
            y += 8
        y += 4
    parts.append("</svg>")
    return "".join(parts)


# ---------- chart: scalability ----------

def load_sweeps():
    out = {}
    for p in sorted(common.LOGS.glob("sweep_*_summary.jsonl")):
        rows = common.read_jsonl(p)
        if rows:
            cfg = rows[0].get("config", p.stem)
            by_n = {}
            for r in rows:
                by_n[r["N"]] = r
            out[cfg] = [by_n[n] for n in sorted(by_n)]
    return out


SWEEP_NAMES = {"baseline": ("naive baseline", "var(--c-baseline)"),
               "session_try_hints_auto": ("session winner", "var(--c-winner)")}


def sweep_chart(sweeps, key, title_txt, fmt, width=370):
    ns = sorted({r["N"] for rows in sweeps.values() for r in rows})
    if not ns:
        return ""
    height, left, top = 220, 52, 26
    plot_w, plot_h = width - left - 46, height - top - 36
    vmax = max((r.get(key) or 0) for rows in sweeps.values() for r in rows) or 1
    def sx(n):
        return left + ns.index(n) / max(len(ns) - 1, 1) * plot_w
    def sy(v):
        return top + plot_h - (v / vmax) * plot_h
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="{esc(title_txt)} vs N parallel agents">']
    parts.append(f'<text x="{left}" y="14" class="vlab">{esc(title_txt)}</text>')
    for gy in (0, 0.5, 1.0):
        yy = sy(gy * vmax)
        parts.append(f'<line class="grid" x1="{left}" y1="{yy:.0f}" x2="{left + plot_w}" y2="{yy:.0f}"/>')
        parts.append(f'<text class="tick" x="{left - 6}" y="{yy + 4:.0f}" text-anchor="end">{fmt(gy * vmax)}</text>')
    for n in ns:
        parts.append(f'<text class="tick" x="{sx(n):.0f}" y="{height - 8}" '
                     f'text-anchor="middle">N={n}</text>')
    for cfg, rows in sweeps.items():
        name, col = SWEEP_NAMES.get(cfg, (cfg, "var(--ink-3)"))
        pts = [(sx(r["N"]), sy(r.get(key) or 0), r) for r in rows if r.get(key) is not None]
        if len(pts) >= 2:
            d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y, _ in pts)
            parts.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2" '
                         f'stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y, r in pts:
            parts.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{col}" '
                         f'stroke="var(--surface-1)" stroke-width="2">'
                         f'<title>{esc(name)} · N={r["N"]}: {fmt(r.get(key) or 0)} '
                         f'({r.get("solved")}/{r.get("attempts")} solved)</title></circle>')
            parts.append(f'<text class="tick" x="{x:.0f}" y="{y - 8:.0f}" '
                         f'text-anchor="middle">{fmt(r.get(key) or 0)}</text>')
    parts.append("</svg>")
    return "".join(parts)


def sweep_section():
    sweeps = load_sweeps()
    if not sweeps:
        return '<div class="card"><span style="color:var(--ink-3)">No sweep data.</span></div>'
    legend = legend_html([SWEEP_NAMES.get(c, (c, "var(--ink-3)")) for c in sweeps])
    charts = (sweep_chart(sweeps, "attempts_per_hour", "throughput — attempts / hour",
                          lambda v: f"{v:.0f}")
              + sweep_chart(sweeps, "wall_s_mean", "wall-clock per attempt (s)",
                            lambda v: f"{v:.0f}"))
    head = ("<tr><th>interface</th><th class=num>N agents</th><th class=num>attempts/h</th>"
            "<th class=num>wall s/attempt</th><th class=num>solved</th>"
            "<th class=num>peak RSS MB*</th><th class=num>CPU %</th></tr>")
    trs = "".join(
        f"<tr><td>{esc(SWEEP_NAMES.get(cfg, (cfg,))[0])}</td><td class=num>{r['N']}</td>"
        f"<td class=num>{r.get('attempts_per_hour', '–')}</td>"
        f"<td class=num>{r.get('wall_s_mean', '–')}</td>"
        f"<td class=num>{r.get('solved')}/{r.get('attempts')}</td>"
        f"<td class=num>{r.get('peak_rss_mb', '–')}</td>"
        f"<td class=num>{r.get('cpu_pct_mean', '–')}</td></tr>"
        for cfg, rows in sweeps.items() for r in rows)
    return (f'<div class="card">{legend}{charts}'
            f'<details><summary>full table (incl. resources; *RSS is a machine-wide '
            f'upper bound)</summary><table>{head}{trs}</table></details></div>')


# ---------- page ----------

def build():
    runs = load_runs()

    # ladder stats + agent-facing tool surface: one dev60 run per ladder config
    stats_by_cfg, tools_by_cfg = {}, {}
    for rid, meta, rows in runs:
        if rid.endswith(LADDER_SUFFIX) and rows:
            cfg = rows[0].get("config_id", rid)
            if cfg in LADDER_INFO:
                stats_by_cfg[cfg] = bucket_stats(rows)
                cfg_meta = meta.get("config", {}) or {}
                tools_by_cfg[cfg] = [t.replace("mcp__rocq__", "")
                                     for t in cfg_meta.get("allowed_tools", [])]

    total_cost = sum((r.get("total_cost_usd") or 0) for _, _, rows in runs for r in rows)
    total_attempts = sum(len(rows) for _, _, rows in runs)

    def p1(st, b):
        return (st.get(b) or {}).get("pass@1")

    def fmt3(st):
        vs = [p1(st, b) for b in BUCKETS]
        return " / ".join("–" if v is None else f"{v:.2f}" for v in vs)

    uni_h = stats_by_cfg.get("universal", {})
    uni_s = stats_for(runs, "universal_sonnet_dev60")
    naive_h = stats_by_cfg.get("baseline", {})
    naive_s = stats_for(runs, "baseline_sonnet_dev60")

    tiles = [
        f'<div class="tile card"><div class="lbl">recommended config (universal) · haiku</div>'
        f'<div class="val">{fmt3(uni_h)}</div><div class="delta">pass@1 e/m/h · 4 reps · dev60</div></div>',
        f'<div class="tile card"><div class="lbl">universal · sonnet</div>'
        f'<div class="val">{fmt3(uni_s)}</div><div class="delta">≥ naive in every bucket · 2 reps</div></div>',
        f'<div class="tile card"><div class="lbl">held-out (miniF2F test, frozen config)</div>'
        f'<div class="val">.52 / .13 / .04</div><div class="delta">single locked run · REPORT §7</div></div>',
        f'<div class="tile card"><div class="lbl">policy spend, whole experiment</div>'
        f'<div class="val">${total_cost:,.0f}</div><div class="delta">{total_attempts:,} gated attempts</div></div>',
    ]
    bmed = naive_h.get("medium") or {}
    umed = uni_h.get("medium") or {}
    if bmed.get("pass@1") and umed.get("pass@1"):
        cb = (bmed.get("cost_usd_mean") or 0) / bmed["pass@1"]
        cu = (umed.get("cost_usd_mean") or 0) / umed["pass@1"]
        wb = (bmed.get("wall_s_mean") or 0) / bmed["pass@1"]
        wu = (umed.get("wall_s_mean") or 0) / umed["pass@1"]
        tiles.insert(2,
            f'<div class="tile card"><div class="lbl">per SOLVED medium proof · haiku</div>'
            f'<div class="val">${cb:.2f} → ${cu:.2f}</div>'
            f'<div class="delta">wall {wb:.0f}s → {wu:.0f}s · naive → universal</div></div>')

    # ladder table: step, change, tool surface, verdict, outcome, numbers
    lrows = []
    for cfg, lab, chg, v, why in LADDER:
        st = stats_by_cfg.get(cfg, {})
        tools = tools_by_cfg.get(cfg, [])
        chips = "".join(f"<code>{esc(t)}</code>" for t in tools) or "–"
        nums = "".join(f"<td class=num>{'–' if p1(st, b) is None else f'{p1(st, b):.2f}'}</td>"
                       for b in BUCKETS)
        lrows.append(f"<tr><td><b>{esc(lab)}</b></td><td class=why>{esc(chg)}</td>"
                     f'<td class="tools">{chips}</td>'
                     f"<td>{badge(v)}</td><td class=why>{esc(why)}</td>{nums}</tr>")
    ladder_table = ("<table><tr><th>step</th><th>what changed</th>"
                    "<th>agent-facing tools</th><th>verdict</th>"
                    "<th>measured outcome</th>"
                    + "".join(f"<th class=num>{b}</th>" for b in BUCKETS)
                    + "</tr>" + "".join(lrows) + "</table>")

    eff_charts = (metric_slope(stats_by_cfg, "cost_usd_mean", "cost $ / solved proof", lambda v: f"${v:.2f}")
                  + metric_slope(stats_by_cfg, "wall_s_mean", "wall s / solved proof", lambda v: f"{v:.0f}")
                  + metric_slope(stats_by_cfg, "tokens_out_mean", "output tokens / solved proof", lambda v: f"{v/1000:.0f}k"))
    ef_rows = []
    for cfg in LADDER_ORDER:
        st = stats_by_cfg.get(cfg)
        if not st:
            continue
        tds = []
        for k, f in (("cost_usd_mean", lambda v: f"{v:.3f}"),
                     ("wall_s_mean", lambda v: f"{v:.0f}"),
                     ("tokens_out_mean", lambda v: f"{v/1000:.1f}k")):
            for b in BUCKETS:
                v = (st.get(b) or {}).get(k)
                tds.append(f"<td class=num>{'–' if v is None else f(v)}</td>")
        ef_rows.append(f"<tr><td><b>{esc(LADDER_INFO[cfg][0])}</b></td>{''.join(tds)}</tr>")
    eff_table = ("<table><tr><th>step</th>"
                 + "".join(f"<th class=num>{b} {m}</th>" for m in ("$", "wall", "tok")
                           for b in BUCKETS)
                 + "</tr>" + "".join(ef_rows) + "</table>")

    # A24 comparison chart
    a24 = ""
    if uni_h and uni_s:
        groups = [
            ("claude-haiku-4-5 (weak policy)",
             [("naive", "var(--c-baseline)", {b: p1(naive_h, b) for b in BUCKETS}),
              ("universal", "var(--c-winner)", {b: p1(uni_h, b) for b in BUCKETS})]),
            ("claude-sonnet-5 (strong policy)",
             [("naive", "var(--c-baseline)", {b: p1(naive_s, b) for b in BUCKETS}),
              ("universal", "var(--c-winner)", {b: p1(uni_s, b) for b in BUCKETS})]),
        ]
        def a24row(name, st):
            cs, ws = [], []
            for b in BUCKETS:
                x = st.get(b) or {}
                p = x.get("pass@1")
                cs.append(f"${(x.get('cost_usd_mean') or 0)/p:.2f}" if p else "–")
                ws.append(f"{x.get('wall_s_mean') or 0:.0f}s" if x else "–")
            return (f"<tr><td>{esc(name)}</td>"
                    + "".join(f"<td class=num>{c}</td>" for c in cs)
                    + "".join(f"<td class=num>{w}</td>" for w in ws) + "</tr>")
        a24_tbl = ("<details><summary>cost per solve &amp; wall per attempt</summary>"
                   "<table><tr><th>config</th>"
                   + "".join(f"<th class=num>{b} $/solve</th>" for b in BUCKETS)
                   + "".join(f"<th class=num>{b} wall</th>" for b in BUCKETS)
                   + "</tr>"
                   + a24row("naive @ haiku", naive_h) + a24row("universal @ haiku", uni_h)
                   + a24row("naive @ sonnet", naive_s) + a24row("universal @ sonnet", uni_s)
                   + "</table></details>")
        def cps_vals(st):
            out = {}
            for b in BUCKETS:
                x = st.get(b) or {}
                pp, c = x.get("pass@1"), x.get("cost_usd_mean")
                out[b] = (c / pp) if pp and c is not None else None
            return out
        def wall_vals(st):
            return {b: (st.get(b) or {}).get("wall_s_mean") for b in BUCKETS}
        mgroups = lambda f: [
            ("claude-haiku-4-5",
             [("naive", "var(--c-baseline)", f(naive_h)),
              ("universal", "var(--c-winner)", f(uni_h))]),
            ("claude-sonnet-5",
             [("naive", "var(--c-baseline)", f(naive_s)),
              ("universal", "var(--c-winner)", f(uni_s))]),
        ]
        a24 = (legend_html([("naive whole-file interface", "var(--c-baseline)"),
                            ("universal (recommended)", "var(--c-winner)")])
               + '<p class="caption">accuracy — pass@1</p>'
               + a24_chart(groups)
               + '<p class="caption">cost — expected $ per solved proof (failures included)</p>'
               + metric_bars(mgroups(cps_vals), lambda v: f"${v:.2f}")
               + '<p class="caption">latency — mean wall-clock seconds per attempt</p>'
               + metric_bars(mgroups(wall_vals), lambda v: f"{v:.0f}s")
               + a24_tbl)

    # annex table: everything measured that is not on the haiku ladder
    annex = []
    seen = set()
    for rid, meta, rows in runs:
        if not rows:
            continue
        cfg = rows[0].get("config_id", rid)
        if cfg in LADDER_INFO and rid.endswith(LADDER_SUFFIX):
            continue
        if rid in seen:
            continue
        seen.add(rid)
        st = bucket_stats(rows)
        model = (meta.get("config", {}) or {}).get("model", "")
        annex.append(f"<tr><td>{esc(rid)}</td><td>{esc(model)}</td>"
                     f"<td class=num>{len(rows)}</td><td>{fmt3(st)}</td></tr>")
    annex_table = ("<table><tr><th>run</th><th>policy</th><th class=num>attempts</th>"
                   "<th>pass@1 e/m/h</th></tr>" + "".join(annex) + "</table>")
    n_annex = len(annex)

    sota_h = stats_for(runs, "rocq_mcp_dev60")
    sota_s = stats_for(runs, "rocq_mcp_sonnet_dev60")
    sota = ""
    if sota_h and sota_s:
        sgroups = [
            ("claude-haiku-4-5",
             [("rocq-mcp (SOTA)", "var(--ink-3)", {b: p1(sota_h, b) for b in BUCKETS}),
              ("naive", "var(--c-baseline)", {b: p1(naive_h, b) for b in BUCKETS}),
              ("universal", "var(--c-winner)", {b: p1(uni_h, b) for b in BUCKETS})]),
            ("claude-sonnet-5",
             [("rocq-mcp (SOTA)", "var(--ink-3)", {b: p1(sota_s, b) for b in BUCKETS}),
              ("naive", "var(--c-baseline)", {b: p1(naive_s, b) for b in BUCKETS}),
              ("universal", "var(--c-winner)", {b: p1(uni_s, b) for b in BUCKETS})]),
        ]
        def dimrow(name, st):
            cells = []
            for key, fn in (("pass@1", lambda v: f"{v:.2f}"),
                            ("$/solve", None),
                            ("wall_s_mean", lambda v: f"{v:.0f}s")):
                for b in BUCKETS:
                    x = st.get(b) or {}
                    if key == "$/solve":
                        p = x.get("pass@1")
                        c = x.get("cost_usd_mean")
                        cells.append(f"${c/p:.2f}" if p and c is not None else "\u2013")
                    else:
                        v = x.get(key)
                        cells.append(fn(v) if v is not None else "\u2013")
            tds = "".join(f"<td class=num>{c}</td>" for c in cells)
            return f"<tr><td>{esc(name)}</td>{tds}</tr>"
        sota_tbl = ("<table><tr><th>config</th>"
                    + "".join(f"<th class=num>{b} pass@1</th>" for b in BUCKETS)
                    + "".join(f"<th class=num>{b} $/solve</th>" for b in BUCKETS)
                    + "".join(f"<th class=num>{b} wall</th>" for b in BUCKETS) + "</tr>"
                    + dimrow("rocq-mcp @ haiku", sota_h) + dimrow("naive @ haiku", naive_h)
                    + dimrow("universal @ haiku", uni_h)
                    + dimrow("rocq-mcp @ sonnet", sota_s) + dimrow("naive @ sonnet", naive_s)
                    + dimrow("universal @ sonnet", uni_s) + "</table>")
        sota = (legend_html([("rocq-mcp (SOTA)", "var(--ink-3)"),
                             ("naive whole-file", "var(--c-baseline)"),
                             ("universal (ours)", "var(--c-winner)")])
                + a24_chart(sgroups)
                + f"<details open><summary>all three dimensions</summary>{sota_tbl}</details>")

    updated = time.strftime("%Y-%m-%d %H:%M:%S")
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>rocq-tools — final results</title>
<style>{CSS}</style></head>
<body class="viz-root">
<h1>AI-native Rocq tooling — final results</h1>
<div class="sub">experiment complete (Jun 30 – Jul 7, 2026) · generated {updated} ·
full analysis: docs/REPORT.md · per-decision rationale: docs/DESIGN.md · repo README for install &amp; try</div>

<div class="tiles">{''.join(tiles)}</div>

<h2>The ladder — one measured change at a time</h2>
<p class="caption">Each step was A/B-tested against its predecessor on the same 60
problems (20 per difficulty bucket), same weak policy (claude-haiku-4-5), ≥2
repetitions; kept only if the per-bucket numbers improved. Lines show pass@1
per bucket; reverted steps are part of the record but not of the shipped
tool. Hover any point for exact values.</p>
<div class="card">{legend_html(BUCKET_LEGEND)}{ladder_slope(stats_by_cfg)}
<details open><summary>step-by-step table (tools available to the agent at each step)</summary>{ladder_table}</details></div>

<h2>Cost and time — expected spend per solved proof</h2>
<p class="caption">The experiment's other two objectives. Each chart divides the
per-attempt mean by pass@1: the expected cost (or wall-clock, or model-output
tokens) to obtain ONE solved proof, failed attempts included. Same ladder
steps and buckets as above — solve rate rose while $ and time per proof fell.
Hover for values; hard-bucket spikes at early steps reflect near-zero solve
rates there.</p>
<div class="card">{legend_html(BUCKET_LEGEND)}{eff_charts}
<details><summary>per-attempt table (cost $, wall s, tokens out — mean per attempt)</summary>{eff_table}</details></div>

<h2>Policy-neutrality — the headline result (A24)</h2>
<p class="caption">One server, one neutral prompt, measured at both a weak and a
strong policy. The universal config beats the naive interface in every bucket
at sonnet (first substrate config to do so) and is best-or-tied at haiku
except hard, where the haiku-tuned variant keeps a .075 edge (within ½σ).
pass@1, dev60.</p>
<div class="card">{a24}</div>

<h2>Comparison with SOTA (rocq-mcp) — accuracy, cost, latency</h2>
<p class="caption">github.com/LLM4Rocq/rocq-mcp, measured under the identical
harness, gate, problems, and policies (first contact only after our design
freeze; REPORT §SOTA). Bars: pass@1. Table: all three dimensions — $/solve =
expected cost per solved proof (failures included), wall = mean s/attempt.
At both policies rocq-mcp is dominated on all three axes; at sonnet,
universal is more accurate in every bucket at roughly half the cost per
solve and ~40 % less wall. Caveat: some rocq-mcp attempts hit an MCP startup
race (REPORT §8) — its numbers are a lower bound; the mechanism analysis is
the robust claim.</p>
<div class="card">{sota}</div>

<h2>Scalability — N parallel agents on one machine</h2>
<p class="caption">Each point is one full run of a fixed 24-problem stratified
batch (8 per bucket) executed with N = 1, 2, 4, 8 concurrent agents — eight
runs total (4 per interface), all in a single night window (Jul 3–4) after two
earlier measurement artifacts were caught and disclosed (REPORT §5). Both
interfaces scale healthily (flat wall per attempt, ~72–80 % parallel
efficiency at N=8); the winner's advantage is its ~2.7× per-attempt speed,
compounding to ≈6× solved-proofs-per-hour at N=8. The local prover is never
the bottleneck (CPU ≤ 24 % of a 14-core laptop).</p>
{sweep_section()}

<h2>Everything else measured</h2>
<p class="caption">Cross-policy annexes, SOTA comparison, team experiments,
in-project probes, held-out — each analyzed in docs/REPORT.md. Raw per-run
numbers below; reproduce any row with <code>python3 harness/report.py
&lt;run&gt;</code>.</p>
<div class="card"><details><summary>all {n_annex} non-ladder runs</summary>{annex_table}</details></div>
</body></html>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--out", default=str(common.LOGS / "dashboard.html"))
    args = ap.parse_args()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    while True:
        out.write_text(build())
        if not args.watch:
            print(f"wrote {out}")
            break
        time.sleep(15)


if __name__ == "__main__":
    main()
