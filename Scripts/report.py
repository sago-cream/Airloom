#!/usr/bin/env python3
"""Create a self-contained report from the recorded, matched playback measurements."""
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = ROOT / "Benchmarks"


def read(name):
    return json.loads((BENCHMARKS / name).read_text())


def chart(title, before, after, detail):
    maximum = max(before["cpu_mean_percent"], after["cpu_mean_percent"]) * 1.05
    rows = []
    for name, result, color in [("Dynamic Wallpaper", before, "--chart-2"), ("Torii", after, "--chart-1")]:
        value = result["cpu_mean_percent"]
        rows.append(f'''<div class="row"><span>{name}</span><div class="track"><div class="bar"
            style="width:{value / maximum * 100:.4f}%;background:var({color})"></div></div>
            <strong>{value:.3f}%</strong></div>''')
    return f'''<section><h2>{title}</h2>{''.join(rows)}<p>{detail}</p></section>'''


covered_before = read("dynamic-covered.json")
covered_after = read("torii-covered.json")
continuous_before = read("dynamic-fresh.json")
continuous_after = read("torii-continuous.json")
speedup = covered_before["cpu_mean_percent"] / covered_after["cpu_mean_percent"]
page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:dark;--foreground:#eee;--muted-foreground:#aaa;--card:#242428;--border:#45454b;--chart-1:#78c5a5;--chart-2:#a99af5;--radius:12px;--font-sans:system-ui,sans-serif}
*{box-sizing:border-box}html,body{margin:0;background:transparent;font-family:var(--font-sans);color:var(--foreground)}
main{display:grid;gap:16px}section{background:var(--card);border-radius:var(--radius);padding:16px}
h2{font-size:15px;font-weight:600;margin:0 0 18px}p{font-size:12px;color:var(--muted-foreground);line-height:1.5;margin:14px 0 0}
.row{display:grid;grid-template-columns:140px minmax(24px,1fr) 70px;gap:12px;align-items:center;margin:12px 0;font-size:13px}
.track{height:20px;background:color-mix(in srgb,var(--border) 40%,transparent);border-radius:3px;overflow:hidden}
.bar{height:20px;min-width:2px;border-radius:3px}strong{font-variant-numeric:tabular-nums;text-align:right;font-weight:600}
.note{padding:0;margin:0;font-size:12px;color:var(--muted-foreground)}
@media(max-width:440px){.row{grid-template-columns:105px minmax(18px,1fr) 62px;gap:8px;font-size:12px}}
</style><main>'''
page += chart("CPU · desktop covered", covered_before, covered_after,
              f"{speedup:.1f}× less app CPU. Same maximized normal window; 61-second samples. Torii pauses hidden video automatically.")
page += chart("CPU · continuous video playback", continuous_before, continuous_after,
              "Similar CPU use. Same original 1080p / 24 fps video; 92-second samples. Torii’s covered-desktop pause disabled for this comparison.")
page += '''<p class="note">Mean CPU as a percentage of one core, measured on this Mac. App process trees only; GPU and shared system-service work excluded. These tests do not establish a 4× gain during visible playback or long-term memory stability.</p></main></html>'''
(BENCHMARKS / "comparison.html").write_text(page)
summary = {
    "covered_cpu_ratio": speedup,
    "covered": {"dynamic_cpu_percent": covered_before["cpu_mean_percent"], "torii_cpu_percent": covered_after["cpu_mean_percent"]},
    "continuous": {"dynamic_cpu_percent": continuous_before["cpu_mean_percent"], "torii_cpu_percent": continuous_after["cpu_mean_percent"],
                   "torii_mean_footprint_mib": continuous_after["footprint_mean_mib"]},
    "video": {"width": 1920, "height": 1080, "fps": 24,
              "encoded_video_sha256": "6597e6ccdcb5372e7343569a14e905d3a34d1ffda191a2b482c2d861c32c31b9"},
    "limitations": ["App CPU only, not total system energy", "No 4x gain in continuous playback", "Short runs cannot establish multi-day memory stability"],
}
(BENCHMARKS / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
