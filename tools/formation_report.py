"""Report on a two-ship formation test (scripts/dev/formation.gd).

    python tools/formation_report.py lead.csv wing.csv [server.csv]

For each client: frame rate and hitches, CPU and GPU render time, physics catching up, own-jet corrections; for the
other jet as this client shows it: how far behind the truth it is drawn (the truth is the other client's own log,
matched by wall clock), how far off it is beyond that delay, and frame-to-frame pops. Everything split into the
jets close together (under 300 m) and apart, since the question is whether being close makes it worse.
"""
import csv
import math
import sys
from bisect import bisect_left


def load(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return v
    return [{k: num(v) for k, v in r.items()} for r in rows if r.get("wall")]


def pct(v, p):
    if not v:
        return float("nan")
    s = sorted(v)
    return s[min(len(s) - 1, int(p / 100.0 * len(s)))]


def mean(v):
    return sum(v) / len(v) if v else float("nan")


def truth_at(other, t):
    """The other jet's own position at wall time t (linear between its frames)."""
    ts = other["_t"]
    i = bisect_left(ts, t)
    if i <= 0 or i >= len(ts):
        return None
    a, b = other["rows"][i - 1], other["rows"][i]
    u = (t - a["wall"]) / max(b["wall"] - a["wall"], 1e-6)
    return tuple(a[k] + (b[k] - a[k]) * u for k in ("x", "y", "z"))


def client_report(name, rows, other):
    fly = [r for r in rows if r["phase"] not in ("wait",)]
    # the last seconds are the other client quitting (its jet stops updating): not flying
    if fly and other:
        end = min(fly[-1]["wall"], other["rows"][-1]["wall"]) - 3.0
        fly = [r for r in fly if r["wall"] < end]
    print(f"\n=== {name}: {len(fly)} frames, {fly[-1]['wall'] - fly[0]['wall']:.0f} s" if fly else f"\n=== {name}: no frames")
    if not fly:
        return
    for label, sel in (("all", fly), ("close <300 m", [r for r in fly if 0 <= r["dist"] < 300]),
                       ("apart >1 km", [r for r in fly if r["dist"] > 1000])):
        if not sel:
            continue
        dts = [r["dt"] for r in sel]
        print(f"  [{label}] frames {len(sel)}  fps avg {1000.0 / mean(dts):.0f}  1% low {1000.0 / pct(dts, 99):.0f}  "
              f"worst {max(dts):.0f} ms  >33 ms {sum(d > 33.3 for d in dts) / len(dts) * 100:.1f}%  "
              f">50 ms {sum(d > 50 for d in dts)}  cpu {mean([r['cpu_ms'] for r in sel]):.1f} ms  "
              f"gpu {mean([r['gpu_ms'] for r in sel]):.1f} ms  physics {mean([r['phys_ms'] for r in sel]):.1f} ms  "
              f"physics steps/frame >2: {sum(r['phys_steps'] > 2 for r in sel)}")
    print(f"  corrections {int(fly[-1]['corr'] - fly[0]['corr'])}  rewind total {fly[-1]['rewind_ms'] - fly[0]['rewind_ms']:.0f} ms  "
          f"rtt avg {mean([r['rtt_ms'] for r in fly]):.0f} ms  loss max {max(r['loss'] for r in fly):.1f}%  "
          f"predicted ahead of newest snapshot avg {mean([r['interp_ticks'] for r in fly]) / 120 * 1000:.0f} ms  "
          f"stale (no snapshot for 0.25 s) {sum(r['extrap'] for r in fly) / len(fly) * 100:.1f}% of frames")
    # the other jet as shown here
    pops = []
    seen = [((r["rx"], r["ry"], r["rz"]), r["wall"]) for r in fly if r["dist"] >= 0]
    for (p0, t0), (p1, t1), (p2, t2) in zip(seen, seen[1:], seen[2:]):
        if t1 - t0 > 1e-4 and t2 - t1 > 1e-4:
            pred = [p1[i] + (p1[i] - p0[i]) / (t1 - t0) * (t2 - t1) for i in range(3)]
            pops.append(math.dist(pred, p2))
    big = sum(e > 0.5 for e in pops)
    print(f"  other jet: frame-to-frame jump beyond its motion p50 {pct(pops, 50) * 100:.1f} cm  p99 {pct(pops, 99) * 100:.1f} cm  "
          f"max {max(pops) if pops else 0:.2f} m  jumps >0.5 m: {big}")
    if "us" in fly[0]:
        # what the screen shows: the other jet relative to ours (the camera rides with our jet), frame to frame.
        # Smooth relative motion has a near constant rate; anything else is the other jet shaking on screen.
        jerk = {"close": [], "apart": []}
        seq = [(r["us"] / 1e6, (r["srx"] - r["sx"], r["sry"] - r["sy"], r["srz"] - r["sz"]), r["dist"]) for r in fly if r["dist"] >= 0]
        for (t0, a, _), (t1, b, _), (t2, c, d) in zip(seq, seq[1:], seq[2:]):
            if t1 - t0 < 1e-4 or t2 - t1 < 1e-4:
                continue
            pred = [b[i] + (b[i] - a[i]) / (t1 - t0) * (t2 - t1) for i in range(3)]
            e = math.dist(pred, c)
            jerk["close" if d < 300 else "apart"].append((e, e / max(d, 1.0) * 1000.0))
        for k, v in jerk.items():
            if v:
                m = [x[0] for x in v]
                ang = [x[1] for x in v]
                print(f"  ON SCREEN ({k}): other jet's wobble relative to ours p50 {pct(m, 50) * 100:.1f} cm  p99 {pct(m, 99) * 100:.1f} cm  "
                      f"max {max(m):.2f} m  |  angle p50 {pct(ang, 50):.2f} mrad  p99 {pct(ang, 99):.2f} mrad  "
                      f"frames over 1 mrad {sum(x > 1.0 for x in ang) / len(ang) * 100:.1f}%")
    if other:
        lags, resid = [], []
        for r in fly[::10]:
            if r["dist"] < 0:
                continue
            shown = (r["rx"], r["ry"], r["rz"])
            best = None
            for ms in range(-300, 400, 5):
                tp = truth_at(other, r["wall"] - ms / 1000.0)
                if tp is None:
                    continue
                d = math.dist(shown, tp)
                if best is None or d < best[0]:
                    best = (d, ms)
            if best:
                resid.append(best[0])
                lags.append(best[1])
        print(f"  other jet drawn behind the truth (negative: ahead) by p50 {pct(lags, 50):.0f} ms (p95 {pct(lags, 95):.0f} ms), "
              f"off its true path by p50 {pct(resid, 50):.2f} m  p99 {pct(resid, 99):.2f} m")


def main():
    lead, wing = load(sys.argv[1]), load(sys.argv[2])
    pack = lambda rows: {"rows": rows, "_t": [r["wall"] for r in rows]}
    client_report("LEAD", lead, pack(wing))
    client_report("WING", wing, pack(lead))
    form = [r["dist"] for r in wing if r["phase"] == "form"]
    if form:
        print(f"\n  formation: {len(form)} frames in position, distance p50 {pct(form, 50):.0f} m  p95 {pct(form, 95):.0f} m")
    agl = [r["agl"] for r in lead + wing if r["phase"] in ("cruise", "form", "join")]
    if agl:
        print(f"  lowest height above ground in flight {min(agl):.0f} m")
    if len(sys.argv) > 3:
        s = load(sys.argv[3])
        if s:
            print(f"\n=== SERVER: {len(s)} s  ticks/s min {min(r['ticks'] for r in s):.0f}  avg {mean([r['ticks'] for r in s]):.1f}  "
                  f"tick avg {mean([r['avg_us'] for r in s]):.0f} us  worst {max(r['max_us'] for r in s) / 1000:.1f} ms  "
                  f"stalled player ticks {sum(r['stalls'] for r in s):.0f}  repeated inputs {sum(r['repeats'] for r in s):.0f}")


if __name__ == "__main__":
    main()
