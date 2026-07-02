#!/usr/bin/env python3
"""Self-refreshing HTML dashboard over the experiment logs.

    python3 harness/dashboard.py            # write logs/dashboard.html once
    python3 harness/dashboard.py --watch    # regenerate every 15 s

Open logs/dashboard.html in a browser; the page reloads itself every 30 s.
Stdlib only; charts are inline SVG. Colors follow the validated reference
palette (light+dark; buckets easy/med/hard = categorical slots 1-3, fixed
order; per-mark <title> tooltips; every chart has a table view).
"""

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

CSS = """
:root { color-scheme: light dark; }
body { margin:0; padding:24px; background:#f9f9f7; color:#0b0b0b;
  font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif; }
.viz-root {
  --surface-1:#fcfcfb; --ink-1:#0b0b0b; --ink-2:#52514e; --ink-3:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --ring:rgba(11,11,11,0.10);
  --good:#006300; --bad:#d03b3b;
  --s-easy:#2a78d6; --s-medium:#1baf7a; --s-hard:#eda100;
  --track:#cde2fb; --accent:#2a78d6;
}
@media (prefers-color-scheme: dark) {
  body { background:#0d0d0d; color:#ffffff; }
  .viz-root {
    --surface-1:#1a1a19; --ink-1:#ffffff; --ink-2:#c3c2b7; --ink-3:#898781;
    --grid:#2c2c2a; --axis:#383835; --ring:rgba(255,255,255,0.10);
    --good:#0ca30c; --bad:#e66767;
    --s-easy:#3987e5; --s-medium:#199e70; --s-hard:#c98500;
    --track:#104281; --accent:#3987e5;
  }
}
h1 { font-size:20px; margin:0 0 2px; }
h2 { font-size:15px; margin:28px 0 10px; color:var(--ink-1); }
.sub { color:var(--ink-3); font-size:12px; margin-bottom:20px; }
.card { background:var(--surface-1); border:1px solid var(--ring);
  border-radius:10px; padding:16px 18px; }
.tiles { display:flex; gap:12px; flex-wrap:wrap; }
.tile { min-width:150px; flex:1; }
.tile .lbl { color:var(--ink-2); font-size:12px; }
.tile .val { font-size:30px; font-weight:600; margin:2px 0; }
.tile .delta { font-size:12px; }
.up-good { color:var(--good); } .down-bad { color:var(--bad); }
.legend { display:flex; gap:16px; font-size:12px; color:var(--ink-2); margin:4px 0 8px; }
.legend .sw { display:inline-block; width:10px; height:10px; border-radius:3px;
  margin-right:5px; vertical-align:-1px; }
table { border-collapse:collapse; font-size:12.5px; width:100%; }
th { text-align:left; color:var(--ink-2); font-weight:600; }
th,td { padding:4px 10px 4px 0; border-bottom:1px solid var(--grid); }
td.num, th.num { text-align:right; font-variant-numeric:tabular-nums; }
details { margin-top:8px; } summary { cursor:pointer; color:var(--ink-3); font-size:12px; }
.meter { background:var(--track); border-radius:5px; height:10px; width:160px;
  display:inline-block; vertical-align:middle; }
.meter > div { background:var(--accent); border-radius:5px; height:10px; }
.status-running { color:var(--good); font-weight:600; }
.status-done { color:var(--ink-3); }
svg text { fill:var(--ink-2); font:11px system-ui,-apple-system,"Segoe UI",sans-serif; }
svg .tick { fill:var(--ink-3); font-variant-numeric:tabular-nums; }
svg .vlab { fill:var(--ink-1); font-weight:600; }
svg .grid { stroke:var(--grid); stroke-width:1; }
svg .axis { stroke:var(--axis); stroke-width:1; }
"""


def load_runs():
    """[(run_id, meta, rows)] sorted by start time."""
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


def ladder_runs(runs):
    """Ladder = completed-or-running dev60 evals, one per config, in time order."""
    seen = {}
    for rid, meta, rows in runs:
        if rid.endswith(LADDER_SUFFIX) and rows:
            seen[rid] = (rid, meta, rows)
    return list(seen.values())


