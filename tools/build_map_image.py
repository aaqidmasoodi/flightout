"""Shaded relief chart of a large map for the in-game map screen (M), from the built terrain and land cover tiles.

Writes <out_dir>/map.jpg and <out_dir>/map.json (the image's extent in map coordinates). The chart is drawn from
one coarse level (default 3: one pixel per 256 m): hypsometric tint, hillshade from the north west, then land cover
(forest, water, snow and ice, towns) on top.

Usage: python build_map_image.py <terrain_dir> <out_dir> [level]
"""
import json
import math
import os
import sys

import imagecodecs
import numpy as np
from scipy.ndimage import gaussian_filter


def read_level(tdir, prefix, iprefix, lv, nx, nz, ts, tq, dtype):
    offs = np.fromfile(os.path.join(tdir, "%s%d.bin" % (iprefix, lv)), dtype="<u8")
    data = open(os.path.join(tdir, "%s%d.bin" % (prefix, lv)), "rb").read()
    out = np.zeros((nz * tq + 1, nx * tq + 1), dtype)
    for j in range(nz):
        for i in range(nx):
            k = j * nx + i
            t = np.frombuffer(imagecodecs.zstd_decode(data[offs[k]:offs[k + 1]]), dtype).reshape(ts, ts)
            out[j * tq: j * tq + tq + 1, i * tq: i * tq + tq + 1] = t[1:-1, 1:-1]
    return out


# hypsometric tint: (height m, rgb)
TINT = [(0, (0.55, 0.62, 0.45)), (800, (0.62, 0.68, 0.48)), (1600, (0.74, 0.72, 0.52)), (2600, (0.72, 0.62, 0.46)),
        (3600, (0.64, 0.54, 0.42)), (4600, (0.63, 0.56, 0.49)), (5600, (0.68, 0.63, 0.58)), (7000, (0.8, 0.78, 0.76))]


def tint(h):
    hs = np.array([t[0] for t in TINT], np.float32)
    out = np.zeros(h.shape + (3,), np.float32)
    for c in range(3):
        out[..., c] = np.interp(h, hs, np.array([t[1][c] for t in TINT], np.float32))
    return out


def render(h, cover, s):
    """The chart's colours (0..1 rgb) from heights h (m) and land cover, s metres per sample."""
    img = tint(h)
    # hillshade, light from the north west, 45 degrees up (map rows grow south, columns east)
    gz, gx = np.gradient(h, s)
    nrm = np.stack([-gx, np.ones_like(h), -gz], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    L = np.array([-0.5, 0.7071, -0.5], np.float32)
    L /= np.linalg.norm(L)
    shade = np.clip((nrm * L).sum(-1), 0.0, 1.0)
    img *= (0.35 + 0.9 * shade)[..., None]

    def frac(lo, hi, sigma=0.8):
        # share of each class around a pixel (soft edges instead of a speckle of single samples)
        return gaussian_filter(((cover >= lo) & (cover < hi)).astype(np.float32), sigma)[..., None]

    def paint(f, rgb, a):
        img[:] = img * (1 - f * a) + np.array(rgb, np.float32) * (f * a)

    paint(frac(5, 15), (0.22, 0.42, 0.2), 0.6)                         # forest
    paint(frac(45, 55), (0.55, 0.45, 0.42), 0.8)                       # towns
    snow_rgb = np.array((0.93, 0.95, 0.98), np.float32) * (0.6 + 0.45 * shade)[..., None]
    fs = frac(65, 75)
    img[:] = img * (1 - fs) + snow_rgb * fs
    paint(np.clip(frac(75, 85, 0.6) * 1.6, 0.0, 1.0), (0.3, 0.52, 0.72), 1.0)   # lakes and rivers

    img[h < -400.0] = (0.3, 0.3, 0.32)                               # outside the elevation data
    img = np.clip(img, 0.0, 1.0) ** (1 / 1.1)
    return img


def main():
    tdir, out = sys.argv[1], sys.argv[2]
    lv = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    meta = json.load(open(os.path.join(tdir, "terrain.json")))
    tq, ts = meta["tile_quads"], meta["tile_samples"]
    nx, nz = meta["tiles"][lv]
    s = meta["spacing"] * (1 << lv)
    raw = read_level(tdir, "h", "i", lv, nx, nz, ts, tq, "<u2")
    h = raw.astype(np.float32) * meta["h_scale"] + meta["h_offset"]
    cover = read_level(tdir, "lc", "lci", lv, nx, nz, ts, tq, np.uint8) if "landcover" in meta else np.zeros(h.shape, np.uint8)

    img = render(h, cover, s)
    rgb = (img * 255 + 0.5).astype(np.uint8)
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "map.jpg"), "wb").write(imagecodecs.jpeg8_encode(rgb, level=88))
    ext = {"x0": meta["x0"], "z0": meta["z0"], "x1": meta["x0"] + (h.shape[1] - 1) * s, "z1": meta["z0"] + (h.shape[0] - 1) * s,
           "width": h.shape[1], "height": h.shape[0], "projection": meta.get("projection"),
           "credits": "Copernicus DEM GLO-30 (C) DLR/Airbus, ESA WorldCover 2021 (CC BY 4.0)"}
    json.dump(ext, open(os.path.join(out, "map.json"), "w"), indent=1)
    print("DONE", rgb.shape)


if __name__ == "__main__":
    main()
