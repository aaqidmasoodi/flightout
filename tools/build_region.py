"""The playable region's outline for the map screen (M): the whole of Kashmir (Jammu and Kashmir with Ladakh,
Azad Kashmir, Gilgit-Baltistan, the Siachen Glacier, Aksai Chin, the Shaksgam valley and Demchok), drawn as a
border and used to dim everything outside it.

Source: Natural Earth 1:10m "admin 0 disputed areas" (public domain), the parts above joined into one outline.

Writes, next to the chart (tools/build_map_image.py, whose map.json gives the extent and projection):
  region.json       the outline in map metres (x east, z south), simplified to about 150 m
  region_mask.png   8-bit mask over the chart's extent at half its resolution: 255 inside, 0 outside, softened over
                    about 1 km

Usage: python build_region.py <map_dir> [disputed_areas.geojson]
(without the file it is fetched from the Natural Earth repository on GitHub)
"""
import json
import math
import os
import sys
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from shapely.geometry import shape
from shapely.ops import unary_union

URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_disputed_areas.geojson"
PARTS = ["Jammu and Kashmir", "Azad Kashmir", "Gilgit-Baltistan", "Siachen Glacier", "Aksai Chin", "Shaksam Valley",
         "Demchok"]
SUPER = 4          # supersampling of the mask


def project(lat, lon, lat0, lon0, r):
    """(lat, lon) degrees -> map (x east, z south) metres, azimuthal equidistant (as the terrain)."""
    p, l = math.radians(lat), math.radians(lon)
    p0, l0 = math.radians(lat0), math.radians(lon0)
    c = math.acos(max(-1.0, min(1.0, math.sin(p0) * math.sin(p) + math.cos(p0) * math.cos(p) * math.cos(l - l0))))
    k = c / math.sin(c) if c > 1e-12 else 1.0
    x = r * k * math.cos(p) * math.sin(l - l0)
    y = r * k * (math.cos(p0) * math.sin(p) - math.sin(p0) * math.cos(p) * math.cos(l - l0))
    return x, -y


def main():
    out = sys.argv[1]
    if len(sys.argv) > 2:
        src = json.load(open(sys.argv[2]))
    else:
        with urllib.request.urlopen(URL, timeout=120) as f:
            src = json.load(f)
    feats = [f for f in src["features"] if f["properties"].get("BRK_NAME") in PARTS]
    found = sorted(f["properties"]["BRK_NAME"] for f in feats)
    assert len(found) == len(PARTS), found
    # joined: grown a little and shrunk back, so the slivers between neighbouring parts close
    region = unary_union([shape(f["geometry"]).buffer(0).buffer(0.002) for f in feats]).buffer(-0.002)
    if region.geom_type == "MultiPolygon":
        region = max(region.geoms, key=lambda g: g.area)
    m = json.load(open(os.path.join(out, "map.json")))
    pr = m["projection"]
    pts = [project(lat, lon, pr["lat0"], pr["lon0"], pr["radius"]) for lon, lat in region.exterior.coords]
    from shapely.geometry import Polygon
    poly = Polygon(pts).simplify(150.0)
    outline = [[round(x, 1), round(z, 1)] for x, z in poly.exterior.coords]
    json.dump({"source": "Natural Earth (public domain)", "parts": PARTS, "outline": outline},
              open(os.path.join(out, "region.json"), "w"))
    # the mask, over the chart's own rectangle (corner pixel centres x0 z0 .. x1 z1)
    s = (m["x1"] - m["x0"]) / (m["width"] - 1)
    left, top = m["x0"] - s * 0.5, m["z0"] - s * 0.5
    span_x, span_z = m["width"] * s, m["height"] * s
    w, h = (m["width"] + 1) // 2, (m["height"] + 1) // 2
    img = Image.new("L", (w * SUPER, h * SUPER), 0)
    ImageDraw.Draw(img).polygon([((x - left) / span_x * w * SUPER, (z - top) / span_z * h * SUPER) for x, z in outline],
                                fill=255)
    img = img.resize((w, h), Image.LANCZOS).filter(ImageFilter.GaussianBlur(1.0))
    img.save(os.path.join(out, "region_mask.png"), optimize=True)
    a = np.asarray(img)
    print("outline: %d points, area %.0f km2; mask %dx%d, %.1f %% inside" %
          (len(outline), poly.area / 1e6, w, h, 100.0 * (a > 127).mean()))


if __name__ == "__main__":
    main()