def esc(s):
    return html.escape(str(s))


def rounded_bar(x, y, w, h, color, title):
    """Horizontal bar: square at baseline (left), 4px rounded data end."""
    r = min(4, w / 2, h / 2)
    if w <= 1:
        return ""
    path = (f"M{x:.1f},{y:.1f} h{w - r:.1f} q{r:.1f},0 {r:.1f},{r:.1f} "
            f"v{h - 2 * r:.1f} q0,{r:.1f} {-r:.1f},{r:.1f} h{-(w - r):.1f} z")
    return (f'<path d="{path}" fill="{color}"><title>{esc(title)}</title></path>')


def ladder_chart(stats_by_cfg):
    """Grouped horizontal bars: pass@1 per config x bucket."""
    cfgs = list(stats_by_cfg.keys())
    bar_h, gap, group_pad = 14, 2, 14
    group_h = 3 * bar_h + 2 * gap + group_pad
    left, right, top = 150, 60, 18
    width = 720
    plot_w = width - left - right
    height = top + group_h * len(cfgs) + 24
    parts = [f'<svg viewBox="0 0 {width} {height}" width="100%" role="img" '
             f'aria-label="pass@1 per config and difficulty bucket">']
    for gx in (0, 0.25, 0.5, 0.75, 1.0):
        x = left + gx * plot_w
        parts.append(f'<line class="grid" x1="{x:.0f}" y1="{top - 6}" x2="{x:.0f}" '
                     f'y2="{height - 20}"/>')
        parts.append(f'<text class="tick" x="{x:.0f}" y="{height - 6}" '
                     f'text-anchor="middle">{gx:g}</text>')
    parts.append(f'<line class="axis" x1="{left}" y1="{top - 6}" x2="{left}" y2="{height - 20}"/>')
    for i, cfg in enumerate(cfgs):
        y0 = top + i * group_h
        parts.append(f'<text x="{left - 8}" y="{y0 + bar_h * 1.5 + gap + 4}" '
                     f'text-anchor="end" class="vlab">{esc(cfg)}</text>')
        for j, b in enumerate(BUCKETS):
            st = stats_by_cfg[cfg].get(b) or {}
            v = st.get("pass@1")
            if v is None:
                continue
            y = y0 + j * (bar_h + gap)
            w = v * plot_w
            col = f"var(--s-{b})"
            parts.append(rounded_bar(left, y, w, bar_h, col,
                                     f"{cfg} · {b}: pass@1 {v:.3f} "
                                     f"({st.get('solved')}/{st.get('attempts')})"))
            parts.append(f'<text x="{left + w + 6}" y="{y + bar_h - 3}" '
                         f'class="tick">{v:.2f}</text>')
    parts.append("</svg>")
    return "".join(parts)


