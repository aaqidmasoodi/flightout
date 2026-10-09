"""Downloads the source data for the Kashmir map (run with the tools venv; resumable: finished files are skipped).

  Copernicus DEM GLO-30 (30 m elevation), 1x1 degree tiles, public AWS bucket copernicus-dem-30m
  ESA WorldCover 2021 v200 (10 m land cover), 3x3 degree tiles, public AWS bucket esa-worldcover

Area: 31-38 N, 71-81 E (the whole of Kashmir with a margin).
Licences: Copernicus DEM (C) DLR e.V. 2010-2014 and (C) Airbus Defence and Space GmbH 2014-2018, provided under
COPERNICUS by the European Union and ESA; ESA WorldCover (C) ESA 2021, CC BY 4.0. Credit both in the game.

Usage: python fetch_kashmir.py <out_dir>
"""
import os
import sys
import time
import urllib.request

LAT = range(31, 38)        # tile south edges
LON = range(71, 81)        # tile west edges


def dem_url(lat, lon):
    n = "Copernicus_DSM_COG_10_N%02d_00_E%03d_00_DEM" % (lat, lon)
    return "https://copernicus-dem-30m.s3.amazonaws.com/%s/%s.tif" % (n, n), n + ".tif"


def wc_tiles():
    seen = set()
    for lat in LAT:
        for lon in LON:
            seen.add((lat // 3 * 3, lon // 3 * 3))
    for la, lo in sorted(seen):
        n = "ESA_WorldCover_10m_2021_v200_N%02dE%03d_Map.tif" % (la, lo)
        yield "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/" + n, n


def fetch(url, path):
    if os.path.exists(path):
        return "have"
    tmp = path + ".part"
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            os.replace(tmp, path)
            return "ok"
        except urllib.error.HTTPError as e:
            if e.code in (403, 404):
                return "missing"
            time.sleep(3)
        except Exception:
            time.sleep(3)
    return "failed"


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(os.path.join(out, "dem"), exist_ok=True)
    os.makedirs(os.path.join(out, "landcover"), exist_ok=True)
    jobs = [(u, os.path.join(out, "dem", n)) for u, n in (dem_url(a, o) for a in LAT for o in LON)]
    jobs += [(u, os.path.join(out, "landcover", n)) for u, n in wc_tiles()]
    for k, (u, p) in enumerate(jobs):
        r = fetch(u, p)
        size = os.path.getsize(p) / 1e6 if os.path.exists(p) else 0.0
        print("%3d/%d %-8s %7.1f MB  %s" % (k + 1, len(jobs), r, size, os.path.basename(p)), flush=True)
    print("DONE", flush=True)
