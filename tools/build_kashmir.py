"""Builds FlightOut's Kashmir terrain tiles from Copernicus DEM GLO-30 (see fetch_kashmir.py).

Map projection: azimuthal equidistant on a sphere, centred at LAT0, LON0. Map x grows east, z grows south (Godot
+Z), in metres; distances from the centre are exact and the distortion at the map edges (~350 km) is well under 1 %.
Heights are metres above sea level (the DEM's EGM2008 geoid heights).

Output, in out_dir (format version 2, read by scripts/world/terrain_streamer.gd):
  terrain.json   layout, projection, tiles per level, encoding
  h<l>.bin       level l tiles, each a zstd frame of (TQ+3)^2 little-endian uint16 heights (TQ+1 samples and a
                 one-sample border), row-major (z then x)
  i<l>.bin       uint64 byte offsets of every tile in h<l>.bin, plus the end offset
  mm<l>.bin      per tile min and max (uint16, same encoding)
Level l samples the DEM every SPACING * 2**l metres on the same grid, so every coarse vertex is also a fine
vertex (the renderer morphs between levels without cracks).

Usage: python build_kashmir.py <src_dir> <out_dir> [--levels-only N]
"""
import json
import math
import os
import sys
import time
from collections import OrderedDict

import imagecodecs
import numpy as np
import tifffile

LAT0, LON0 = 34.55, 76.4          # map centre
R_EARTH = 6371008.8
TQ = 64                           # quads per tile side
TS = TQ + 3
SPACING = 32.0                    # level 0 sample spacing (m)
HALF_X = 400000.0                 # map half extents (m)
HALF_Z = 344000.0
H_SCALE = 0.25
H_OFFSET = -500.0


def inverse_aeqd(x, z):
    """Map (x east, z south) metres -> (lat, lon) degrees."""
    y = -z
    rho = np.hypot(x, y)
    c = rho / R_EARTH
    phi0 = math.radians(LAT0)
    with np.errstate(invalid="ignore", divide="ignore"):
        sc, cc = np.sin(c), np.cos(c)
        lat = np.arcsin(cc * math.sin(phi0) + np.where(rho > 0, y * sc * math.cos(phi0) / rho, 0.0))
        lon = math.radians(LON0) + np.arctan2(x * sc, rho * math.cos(phi0) * cc - y * math.sin(phi0) * sc)
    return np.degrees(lat), np.degrees(lon)


class Dem:
    """1x1 degree GLO-30 tiles (3600 x 3600 here, pixel-is-point at whole arcseconds from the NW corner)."""

    def __init__(self, src, cache=24):
        self.src = src
        self.cache = OrderedDict()
        self.max = cache

    def tile(self, la, lo):
        k = (la, lo)
        if k in self.cache:
            self.cache.move_to_end(k)
            return self.cache[k]
        n = "Copernicus_DSM_COG_10_N%02d_00_E%03d_00_DEM.tif" % (la, lo)
        p = os.path.join(self.src, "dem", n)
        a = tifffile.imread(p).astype(np.float32) if os.path.exists(p) else None
        self.cache[k] = a
        if len(self.cache) > self.max:
            self.cache.popitem(last=False)
        return a

    def sample(self, lat, lon):
        out = np.zeros(lat.shape, np.float32)
        la0 = np.floor(lat).astype(int)
        lo0 = np.floor(lon).astype(int)
        for la, lo in set(zip(la0.ravel().tolist(), lo0.ravel().tolist())):
            m = (la0 == la) & (lo0 == lo)
            a = self.tile(la, lo)
            if a is None:
                continue
            h, w = a.shape
            # row 0 is the north edge (lat la + 1), column 0 the west edge
            fy = (la + 1 - lat[m]) * h
            fx = (lon[m] - lo) * w
            y0 = np.clip(np.floor(fy).astype(int), 0, h - 1)
            x0 = np.clip(np.floor(fx).astype(int), 0, w - 1)
            y1 = np.minimum(y0 + 1, h - 1)
            x1 = np.minimum(x0 + 1, w - 1)
            ty = np.clip(fy - y0, 0.0, 1.0)
            tx = np.clip(fx - x0, 0.0, 1.0)
            top = a[y0, x0] * (1 - tx) + a[y0, x1] * tx
            bot = a[y1, x0] * (1 - tx) + a[y1, x1] * tx
            out[m] = top * (1 - ty) + bot * ty
        return out


def encode(h):
    return np.clip(np.round((h - H_OFFSET) / H_SCALE), 0, 65535).astype("<u2")


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    dem = Dem(src)
    x0, z0 = -HALF_X, -HALF_Z
    leaf = TQ * SPACING
    nx0 = int(math.ceil(2 * HALF_X / leaf))
    nz0 = int(math.ceil(2 * HALF_Z / leaf))
    levels = 1
    while max(nx0, nz0) > (1 << (levels - 1)):
        levels += 1
    meta = {"version": 2, "tile_quads": TQ, "tile_samples": TS, "levels": levels, "spacing": SPACING,
            "x0": x0, "z0": z0, "h_scale": H_SCALE, "h_offset": H_OFFSET, "compression": "zstd",
            "projection": {"type": "aeqd", "lat0": LAT0, "lon0": LON0, "radius": R_EARTH},
            "source": "Copernicus DEM GLO-30", "tiles": []}
    k = np.arange(-1, TQ + 2, dtype=np.float64)
    for lv in range(levels):
        s = SPACING * (1 << lv)
        nx = int(math.ceil(nx0 / (1 << lv)))
        nz = int(math.ceil(nz0 / (1 << lv)))
        meta["tiles"].append([nx, nz])
        t0 = time.time()
        with open(os.path.join(out, "h%d.bin" % lv), "wb") as fh:
            offs = [0]
            mm = bytearray()
            for j in range(nz):
                # one row of tiles at a time (they share DEM tiles)
                zs = z0 + (j * TQ + k) * s
                xs = x0 + (np.arange(nx * TQ + 3) - 1) * s
                X, Z = np.meshgrid(xs, zs)
                lat, lon = inverse_aeqd(X, Z)
                H = dem.sample(lat, lon)
                for i in range(nx):
                    t = H[:, i * TQ: i * TQ + TS]
                    e = encode(t)
                    c = imagecodecs.zstd_encode(e.tobytes(), level=12)
                    fh.write(c)
                    offs.append(offs[-1] + len(c))
                    core = t[1:-1, 1:-1]
                    mm += encode(np.array([core.min(), core.max()])).tobytes()
                if j % 20 == 0:
                    print("level %d row %d/%d  %.0f s" % (lv, j, nz, time.time() - t0), flush=True)
        np.array(offs, dtype="<u8").tofile(os.path.join(out, "i%d.bin" % lv))
        with open(os.path.join(out, "mm%d.bin" % lv), "wb") as f:
            f.write(mm)
        print("LEVEL %d done: %d x %d tiles, %.1f MB, %.0f s" % (lv, nx, nz, offs[-1] / 1e6, time.time() - t0), flush=True)
    with open(os.path.join(out, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