def mini_line(title_txt, stats_by_cfg, key, fmt):
    """Small-multiple line chart of one metric across ladder steps, 3 series."""
    cfgs = list(stats_by_cfg.keys())
    if len(cfgs) < 2:
        return ""
    width, height, left, top = 320, 150, 46, 26
    plot_w, plot_h = width - left - 14, height - top - 30
    vals = {}
    vmax = 0.0
    for b in BUCKETS:
        vs = []
        for cfg in cfgs:
            v = (stats_by_cfg[cfg].get(b) or {}).get(key)
            vs.append(v)
            if v is not None:
                vmax = max(vmax, v)
        vals[b] = vs
    if vmax == 0:
        return ""
    def sx(i):
        return left + (i / max(len(cfgs) - 1, 1)) * plot_w
    def sy(v):
        return top + plot_h - (v / vmax) * plot_h
    parts = [f'<svg viewBox="0 0 {width} {height}" width="{width}" role="img" '
             f'aria-label="{esc(title_txt)} across configs">']
    parts.append(f'<text x="{left}" y="14" class="vlab">{esc(title_txt)}</text>')
    for gy in (0, 0.5, 1.0):
        y = top + plot_h - gy * plot_h
        parts.append(f'<line class="grid" x1="{left}" y1="{y:.0f}" x2="{left + plot_w}" y2="{y:.0f}"/>')
        parts.append(f'<text class="tick" x="{left - 6}" y="{y + 4:.0f}" '
                     f'text-anchor="end">{fmt(gy * vmax)}</text>')
    for i, cfg in enumerate(cfgs):
        parts.append(f'<text class="tick" x="{sx(i):.0f}" y="{height - 8}" '
                     f'text-anchor="middle">{i}</text>')
    for b in BUCKETS:
        pts = [(sx(i), sy(v)) for i, v in enumerate(vals[b]) if v is not None]
        if len(pts) < 2:
            continue
        d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
        col = f"var(--s-{b})"
        parts.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2" '
                     f'stroke-linejoin="round" stroke-linecap="round"/>')
        ex, ey = pts[-1]
        parts.append(f'<circle cx="{ex:.1f}" cy="{ey:.1f}" r="4" fill="{col}" '
                     f'stroke="var(--surface-1)" stroke-width="2">'
                     f'<title>{esc(title_txt)} · {b}: '
                     + ", ".join(fmt(v) for v in vals[b] if v is not None)
                     + "</title></circle>")
    parts.append("</svg>")
    return "".join(parts)


def legend_html():
    return ('<div class="legend">'
            + "".join(f'<span><span class="sw" style="background:var(--s-{b})"></span>{b}</span>'
                      for b in BUCKETS)
            + "</div>")


def stats_table(stats_by_cfg, keys):
    head = "<tr><th>config</th>" + "".join(
        f"<th class=num>{b} {k}</th>" for k in keys for b in BUCKETS) + "</tr>"
    rows = []
    for cfg, st in stats_by_cfg.items():
        tds = []
        for k in keys:
            for b in BUCKETS:
                v = (st.get(b) or {}).get(k)
                if v is None:
                    tds.append("<td class=num>–</td>")
                elif isinstance(v, float):
                    tds.append(f"<td class=num>{v:,.3g}</td>")
                else:
                    tds.append(f"<td class=num>{v}</td>")
        rows.append(f"<tr><td>{esc(cfg)}</td>{''.join(tds)}</tr>")
    return f"<table>{head}{''.join(rows)}</table>"


