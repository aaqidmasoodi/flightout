"""Su-27 external stores: pylons, launch rails and missiles, built procedurally and exported for the game.

Run with the airframe loaded (the stations are fitted to the real underside by ray casts):
  blender -b blender/su27.blend --factory-startup --python blender/build_stores.py -- \
      <out.glb> <out_stations.json> [--render <png>] [--lineup <png>]

Coordinates are the airframe's (Blender): nose toward -Y, +X is the jet's LEFT, +Z up. Every store is modelled
along its own Y axis (nose at -Y) with its suspension lugs on top (+Z), and placed at its station as a linked
duplicate, so the GLB carries one mesh per store type however many stations show it.

The real Su-27S has ten hardpoints (no drop tanks: its internal fuel is enormous):
  1 / 10  wingtip launch rails (P-72-1)          R-73
  2 / 9   outer wing pylons, P-72 rails          R-73
  3 / 8   inner wing pylons, APU-470 rails       R-27R / R-27ER / R-27T / R-27ET / R-77
  4 / 7   under the engine intakes, AKU-470      R-27R / R-27ER / R-27T / R-27ET / R-77
  5 / 6   tandem between the engines, AKU-470    R-27R / R-27ER / R-77
Each station in the GLB has STA_<n>_PYLON (always fitted) and one object per store it can carry,
STA_<n>_<STORE>; the game shows the one its loadout names (scripts/sim/stores.gd).
"""
import bpy, bmesh, math, json, sys, os
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT_GLB = argv[0] if len(argv) > 0 else "su27_stores.glb"
OUT_JSON = argv[1] if len(argv) > 1 else "su27_stations.json"
RENDER = argv[argv.index("--render") + 1] if "--render" in argv else None
LINEUP = argv[argv.index("--lineup") + 1] if "--lineup" in argv else None

scene = bpy.context.scene
dg = bpy.context.evaluated_depsgraph_get()
COL = bpy.data.collections.new("Stores")
scene.collection.children.link(COL)
LIB = bpy.data.collections.new("StoreLib")      # the master store models (not exported, linked copies are)
scene.collection.children.link(LIB)


