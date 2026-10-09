"""Terrain tile pyramid builder for FlightOut's streamed terrain (scripts/world/terrain_streamer.gd).

Input: a regular height grid (metres above sea level) in map coordinates: grid[kz, kx] is the height at
x = x0 + kx * spacing, z = z0 + kz * spacing (z grows southward, as Godot's +Z). Its size must be
TILE_QUADS * 2**(levels - 1) * roots + 1 samples per side (pad it).

Output (in out_dir):
  terrain.json        layout: levels, tile size, spacing, origin, tiles per level, height encoding
  h<level>.bin        every tile of that level, row-major (z then x); a tile is (TILE_QUADS + 3)^2 little-endian
                      uint16 heights: TILE_QUADS + 1 samples plus a one-sample border on every side (for normals)
  mm<level>.bin       per tile: min and max height (two uint16, same encoding), for culling and LOD distances
Level 0 is the finest. Level l is level 0 decimated by 2**l (every other sample), so a coarse vertex always sits
exactly on a fine one: the renderer morphs fine grids onto coarse ones without cracks.
Height encoding: h = value * H_SCALE + H_OFFSET (0.25 m steps from -500 m to 15883 m).

Usage (standalone or inside Blender's Python):
  python terrain_tiles.py --r32 heightmap.r32 --size 1025 --spacing 40 --x0 -20480 --z0 -20480 --out assets/terrain
"""
import json
import os
import sys

import numpy as np

TILE_QUADS = 64
TS = TILE_QUADS + 3          # samples per tile side, border included
H_SCALE = 0.25
H_OFFSET = -500.0


def encode(h):
    return np.clip(np.round((h - H_OFFSET) / H_SCALE), 0, 65535).astype("<u2")


def build(grid, spacing, x0, z0, out_dir, levels=None):
    grid = np.asarray(grid, dtype=np.float64)
    n = grid.shape[0]
    assert grid.shape[0] == grid.shape[1], "square grids only"
    quads = n - 1
    assert quads % TILE_QUADS == 0, "size must be TILE_QUADS * k + 1"
    leaf_tiles = quads // TILE_QUADS
    if levels is None:
        levels = 1
        while (leaf_tiles >> (levels - 1)) > 1 and (leaf_tiles >> (levels - 1)) % 2 == 0:
            levels += 1
    os.makedirs(out_dir, exist_ok=True)
    meta = {"version": 1, "tile_quads": TILE_QUADS, "tile_samples": TS, "levels": levels, "spacing": spacing,
            "x0": x0, "z0": z0, "h_scale": H_SCALE, "h_offset": H_OFFSET, "tiles": []}
    g = grid
    for lv in range(levels):
        if lv > 0:
            g = g[::2, ::2]
        nt = (g.shape[0] - 1) // TILE_QUADS
        meta["tiles"].append([nt, nt])
        pad = np.pad(g, 1, mode="edge")          # border samples beyond the data repeat the edge
        tiles = bytearray()
        mm = bytearray()
        for tz in range(nt):
            for tx in range(nt):
                t = pad[tz * TILE_QUADS: tz * TILE_QUADS + TS, tx * TILE_QUADS: tx * TILE_QUADS + TS]
                tiles += encode(t).tobytes()
                core = t[1:-1, 1:-1]
                mm += encode(np.array([core.min(), core.max()])).tobytes()
        with open(os.path.join(out_dir, "h%d.bin" % lv), "wb") as f:
            f.write(tiles)
        with open(os.path.join(out_dir, "mm%d.bin" % lv), "wb") as f:
            f.write(mm)
        print("level %d: %d x %d tiles, spacing %.1f m" % (lv, nt, nt, spacing * 2 ** lv))
    with open(os.path.join(out_dir, "terrain.json"), "w") as f:
        json.dump(meta, f, indent=1)
    return meta


def _arg(name, default=None):
    a = sys.argv
    return a[a.index(name) + 1] if name in a else default


if __name__ == "__main__":
    size = int(_arg("--size"))
    raw = np.fromfile(_arg("--r32"), dtype="<f4").reshape(size, size)
    # heightmap.r32 rows run north to south from z = +half; the tile grid runs from z0 upward
    grid = raw[::-1, :] if "--flip" in sys.argv else raw
    build(grid, float(_arg("--spacing")), float(_arg("--x0")), float(_arg("--z0")), _arg("--out"))
