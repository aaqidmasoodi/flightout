"""Detail tiles for the map screen (M): the same chart as map.jpg (tools/build_map_image.py), from a finer terrain
level, cut into square JPEG tiles that the map loads as you zoom in (scripts/ui/map_view.gd).

Writes into the terrain folder (shipped with it, not in git):
  chart<level>.json        the index: metres per pixel, tile size, the corner, tiles across and down, and where
                           each tile is: [file, offset, length] (empty where a tile is missing)
  chart<level>_<n>.bin     the tiles' JPEGs one after another, split into files of at most about 25 MB

Usage: python build_chart_tiles.py <terrain_dir> [level=1] [tile_px=512]
"""
import json
import os
import sys

import imagecodecs
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_map_image import read_level, render   # noqa: E402

PACK_MAX = 25 * 1024 * 1024
MARGIN = 8           # samples around each block, so the shading and land cover blur match across block edges


def main():
    tdir = sys.argv[1]
    lv = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    tp = int(sys.argv[3]) if len(sys.argv) > 3 else 512
    meta = json.load(open(os.path.join(tdir, "terrain.json")))
    tq, ts = meta["tile_quads"], meta["tile_samples"]
    nx, nz = meta["tiles"][lv]
    s = meta["spacing"] * (1 << lv)
    raw = read_level(tdir, "h", "i", lv, nx, nz, ts, tq, "<u2")
    cover = read_level(tdir, "lc", "lci", lv, nx, nz, ts, tq, np.uint8) if "landcover" in meta else np.zeros(raw.shape, np.uint8)
    H, W = raw.shape
    tx, tz = (W + tp - 1) // tp, (H + tp - 1) // tp
    print("level %d: %d x %d samples of %.0f m, %d x %d tiles" % (lv, W, H, s, tx, tz), flush=True)
    index = []
    packs = []
    cur = bytearray()

    def flush():
        nonlocal cur
        if cur:
            name = "chart%d_%d.bin" % (lv, len(packs))
            open(os.path.join(tdir, name), "wb").write(cur)
            packs.append(name)
            cur = bytearray()

    for j in range(tz):
        for i in range(tx):
            x0, z0 = i * tp, j * tp
            a0, b0 = max(z0 - MARGIN, 0), max(x0 - MARGIN, 0)
            a1, b1 = min(z0 + tp + MARGIN, H), min(x0 + tp + MARGIN, W)
            h = raw[a0:a1, b0:b1].astype(np.float32) * meta["h_scale"] + meta["h_offset"]
            img = render(h, cover[a0:a1, b0:b1], s)
            img = img[z0 - a0: z0 - a0 + tp, x0 - b0: x0 - b0 + tp]
            if img.shape[0] < tp or img.shape[1] < tp:            # the last row and column: padded with their edge
                img = np.pad(img, ((0, tp - img.shape[0]), (0, tp - img.shape[1]), (0, 0)), mode="edge")
            jpg = imagecodecs.jpeg8_encode((img * 255 + 0.5).astype(np.uint8), level=84)
            if len(cur) + len(jpg) > PACK_MAX:
                flush()
            index.append([len(packs), len(cur), len(jpg)])
            cur += jpg
        print("row %d / %d" % (j + 1, tz), flush=True)
    flush()
    json.dump({"level": lv, "m_per_px": s, "tile_px": tp, "x0": meta["x0"], "z0": meta["z0"], "tiles_x": tx, "tiles_z": tz,
               "packs": packs, "tiles": index}, open(os.path.join(tdir, "chart%d.json" % lv), "w"))
    print("DONE %d tiles in %d packs" % (len(index), len(packs)))


if __name__ == "__main__":
    main()
