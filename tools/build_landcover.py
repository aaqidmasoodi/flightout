"""Land cover tiles for the Kashmir terrain, from ESA WorldCover 2021 (10 m, read at its 40 m overview).

Same tile layout as the heights (tools/build_kashmir.py): every height sample gets the land cover class at that
spot, so the renderer reads both with the same texture coordinates. Output, next to the heights:
  lc<l>.bin   level l tiles, each a zstd frame of (TQ+3)^2 uint8 WorldCover class codes
  lci<l>.bin  uint64 byte offsets of the tiles, plus the end offset
WorldCover classes: 10 tree cover, 20 shrubland, 30 grassland, 40 cropland, 50 built-up, 60 bare / sparse
vegetation, 70 snow and ice, 80 permanent water, 90 herbaceous wetland, 95 mangroves, 100 moss and lichen.
ESA WorldCover (C) ESA 2021, CC BY 4.0.

Usage: python build_landcover.py <src_dir> <terrain_dir>
"""
import json
import math
import os
import sys
import time

import imagecodecs
import numpy as np
import tifffile

sys.path.insert(0, os.path.dirname(__file__))
import build_kashmir as bk   # noqa: E402  (projection and grid)

OVERVIEW = 2                  # 0 = 10 m, 1 = 20 m, 2 = 40 m


class Cover:
    def __init__(self, src):
        self.src = src
        self.tiles = {}

    def tile(self, la, lo):
        k = (la, lo)
        if k not in self.tiles:
            n = "ESA_WorldCover_10m_2021_v200_N%02dE%03d_Map.tif" % (la, lo)
            p = os.path.join(self.src, "landcover", n)
            a = None
            if os.path.exists(p):
                with tifffile.TiffFile(p) as t:
                    a = t.series[0].levels[OVERVIEW].asarray()
            self.tiles[k] = a
        return self.tiles[k]

    def sample(self, lat, lon):
        out = np.zeros(lat.shape, np.uint8)
        la0 = (np.floor(lat / 3.0) * 3).astype(int)
        lo0 = (np.floor(lon / 3.0) * 3).astype(int)
        for la, lo in set(zip(la0.ravel().tolist(), lo0.ravel().tolist())):
            m = (la0 == la) & (lo0 == lo)
            a = self.tile(la, lo)
            if a is None:
                continue
            h, w = a.shape
            y = np.clip(((la + 3 - lat[m]) / 3.0 * h).astype(int), 0, h - 1)
            x = np.clip(((lon[m] - lo) / 3.0 * w).astype(int), 0, w - 1)
            out[m] = a[y, x]
        return out


def main():
    src, out = sys.argv[1], sys.argv[2]
    meta = json.load(open(os.path.join(out, "terrain.json")))
    TQ, TS = meta["tile_quads"], meta["tile_samples"]
    cover = Cover(src)
    k = np.arange(-1, TQ + 2, dtype=np.float64)
    for lv, (nx, nz) in enumerate(meta["tiles"]):
        s = meta["spacing"] * (1 << lv)
        t0 = time.time()
        with open(os.path.join(out, "lc%d.bin" % lv), "wb") as fh:
            offs = [0]
            for j in range(nz):
                zs = meta["z0"] + (j * TQ + k) * s
                xs = meta["x0"] + (np.arange(nx * TQ + 3) - 1) * s
                X, Z = np.meshgrid(xs, zs)
                lat, lon = bk.inverse_aeqd(X, Z)
                C = cover.sample(lat, lon)
                for i in range(nx):
                    c = imagecodecs.zstd_encode(np.ascontiguousarray(C[:, i * TQ: i * TQ + TS]).tobytes(), level=12)
                    fh.write(c)
                    offs.append(offs[-1] + len(c))
                if j % 40 == 0:
                    print("level %d row %d/%d  %.0f s" % (lv, j, nz, time.time() - t0), flush=True)
        np.array(offs, dtype="<u8").tofile(os.path.join(out, "lci%d.bin" % lv))
        print("LEVEL %d done: %.1f MB, %.0f s" % (lv, offs[-1] / 1e6, time.time() - t0), flush=True)
    meta["landcover"] = "ESA WorldCover 2021 v200"
    with open(os.path.join(out, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
