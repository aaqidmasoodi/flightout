"""One coarse heightmap of the whole large map, for effects that need to see far across it at once (the terrain's
cast shadows: scripts/world/terrain_overview.gd, shaders/terrain_cdlod.gdshader).

Reads one level of the terrain tiles (default 3: a sample every 256 m) and writes, next to them:
  overview.bin   zstd frame of width x height little-endian uint16 heights (same encoding as the tiles)
and adds "overview": {level, width, height, x0, z0, spacing} to terrain.json.

Usage: python build_overview.py <terrain_dir> [level]
"""
import json
import os
import sys

import imagecodecs
import numpy as np


def main():
    tdir = sys.argv[1]
    lv = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    meta = json.load(open(os.path.join(tdir, "terrain.json")))
    tq, ts = meta["tile_quads"], meta["tile_samples"]
    nx, nz = meta["tiles"][lv]
    offs = np.fromfile(os.path.join(tdir, "i%d.bin" % lv), dtype="<u8")
    data = open(os.path.join(tdir, "h%d.bin" % lv), "rb").read()
    out = np.zeros((nz * tq + 1, nx * tq + 1), "<u2")
    for j in range(nz):
        for i in range(nx):
            k = j * nx + i
            t = np.frombuffer(imagecodecs.zstd_decode(data[offs[k]:offs[k + 1]]), "<u2").reshape(ts, ts)
            out[j * tq: j * tq + tq + 1, i * tq: i * tq + tq + 1] = t[1:-1, 1:-1]
    open(os.path.join(tdir, "overview.bin"), "wb").write(imagecodecs.zstd_encode(out.tobytes(), level=12))
    meta["overview"] = {"level": lv, "width": int(out.shape[1]), "height": int(out.shape[0]), "x0": meta["x0"],
                        "z0": meta["z0"], "spacing": meta["spacing"] * (1 << lv)}
    json.dump(meta, open(os.path.join(tdir, "terrain.json"), "w"), indent=1)
    print("DONE", out.shape)


if __name__ == "__main__":
    main()