# ------------------------------------------------------------------ materials
def mat(name, rgb, rough=0.5, metal=0.0, alpha=None, emit=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if alpha is not None:
        b.inputs["Alpha"].default_value = alpha
        m.blend_method = "BLEND" if hasattr(m, "blend_method") else None
    return m

M = {
    "white": mat("ST_White", (0.82, 0.83, 0.82), 0.45),
    "grey": mat("ST_Grey", (0.56, 0.58, 0.58), 0.5),
    "dark": mat("ST_Dark", (0.12, 0.12, 0.13), 0.55),
    "radome": mat("ST_Radome", (0.72, 0.72, 0.66), 0.35),
    "dome": mat("ST_SeekerDome", (0.05, 0.07, 0.1), 0.05, 0.3),
    "yellow": mat("ST_Yellow", (0.85, 0.65, 0.05), 0.45),
    "red": mat("ST_Red", (0.6, 0.08, 0.05), 0.45),
    "black": mat("ST_Black", (0.03, 0.03, 0.03), 0.6),
    "nozzle": mat("ST_Nozzle", (0.18, 0.17, 0.16), 0.35, 0.8),
    "pylon": mat("ST_Pylon", (0.52, 0.6, 0.64), 0.55),      # the airframe's blue-grey
    "rail": mat("ST_Rail", (0.3, 0.32, 0.33), 0.45, 0.6),
}


# ------------------------------------------------------------------ geometry helpers
def to_obj(name, bm, material, coll=LIB, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(material)
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
        try:
            me.set_sharp_from_angle(angle=math.radians(35))
        except Exception:
            pass
    ob = bpy.data.objects.new(name, me)
    coll.objects.link(ob)
    return ob


def rev(name, prof, material, segs=32, cap=True):
    """Body of revolution about Y: prof = [(y, r), ...] from nose (-Y) to tail. Closed at the ends."""
    bm = bmesh.new()
    rings = []
    for y, r in prof:
        if r <= 1e-5:
            rings.append([bm.verts.new((0.0, y, 0.0))])
        else:
            rings.append([bm.verts.new((r * math.sin(2 * math.pi * k / segs), y, r * math.cos(2 * math.pi * k / segs))) for k in range(segs)])
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        for k in range(segs):
            k2 = (k + 1) % segs
            if len(a) == 1:
                bm.faces.new((a[0], b[k2], b[k]))
            elif len(b) == 1:
                bm.faces.new((a[k], a[k2], b[0]))
            else:
                bm.faces.new((a[k], a[k2], b[k2], b[k]))
    if cap:
        for ring in (rings[0], rings[-1]):
            if len(ring) > 2:
                bm.faces.new(ring)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return to_obj(name, bm, material)


def fin(name, r0, y_root0, y_root1, span, y_tip0, y_tip1, thick, angle, material, tip_thick=None):
    """A flat fin radiating from the body at `angle` (radians, 0 = up, around Y): root chord y_root0..y_root1 at
    radius r0, tip chord y_tip0..y_tip1 at radius r0 + span. Bevelled leading and trailing edges."""
    tt = thick if tip_thick is None else tip_thick
    bm = bmesh.new()
    pts = [(r0, y_root0, 0.0), (r0 + span, y_tip0, 0.0), (r0 + span, y_tip1, 0.0), (r0, y_root1, 0.0)]
    # a lens section: thick in the middle of the chord, sharp at the edges
    def sec(r, y0, y1, t):
        m = (y0 + y1) / 2
        return [(r, y0, 0.0), (r, m - (y1 - y0) * 0.2, t / 2), (r, m + (y1 - y0) * 0.2, t / 2), (r, y1, 0.0),
                (r, m + (y1 - y0) * 0.2, -t / 2), (r, m - (y1 - y0) * 0.2, -t / 2)]
    root = [bm.verts.new(p) for p in sec(r0 - 0.004, y_root0, y_root1, thick)]
    tip = [bm.verts.new(p) for p in sec(r0 + span, y_tip0, y_tip1, tt)]
    n = len(root)
    for k in range(n):
        k2 = (k + 1) % n
        bm.faces.new((root[k], root[k2], tip[k2], tip[k]))
    bm.faces.new(list(reversed(root)))
    bm.faces.new(tip)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # radial direction: local X -> rotate about Y by angle (0 = +Z up)
    rot = Matrix.Rotation(-angle + math.pi / 2, 4, "Y")
    bm2 = bm
    ob = to_obj(name, bm2, material, smooth=False)
    ob.data.transform(rot)
    return ob


def box(name, lo, hi, material, bev=0.0):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    c = (Vector(lo) + Vector(hi)) / 2
    s = Vector(hi) - Vector(lo)
    for v in bm.verts:
        v.co = Vector((c.x + v.co.x * s.x, c.y + v.co.y * s.y, c.z + v.co.z * s.z))
    if bev > 0:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=bev, segments=2, affect="EDGES")
    return to_obj(name, bm, material, smooth=False)


def loft_profile(name, sections, material, smooth=True):
    """Loft closed 2D sections [(y, [(x, z), ...]), ...] along Y (equal point counts)."""
    bm = bmesh.new()
    rings = [[bm.verts.new((x, y, z)) for x, z in pts] for y, pts in sections]
    n = len(rings[0])
    for a, b in zip(rings, rings[1:]):
        for k in range(n):
            k2 = (k + 1) % n
            bm.faces.new((a[k], a[k2], b[k2], b[k]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return to_obj(name, bm, material, smooth=smooth)


def pylon_section(width, height, n=10):
    """Streamlined pylon cross-section in XZ: a slim aerofoil-like slab, flat top, rounded bottom."""
    pts = []
    for k in range(n):
        a = math.pi * k / (n - 1)
        pts.append((width / 2 * math.cos(a), -height + (height * 0.15) * (1 - math.sin(a))))
    pts = [(width / 2, 0.0)] + pts + [(-width / 2, 0.0)]
    return pts


def join(name, objs):
    for o in objs[1:]:
        for m_ in o.data.materials:
            pass
    ctx = bpy.context.copy()
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob


def ring(name, y, r, w, material):
    return rev(name, [(y - w / 2, 0.0), (y - w / 2, r), (y + w / 2, r), (y + w / 2, 0.0)], material, cap=False)


def ogive(y_nose, y_base, r, n=10, blunt=0.06):
    """Tangent-ogive nose profile [(y, r)] from a slightly blunted tip to the full radius."""
    L = y_base - y_nose
    prof = [(y_nose, 0.0)]
    for k in range(n + 1):
        t = blunt + (1.0 - blunt) * k / n
        prof.append((y_nose + L * t, r * math.sqrt(max(0.0, 1.0 - (1.0 - t) ** 2))))
    return prof


# ------------------------------------------------------------------ missiles
def r73():
    """R-73 (AA-11 Archer): IR dogfight missile. 2.9 m, 170 mm. Glass seeker dome; destabilizers and canard
    control fins at the nose, cruciform tail wings with rollerons; white body, yellow warhead band."""
    L, R = 2.9, 0.085
    y0 = -L / 2
    parts = []
    parts.append(rev("r73_dome", [(y0, 0.0), (y0 + 0.012, 0.03), (y0 + 0.03, 0.05), (y0 + 0.055, 0.068), (y0 + 0.085, 0.074)], M["dome"], 24))
    parts.append(rev("r73_nose", [(y0 + 0.085, 0.074), (y0 + 0.2, 0.08), (y0 + 0.35, R), (y0 + 0.36, R)], M["grey"]))
    parts.append(rev("r73_body", [(y0 + 0.36, R), (y0 + 2.75, R), (y0 + 2.84, 0.078), (y0 + 2.86, 0.0)], M["white"]))
    parts.append(rev("r73_nozzle", [(y0 + 2.8, 0.05), (y0 + 2.92, 0.056), (y0 + 2.92, 0.045), (y0 + 2.83, 0.04)], M["nozzle"], 20, cap=False))
    parts.append(ring("r73_band", y0 + 0.95, R + 0.0015, 0.05, M["yellow"]))
    parts.append(ring("r73_band2", y0 + 1.06, R + 0.0015, 0.02, M["red"]))
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        parts.append(fin("r73_destab", R, y0 + 0.13, y0 + 0.2, 0.035, y0 + 0.175, y0 + 0.2, 0.006, a, M["grey"]))
        parts.append(fin("r73_canard", R, y0 + 0.36, y0 + 0.58, 0.12, y0 + 0.5, y0 + 0.58, 0.012, a, M["white"]))
        parts.append(fin("r73_wing", R, y0 + 2.3, y0 + 2.8, 0.17, y0 + 2.62, y0 + 2.8, 0.012, a, M["white"]))
        parts.append(fin("r73_aileron", R + 0.12, y0 + 2.7, y0 + 2.8, 0.05, y0 + 2.72, y0 + 2.8, 0.008, a, M["grey"]))
    # umbilical / launch shoe raceway along the top
    parts.append(box("r73_shoe", (-0.02, y0 + 0.8, R - 0.01), (0.02, y0 + 2.2, R + 0.025), M["grey"], 0.004))
    return join("R-73", parts)


def r27(variant):
    """R-27 family (AA-10 Alamo). R/ER: semi-active radar (Fox 1), radome nose; T/ET: infrared (Fox 2), glass
    dome. E: extended range, longer and fatter motor. The famous 'butterfly' control wings (wider at the tips)
    sit at mid body; small destabilizers forward, trapezoid tail wings aft."""
    ir = variant in ("T", "ET")
    ext = variant in ("ER", "ET")
    L = {"R": 4.08, "T": 3.8, "ER": 4.78, "ET": 4.5}[variant]
    R = 0.115
    RM = 0.13 if ext else R            # the E's motor section is fatter
    y0 = -L / 2
    parts = []
    if ir:
        parts.append(rev("r27_dome", [(y0, 0.0), (y0 + 0.02, 0.045), (y0 + 0.05, 0.075), (y0 + 0.09, 0.095), (y0 + 0.13, 0.1)], M["dome"], 28))
        parts.append(rev("r27_seek", [(y0 + 0.13, 0.1), (y0 + 0.4, 0.112), (y0 + 0.55, R), (y0 + 0.56, R)], M["grey"]))
        nose_end = y0 + 0.56
    else:
        parts.append(rev("r27_radome", ogive(y0, y0 + 0.75, R, 12, 0.04), M["radome"], 32))
        nose_end = y0 + 0.75
    motor_y = y0 + L * 0.42
    prof = [(nose_end, R), (motor_y, R)]
    if ext:
        prof += [(motor_y + 0.08, RM)]
    prof += [(y0 + L - 0.14, RM), (y0 + L - 0.04, RM * 0.82), (y0 + L - 0.02, 0.0)]
    parts.append(rev("r27_body", prof, M["white"]))
    parts.append(rev("r27_nozzle", [(y0 + L - 0.06, 0.07), (y0 + L + 0.04, 0.078), (y0 + L + 0.04, 0.065), (y0 + L - 0.02, 0.055)], M["nozzle"], 20, cap=False))
    parts.append(ring("r27_band", nose_end + 0.55, R + 0.002, 0.07, M["yellow"]))
    parts.append(ring("r27_band2", motor_y + 0.25, RM + 0.002, 0.04, M["red"]))
    ym = motor_y - 0.35
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        parts.append(fin("r27_destab", R, nose_end + 0.05, nose_end + 0.3, 0.07, nose_end + 0.22, nose_end + 0.3, 0.01, a, M["grey"]))
        # butterfly control wing: short root, long tip chord, leading edge swept forward at the tip
        parts.append(fin("r27_ctrl", R, ym - 0.12, ym + 0.12, 0.27, ym - 0.3, ym + 0.12, 0.016, a, M["white"], tip_thick=0.01))
        parts.append(fin("r27_tail", RM, y0 + L - 0.75, y0 + L - 0.12, 0.2, y0 + L - 0.38, y0 + L - 0.14, 0.014, a, M["white"]))
    parts.append(box("r27_hook_f", (-0.025, ym - 0.6, R - 0.01), (0.025, ym - 0.45, R + 0.03), M["grey"], 0.005))
    parts.append(box("r27_hook_r", (-0.025, motor_y + 0.6, RM - 0.01), (0.025, motor_y + 0.75, RM + 0.03), M["grey"], 0.005))
    parts.append(box("r27_raceway", (-0.018, nose_end + 0.1, R - 0.01), (0.018, y0 + L - 0.3, R + 0.018), M["grey"], 0.004))
    return join("R-27" + variant, parts)


def r77():
    """R-77 (AA-12 Adder): active radar (Fox 3). 3.6 m, 200 mm. Ogive radome, four long narrow strake wings and
    the unmistakable lattice (grid) tail fins."""
    L, R = 3.6, 0.1
    y0 = -L / 2
    parts = []
    parts.append(rev("r77_radome", ogive(y0, y0 + 0.62, R, 12, 0.05), M["radome"], 32))
    parts.append(rev("r77_body", [(y0 + 0.62, R), (y0 + 3.42, R), (y0 + 3.52, 0.082), (y0 + 3.54, 0.0)], M["white"]))
    parts.append(rev("r77_nozzle", [(y0 + 3.48, 0.055), (y0 + 3.6, 0.062), (y0 + 3.6, 0.05), (y0 + 3.5, 0.045)], M["nozzle"], 20, cap=False))
    parts.append(ring("r77_band", y0 + 1.05, R + 0.002, 0.06, M["yellow"]))
    parts.append(ring("r77_band2", y0 + 1.95, R + 0.002, 0.035, M["red"]))
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        parts.append(fin("r77_strake", R, y0 + 1.25, y0 + 2.75, 0.045, y0 + 1.45, y0 + 2.7, 0.008, a, M["white"]))
        # grid fin: an outer frame with a diagonal lattice, standing out from the tail on a short stub
        gf = []
        fw, fh, depth = 0.21, 0.16, 0.035     # span, chord-wise height of the frame, its depth along the flow
        yc = y0 + 3.3
        rb = R + 0.015
        gf.append(box("gf_stub", (rb - 0.02, yc - 0.03, -0.012), (rb + 0.005, yc + 0.03, 0.012), M["grey"]))
        t = 0.006
        for (x0, x1, z0, z1) in ((rb, rb + fw, fh / 2 - t, fh / 2), (rb, rb + fw, -fh / 2, -fh / 2 + t),
                                  (rb, rb + t, -fh / 2, fh / 2), (rb + fw - t, rb + fw, -fh / 2, fh / 2)):
            gf.append(box("gf_frame", (x0, yc - depth / 2, z0), (x1, yc + depth / 2, z1), M["grey"]))
        # lattice: thin plates at +-45 degrees
        for j in range(-4, 5):
            for sgn in (-1, 1):
                b = box("gf_web", (-0.0015, yc - depth / 2 + 0.002, -0.17), (0.0015, yc + depth / 2 - 0.002, 0.17), M["grey"])
                b.data.transform(Matrix.Translation((rb + fw / 2 + j * 0.03, 0, 0)) @ Matrix.Rotation(sgn * math.pi / 4, 4, "Y"))
                # clip to the frame: keep only vertices inside by scaling (approximation: shorten long webs)
                for v in b.data.vertices:
                    v.co.x = min(max(v.co.x, rb + 0.004), rb + fw - 0.004)
                    v.co.z = min(max(v.co.z, -fh / 2 + 0.004), fh / 2 - 0.004)
                gf.append(b)
        g = join("r77_grid", gf)
        g.data.transform(Matrix.Rotation(-a + math.pi / 2, 4, "Y"))
        parts.append(g)
    parts.append(box("r77_shoe", (-0.022, y0 + 0.9, R - 0.01), (0.022, y0 + 2.9, R + 0.022), M["grey"], 0.004))
    return join("R-77", parts)


# ------------------------------------------------------------------ pylons and launchers
def streamlined(name, length, width, height, material, nose=0.35, tail=0.25):
    """A pylon body: aerofoil-ish slab, top at z = 0, hanging down `height`, tapering at both ends."""
    secs = []
    n = 9
    for k in range(n):
        t = k / (n - 1)
        y = -length / 2 + length * t
        # thickness taper: rounded nose, sharp tail
        if t < nose:
            f = math.sin(t / nose * math.pi / 2)
        elif t > 1 - tail:
            f = max(0.12, (1 - t) / tail)
        else:
            f = 1.0
        h = height * (0.55 + 0.45 * f)
        secs.append((y, [(x, z) for x, z in pylon_section(width * f, h)]))
    return loft_profile(name, secs, material)


def rail(name, length, material):
    """Launch rail (P-72 / APU-470 style): a slim beam with a T-slot underneath."""
    parts = [box(name + "_beam", (-0.035, -length / 2, -0.06), (0.035, length / 2, 0.0), material, 0.006),
             box(name + "_slot", (-0.02, -length / 2 + 0.05, -0.075), (0.02, length / 2 - 0.05, -0.058), M["rail"], 0.003),
             box(name + "_nose", (-0.03, -length / 2 - 0.1, -0.045), (0.03, -length / 2, 0.0), material, 0.012)]
    return join(name, parts)


def pyl_wingtip():
    """Wingtip launcher: a long slim pod along the tip chord carrying the R-73 rail underneath."""
    parts = [rev("tip_pod", [(-1.25, 0.0), (-1.15, 0.03), (-0.9, 0.05), (0.9, 0.05), (1.15, 0.03), (1.2, 0.0)], M["pylon"], 20)]
    r = rail("tip_rail", 1.7, M["pylon"])
    r.data.transform(Matrix.Translation((0, 0.05, -0.035)))
    parts.append(r)
    return join("PYL_WINGTIP", parts)


def pyl_r73():
    """Outer wing pylon with a P-72 rail for the R-73."""
    p = streamlined("p72_body", 1.25, 0.08, 0.16, M["pylon"])
    r = rail("p72_rail", 1.6, M["pylon"])
    r.data.transform(Matrix.Translation((0, 0.05, -0.15)))
    return join("PYL_P72", [p, r])


def pyl_wing_r27():
    """Inner wing pylon with the APU-470 rail launcher for the R-27 / R-77."""
    p = streamlined("apu_body", 1.9, 0.1, 0.24, M["pylon"])
    r = rail("apu_rail", 2.6, M["pylon"])
    r.data.transform(Matrix.Translation((0, 0.1, -0.23)))
    fair = box("apu_fair", (-0.05, -0.6, -0.25), (0.05, 0.9, -0.2), M["pylon"], 0.012)
    return join("PYL_APU470", [p, r, fair])


def pyl_ejector():
    """AKU-470 ejector launcher (under the intakes and between the engines): a short deep box with two hooks."""
    parts = [streamlined("aku_body", 2.1, 0.16, 0.085, M["pylon"], 0.25, 0.25)]
    for y in (-0.45, 0.45):
        parts.append(box("aku_hook", (-0.03, y - 0.05, -0.1), (0.03, y + 0.05, -0.075), M["rail"], 0.004))
    parts.append(box("aku_ram", (-0.012, -0.05, -0.1), (0.012, 0.05, -0.075), M["black"], 0.0))
    return join("PYL_AKU470", parts)


# ------------------------------------------------------------------ stations
def underside(x, y):
    """Height of the airframe's lower surface at (x, y): a ray up from below."""
    hit, loc, nrm, idx, ob, mtx = scene.ray_cast(dg, Vector((x, y, -6.0)), Vector((0, 0, 1)))
    return loc.z if hit else None

# id, name, x (+ = left), y, pylon kind, allowed stores
LEFT = [
    (1, "L WINGTIP", 7.42, 4.0, "tip", ["R-73"]),
    (2, "L OUTER WING", 5.55, 3.55, "p72", ["R-73"]),
    (3, "L INNER WING", 3.95, 2.25, "apu", ["R-27ER", "R-27R", "R-27ET", "R-27T", "R-77"]),
    (4, "L INTAKE", 1.25, -1.9, "aku", ["R-27ET", "R-27T", "R-27ER", "R-27R", "R-77"]),
]
CENTRE = [
    (5, "CENTRE FWD", 0.0, -2.45, "aku", ["R-27ER", "R-27R", "R-77"]),
    (6, "CENTRE AFT", 0.0, 2.65, "aku", ["R-27ER", "R-27R", "R-77"]),
]
STATIONS = []
for s in LEFT:
    STATIONS.append(s)
STATIONS += CENTRE
for s in reversed(LEFT):
    sid = {1: 10, 2: 9, 3: 8, 4: 7}[s[0]]
    STATIONS.append((sid, s[1].replace("L ", "R "), -s[2], s[3], s[4], s[5]))
STATIONS.sort(key=lambda s: s[0])

# pylon depth (top to missile axis) per kind, and missile radius allowance
AXIS_DROP = {"tip": 0.2, "p72": 0.32, "apu": 0.44, "aku": 0.23}
TIP_Z = -0.31

# fit every station to the airframe BEFORE any store geometry exists (the rays must only see the jet)
ZS = {}
for sid, name, x, y, kind, allowed in STATIONS:
    if kind == "tip":
        ZS[sid] = TIP_Z
    else:
        z = underside(x, y)
        if z is None:
            z = underside(x, y + 0.3)
        ZS[sid] = z if z is not None else -0.3
print("STATION_Z", ZS)

lib = {"R-73": r73(), "R-27R": r27("R"), "R-27ER": r27("ER"), "R-27T": r27("T"), "R-27ET": r27("ET"), "R-77": r77()}
pyl = {"tip": pyl_wingtip(), "p72": pyl_r73(), "apu": pyl_wing_r27(), "aku": pyl_ejector()}
STORE_INFO = {
    "R-73": {"kind": "missile", "guidance": "IR", "fox": 2, "mass": 105, "range_km": 30},
    "R-27R": {"kind": "missile", "guidance": "SARH", "fox": 1, "mass": 253, "range_km": 70},
    "R-27ER": {"kind": "missile", "guidance": "SARH", "fox": 1, "mass": 350, "range_km": 110},
    "R-27T": {"kind": "missile", "guidance": "IR", "fox": 2, "mass": 245, "range_km": 60},
    "R-27ET": {"kind": "missile", "guidance": "IR", "fox": 2, "mass": 343, "range_km": 100},
    "R-77": {"kind": "missile", "guidance": "ARH", "fox": 3, "mass": 175, "range_km": 80},
}

out = {"aircraft": "su27", "stations": [], "stores": STORE_INFO}
for sid, name, x, y, kind, allowed in STATIONS:
    z = ZS[sid]
    p = pyl[kind].copy()
    p.name = "STA_%d_PYLON" % sid
    p.location = (x, y, z + 0.01)
    if kind == "tip":
        # the pod sits ON the wingtip line, the rail underneath
        p.location = (x, y, z)
    COL.objects.link(p)
    axis = Vector((x, y + (0.0 if kind != "aku" else 0.0), z - AXIS_DROP[kind]))
    for st in allowed:
        o = lib[st].copy()
        o.name = "STA_%d_%s" % (sid, st)
        o.location = axis
        COL.objects.link(o)
    out["stations"].append({"id": sid, "name": name, "pylon": kind, "allowed": allowed,
                            "axis": [round(axis.x, 4), round(axis.y, 4), round(axis.z, 4)]})

json.dump(out, open(OUT_JSON, "w"), indent=1)

# ------------------------------------------------------------------ preview renders
def preview(path, eye, target, lens=35, only_lib=False):
    cam = bpy.data.objects.get("StoresCam")
    if cam is None:
        cam = bpy.data.objects.new("StoresCam", bpy.data.cameras.new("StoresCam"))
        scene.collection.objects.link(cam)
    cam.location = eye
    cam.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = lens
    cam.data.clip_start = 0.05
    scene.camera = cam
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_shadows = True
    scene.render.resolution_x, scene.render.resolution_y = 1600, 900
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)

if LINEUP:
    # the master models side by side, away from the jet
    for i, (k, o) in enumerate(lib.items()):
        o.location = (20.0 + i * 0.6, 0.0, 0.0)
    for k, o in pyl.items():
        o.location = (20.0 + list(pyl).index(k) * 0.6, 4.0, 0.0)
    preview(LINEUP, (22.0, -3.5, 1.8), (21.6, 0.5, 0.0), 30)
if RENDER:
    preview(RENDER, (9.5, -9.0, -4.0), (0.0, 0.5, -0.6), 28)
    preview(RENDER.replace(".png", "_b.png"), (0.0, -1.0, -9.0), (0.0, 0.0, -0.5), 24)

# ------------------------------------------------------------------ export only the placed stores
bpy.ops.object.select_all(action="DESELECT")
for o in COL.objects:
    o.select_set(True)
bpy.context.view_layer.objects.active = COL.objects[0]
bpy.ops.export_scene.gltf(filepath=OUT_GLB, export_format="GLB", use_selection=True, export_apply=True,
                          export_yup=True, export_materials="EXPORT")
print("STORES_OK", len(COL.objects))