def build():
    runs = load_runs()
    ladder = ladder_runs(runs)
    stats_by_cfg = {}
    for rid, meta, rows in ladder:
        cfg = rows[0].get("config_id", rid)
        stats_by_cfg[cfg] = bucket_stats(rows)

    total_cost = sum((r.get("total_cost_usd") or 0) for _, _, rows in runs for r in rows)
    total_attempts = sum(len(rows) for _, _, rows in runs)

    # stat tiles: latest config vs baseline
    tiles = []
    base = stats_by_cfg.get("baseline", {})
    if stats_by_cfg:
        latest_cfg = list(stats_by_cfg)[-1]
        latest = stats_by_cfg[latest_cfg]
        for b in BUCKETS:
            v = (latest.get(b) or {}).get("pass@1")
            bv = (base.get(b) or {}).get("pass@1")
            delta = ""
            if v is not None and bv is not None:
                d = v - bv
                cls = "up-good" if d >= 0 else "down-bad"
                delta = f'<div class="delta {cls}">{d:+.3f} vs baseline</div>'
            val = "–" if v is None else f"{v:.2f}"
            tiles.append(f'<div class="tile card"><div class="lbl">{b} pass@1 · '
                         f'{esc(latest_cfg)}</div><div class="val">{val}</div>{delta}</div>')
    tiles.append(f'<div class="tile card"><div class="lbl">policy spend, all runs</div>'
                 f'<div class="val">${total_cost:,.2f}</div>'
                 f'<div class="delta">{total_attempts:,} attempts</div></div>')

    # runs table
    now = time.time()
    run_rows = []
    for rid, meta, rows in runs:
        total = (meta.get("n_problems") or 0) * (meta.get("reps") or 1)
        done = len(rows)
        solved = sum(1 for r in rows if r.get("solved"))
        cost = sum((r.get("total_cost_usd") or 0) for r in rows)
        latest_ts = max((r.get("ts", 0) for r in rows), default=0)
        running = total and done < total and (now - latest_ts) < 900
        pct = 100 * done / total if total else 0
        status = ('<span class="status-running">running</span>' if running
                  else '<span class="status-done">done</span>' if total and done >= total
                  else '<span class="status-done">partial</span>')
        q = common.LOGS / "runs" / rid / "results.quarantine.jsonl"
        qn = len(common.read_jsonl(q)) if q.exists() else 0
        per_bucket = defaultdict(lambda: [0, 0])
        for r in rows:
            pb = per_bucket[r.get("difficulty", "?")]
            pb[0] += 1
            pb[1] += bool(r.get("solved"))
        pb_txt = " · ".join(f"{b}:{per_bucket[b][1]}/{per_bucket[b][0]}"
                            for b in BUCKETS if b in per_bucket)
        run_rows.append(
            f"<tr><td>{esc(rid)}</td><td>{status}</td>"
            f'<td><span class="meter"><div style="width:{pct:.0f}%"></div></span> '
            f"{done}/{total or '?'}</td>"
            f"<td>{solved}</td><td>{esc(pb_txt)}</td>"
            f"<td class=num>${cost:.2f}</td><td class=num>{qn or ''}</td></tr>")

    # rejects across ladder runs
    rej = defaultdict(lambda: defaultdict(int))
    for rid, meta, rows in ladder:
        cfg = rows[0].get("config_id", rid)
        for r in rows:
            if r.get("reject_reason"):
                rej[cfg][r["reject_reason"]] += 1
    rej_rows = "".join(
        f"<tr><td>{esc(cfg)}</td><td>" +
        ", ".join(f"{esc(k)}×{v}" for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:6])
        + "</td></tr>"
        for cfg, d in rej.items())

    minis = "".join(
        mini_line(t, stats_by_cfg, k, f) for t, k, f in [
            ("output tokens / attempt", "tokens_out_mean", lambda v: f"{v/1000:.1f}k"),
            ("cost $ / attempt", "cost_usd_mean", lambda v: f"{v:.3f}"),
            ("wall s / attempt", "wall_s_mean", lambda v: f"{v:.0f}"),
        ])

    updated = time.strftime("%Y-%m-%d %H:%M:%S")
    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<title>rocq-tools experiment dashboard</title>
<style>{CSS}</style></head>
<body class="viz-root">
<h1>AI-native Rocq tooling — experiment dashboard</h1>
<div class="sub">generated {updated} · auto-reloads every 30 s · regenerate:
<code>python3 harness/dashboard.py --watch</code> · details: STATUS.md, docs/REPORT.md</div>

<div class="tiles">{''.join(tiles)}</div>

<h2>Ladder — pass@1 by difficulty bucket (dev60, 2 reps)</h2>
<div class="card">{legend_html()}{ladder_chart(stats_by_cfg)}
<details><summary>table view</summary>
{stats_table(stats_by_cfg, ["pass@1", "solved", "attempts"])}</details></div>

<h2>Efficiency across ladder steps (x = ladder step, in scoreboard order)</h2>
<div class="card">{legend_html()}{minis}
<details><summary>table view</summary>
{stats_table(stats_by_cfg, ["tokens_out_mean", "cost_usd_mean", "wall_s_mean", "tool_calls_mean"])}</details></div>

<h2>Runs</h2>
<div class="card"><table>
<tr><th>run</th><th>status</th><th>progress</th><th>solved</th><th>per bucket</th>
<th class=num>cost</th><th class=num>quarantined</th></tr>
{''.join(run_rows)}</table></div>

<h2>Gate rejections (ladder runs)</h2>
<div class="card"><table><tr><th>config</th><th>reasons</th></tr>{rej_rows}</table></div>
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
