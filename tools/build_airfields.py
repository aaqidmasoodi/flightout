"""Airfields of the Kashmir map, from OurAirports (public domain: https://ourairports.com/data/).

Writes data/maps/kashmir/airfields.json: every open airfield in the map with a hard runway of 4000 ft or more,
with each runway's ends in map coordinates (tools/build_kashmir.py projection) and a straight height profile
fitted to the elevation data along it. build_kashmir.py flattens the terrain to that profile under every runway,
and the game draws the runway surface on it (scripts/world/airfields.gd).

Usage: python build_airfields.py <src_dir with dem/, airports.csv, runways.csv> <out_json>
"""
import csv
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import build_kashmir as bk   # noqa: E402

MIN_FT = 4000
HARD = ("ASP", "CON", "PEM", "BIT", "ASPH", "CONC", "GVL")


def forward_aeqd(lat, lon):
    p, l = math.radians(lat), math.radians(lon)
    p0, l0 = math.radians(bk.LAT0), math.radians(bk.LON0)
    c = math.acos(max(-1.0, min(1.0, math.sin(p0) * math.sin(p) + math.cos(p0) * math.cos(p) * math.cos(l - l0))))
    k = c / math.sin(c) if c > 1e-12 else 1.0
    x = bk.R_EARTH * k * math.cos(p) * math.sin(l - l0)
    y = bk.R_EARTH * k * (math.cos(p0) * math.sin(p) - math.sin(p0) * math.cos(p) * math.cos(l - l0))
    return x, -y


def main():
    src, out = sys.argv[1], sys.argv[2]
    dem = bk.Dem(src)
    airports = {}
    for r in csv.DictReader(open(os.path.join(src, "airports.csv"), encoding="utf-8")):
        try:
            la, lo = float(r["latitude_deg"]), float(r["longitude_deg"])
        except ValueError:
            continue
        x, z = forward_aeqd(la, lo)
        if abs(x) < bk.HALF_X - 5000 and abs(z) < bk.HALF_Z - 5000 and r["type"] in ("large_airport", "medium_airport", "small_airport"):
            airports[r["ident"]] = {"id": r["ident"], "icao": r["gps_code"] or r["ident"], "name": r["name"],
                                    "country": r["iso_country"], "type": r["type"], "lat": la, "lon": lon_round(lo),
                                    "x": round(x, 1), "z": round(z, 1), "runways": []}
    for r in csv.DictReader(open(os.path.join(src, "runways.csv"), encoding="utf-8")):
        a = airports.get(r["airport_ident"])
        if a is None or r["closed"] == "1" or not r["le_latitude_deg"] or not r["he_latitude_deg"]:
            continue
        try:
            length_ft = float(r["length_ft"] or 0)
        except ValueError:
            continue
        if length_ft < MIN_FT or not r["surface"].upper().startswith(HARD):
            continue
        ax, az = forward_aeqd(float(r["le_latitude_deg"]), float(r["le_longitude_deg"]))
        bx, bz = forward_aeqd(float(r["he_latitude_deg"]), float(r["he_longitude_deg"]))
        length = math.hypot(bx - ax, bz - az)
        try:
            width = max(30.0, float(r["width_ft"] or 0) * 0.3048)
        except ValueError:
            width = 45.0
        if width < 30.1:
            width = 45.0
        # straight height profile fitted to the elevation data along the centreline
        t = np.linspace(0.0, 1.0, 41)
        X = ax + (bx - ax) * t
        Z = az + (bz - az) * t
        la, lo = bk.inverse_aeqd(X, Z)
        h = dem.sample(la, lo).astype(np.float64)
        k1, k0 = np.polyfit(t, h, 1)
        a["runways"].append({"ids": [r["le_ident"], r["he_ident"]], "a": [round(ax, 2), round(k0, 2), round(az, 2)],
                             "b": [round(bx, 2), round(k0 + k1, 2), round(bz, 2)], "length": round(length, 1),
                             "width": round(width, 1), "surface": r["surface"]})
    fields = [a for a in airports.values() if a["runways"]]
    fields.sort(key=lambda a: a["name"])
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump({"source": "OurAirports (public domain)", "airfields": fields}, f, indent=1)
    for a in fields:
        print("%-6s %-45s %s %d runway(s)" % (a["id"], a["name"][:45], a["country"], len(a["runways"])))
    print("DONE %d airfields" % len(fields))


def lon_round(v):
    return round(v, 6)


if __name__ == "__main__":
    main()
