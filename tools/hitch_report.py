"""Summarises a per-frame bench log (scripts/dev/bench.gd --bench-frames=...): finds hitches and what each one
coincided with. Usage: python hitch_report.py <frames.csv>"""
import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
for r in rows:
    for k in r:
        r[k] = float(r[k])
dts = [r["dt_ms"] for r in rows]
med = statistics.median(dts)
print("frames %d  median %.2f ms  p99 %.2f  max %.2f" % (len(rows), med, sorted(dts)[int(len(dts) * 0.99)], max(dts)))
tot = {k: sum(r[k] for r in rows) for k in ["loads", "evict", "evict_split", "near_rebuild", "cells_planted", "origin_shift"]}
print("totals", {k: int(v) for k, v in tot.items()})
if "pipelines" in rows[0]:
    print("pipeline compilations during the run:", int(sum(r["pipelines"] for r in rows)))
print("terrain_us median %.0f max %.0f | forest_us median %.0f max %.0f | near_us max %.0f" % (
    statistics.median(r["terrain_us"] for r in rows), max(r["terrain_us"] for r in rows),
    statistics.median(r["forest_us"] for r in rows), max(r["forest_us"] for r in rows), max(r["near_us"] for r in rows)))
spikes = [i for i, r in enumerate(rows) if r["dt_ms"] > max(med * 1.6, med + 6.0)]
print("hitches (> %.1f ms): %d" % (max(med * 1.6, med + 6.0), len(spikes)))
cause = {"pipeline_compile": 0, "main_thread": 0, "near_rebuild": 0, "planting": 0, "origin_shift": 0, "evict_split": 0, "gpu": 0, "loads>8": 0, "none": 0}
for i in spikes:
    r = rows[i]
    p = rows[i - 1] if i > 0 else r
    tags = []
    if r.get("pipelines", 0) or p.get("pipelines", 0):
        tags.append("pipeline_compile")
    if r.get("process_ms", 0) + r.get("physics_ms", 0) > 10.0:
        tags.append("main_thread")
    if r["near_rebuild"] or p["near_rebuild"]:
        tags.append("near_rebuild")
    if r["cells_planted"] or p["cells_planted"]:
        tags.append("planting")
    if r["origin_shift"] or p["origin_shift"]:
        tags.append("origin_shift")
    if r["evict_split"] or p["evict_split"]:
        tags.append("evict_split")
    if r["gpu_ms"] > statistics.median(x["gpu_ms"] for x in rows) * 1.5:
        tags.append("gpu")
    if r["loads"] + p["loads"] > 8:
        tags.append("loads>8")
    for t in tags:
        cause[t] += 1
    if not tags:
        cause["none"] += 1
print("hitch coincidences", cause)
for i in spikes[:40]:
    r = rows[i]
    print("t %.2f dt %.1f proc %.1f phys %.1f pipes %d cpu %.1f gpu %.1f terr %d forest %d near %d loads %d evict %d/%d planted %d shift %d" % (
        r["t"], r["dt_ms"], r.get("process_ms", 0), r.get("physics_ms", 0), r.get("pipelines", 0), r["cpu_ms"], r["gpu_ms"], r["terrain_us"], r["forest_us"], r["near_us"], r["loads"], r["evict"],
        r["evict_split"], r["cells_planted"], r["origin_shift"]))
# terrain coarsening: frames where the number of drawn tiles drops sharply and comes back (a patch collapsing)
flick = 0
for i in range(1, len(rows) - 3):
    a = rows[i - 1]["drawn"]
    b = rows[i]["drawn"]
    if a - b >= 3 and max(rows[i + 1]["drawn"], rows[i + 2]["drawn"], rows[i + 3]["drawn"]) >= a - 1:
        flick += 1
print("terrain collapse-and-return events:", flick)
