# FlightOut: Su-27S cockpit builder. Run:  blender -b --python blender/build_cockpit.py -- [--render out.png] [--export]
# Builds the whole interior procedurally in the jet's own frame (Blender: nose -Y, up +Z, pilot's left +X),
# so the result drops straight onto su27.glb. Named parts for the game:
#   GAU_<name>  gauge pivot (local Z = face normal);  NDL_<name>_<n>  needles;  LMP_<id>  lamps;  ANIM_<part>  movers.
import bpy, mathutils, mathutils.noise, mathutils.bvhtree, bmesh, math, json, os, sys, zlib
from mathutils import Vector, Matrix

ROOT = r"<project folder>"
TEX = os.path.join(ROOT, "assets", "aircraft", "su27_cockpit")
CELLS = json.load(open(os.path.join(TEX, "cells.json")))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

bpy.ops.wm.read_factory_settings(use_empty=True)
SCN = bpy.context.scene
COL = bpy.data.collections.new("Su27Cockpit")
SCN.collection.children.link(COL)

EYE = Vector((0.0, -5.10, 1.18))   # design eye: matches the pilot's eyes (data/aircraft/su27.tres cockpit_eye)
FLOOR = 0.14
CONSOLE_TOP = 0.45

# ------------------------------------------------------------------ materials (names drive the game's shaders)
def mat(name, rgb, rough=0.6, metal=0.0, img=None, emit=None, alpha=None):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if img:
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(os.path.join(TEX, img), check_existing=True)
        nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
        nt.links.new(t.outputs["Alpha"], b.inputs["Alpha"])
        m.blend_method = "CLIP" if hasattr(m, "blend_method") else None
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1.0)
        b.inputs["Emission Strength"].default_value = 1.0
    if alpha is not None:
        b.inputs["Alpha"].default_value = alpha
        try:
            m.surface_render_method = "BLENDED"
        except Exception:
            pass
    return m

M = {
    "paint": mat("CP_Paint", (0.20, 0.37, 0.38), 0.55),          # Soviet cockpit turquoise
    "paint_dark": mat("CP_PaintDark", (0.06, 0.065, 0.07), 0.7),  # instrument panel black
    "metal": mat("CP_Metal", (0.42, 0.43, 0.44), 0.35, 0.9),
    "steel_dark": mat("CP_SteelDark", (0.12, 0.12, 0.13), 0.45, 0.8),
    "rubber": mat("CP_Rubber", (0.03, 0.03, 0.03), 0.9),
    "leather": mat("CP_Leather", (0.09, 0.075, 0.06), 0.65),
    "fabric": mat("CP_Fabric", (0.26, 0.27, 0.2), 0.9),
    "yellow": mat("CP_Yellow", (0.85, 0.62, 0.05), 0.5),
    "red": mat("CP_Red", (0.6, 0.06, 0.04), 0.5),
    "gauge": mat("CP_Gauge", (1, 1, 1), 0.55, img="instruments.png"),
    "label": mat("CP_Label", (1, 1, 1), 0.6, img="labels.png"),
    "needle": mat("CP_Needle", (0.92, 0.9, 0.82), 0.5),
    "glass": mat("CP_GaugeGlass", (0.02, 0.02, 0.02), 0.05, alpha=0.12),
    "hudglass": mat("CP_HUDGlass", (0.3, 0.5, 0.35), 0.03, alpha=0.18),
    "apface": mat("CP_APFace", (0.12, 0.12, 0.12), 0.6),
    "screen": mat("CP_Screen", (0.01, 0.025, 0.02), 0.2),
    "mfd": mat("CP_MFD", (0.01, 0.02, 0.015), 0.15),
    "hudshade": mat("CP_HUDShade", (0.08, 0.09, 0.07), 0.05, alpha=0.55),
    "lamp_red": mat("CP_LampRed", (0.35, 0.05, 0.04), 0.3, img="labels.png"),
    "lamp_amber": mat("CP_LampAmber", (0.35, 0.22, 0.03), 0.3, img="labels.png"),
    "lamp_green": mat("CP_LampGreen", (0.05, 0.3, 0.08), 0.3, img="labels.png"),
    "lamp_white": mat("CP_LampWhite", (0.3, 0.3, 0.28), 0.3, img="labels.png"),
}

# ------------------------------------------------------------------ mesh helpers
def link(name, me, material=None, parent=None, matrix=None, smooth=True):
    ob = bpy.data.objects.new(name, me)
    COL.objects.link(ob)
    if material:
        me.materials.append(material)
    if parent:
        ob.parent = parent
    if matrix is not None:
        ob.matrix_world = matrix
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
        try:
            me.set_sharp_from_angle(angle=math.radians(35))
        except Exception:
            pass
    return ob

def bm_to(name, bm, material=None, matrix=None, parent=None, smooth=True):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return link(name, me, material, parent, matrix, smooth)

def bevel(ob, w=0.003, seg=2):
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width = w
    mod.segments = seg
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(40)
    mod.harden_normals = False
    return ob

def frame(origin, right, up):
    """Matrix whose X = right, Y = up, Z = right x up (toward the viewer for panels)."""
    r = right.normalized(); u = up.normalized(); n = r.cross(u).normalized(); u = n.cross(r).normalized()
    m = Matrix((r, u, n)).transposed().to_4x4()
    m.translation = origin
    return m

def box(name, mtx, lo, hi, material, bev=0.003, parent=None):
    """Axis box in a local frame: lo/hi corners (local coords)."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    c = (Vector(lo) + Vector(hi)) * 0.5
    s = Vector(hi) - Vector(lo)
    for v in bm.verts:
        v.co = Vector((c.x + v.co.x * s.x, c.y + v.co.y * s.y, c.z + v.co.z * s.z))
    ob = bm_to(name, bm, material, mtx, parent, smooth=False)
    if bev > 0:
        bevel(ob, bev)
    return ob

def lathe(name, mtx, profile, segs, material, parent=None, smooth=True, angle=2 * math.pi):
    """Spin a (radius, height) profile around local Z."""
    bm = bmesh.new()
    rings = []
    full = abs(angle - 2 * math.pi) < 1e-6
    n = segs if full else segs + 1
    for i in range(n):
        a = angle * i / segs
        ring = [bm.verts.new((r * math.cos(a), r * math.sin(a), h)) for r, h in profile]
        rings.append(ring)
    for i in range(segs):
        a = rings[i]; b = rings[(i + 1) % n] if full else rings[i + 1]
        for k in range(len(profile) - 1):
            try:
                bm.faces.new((a[k], b[k], b[k + 1], a[k + 1]))
            except ValueError:
                pass
    return bm_to(name, bm, material, mtx, parent, smooth)

def cylinder(name, mtx, r, h, segs, material, z0=0.0, parent=None, cap=True):
    prof = [(0.0, z0), (r, z0), (r, z0 + h), (0.0, z0 + h)] if cap else [(r, z0), (r, z0 + h)]
    return lathe(name, mtx, prof, segs, material, parent, smooth=True)

def disc_uv(name, mtx, r, cell, material, segs=64, frac=240.0 / 256.0, parent=None, w=0.0):
    """Flat disc in local XY at z=w, UV-mapped to an atlas cell (pixel rect, 4096 atlas)."""
    x0, y0, cw, ch = cell
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    c = bm.verts.new((0, 0, w))
    ring = [bm.verts.new((r * math.cos(2 * math.pi * i / segs), r * math.sin(2 * math.pi * i / segs), w)) for i in range(segs)]
    def uvof(v):
        s = v.co.x / r; t = v.co.y / r
        px = x0 + cw * 0.5 + s * cw * 0.5 * frac
        py = y0 + ch * 0.5 - t * ch * 0.5 * frac
        return (px / 4096.0, 1.0 - py / 4096.0)
    for i in range(segs):
        f = bm.faces.new((c, ring[i], ring[(i + 1) % segs]))
        for l in f.loops:
            l[uv].uv = uvof(l.vert)
    return bm_to(name, bm, material, mtx, parent, smooth=False)

def quad_uv(name, mtx, w, h, rect, material, atlas=4096, parent=None, z=0.0):
    """Rectangle w x h in local XY (centred), UV to a pixel rect of an atlas."""
    x0, y0, cw, ch = rect
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    vs = [bm.verts.new(p) for p in ((-w / 2, -h / 2, z), (w / 2, -h / 2, z), (w / 2, h / 2, z), (-w / 2, h / 2, z))]
    f = bm.faces.new(vs)
    uvs = [(x0, y0 + ch), (x0 + cw, y0 + ch), (x0 + cw, y0), (x0, y0)]
    for l, (px, py) in zip(f.loops, uvs):
        l[uv].uv = (px / atlas, 1.0 - py / atlas)
    return bm_to(name, bm, material, mtx, parent, smooth=False)

def screw(name, mtx, r=0.0028, parent=None):
    ob = lathe(name, mtx, [(0, 0.0012), (r * 0.8, 0.0011), (r, 0.0005), (r, 0.0)], 10, M["steel_dark"], parent)
    return ob

# ------------------------------------------------------------------ front panel frame (concave)
# The panel is a ruled surface: in plan a flat centre with wings that curve back toward the pilot, every vertical
# line leaning away from him. (u, v, w) = (along the panel to the pilot's right, up the panel, out toward him).
P_YB, P_ZB = -5.80, 0.47            # bottom centre (built here, then the whole interior is moved; see DY)
P_FLAT, P_RAD = 0.2, 0.8          # flat half-width, wing bend radius
P_LEAN = (0.125, 0.415)             # lean back over height
P_HALF = 0.45                       # half length of the panel along u
P_TOPV = 0.52                       # panel height along v at the centre (under the HUD)
P_TOPV_EDGE = 0.42                  # ... and at its ends: the top steps down either side of the HUD
TUNNEL_X, TUNNEL_HW, TUNNEL_TOP = 0.205, 0.125, 0.566  # leg wells under the panel
P_R = Vector((-1.0, 0.0, 0.0))

def _pc(u):
    a = abs(u); s = 1.0 if u >= 0 else -1.0
    if a <= P_FLAT:
        x, y = a, 0.0
    else:
        th = (a - P_FLAT) / P_RAD
        x, y = P_FLAT + P_RAD * math.sin(th), P_RAD * (1.0 - math.cos(th))
    return Vector((-s * x, P_YB + y, P_ZB))

def _pt(u):
    return (_pc(u + 1e-4) - _pc(u - 1e-4)).normalized()

def _pup(u):
    t = _pt(u)
    n = Vector((t.y, -t.x, 0.0)).normalized()
    return (Vector((0.0, 0.0, P_LEAN[1])) - n * P_LEAN[0]).normalized()

def _pnorm(u):
    return _pt(u).cross(_pup(u)).normalized()

def pp(u, v, w=0.0):
    return _pc(u) + _pup(u) * v + _pnorm(u) * w

def at(u, v, w=0.0, spin=0.0):
    m = frame(pp(u, v, w), _pt(u), _pup(u))
    if spin:
        m = m @ Matrix.Rotation(spin, 4, "Z")
    return m

PANEL = at(0.0, 0.0)

def panel_top(u):
    """v of the panel's top edge: flat across the HUD, sloping down toward the sides (the pagoda outline)."""
    a = abs(u)
    if a <= 0.14:
        return P_TOPV
    return P_TOPV - (P_TOPV - P_TOPV_EDGE) * min(1.0, (a - 0.14) / (P_HALF - 0.14))

def panel_bottom(u):
    """v of the panel's lower edge: arched where the leg wells cut in."""
    x = abs(_pc(u).x)
    d = abs(x - TUNNEL_X)
    if d >= TUNNEL_HW:
        return 0.0
    return (TUNNEL_TOP - P_ZB) * math.sqrt(max(0.0, 1.0 - (d / TUNNEL_HW) ** 2)) / _pup(u).z

def panel_shell():
    """The instrument panel as one curved plate with the knee arches cut into its lower edge."""
    NU, NV = 64, 14
    bm = bmesh.new()
    front, back = [], []
    for i in range(NU + 1):
        u = -P_HALF + 2 * P_HALF * i / NU
        vb = panel_bottom(u)
        fr, bk = [], []
        for k in range(NV + 1):
            v = vb + (panel_top(u) - vb) * k / NV
            fr.append(bm.verts.new(pp(u, v, 0.0)))
            bk.append(bm.verts.new(pp(u, v, -0.03)))
        front.append(fr); back.append(bk)
    for i in range(NU):
        for k in range(NV):
            bm.faces.new((front[i][k], front[i + 1][k], front[i + 1][k + 1], front[i][k + 1]))
            bm.faces.new((back[i][k + 1], back[i + 1][k + 1], back[i + 1][k], back[i][k]))
        bm.faces.new((front[i][0], back[i][0], back[i + 1][0], front[i + 1][0]))
        bm.faces.new((front[i + 1][NV], back[i + 1][NV], back[i][NV], front[i][NV]))
    for k in range(NV):
        bm.faces.new((front[0][k + 1], back[0][k + 1], back[0][k], front[0][k]))
        bm.faces.new((front[NU][k], back[NU][k], back[NU][k + 1], front[NU][k + 1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = bm_to("PanelPlate", bm, M["paint"], smooth=False)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def curve_strip(name, pts_in, pts_out, material, smooth=True):
    """Quad strip between two matching point rows."""
    bm = bmesh.new()
    a = [bm.verts.new(p) for p in pts_in]; b = [bm.verts.new(p) for p in pts_out]
    for i in range(len(a) - 1):
        bm.faces.new((a[i], a[i + 1], b[i + 1], b[i]))
    return bm_to(name, bm, material, smooth=smooth)

def loft(name, rings, material, cap=True, smooth=True, close=True):
    """Skin a list of equal-length point rings."""
    bm = bmesh.new()
    vr = [[bm.verts.new(p) for p in r] for r in rings]
    n = len(rings[0])
    for i in range(len(vr) - 1):
        for k in range(n if close else n - 1):
            k2 = (k + 1) % n
            bm.faces.new((vr[i][k], vr[i][k2], vr[i + 1][k2], vr[i + 1][k]))
    if cap and close:
        bm.faces.new(list(reversed(vr[0]))); bm.faces.new(vr[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_to(name, bm, material, smooth=smooth)

# ------------------------------------------------------------------ gauges
NEEDLES = []

def needle_mesh(name, length, width, tail, mtx, parent, style="std"):
    bm = bmesh.new()
    pts = [(0, length), (width * 0.5, length * 0.25), (width * 0.55, 0), (width * 0.9, -tail * 0.6), (0, -tail), (-width * 0.9, -tail * 0.6), (-width * 0.55, 0), (-width * 0.5, length * 0.25)]
    if style == "short":
        pts = [(0, length), (width * 0.7, length * 0.6), (width * 0.7, 0), (width, -tail), (-width, -tail), (-width * 0.7, 0), (-width * 0.7, length * 0.6)]
    top = [bm.verts.new((x, y, 0.0012)) for x, y in pts]
    bot = [bm.verts.new((x, y, 0.0)) for x, y in pts]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    n = len(pts)
    for i in range(n):
        bm.faces.new((bot[i], bot[(i + 1) % n], top[(i + 1) % n], top[i]))
    ob = bm_to(name, bm, M["needle"], None, parent, smooth=False)
    ob.matrix_parent_inverse = Matrix()
    ob.matrix_basis = mtx
    return ob

def flange_plate(name, mtx, s, r, z0, z1, material, n=32):
    """Square mounting flange with a round hole (the face shows through, nothing is coplanar with it)."""
    bm = bmesh.new()
    ot, ob, it, ib = [], [], [], []
    for i in range(n):
        a = 2 * math.pi * i / n
        c, sn = math.cos(a), math.sin(a)
        k = s / max(abs(c), abs(sn))
        ot.append(bm.verts.new((c * k, sn * k, z1))); ob.append(bm.verts.new((c * k, sn * k, z0)))
        it.append(bm.verts.new((c * r, sn * r, z1))); ib.append(bm.verts.new((c * r, sn * r, z0)))
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((it[i], ot[i], ot[j], it[j]))
        bm.faces.new((ib[j], ob[j], ob[i], ib[i]))
        bm.faces.new((ot[i], ob[i], ob[j], ot[j]))
        bm.faces.new((it[j], ib[j], ib[i], it[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_to(name, bm, material, mtx, smooth=False)

def gauge(name, u, v, d, needles=(), cell=None, flange=True, square=False, lift=0.0, face_w=0.0035, base_mtx=None):
    """Round instrument: holed flange with 4 screws, stepped bezel, recessed face, glass, needles (pivot empty GAU_).
    `lift` stands the whole instrument proud of the panel on a housing (deep instruments like the ADI)."""
    r = d * 0.5
    base = base_mtx if base_mtx is not None else at(u, v, 0.0)
    top = base @ Matrix.Translation((0, 0, lift))
    piv = bpy.data.objects.new("GAU_" + name, None)
    piv.empty_display_size = r
    COL.objects.link(piv)
    piv.matrix_world = top
    s = r + 0.011
    if lift > 0:
        for sx, sy, w, h in ((0, 1, s, 0.004), (0, -1, s, 0.004), (1, 0, 0.004, s), (-1, 0, 0.004, s)):
            cx, cy = sx * (s - 0.004), sy * (s - 0.004)
            box(name + "_Housing", base, (cx - w, cy - h, 0.0), (cx + w, cy + h, lift), M["paint_dark"], 0.002)
    if flange:
        flange_plate(name + "_Flange", top, s, r - 0.0005, -0.001, 0.003, M["paint_dark"])
        for sx in (-1, 1):
            for sy in (-1, 1):
                screw(name + "_Screw", top @ Matrix.Translation((sx * (s - 0.006), sy * (s - 0.006), 0.003)))
    lathe(name + "_Bezel", top, [(r - 0.0005, 0.002), (r - 0.0005, 0.0125), (r + 0.002, 0.0145), (r + 0.0075, 0.0135), (r + 0.0085, 0.009), (r + 0.0085, 0.003)], 56, M["steel_dark"])
    lathe(name + "_Well", top, [(r - 0.0005, 0.002), (r - 0.0005, 0.0125)], 56, M["paint_dark"])
    disc_uv(name + "_Face", top, r, CELLS[cell or name], M["gauge"], w=face_w)
    disc_uv(name + "_Glass", top, r, [0, 0, 1, 1], M["glass"], segs=40, w=0.0115)
    for i, (L, wdt, tail, style) in enumerate(needles):
        needle_mesh("NDL_%s_%d" % (name, i), L * r, wdt, tail * r, Matrix.Translation((0, 0, 0.0055 + i * 0.0016)), piv, style)
    if needles:
        cylinder(name + "_Hub", top @ Matrix.Translation((0, 0, 0.0055)), 0.0045, 0.004 + 0.0016 * len(needles), 16, M["rubber"])
    return piv

# ------------------------------------------------------------------ cockpit tub
def bevel_smooth(ob, w=0.006, seg=3):
    """Rounded edges with flat faces kept flat (weighted normals): reads as one moulded part."""
    mod = ob.modifiers.new("Bevel", "BEVEL")
    mod.width = w; mod.segments = seg
    mod.limit_method = "ANGLE"; mod.angle_limit = math.radians(30)
    mod.harden_normals = True
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

TUB_Y0, TUB_Y1 = -6.32, -4.55      # cockpit tub, in final (moved) coordinates: under the panel to behind the seat

def tub():
    """Floor, side consoles with the heavy canopy sill beams, rear bulkhead. Built in final coordinates
    (the canopy opening is fixed by the airframe; everything else is moved forward to fit it, see DY)."""
    W = Matrix()
    box("Floor", W, (-0.36, TUB_Y0, FLOOR - 0.02), (0.36, TUB_Y1, FLOOR), M["floormat"], 0.004)
    for s in (-1, 1):
        prof = [(0.36, FLOOR), (0.36, CONSOLE_TOP - 0.012), (0.372, CONSOLE_TOP), (0.535, CONSOLE_TOP + 0.012),
                (0.548, CONSOLE_TOP + 0.03), (0.55, 0.535), (0.556, 0.572), (0.572, 0.591), (0.596, 0.597),
                (0.614, 0.586), (0.621, 0.56), (0.621, FLOOR)]
        rings = [[Vector((s * x, y, z)) for x, z in prof] for y in (TUB_Y0, -4.05)]
        bevel_smooth(loft("ConsoleBody", rings, M["paint"], smooth=False), 0.006, 3)
        # rivet rows along the top of the sill beam
        bm = bmesh.new()
        for row_x, row_z in ((0.585, 0.596), (0.61, 0.589)):
            y = -6.3
            while y < -4.1:
                c = Vector((s * row_x, y, row_z + 0.0005))
                ring = [bm.verts.new(c + Vector((0.0022 * math.cos(2 * math.pi * k / 6), 0.0022 * math.sin(2 * math.pi * k / 6), 0))) for k in range(6)]
                top = bm.verts.new(c + Vector((0, 0, 0.0012)))
                for k in range(6):
                    bm.faces.new((ring[k], ring[(k + 1) % 6], top))
                y += 0.05
        bm_to("SillRivets", bm, M["metal"], smooth=True)
        # inner wall cover strip where the console meets the floor (kick plate)
        # padded elbow roll along the inside of the sill (grained vinyl over foam, soft rounded edges)
        pad = box("SillPad", W, (min(s * 0.532, s * 0.556), -6.05, CONSOLE_TOP + 0.034), (max(s * 0.532, s * 0.556), -4.85, CONSOLE_TOP + 0.082), M["pad"], 0.0)
        bevel(pad, 0.011, 5)
        box("KickPlate", W, (min(s * 0.358, s * 0.362), TUB_Y0 + 0.1, FLOOR), (max(s * 0.358, s * 0.362), TUB_Y1, FLOOR + 0.07), M["steel_dark"], 0.002)
    # rear bulkhead behind the seat and the deck over the avionics bay up to the canopy's end
    box("RearBulkhead", W, (-0.56, TUB_Y1 - 0.03, FLOOR), (0.56, TUB_Y1, 0.98), M["paint"], 0.006)
    bm = bmesh.new()
    q = [(-0.56, TUB_Y1, 0.98), (0.56, TUB_Y1, 0.98), (0.56, -4.05, 0.86), (-0.56, -4.05, 0.86)]
    bm.faces.new([bm.verts.new(p) for p in q])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm_to("RearDeck", bm, M["paint_dark"], smooth=False)

# ------------------------------------------------------------------ front panel, glareshield, HUD
def uv_quad(name, mtx, w, h, z, material):
    """A flat rectangle in local XY at height z with UVs 0..1 across it (texture top = local +Y)."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    vs = [bm.verts.new((x, y, z)) for x, y in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2))]
    f = bm.faces.new(vs)
    for l in f.loops:
        l[uv].uv = (l.vert.co.x / w + 0.5, l.vert.co.y / h + 0.5)
    return bm_to(name, bm, material, mtx, None, smooth=False)

# MFD bezel button layout, shared with scripts/avionics/mfd.gd: side buttons (round) at local x = +-(w/2 + 0.0145),
# y = -h/2 + 0.012 + (h - 0.024) * k / (cols - 1) (k from the bottom); top / bottom keys at
# x = -w/2 + 0.02 + (w - 0.04) * k / (rows - 1), y = +-(h/2 + 0.0145). Each is its own pressable object
# OSB_<mfd>_<L|R|T|B><index> (L/R index from the top, T/B from the left), origin at the button's base.
def mfd(name, u, v, w, h, cols=6, rows=5):
    """Multifunction display: deep bezel with pressable buttons on all four sides set in wells, and a recessed
    live screen (SCR_<name>, UV-mapped for the game's display texture)."""
    m = at(u, v, 0.0)
    bw, bh = w + 0.05, h + 0.05
    # bezel: a deep frame around the opening (the screen sits a centimetre down inside it)
    ow, oh = w / 2 + 0.004, h / 2 + 0.004
    for lo, hi in (((-bw / 2, oh), (bw / 2, bh / 2)), ((-bw / 2, -bh / 2), (bw / 2, -oh)),
                   ((-bw / 2, -oh), (-ow, oh)), ((ow, -oh), (bw / 2, oh))):
        box(name + "_Bezel", m, (lo[0], lo[1], -0.002), (hi[0], hi[1], 0.016), M["paint_dark"], 0.003)
    # rubber walls of the well and the back plate under the screen
    t = 0.0025
    for lo, hi in (((-ow, oh - t), (ow, oh)), ((-ow, -oh), (ow, -oh + t)), ((-ow, -oh), (-ow + t, oh)), ((ow - t, -oh), (ow, oh))):
        box(name + "_Recess", m, (lo[0], lo[1], 0.004), (hi[0], hi[1], 0.0165), M["rubber"], 0.0)
    box(name + "_Back", m, (-ow, -oh, -0.002), (ow, oh, 0.006), M["screen"], 0.0)
    uv_quad("SCR_" + name, m, w, h, 0.0065, M["mfd"])
    for k in range(cols):
        y = -h / 2 + 0.012 + (h - 0.024) * k / (cols - 1)
        for sx, side in ((-1, "L"), (1, "R")):
            bm_ = m @ Matrix.Translation((sx * (w / 2 + 0.0145), y, 0.016))
            lathe(name + "_BtnWell", bm_, [(0.0072, 0.0), (0.0084, 0.0), (0.0084, 0.0012), (0.0072, 0.0012)], 18, M["steel_dark"], smooth=False)
            cylinder("OSB_%s_%s%d" % (name, side, cols - 1 - k), bm_ @ Matrix.Translation((0, 0, -0.003)), 0.0062, 0.0075, 16, M["rubber"])
    for k in range(rows):
        x = -w / 2 + 0.02 + (w - 0.04) * k / max(rows - 1, 1)
        for sy, side in ((1, "T"), (-1, "B")):
            km = m @ Matrix.Translation((x, sy * (h / 2 + 0.0145), 0.016))
            box(name + "_KeyWell", km, (-0.0095, -0.0065, -0.001), (0.0095, 0.0065, 0.0008), M["steel_dark"], 0.001)
            box("OSB_%s_%s%d" % (name, side, k), km @ Matrix.Translation((0, 0, -0.003)), (-0.008, -0.005, 0.0), (0.008, 0.005, 0.0075), M["rubber"], 0.0015)
    for sx in (-1, 1):
        for sy in (-1, 1):
            screw(name + "_Screw", m @ Matrix.Translation((sx * (bw / 2 - 0.007), sy * (bh / 2 - 0.007), 0.012)))

def front_panel():
    """Layout after the reference (glass-cockpit Su-27): three MFDs across the middle, a row of standby round
    gauges under them, two knee wells with a pedestal between, the HUD on a stepped housing above, angled
    switch and lamp corners either side of it."""
    panel_shell()
    NU = 64
    for u in (-0.455 + 0.012, 0.455 - 0.012):
        for k in range(6):
            screw("PanelScrew", at(u, 0.03 + k * 0.065, 0.0))
    # rolled lower lip following the arches
    ring_prof = [(0.0, -0.03), (0.0, 0.004), (-0.006, 0.01), (-0.016, 0.01), (-0.022, 0.0), (-0.022, -0.03)]
    rings = []
    for i in range(NU + 1):
        u = -P_HALF + 2 * P_HALF * i / NU
        vb = panel_bottom(u)
        rings.append([pp(u, vb + dv, dw) for dv, dw in ring_prof])
    loft("PanelLowerLip", rings, M["paint"], cap=True, close=True)
    # glareshield: black roll along the stepped top edge
    # (dv up the panel, dw out toward the pilot): the hood overhangs the panel top by ~8 cm, a soft underside
    # rising to a round bullnose, then a top that sweeps back into the coaming deck
    hood = [(0.05, -0.035), (0.054, 0.0), (0.052, 0.035)]
    for k in range(9):
        a = math.pi / 2 - math.pi * k / 8              # +90 (top) .. -90 (bottom) round the nose
        hood.append((0.031 + 0.022 * math.sin(a), 0.064 + 0.022 * math.cos(a)))
    hood += [(0.006, 0.045), (0.0, 0.02), (-0.004, -0.004), (-0.004, -0.035)]
    for sgn in (-1, 1):
        rings = []
        for i in range(NU // 2 + 1):
            u = sgn * (0.092 + (P_HALF + 0.01 - 0.092) * i / (NU // 2))
            rings.append([pp(u, panel_top(u) + dv, dw) for dv, dw in hood])
        loft("GlareshieldPad", rings, M["glare"], cap=True, close=True)
    # cheeks closing the panel ends against the cockpit sides
    for sgn in (-1, 1):
        u = sgn * P_HALF
        e0, e1 = pp(u, 0.0, -0.03), pp(u, panel_top(u) + 0.03, -0.03)
        xo = 0.565 * (1 if e0.x > 0 else -1)
        bm = bmesh.new()
        q = [e0 + Vector((0, 0, -0.12)), e1, Vector((xo, e1.y - 0.06, e1.z - 0.02)), Vector((xo, e0.y - 0.02, e0.z - 0.12))]
        a = [bm.verts.new(p) for p in q]
        b = [bm.verts.new(p + Vector((0, -0.02, 0))) for p in q]
        bm.faces.new(a); bm.faces.new(list(reversed(b)))
        for k in range(4):
            k2 = (k + 1) % 4
            bm.faces.new((a[k2], a[k], b[k], b[k2]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bevel(bm_to("PanelCheek", bm, M["paint"], smooth=False), 0.006)
    lower_front()
    glare_blocks()
    # ---- three MFDs
    mfd("MFD_L", -0.205, 0.28, 0.2, 0.15)
    mfd("MFD_C", 0.0, 0.28, 0.1, 0.15, cols=6, rows=3)
    mfd("MFD_R", 0.205, 0.28, 0.2, 0.15)
    # ---- standby gauges under the MFDs (the stick stands in front of the middle)
    G = 0.128      # clear of the MFD bezels: a gap and a step between the screens and the round gauges
    gauge("AOA_G", -0.30, G, 0.052, [(0.9, 0.0045, 0.25, "std"), (0.9, 0.0045, 0.25, "std")])
    gauge("IAS", -0.235, G, 0.052, [(0.92, 0.0045, 0.25, "std"), (0.55, 0.004, 0.15, "short")])
    gauge("BARO", -0.17, G, 0.052, [(0.92, 0.004, 0.25, "std"), (0.6, 0.006, 0.15, "short")])
    adi_c = at(-0.085, G, 0.0)
    ADI_LIFT = 0.012
    piv = gauge("ADI", -0.085, G, 0.064, [], cell="ADI_BEZEL", lift=ADI_LIFT, face_w=0.0042)
    squash = bpy.data.objects.new("ADI_Squash", None); COL.objects.link(squash)
    squash.parent = piv; squash.matrix_parent_inverse = Matrix()
    squash.matrix_basis = Matrix.Translation((0, 0, -ADI_LIFT)) @ Matrix.Diagonal((1.0, 1.0, 0.45, 1.0))
    ball = bpy.data.meshes.new("ADI_Ball")
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=24, radius=0.028)
    uvl = bm.loops.layers.uv.new("UVMap")
    x0, y0, cw, ch = CELLS["ADI_BALL"]
    for f in bm.faces:
        for l in f.loops:
            co = l.vert.co.normalized()
            lon = math.atan2(co.x, co.z)
            lat = math.asin(max(-1, min(1, co.y)))
            l[uvl].uv = ((x0 + (0.5 + lon / (2 * math.pi)) * cw) / 4096.0, 1.0 - (y0 + (0.5 - lat / math.pi) * ch) / 4096.0)
    bm.to_mesh(ball); bm.free()
    bo = link("ANIM_ADI_Ball", ball, M["gauge"], squash)
    bo.matrix_parent_inverse = Matrix(); bo.matrix_basis = Matrix()
    adi_c = adi_c @ Matrix.Translation((0, 0, ADI_LIFT - 0.003))
    box("ADI_Symbol", adi_c @ Matrix.Translation((0, 0, 0.009)), (-0.019, -0.001, 0), (0.019, 0.001, 0.0015), mat("CP_Orange", (0.95, 0.45, 0.05), 0.5), 0)
    box("ADI_SymbolDot", adi_c @ Matrix.Translation((0, 0, 0.009)), (-0.002, -0.002, 0), (0.002, 0.002, 0.0018), M["yellow"], 0)
    gauge("RADALT", 0.06, G, 0.052, [(0.9, 0.0045, 0.25, "std")])
    gauge("VVI", 0.125, G, 0.052, [(0.9, 0.0045, 0.2, "std")])
    gauge("RPM", 0.19, G, 0.052, [(0.9, 0.0045, 0.25, "std"), (0.75, 0.0045, 0.2, "std")])
    gauge("EGT", 0.255, G, 0.052, [(0.9, 0.0045, 0.25, "std"), (0.75, 0.0045, 0.2, "std")])
    # ---- left edge column: oxygen, flaps, gear indicator and the gear lever
    gauge("OXY", -0.395, 0.315, 0.042, [(0.85, 0.004, 0.2, "std")])
    gauge("FLAPS", -0.395, 0.245, 0.042, [(0.85, 0.004, 0.25, "std")])
    mech = at(-0.395, 0.165, 0.0)
    box("MECH_Body", mech, (-0.032, -0.032, -0.004), (0.032, 0.032, 0.008), M["steel_dark"], 0.003)
    quad_uv("MECH_Face", mech, 0.058, 0.058, CELLS["MECH"], M["gauge"], z=0.0082)
    for nm, (x, y) in (("GEAR_N", (0, 0.0128)), ("GEAR_L", (-0.0092, -0.0046)), ("GEAR_R", (0.0092, -0.0046)), ("GEAR_UNSAFE", (0, -0.0035))):
        cylinder("LMP_" + nm, mech @ Matrix.Translation((x, y, 0.0082)), 0.003, 0.0015, 16, M["lamp_green"] if nm != "GEAR_UNSAFE" else M["lamp_red"])
    # landing gear lever: a slotted housing standing off the panel, the lever pivoting inside it
    gear = at(-0.395, 0.065, 0.0)
    D = 0.032
    box("GearHousingBack", gear, (-0.026, -0.058, 0.0), (0.026, 0.058, 0.004), M["rubber"], 0.001)
    for x0, x1 in ((-0.026, -0.018), (0.018, 0.026)):
        box("GearHousingSide", gear, (x0, -0.058, 0.0), (x1, 0.058, D), M["paint_dark"], 0.002)
    for sy in (-1, 1):
        box("GearHousingEnd", gear, (-0.026, (0.05 if sy > 0 else -0.058), 0.0), (0.026, (0.058 if sy > 0 else -0.05), D), M["paint_dark"], 0.002)
    for sy, t in ((1, "UP"), (-1, "DN")):
        label(t, gear @ Matrix.Translation((-0.042, sy * 0.04, 0.0)), 0.0055)
    # pivot pin across the slot, near the bottom of the housing
    piv_m = gear @ Matrix.Translation((0, 0, 0.008))
    cylinder("GearPivotPin", piv_m @ Matrix.Rotation(math.radians(90), 4, "Y") @ Matrix.Translation((0, 0, -0.019)), 0.004, 0.038, 12, M["metal"])
    lever = bpy.data.objects.new("ANIM_GearLever", None); COL.objects.link(lever)
    lever.matrix_world = piv_m
    sh = cylinder("GearLeverShaft", Matrix(), 0.0042, 0.075, 12, M["metal"], parent=lever); sh.matrix_parent_inverse = Matrix(); sh.matrix_basis = Matrix()
    # wheel-shaped handle, as on Soviet fighters (the gear handle is a small wheel)
    kn = lathe("GearLeverWheel", Matrix(), [(0.0, 0.0), (0.016, 0.0), (0.018, 0.004), (0.018, 0.01), (0.016, 0.014), (0.0, 0.014)], 24, M["red"], parent=lever)
    kn.matrix_parent_inverse = Matrix(); kn.matrix_basis = Matrix.Translation((0, 0, 0.072)) @ Matrix.Rotation(math.radians(90), 4, "Y") @ Matrix.Translation((0, 0, -0.007))
    # ---- right edge column: fuel tape in its octagonal case, hydraulics, brakes
    fuel_m = at(0.395, 0.27, 0.0)
    oct_pts = [(0.03, 0.06), (0.012, 0.085), (-0.012, 0.085), (-0.03, 0.06), (-0.03, -0.06), (-0.012, -0.085), (0.012, -0.085), (0.03, -0.06)]
    rings = [[fuel_m @ Vector((x * sc, y * sc, z)) for x, y in oct_pts] for sc, z in ((1.0, -0.002), (1.0, 0.01), (0.94, 0.012))]
    bevel_smooth(loft("FUEL_Housing", rings, M["steel_dark"], smooth=False), 0.002, 2)
    quad_uv("FUEL_Face", fuel_m, 0.05, 0.13, [CELLS["FUEL"][0] + 6, CELLS["FUEL"][1] + 6, 500, 500], M["gauge"], z=0.0125)
    fp = bpy.data.objects.new("GAU_FUEL", None); COL.objects.link(fp); fp.matrix_world = fuel_m @ Matrix.Translation((0, 0, 0.003))
    for i, x in enumerate((-0.009, 0.009)):
        bm = bmesh.new()
        vs = [bm.verts.new(p) for p in ((x - 0.0038, 0, 0.0095), (x - 0.0095, -0.003, 0.0095), (x - 0.0095, 0.003, 0.0095))]
        bm.faces.new(vs)
        o = bm_to("NDL_FUEL_%d" % i, bm, mat("CP_Orange", (0.95, 0.45, 0.05)), None, fp, smooth=False)
        o.matrix_parent_inverse = Matrix()
    gauge("HYD", 0.395, 0.135, 0.042, [(0.85, 0.004, 0.2, "std"), (0.85, 0.004, 0.2, "std")])
    gauge("BRAKE", 0.395, 0.06, 0.042, [(0.85, 0.004, 0.2, "std"), (0.85, 0.004, 0.2, "std")])
    # ---- upper left corner: clock, cabin pressure, weapon status lamps
    gauge("CLOCK", -0.33, 0.405, 0.05, [(0.6, 0.004, 0.1, "short"), (0.85, 0.0035, 0.15, "std"), (0.9, 0.002, 0.2, "std")])
    gauge("CABIN", -0.26, 0.4, 0.044, [(0.85, 0.004, 0.2, "std"), (0.85, 0.004, 0.2, "std")])
    for i, lab in enumerate(("R-27R", "R-27T", "R-27ER", "R-27ET", "R-73", "GUN", "READY", "LAUNCH")):
        lamp("WPN_%d" % i, -0.205 + (i % 4) * 0.026, 0.39 + (i // 4) * 0.02, 0.024, 0.016, lab, "lamp_green" if lab != "LAUNCH" else "lamp_red")
    # ---- upper right corner: the stepped block of warning lamps
    warn = ("FIRE L", "FIRE R", "LOW FUEL", "GEN FAIL", "HYD 1", "HYD 2", "OIL PRESS", "SDU", "ACS FAIL", "STALL", "CANOPY", "O2 LOW")
    slots = [(r, c) for r, n in enumerate((5, 4, 3)) for c in range(n)]
    for i, lab in enumerate(warn):
        r, c = slots[i]
        lamp("WARN_%d" % i, 0.175 + c * 0.034, 0.388 + r * 0.021, 0.031, 0.017, lab, "lamp_red" if i < 3 or lab == "STALL" else "lamp_amber")

def glare_blocks():
    """Framed sensor heads either side of the HUD base (white-edged windows), as in the reference."""
    for sx in (-1, 1):
        m = at(sx * 0.135, panel_top(0) - 0.03, -0.01)
        box("HUD_SideBox", m, (-0.032, -0.04, -0.06), (0.032, 0.04, 0.012), M["paint_dark"], 0.006)
        box("HUD_SideFrame", m, (-0.026, -0.032, 0.012), (0.026, 0.032, 0.016), M["needle"], 0.002)
        box("HUD_SideWindow", m, (-0.02, -0.026, 0.012), (0.02, 0.026, 0.0175), M["screen"], 0.002)
    # canopy-jettison style red handle at the panel's upper left, as on the real jet
    box("RedHandle", at(-0.4, 0.39, 0.004) @ Matrix.Rotation(math.radians(35), 4, "Z"), (-0.022, -0.005, 0.0), (0.022, 0.005, 0.012), M["red"], 0.003)

def lower_front():
    """Under the panel: the central pedestal between the knees, the outer walls, and two arched leg tunnels
    running forward to the rudder pedals (the dark openings either side of the stick)."""
    T0 = TUNNEL_X - TUNNEL_HW; T1 = TUNNEL_X + TUNNEL_HW
    yfront = -6.78
    for sgn in (-1, 1):
        # tunnel: side walls and arched roof, from the panel plane forward
        prof = []
        for k in range(13):
            a = math.pi * k / 12
            prof.append((sgn * (TUNNEL_X + TUNNEL_HW * math.cos(a)), (TUNNEL_TOP - TUNNEL_HW) + TUNNEL_HW * math.sin(a)))
        prof = [(sgn * T1, FLOOR)] + prof + [(sgn * T0, FLOOR)]
        y0 = P_YB + 0.004
        rings = [[Vector((x, y, z)) for x, z in prof] for y in (y0, yfront)]
        loft("LegTunnel", rings, M["paint"], cap=False, close=False)
        # end wall at the front of the tunnel
        bm = bmesh.new()
        vs = [bm.verts.new(Vector((x, yfront, z))) for x, z in prof]
        bm.faces.new(vs)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm_to("LegTunnelEnd", bm, M["paint_dark"], smooth=False)
        # ribbed rubber foot ramp in the tunnel floor
        ramp = Matrix.Translation((sgn * TUNNEL_X, -6.45, FLOOR + 0.03)) @ Matrix.Rotation(math.radians(-24), 4, "X")
        box("FootRampPlate", ramp, (-TUNNEL_HW + 0.006, -0.22, -0.01), (TUNNEL_HW - 0.006, 0.2, 0.0), M["steel_dark"], 0.003)
        for r in range(11):
            box("FootRampRib", ramp @ Matrix.Translation((0, -0.2 + r * 0.04, 0.0)), (-TUNNEL_HW + 0.012, -0.006, 0.0), (TUNNEL_HW - 0.012, 0.006, 0.008), M["rubber"], 0.002)
    # walls under the panel bottom: pedestal centre and outer parts
    def wall(name, x0, x1, n=6):
        rows = []
        for k in range(n + 1):
            x = x0 + (x1 - x0) * k / n
            u = -x      # in the flat middle u = -x; outside it, close enough for the outer walls (they are hidden by consoles)
            yb = _pc(u).y if abs(u) <= P_HALF else _pc(math.copysign(P_HALF, u)).y
            rows.append((Vector((x, yb + 0.002, FLOOR)), Vector((x, yb + 0.002, P_ZB + 0.002))))
        curve_strip(name, [a for a, b in rows], [b for a, b in rows], M["paint"])
    wall("PedestalWall", -T0, T0)
    for sgn in (-1, 1):
        wall("LowerWall", sgn * T1, sgn * 0.47)
    # the pedestal itself: a block standing proud between the knees with a small lamp panel and two switches
    ped = frame(Vector((0, P_YB + 0.06, FLOOR)), P_R, Vector((0, 0.18, 1)))
    box("Pedestal", ped, (-T0 + 0.004, -0.0, -0.06), (T0 - 0.004, 0.40, 0.0), M["paint"], 0.008)
    # HSI on the pedestal face, trim lamps above it, two switches below
    hm = ped @ Matrix.Translation((0, 0.24, 0.0))
    piv = gauge("HSI", 0, 0, 0.062, [], cell="HSI_FACE", face_w=0.0062, base_mtx=hm)
    card = disc_uv("ANIM_HSI_Card", Matrix(), 0.029, CELLS["HSI_CARD"], M["gauge"], w=0.0045, frac=236.0 / 256.0, parent=piv)
    card.matrix_parent_inverse = Matrix(); card.matrix_basis = Matrix()
    needle_mesh("NDL_HSI_0", 0.026, 0.004, 0.026, Matrix.Translation((0, 0, 0.0072)), piv, "std")
    cylinder("HSI_Hub", hm @ Matrix.Translation((0, 0, 0.0072)), 0.003, 0.003, 16, M["rubber"])
    for i, lab in enumerate(("TRIM P", "TRIM R", "TRIM Y")):
        tm = ped @ Matrix.Translation((-0.044 + i * 0.044, 0.31, 0.0))
        box("TRIM_%d_Housing" % i, tm, (-0.02, -0.01, -0.002), (0.02, 0.01, 0.004), M["steel_dark"], 0.001)
        quad_uv("LMP_TRIM_%d" % i, tm, 0.036, 0.016, CELLS["_labels"][lab], M["lamp_green"], atlas=2048, z=0.0042)
    for kx in (-0.03, 0.03):
        toggle(ped @ Matrix.Translation((kx, 0.16, 0.0)))

def lamp(name, u, v, w, h, legend, color):
    m = at(u, v, 0.0)
    box(name + "_Housing", m, (-w / 2 - 0.002, -h / 2 - 0.002, -0.002), (w / 2 + 0.002, h / 2 + 0.002, 0.004), M["steel_dark"], 0.0012)
    quad_uv("LMP_" + name, m, w, h, CELLS["_labels"][legend], M[color], atlas=2048, z=0.0042)

def rwr_lamps(m):
    import math as _m
    for i, a in enumerate(range(0, 360, 30)):
        x = _m.sin(_m.radians(a)) * 0.0337
        y = -_m.cos(_m.radians(a)) * -0.0337 - 0.0045
        cylinder("LMP_RWR_%02d" % i, m @ Matrix.Translation((x * -1 if False else x, y, 0.0102)), 0.0028, 0.0012, 12, M["lamp_red"] if a in (0, 330, 30) else M["lamp_amber"])

def coaming():
    """Anti-glare deck from the glareshield forward under the windscreen (the HUD stands on it)."""
    NU = 40
    back, front = [], []
    for i in range(NU + 1):
        u = -P_HALF + 2 * P_HALF * i / NU
        b = pp(u, panel_top(u) + 0.045, -0.04)
        back.append(b)
        f = Vector((b.x * 0.86, -6.78, 0.70 + 0.04 * (1 - (b.x / 0.47) ** 2)))
        front.append(f)
    curve_strip("CoamingDeck", back, front, M["paint_dark"])
    # side walls of the deck down to the consoles
    for sgn in (0, NU):
        b, f = back[sgn], front[sgn]
        lo_b = Vector((b.x, b.y, CONSOLE_TOP)); lo_f = Vector((f.x, f.y, CONSOLE_TOP))
        bm = bmesh.new()
        vs = [bm.verts.new(p) for p in (b, f, lo_f, lo_b)]
        bm.faces.new(vs)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm_to("CoamingCheek", bm, M["paint"], smooth=False)

def bar_sweep(name, mtx, path, w, d, material):
    """A rectangular bar (w across the path in its plane, d through it) swept along a 2D path in local XY."""
    bm = bmesh.new()
    rings = []
    for i, (x, y) in enumerate(path):
        a = Vector(path[max(i - 1, 0)]); b = Vector(path[min(i + 1, len(path) - 1)])
        t = (b - a).normalized()
        n = Vector((-t.y, t.x))
        rings.append([bm.verts.new((x + n.x * sw * w / 2, y + n.y * sw * w / 2, sd * d / 2)) for sw, sd in ((1, 1), (-1, 1), (-1, -1), (1, -1))])
    for r0, r1 in zip(rings, rings[1:]):
        for k in range(4):
            bm.faces.new((r0[k], r0[(k + 1) % 4], r1[(k + 1) % 4], r1[k]))
    bm.faces.new(rings[0]); bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_to(name, bm, material, mtx, None, smooth=True)

PANEL_DZ = -0.045      # the dashboard (panel, coaming, HUD housing) sits this much lower: more view over the nose
HUD_LIFT = -PANEL_DZ   # ... while the HUD glass stays where it was in front of the eye
HUD_NECK = 0.008       # the yoke sits right on the housing (no stem)
HUD_PROUD = 0.015      # the glass top sits this much higher than before (the frame stops lower, the glass goes on)
HUD_TRIM = 0.035       # the frame and glass end this much lower than the canopy bow line: windscreen shows above
                       # (the symbology moves down with it: EL_OFS in scripts/avionics/hud_display.gd)

def hud():
    """ILS-31 style HUD: stepped black housing on the coaming, two tall posts with a large combiner, the control
    panel (brightness ARK, TEST, grid SETKA, day/night) facing the pilot, framed sensor heads either side."""
    base = frame(pp(0, panel_top(0) + 0.0, 0.0), P_R, Vector((0, -0.12, 1)))      # local y up, z toward the pilot
    box("HUD_Body", base, (-0.1, -0.06, -0.2), (0.1, 0.06, 0.0), M["paint_dark"], 0.008)
    # a small, low mount on top of the housing carries the yoke
    MOUNT_TOP = 0.072
    box("HUD_Mount", base, (-0.032, 0.058, -0.1), (0.032, MOUNT_TOP, -0.018), M["paint_dark"], 0.004)
    # autopilot mode control panel on the face toward the pilot (see ap_panel())
    # (raised so the whole panel, buttons included, shows above the coaming from the seat)
    ap_panel(base @ Matrix.Translation((0, 0.017, 0.0)))
    # combiner frame, tuning-fork shaped: a single stem rises from the housing to a U-shaped yoke whose two prongs
    # hold the glass at its sides; nothing across the top (a clear gap under the canopy bow). The whole dashboard
    # sits PANEL_DZ lower than it used to, so the stem is HUD_LIFT taller: the glass keeps its place in front of
    # the eye, which is what the collimated symbology is calibrated for (scripts/avionics/hud_display.gd).
    # the yoke sits almost directly on the housing (a very short neck, HUD_NECK); the prongs and the glass reach
    # further down instead, so the glass still covers the same view in front of the eye
    top = base @ Matrix.Translation((0, MOUNT_TOP + HUD_NECK, -0.035))
    OFF = HUD_LIFT - HUD_NECK - HUD_TRIM + (0.1 - MOUNT_TOP)
    GB = 0.022                           # glass bottom and top in the yoke frame: the glass stands proud of the
    GT = 0.198 + OFF + HUD_PROUD         # prong tops by HUD_PROUD + 0.025, as a real combiner plate does
    PT = GT - HUD_PROUD - 0.025          # prong tops
    GC, GH = (GB + GT) / 2, (GT - GB) / 2
    PR, RC = 0.122, 0.034                 # prong distance from the centre, corner radius of the U
    path = [(-PR, PT), (-PR, RC)]
    for k in range(1, 8):
        a = math.pi + (math.pi / 2) * k / 8
        path.append((-PR + RC + RC * math.cos(a), RC + RC * math.sin(a)))
    path += [(-PR + RC, 0.0), (PR - RC, 0.0)]
    for k in range(1, 8):
        a = 1.5 * math.pi + (math.pi / 2) * k / 8
        path.append((PR - RC + RC * math.cos(a), RC + RC * math.sin(a)))
    path += [(PR, RC), (PR, PT)]
    bar_sweep("HUD_Yoke", top @ Matrix.Translation((0, 0, -0.0045)), path, 0.014, 0.016, M["paint_dark"])
    for sx in (-1, 1):
        lathe("HUD_ProngCap", top @ Matrix.Translation((sx * PR, PT, -0.0045)) @ Matrix.Rotation(math.radians(-90), 4, "X"),
              [(0.0, 0.0), (0.0075, 0.0), (0.0075, 0.003), (0.004, 0.007), (0.0, 0.008)], 16, M["paint_dark"])
    # the stem, flared where it meets the housing and where it carries the yoke
    # the glass plate follows the yoke: its edge runs down the middle of the prongs and round the U's curved chin,
    # so the frame grips it all the way round (no gaps), and above the prong tops it stands free to its top edge
    comb = top @ Matrix.Translation((0, GC, -0.0045))
    outline = [(-PR, GT)] + [p for p in path[1:-1]] + [(PR, GT)]
    bm = bmesh.new()
    front = [bm.verts.new((x, y, 0.002)) for x, y in outline]
    back = [bm.verts.new((x, y, -0.002)) for x, y in outline]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(outline)
    for k in range(n):
        k2 = (k + 1) % n
        bm.faces.new((front[k], back[k], back[k2], front[k2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm_to("HUD_Combiner", bm, M["hudglass"], top @ Matrix.Translation((0, 0, -0.0045)), None, smooth=False)
    # polished edges where the glass stands free above the prongs, so it reads as a glass plate
    if "gedge" not in M:
        M["gedge"] = mat("CP_GlassEdge", (0.30, 0.48, 0.42), 0.1, alpha=0.55)
    edge_m = top @ Matrix.Translation((0, 0, -0.0045))
    box("HUD_CombinerEdgeTop", edge_m, (-PR, GT - 0.0018, -0.0022), (PR, GT, 0.0022), M["gedge"], 0.0)
    for sx in (-1, 1):
        box("HUD_CombinerEdgeSide", edge_m, (min(sx * PR, sx * PR - sx * 0.0018), PT, -0.0022), (max(sx * PR, sx * PR - sx * 0.0018), GT, 0.0022), M["gedge"], 0.0)
    box("HUD_ProjectorLens", top, (-0.06, -HUD_NECK, -0.07), (0.06, -HUD_NECK + 0.004, -0.02), M["glass"], 0.0)
    # sun shade: a dark tinted filter hinged on the base bar, on the far side of the combiner. Stowed it lies
    # folded forward over the housing; deployed (the game rotates ANIM_HUDShade about its local X) it stands up
    # behind the combiner and darkens the bright sky so the green symbology stands out.
    # hinged just above the housing, behind the yoke's chin: folded forward it lies flat on the housing
    SH0 = -0.014                         # hinge height in the yoke frame
    hinge = top @ Matrix.Translation((0, SH0, -0.021))
    shade = bpy.data.objects.new("ANIM_HUDShade", None); COL.objects.link(shade)
    shade.matrix_world = hinge
    def sh_child(ob):
        ob.parent = shade; ob.matrix_parent_inverse = Matrix(); return ob
    sh_child(box("HUD_ShadeGlass", Matrix(), (-0.115, 0.004, -0.0015), (0.115, GT - SH0 - 0.002, 0.0015), M["hudshade"], 0.0))
    sh_child(box("HUD_ShadeFrame", Matrix(), (-0.118, -0.002, -0.003), (0.118, 0.006, 0.003), M["paint_dark"], 0.001))
    for sx in (-1, 1):
        sh_child(box("HUD_ShadeRail", Matrix(), (sx * 0.118 - 0.003, 0.0, -0.0025), (sx * 0.118 + 0.003, GT - SH0, 0.0025), M["paint_dark"], 0.001))
    # the shade lever on the right post: down = shade in front of the sky
    lev_m = top @ Matrix.Translation((0.122 + 0.007, 0.07, -0.0045))
    box("HUD_ShadeLeverBoss", lev_m, (-0.002, -0.01, -0.008), (0.006, 0.01, 0.008), M["paint_dark"], 0.002)
    lever = bpy.data.objects.new("ANIM_HUDShadeLever", None); COL.objects.link(lever)
    lever.matrix_world = lev_m @ Matrix.Translation((0.006, 0, 0)) @ Matrix.Rotation(math.radians(90), 4, "Y")
    lv = cylinder("HUD_ShadeLeverArm", Matrix(), 0.0018, 0.022, 10, M["metal"], parent=lever)
    lv.matrix_parent_inverse = Matrix(); lv.matrix_basis = Matrix()
    kn = lathe("HUD_ShadeLeverKnob", Matrix(), [(0.0, 0.0), (0.0042, 0.0), (0.0048, 0.003), (0.0042, 0.008), (0.0, 0.008)], 14, M["yellow"], parent=lever)
    kn.matrix_parent_inverse = Matrix(); kn.matrix_basis = Matrix.Translation((0, 0, 0.02))

# ------------------------------------------------------------------ autopilot panel
# Layout in panel metres (x to the pilot's right, y up, origin at the centre). scripts/avionics/ap_panel.gd draws
# the face texture and picks clicks with the same numbers: keep the two in step.
AP_W, AP_H = 0.19, 0.07
# Per value (SPD, HDG, ALT, V/S) a column, top to bottom: the green ACTIVE display (what the autopilot is flying),
# the amber SELECTED display (what the knob or typing sets), the knob, and the ENTER button that sends the
# selected value up to the active display. AP (engage) and LVL (level flight) sit on the right.
AP_WIN_X = (-0.075, -0.035, 0.005, 0.045)
AP_ACT_Y, AP_SEL_Y, AP_WIN_W, AP_WIN_H = 0.0205, 0.0055, 0.034, 0.012
AP_KNOB_Y, AP_KNOB_R = -0.0115, 0.005
AP_BTNS = (("SPD", -0.075, -0.0265, 0.03, 0.009), ("HDG", -0.035, -0.0265, 0.03, 0.009),
           ("ALT", 0.005, -0.0265, 0.03, 0.009), ("VS", 0.045, -0.0265, 0.03, 0.009),
           ("AP", 0.0775, 0.0125, 0.024, 0.026), ("LVL", 0.0775, -0.0205, 0.024, 0.017))

def ap_uv(x, y):
    return ((x + AP_W / 2) / AP_W, (y + AP_H / 2) / AP_H)

def ap_face_box(name, mtx, cx, cy, w, h, z0, z1, material):
    """A box whose top face shows its own patch of the panel face texture; the sides repeat the patch's edge."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    x0, x1, y0, y1 = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    corners = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
    bot = [bm.verts.new((x, y, z0)) for x, y in corners]
    top = [bm.verts.new((x, y, z1)) for x, y in corners]
    faces = [bm.faces.new(top)]
    for i in range(4):
        j = (i + 1) % 4
        faces.append(bm.faces.new((bot[i], bot[j], top[j], top[i])))
    for f in faces:
        for l in f.loops:
            l[uv].uv = ap_uv(l.vert.co.x, l.vert.co.y)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_to(name, bm, material, mtx, None, smooth=False)

def ap_panel(cpm):
    """Autopilot mode control panel: SPD / HDG / ALT / V/S windows, a knob under each to set the value and an
    enter button under that; AP (engage: holds speed, heading and altitude together) and LVL on the right.
    The face (legends, digits, lit buttons) is a live texture drawn by the game."""
    box("AP_Housing", cpm, (-AP_W / 2 - 0.003, -AP_H / 2 - 0.003, -0.006), (AP_W / 2 + 0.003, AP_H / 2 + 0.003, 0.002), M["steel_dark"], 0.003)
    ap_face_box("AP_Face", cpm, 0.0, 0.0, AP_W, AP_H, 0.001, 0.004, M["apface"])
    # window bezels: thin raised frames
    for x in AP_WIN_X:
        for wy in (AP_ACT_Y, AP_SEL_Y):
            hw, hh, t = AP_WIN_W / 2 + 0.0012, AP_WIN_H / 2 + 0.0012, 0.0012
            for (a, b) in (((-hw, hh - t), (hw, hh)), ((-hw, -hh), (hw, -hh + t)), ((-hw, -hh), (-hw + t, hh)), ((hw - t, -hh), (hw, hh))):
                box("APBezel", cpm @ Matrix.Translation((x, wy, 0.0)), (a[0], a[1], 0.004), (b[0], b[1], 0.0052), M["steel_dark"], 0.0)
    # selector knobs (the game turns them as the values change)
    for x, n in zip(AP_WIN_X, ("SPD", "HDG", "ALT", "VS")):
        knob("AP_KNOB_" + n, cpm @ Matrix.Translation((x, AP_KNOB_Y, 0.004)), AP_KNOB_R, pointer=True, h=0.008)
    # push buttons: raised caps carrying their legend and mode light from the face texture
    for n, x, y, w, h in AP_BTNS:
        box("APBtnWell", cpm @ Matrix.Translation((x, y, 0.0)), (-w / 2 - 0.0015, -h / 2 - 0.0015, 0.004),
            (w / 2 + 0.0015, h / 2 + 0.0015, 0.0047), M["rubber"], 0.0)
        ap_face_box("AP_BTN_" + n, cpm, x, y, w, h, 0.004, 0.0072, M["apface"])

def knob(name, mtx, r, pointer=True, h=0.012):
    lathe(name + "_Skirt", mtx, [(0, 0), (r * 1.25, 0), (r * 1.25, h * 0.25), (r, h * 0.35), (r, h), (r * 0.8, h * 1.05), (0, h * 1.05)], 24, M["rubber"])
    if pointer:
        box(name + "_Pointer", mtx, (-r * 0.12, 0, h * 1.05), (r * 0.12, r * 0.95, h * 1.07), M["needle"], 0)

# ------------------------------------------------------------------ side consoles
CONSOLE_T = math.atan(0.012 / 0.163)

def console_frame(side):
    """side +1 = left console, -1 = right. Local x = pilot's right, y = forward, z = up from the console face."""
    t = CONSOLE_T
    right = Vector((-math.cos(t), 0, -math.sin(t))) if side > 0 else Vector((-math.cos(t), 0, math.sin(t)))
    return frame(Vector((0.455 * side, -5.05, CONSOLE_TOP + 0.0085)), right, Vector((0, -1, 0)))

def cp_at(side, u, v, w=0.0):
    # the console layout was drawn for a longer console: compress it to fit between the panel and the seat back
    return console_frame(side) @ Matrix.Translation((u * 0.95, v * 0.82 - 0.05, w))

def label(text, mtx, h=0.0075):
    if text not in CELLS["_labels"]:
        return
    quad_uv("Label_" + text, mtx @ Matrix.Translation((0, 0, 0.0007)), h * 4.0, h, CELLS["_labels"][text], M["label"], atlas=2048)

def toggle(mtx, guarded=False, lab=None):
    lathe("TogNut", mtx, [(0, 0), (0.0055, 0), (0.0055, 0.003), (0.0045, 0.0035), (0, 0.0035)], 6, M["metal"], smooth=False)
    bat = mtx @ Matrix.Translation((0, 0, 0.003)) @ Matrix.Rotation(math.radians(18), 4, "X")
    lathe("TogBat", bat, [(0, 0), (0.0018, 0), (0.0026, 0.016), (0.0034, 0.018), (0.003, 0.021), (0, 0.022)], 10, M["metal"])
    if guarded:
        g = mtx @ Matrix.Translation((0, -0.002, 0.0))
        box("TogGuard", g, (-0.009, -0.006, 0.0), (0.009, 0.004, 0.028), M["red"], 0.0015)
    if lab:
        label(lab, mtx @ Matrix.Translation((0, -0.017, 0)), 0.0055)

def pushlight(mtx, legend, color, w=0.022, h=0.016):
    box("PushHousing", mtx, (-w / 2 - 0.002, -h / 2 - 0.002, 0), (w / 2 + 0.002, h / 2 + 0.002, 0.006), M["steel_dark"], 0.0012)
    quad_uv("LMP_PL_" + legend.replace(" ", "_"), mtx, w, h, CELLS["_labels"][legend], M[color], atlas=2048, z=0.0062)

SUB_USED = {1: [], -1: []}

def subpanel(side, name, u, v, w, h, title=None, items=()):
    SUB_USED[side].append((v - h / 2, v + h / 2))
    m = cp_at(side, u, v)
    w = w * 0.95
    box(name + "_Plate", m, (-w / 2, -h / 2, -0.004), (w / 2, h / 2, 0.003), M["paint"], 0.002)
    for sx in (-1, 1):
        for sy in (-1, 1):
            lathe("Dzus", m @ Matrix.Translation((sx * (w / 2 - 0.007), sy * (h / 2 - 0.007), 0.003)), [(0, 0.0012), (0.0035, 0.0009), (0.0038, 0)], 12, M["steel_dark"])
    if title:
        label(title, m @ Matrix.Translation((0, h / 2 - 0.012, 0.003)), 0.007)
    for it in items:
        kind = it[0]; im = m @ Matrix.Translation((it[1], it[2], 0.003))
        if kind == "tog":
            toggle(im, False, it[3] if len(it) > 3 else None)
        elif kind == "guard":
            toggle(im, True, it[3] if len(it) > 3 else None)
        elif kind == "knob":
            knob("Knob", im, it[3] if len(it) > 3 else 0.008)
            if len(it) > 4:
                label(it[4], im @ Matrix.Translation((0, -0.02, 0)), 0.0055)
        elif kind == "push":
            pushlight(im, it[3], it[4] if len(it) > 4 else "lamp_green")
        elif kind == "lamp":
            cylinder("LMP_C_%s" % it[3].replace(" ", "_"), im, 0.004, 0.003, 14, M[it[4] if len(it) > 4 else "lamp_amber"])
        elif kind == "cb":
            for k in range(it[3]):
                cylinder("CB", im @ Matrix.Translation((k * 0.011, 0, 0)), 0.0035, 0.008, 10, M["rubber"])
        elif kind == "label":
            label(it[3], im, it[4] if len(it) > 4 else 0.006)
        elif kind == "gauge":
            pass
        elif kind == "keys":
            keys = ("1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "ENT")
            for k, kk in enumerate(keys):
                km = im @ Matrix.Translation(((k % 3) * 0.02, -(k // 3) * 0.018, 0))
                box("Key", km, (-0.008, -0.007, 0), (0.008, 0.007, 0.006), M["steel_dark"], 0.0015)
                label(kk, km @ Matrix.Translation((0, 0, 0.0062)), 0.006)
        elif kind == "screen":
            box("SCR_" + it[3], im, (-it[4] / 2, -it[5] / 2, 0), (it[4] / 2, it[5] / 2, 0.002), M["screen"], 0)

def console_fill():
    """Real consoles are packed edge to edge: fill every gap between the main panels with switch and breaker
    panels (deterministic layouts)."""
    for side in (1, -1):
        used = sorted(SUB_USED[side])
        edges = [(-0.86, -0.86)] + used + [(0.88, 0.88)]
        k = 0
        for (a0, a1), (b0, b1) in zip(edges, edges[1:]):
            g0, g1 = a1 + 0.004, b0 - 0.004
            g = g1 - g0
            if g < 0.035:
                continue
            c = (g0 + g1) / 2
            items = []
            n = 4 if g < 0.06 else 5
            for i in range(n):
                x = -0.07 + 0.14 * i / (n - 1)
                kind = "guard" if (i + k) % 5 == 3 else "tog"
                items.append((kind, x, -0.006 if g >= 0.06 else 0.0))
            if g >= 0.06:
                for i in range(6):
                    items.append(("lamp", -0.075 + i * 0.03, 0.02 if g < 0.1 else 0.03, "FILL%d" % i, ("lamp_green", "lamp_amber", "lamp_white")[(i + k) % 3]))
            if g >= 0.1:
                items.append(("cb", -0.077, -0.035, 15))
            subpanel(side, "Filler", 0.0, c, 0.19, g, None, items)
            k += 1

def consoles():
    L, Rr = 1, -1
    # ---- left console, front to back
    subpanel(L, "EngStart", 0.0, 0.79, 0.19, 0.11, "ENGINE START", [("guard", -0.05, 0.0, "LEFT"), ("guard", 0.05, 0.0, "RIGHT"), ("push", -0.05, -0.03, "START", "lamp_amber"), ("push", 0.05, -0.03, "START", "lamp_amber"), ("tog", 0.0, -0.005, "IGNITION")])
    subpanel(L, "FuelPanel", -0.06, 0.62, 0.075, 0.2, "FUEL", [("tog", 0.0, 0.05, "PUMPS"), ("tog", 0.0, 0.0, "XFEED"), ("guard", 0.0, -0.05, "FUEL DUMP")])
    subpanel(L, "FlapPanel", -0.06, 0.40, 0.075, 0.2, "WING FLAP", [("tog", 0.0, 0.04, "TAKEOFF"), ("tog", 0.0, -0.02, "AUTO"), ("lamp", 0.0, -0.06, "FLAPS", "lamp_green")])
    subpanel(L, "Radio", 0.0, 0.12, 0.19, 0.13, "RADIO", [("knob", -0.06, 0.0, 0.011, "CHAN"), ("knob", 0.0, 0.0, 0.008, "VOL"), ("knob", 0.05, 0.0, 0.008, "SQL"), ("tog", 0.0, -0.04, "ON")])
    subpanel(L, "ACS", 0.0, -0.11, 0.19, 0.11, "ACS", [("push", -0.065, 0.015, "AUTO", "lamp_green"), ("push", -0.022, 0.015, "ALT HOLD", "lamp_green"), ("push", 0.022, 0.015, "ATT HOLD", "lamp_green"), ("push", 0.065, 0.015, "RETURN", "lamp_green"), ("push", -0.022, -0.02, "LANDING", "lamp_green"), ("push", 0.022, -0.02, "RESET", "lamp_amber")])
    subpanel(L, "Lights", 0.0, -0.33, 0.19, 0.13, "LIGHTS", [("knob", -0.06, 0.01, 0.009, "PANEL"), ("knob", 0.0, 0.01, 0.009, "FLOOD"), ("knob", 0.06, 0.01, 0.009, "CONSOLE"), ("tog", -0.04, -0.04, "NAV LTS"), ("tog", 0.0, -0.04, "STROBE"), ("tog", 0.04, -0.04, "TAXI")])
    subpanel(L, "AntiIce", 0.0, -0.53, 0.19, 0.1, "ANTI-ICE", [("tog", -0.05, 0.0, "PITOT HEAT"), ("tog", 0.0, 0.0, "INTAKE"), ("tog", 0.05, 0.0, "DEFOG")])
    subpanel(L, "LCB", 0.0, -0.74, 0.19, 0.14, "ELECTRICAL", [("cb", -0.077, 0.02, 15), ("cb", -0.077, -0.005, 15), ("cb", -0.077, -0.03, 15)])
    # ---- right console, front to back
    subpanel(Rr, "NavKeys", 0.0, 0.76, 0.19, 0.16, "DATA", [("screen", 0.0, 0.045, "NAV", 0.15, 0.025), ("keys", -0.04, 0.012), ("push", 0.06, 0.01, "WPT", "lamp_white"), ("push", 0.06, -0.015, "AIRFLD", "lamp_white"), ("push", 0.06, -0.04, "MARK", "lamp_white")])
    subpanel(Rr, "CMPanel", 0.0, 0.52, 0.19, 0.12, "CM", [("lamp", -0.07, 0.02, "CHAFF", "lamp_green"), ("lamp", -0.055, 0.02, "CHAFF", "lamp_green"), ("lamp", -0.04, 0.02, "CHAFF", "lamp_green"), ("lamp", 0.04, 0.02, "FLARE", "lamp_green"), ("lamp", 0.055, 0.02, "FLARE", "lamp_green"), ("lamp", 0.07, 0.02, "FLARE", "lamp_green"), ("knob", 0.0, 0.0, 0.01, "PROGRAM"), ("guard", -0.05, -0.03, "ARM"), ("tog", 0.05, -0.03, "DISP")])
    subpanel(Rr, "Elec", 0.0, 0.29, 0.19, 0.12, "ELECTRICAL", [("tog", -0.07, 0.0, "BATT"), ("tog", -0.035, 0.0, "GEN"), ("tog", 0.0, 0.0, "AC"), ("tog", 0.035, 0.0, "DC"), ("guard", 0.07, 0.0, "EXT PWR")])
    subpanel(Rr, "IFF", 0.0, 0.07, 0.19, 0.11, "IFF", [("knob", -0.06, 0.0, 0.01, "MODE"), ("knob", 0.0, 0.0, 0.01, "CODE"), ("tog", 0.06, 0.0, "TEST")])
    subpanel(Rr, "Oxygen", 0.0, -0.16, 0.19, 0.15, "OXYGEN", [("tog", -0.06, 0.02, "100%"), ("tog", -0.06, -0.03, "PRESS"), ("lamp", 0.07, 0.04, "O2 LOW", "lamp_red")])
    gauge("OXY2", 0.0, 0.0, 0.05, [(0.85, 0.005, 0.2, "std")], cell="OXY")
    bpy.data.objects["GAU_OXY2"].matrix_world = cp_at(Rr, 0.025, -0.16, 0.003)
    for o in [o for o in bpy.data.objects if o.name.startswith("OXY2_")]:
        o.matrix_world = cp_at(Rr, 0.025, -0.16, 0.003) @ (PANEL @ Matrix.Translation((0, 0, 0))).inverted() @ o.matrix_world
    subpanel(Rr, "EngMode", 0.0, -0.38, 0.19, 0.1, "ENG MODE", [("guard", -0.04, 0.0, "COMBAT"), ("tog", 0.04, 0.0, "TRAINING")])
    subpanel(Rr, "RCB", 0.0, -0.6, 0.19, 0.18, "HYDRAULICS", [("cb", -0.077, 0.04, 15), ("cb", -0.077, 0.015, 15), ("cb", -0.077, -0.01, 15), ("cb", -0.077, -0.035, 15)])
    subpanel(Rr, "Seat", 0.0, -0.8, 0.19, 0.08, "SEAT", [("tog", -0.04, 0.0, "SEAT HEIGHT"), ("tog", 0.04, 0.0, "HARNESS")])

# ------------------------------------------------------------------ throttle quadrant (left console, inboard)
def throttle():
    side = 1
    base = cp_at(side, 0.072, 0.30, 0.003)
    box("ThrQuadrant", base, (-0.03, -0.24, 0.0), (0.03, 0.24, 0.035), M["paint_dark"], 0.006)
    box("ThrSlot", base, (-0.012, -0.215, 0.034), (0.012, 0.215, 0.036), M["rubber"], 0.002)
    for i, (dv, txt) in enumerate(((-0.19, "IDLE"), (0.02, "MIL"), (0.18, "MAX"))):
        box("ThrDetent", base, (-0.03, dv - 0.002, 0.035), (-0.022, dv + 0.002, 0.037), M["needle"], 0)
        label(txt, base @ Matrix.Translation((-0.045, dv, 0.0)) @ Matrix.Rotation(math.radians(90), 4, "Z"), 0.006)
    # the Su-27 throttle (RUD) does not pivot: the levers ride a carriage that slides fore and aft along the
    # quadrant slot. The rest pose is mid-slot; the game slides it along local forward (IDLE -0.19 .. MAX +0.18).
    piv = bpy.data.objects.new("ANIM_Throttle", None); COL.objects.link(piv)
    piv.matrix_world = base @ Matrix.Translation((0, 0.0, 0.035))
    def child(ob, m):
        ob.parent = piv; ob.matrix_parent_inverse = Matrix(); ob.matrix_basis = m
    child(box("ThrCarriage", Matrix(), (-0.02, -0.022, -0.004), (0.02, 0.022, 0.012), M["steel_dark"], 0.004), Matrix())
    for dx in (-0.008, 0.008):
        child(box("ThrLever", Matrix(), (dx - 0.004, -0.006, 0.0), (dx + 0.004, 0.006, 0.105), M["metal"], 0.002), Matrix())
    # grip: chunky handle with buttons, angled toward the pilot's palm
    g = Matrix.Translation((0.004, 0.0, 0.125)) @ Matrix.Rotation(math.radians(-12), 4, "Y")
    child(box("ThrGrip", Matrix(), (-0.028, -0.055, -0.03), (0.032, 0.05, 0.03), M["rubber"], 0.014), g)
    child(box("ThrGripCap", Matrix(), (-0.024, -0.05, 0.028), (0.028, 0.046, 0.038), M["paint_dark"], 0.008), g)
    for i, (x, y) in enumerate(((0.0, 0.03), (0.012, 0.0), (-0.01, -0.02), (0.015, -0.03))):
        child(cylinder("ThrBtn", Matrix(), 0.0045, 0.006, 12, M["red"] if i == 0 else M["steel_dark"]), g @ Matrix.Translation((x, y, 0.038)))
    child(box("ThrAirbrakeSw", Matrix(), (-0.004, -0.008, 0.0), (0.004, 0.008, 0.012), M["metal"], 0.002), g @ Matrix.Translation((0.03, 0.03, 0.01)) @ Matrix.Rotation(math.radians(-90), 4, "Y"))

# ------------------------------------------------------------------ stick, pedals
STICK_BASE = Vector((0.0, -5.53, FLOOR))
STICK_PIVOT = 0.08
STICK_GM = Matrix.Translation((0, 0.0, 0.47)) @ Matrix.Rotation(math.radians(-8), 4, "X")   # grip frame in the stick's space

def stick():
    """Long centre stick (Su-27 RUS-2 style grip): ribbed boot on the floor, steel shaft, sculpted handle with a
    button head leaning slightly aft, trigger in front, wheel-brake lever."""
    base = Matrix.Translation(STICK_BASE)
    boot = [(0.085, 0.0)]
    for k in range(9):
        z = 0.02 + k * 0.02
        r = 0.08 - k * 0.0068
        boot += [(r, z), (r - 0.012, z + 0.01)]
    boot += [(0.016, 0.205), (0.0, 0.205)]
    lathe("StickBoot", base, boot, 28, M["rubber"])
    lathe("StickBootRing", base, [(0.0, 0.0), (0.1, 0.0), (0.1, 0.012), (0.085, 0.016), (0.0, 0.016)], 28, M["steel_dark"])
    piv = bpy.data.objects.new("ANIM_Stick", None); COL.objects.link(piv)
    piv.matrix_world = base @ Matrix.Translation((0, 0, STICK_PIVOT))
    def child(ob, m):
        ob.parent = piv; ob.matrix_parent_inverse = Matrix(); ob.matrix_basis = m
    child(cylinder("StickShaft", Matrix(), 0.012, 0.44, 16, M["paint"]), Matrix())
    child(lathe("StickCollar", Matrix(), [(0.0, 0.0), (0.017, 0.0), (0.019, 0.01), (0.019, 0.03), (0.015, 0.036), (0.0, 0.036)], 20, M["steel_dark"]), Matrix.Translation((0, 0, 0.435)))
    # handle: lofted sections (rx, ry, y-offset) up the grip, swelling into the button head
    secs = [(0.0, 0.019, 0.022, 0.0), (0.015, 0.021, 0.025, 0.0), (0.04, 0.023, 0.028, 0.002), (0.07, 0.022, 0.027, 0.0),
            (0.095, 0.024, 0.029, -0.004), (0.115, 0.029, 0.036, -0.012), (0.135, 0.031, 0.042, -0.016),
            (0.155, 0.029, 0.04, -0.016), (0.168, 0.022, 0.032, -0.014), (0.174, 0.01, 0.016, -0.012)]
    rings = []
    for z, rx, ry, oy in secs:
        rings.append([Vector((rx * math.cos(2 * math.pi * k / 20), oy + ry * math.sin(2 * math.pi * k / 20), z)) for k in range(20)])
    grip = loft("StickGrip", rings, M["paint"], cap=True, smooth=True)
    soften(grip, 1)
    child(grip, STICK_GM)
    # black rubber wrap on the handle
    wr = [[Vector((p.x * 1.04, p.y * 1.04 + (0.0 if True else 0), p.z)) for p in r] for r in rings[1:5]]
    wrap = loft("StickWrap", wr, M["rubber"], cap=False, smooth=True)
    child(wrap, STICK_GM)
    g = STICK_GM
    child(cylinder("WpnRelease", Matrix(), 0.0075, 0.009, 16, M["red"]), g @ Matrix.Translation((0.013, -0.024, 0.166)))
    child(cylinder("TrimHat", Matrix(), 0.0065, 0.009, 12, M["steel_dark"]), g @ Matrix.Translation((-0.012, -0.012, 0.168)))
    child(cylinder("APDisc", Matrix(), 0.0055, 0.008, 12, M["metal"]), g @ Matrix.Translation((-0.004, 0.012, 0.165)))
    child(cylinder("TDCKnob", Matrix(), 0.011, 0.016, 18, M["rubber"]), g @ Matrix.Translation((0.024, -0.03, 0.135)) @ Matrix.Rotation(math.radians(90), 4, "Y"))
    child(lathe("Trigger", Matrix(), [(0, 0), (0.0065, 0.0), (0.006, 0.026), (0, 0.03)], 12, M["metal"]), g @ Matrix.Translation((0, -0.026, 0.09)) @ Matrix.Rotation(math.radians(95), 4, "X"))
    child(box("BrakeLever", Matrix(), (-0.004, -0.004, -0.075), (0.004, 0.004, 0.0), M["metal"], 0.002), g @ Matrix.Translation((0.0, -0.04, 0.11)) @ Matrix.Rotation(math.radians(-12), 4, "X"))

PEDAL_Y, PEDAL_Z = -6.12, 0.40

def pedals():
    bar = Matrix.Translation((0, PEDAL_Y, PEDAL_Z))
    cylinder("PedalBar", bar @ Matrix.Rotation(math.radians(90), 4, "Y") @ Matrix.Translation((0, 0, -0.22)), 0.012, 0.44, 12, M["steel_dark"])
    for s, nm in ((1, "L"), (-1, "R")):
        piv = bpy.data.objects.new("ANIM_Pedal" + nm, None); COL.objects.link(piv)
        piv.matrix_world = Matrix.Translation((0.13 * s, PEDAL_Y, PEDAL_Z))
        arm = cylinder("PedalArm", Matrix(), 0.008, 0.13, 10, M["steel_dark"]); arm.parent = piv; arm.matrix_parent_inverse = Matrix(); arm.matrix_basis = Matrix.Rotation(math.radians(180), 4, "X")
        pad = box("Pedal", Matrix(), (-0.05, -0.012, -0.075), (0.05, 0.012, 0.075), M["steel_dark"], 0.006)
        pad.parent = piv; pad.matrix_parent_inverse = Matrix(); pad.matrix_basis = Matrix.Translation((0, 0.02, -0.14)) @ Matrix.Rotation(math.radians(-20), 4, "X")
        for k in range(5):
            r = box("PedalRib", Matrix(), (-0.045, 0.0, -0.002), (0.045, 0.004, 0.002), M["rubber"], 0)
            r.parent = piv; r.matrix_parent_inverse = Matrix(); r.matrix_basis = Matrix.Translation((0, 0.02, -0.14)) @ Matrix.Rotation(math.radians(-20), 4, "X") @ Matrix.Translation((0, 0.012, -0.06 + k * 0.03))

def frustum(name, mtx, lo0, hi0, lo1, hi1, material, bev=0.003):
    """Box whose bottom rectangle (lo0/hi0 at z0) tapers to a top rectangle (lo1/hi1 at z1)."""
    bm = bmesh.new()
    vs = []
    for lo, hi in ((lo0, hi0), (lo1, hi1)):
        z = lo[2]
        vs += [bm.verts.new((x, y, z)) for x, y in ((lo[0], lo[1]), (hi[0], lo[1]), (hi[0], hi[1]), (lo[0], hi[1]))]
    for f in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        bm.faces.new([vs[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    ob = bm_to(name, bm, material, mtx, smooth=False)
    if bev > 0:
        bevel(ob, bev)
    return ob

# ------------------------------------------------------------------ K-36DM ejection seat
SEAT_RAKE = math.radians(16)

def seat():
    hip = Vector((0.0, -5.26, 0.43))
    back = Matrix.Translation(hip + Vector((0, 0.13, -0.02))) @ Matrix.Rotation(-SEAT_RAKE, 4, "X")   # local z up the back
    # bucket and cushion
    box("SeatBucket", Matrix(), (-0.235, -5.42, 0.22), (0.235, -5.02, 0.36), M["steel_dark"], 0.012)
    for s in (-1, 1):
        box("SeatSide", Matrix(), (min(0.215 * s, 0.245 * s), -5.45, 0.24), (max(0.215 * s, 0.245 * s), -5.0, 0.47), M["paint_dark"], 0.01)
    box("SeatCushion", Matrix(), (-0.2, -5.44, 0.35), (0.2, -5.06, 0.40), M["leather"], 0.025)
    # back cushion, headbox and canopy breakers
    box("SeatBack", back, (-0.2, -0.02, 0.0), (0.2, 0.08, 0.62), M["leather"], 0.025)
    box("SeatBackFrame", back, (-0.24, 0.07, -0.05), (0.24, 0.13, 0.66), M["paint_dark"], 0.012)
    frustum("Headbox", back, (-0.16, 0.06, 0.62), (0.16, 0.22, 0.62), (-0.125, 0.08, 0.95), (0.125, 0.2, 0.95), M["paint_dark"], 0.018)
    # telescopic stabilising booms folded along the headbox, and the drogue gun tube on its back
    for s in (-1, 1):
        cylinder("SeatBoom", back @ Matrix.Translation((s * 0.15, 0.12, 0.3)) @ Matrix.Rotation(math.radians(-4 * s), 4, "Y"), 0.016, 0.66, 14, M["metal"])
        cylinder("SeatBoomCap", back @ Matrix.Translation((s * 0.15 + s * 0.046, 0.12, 0.96)), 0.019, 0.02, 14, M["red"])
    cylinder("DrogueGun", back @ Matrix.Translation((0.0, 0.19, 0.2)), 0.03, 0.62, 18, M["paint_dark"])
    box("SeatPlacard", back @ Matrix.Translation((0, 0.172, 0.8)), (-0.05, 0.0, -0.025), (0.05, 0.002, 0.025), M["yellow"], 0)
    box("Headrest", back, (-0.11, 0.035, 0.68), (0.11, 0.07, 0.86), M["leather"], 0.018)
    for s in (-1, 1):
        box("CanopyBreaker", back, (s * 0.12 - 0.012, 0.03, 0.92), (s * 0.12 + 0.012, 0.09, 0.99), M["metal"], 0.004)
        box("SeatRail", back, (s * 0.2 - 0.015, 0.13, -0.15), (s * 0.2 + 0.015, 0.17, 0.95), M["metal"], 0.004)
        box("SeatHeadSide", back, (s * 0.16 - 0.012 * s, 0.03, 0.62), (s * 0.172, 0.21, 0.9), M["paint_dark"], 0.006)
    # yellow and black striped ejection handle loop, between the knees at the seat front
    loop = Matrix.Translation((0, -5.47, 0.36))
    for i in range(10):
        a0 = math.pi * i / 10; a1 = math.pi * (i + 1) / 10
        p0 = Vector((math.cos(a0) * 0.07, -math.sin(a0) * 0.02, math.sin(a0) * 0.05))
        p1 = Vector((math.cos(a1) * 0.07, -math.sin(a1) * 0.02, math.sin(a1) * 0.05))
        d = p1 - p0
        seg = Matrix.Translation(p0) @ d.to_track_quat("Z", "Y").to_matrix().to_4x4()
        cylinder("EjectHandle", loop @ seg, 0.009, d.length, 10, M["red"])
    label("PULL TO EJECT", Matrix.Translation((0, -5.445, 0.362)) @ Matrix.Rotation(math.radians(90), 4, "X"), 0.008)
    # harness straps (shoulder, lap) and oxygen/comm hose connector
    for s in (-1, 1):
        box("LapStrap", Matrix.Translation((s * 0.17, -5.2, 0.42)) @ Matrix.Rotation(math.radians(-30 * s), 4, "Y"), (-0.022, -0.005, -0.06), (0.022, 0.005, 0.06), M["fabric"], 0.003)
    box("SeatHoseBlock", Matrix(), (-0.27, -5.2, 0.33), (-0.235, -5.1, 0.40), M["paint_dark"], 0.005)
    cylinder("SeatHose", Matrix.Translation((-0.255, -5.15, 0.40)), 0.012, 0.08, 12, M["rubber"])

# ------------------------------------------------------------------ canopy and windscreen: thick glass, bows, rails, mirrors, standby compass
M["cglass"] = mat("CP_CanopyGlass", (0.62, 0.68, 0.66), 0.04, alpha=0.08)
if "gedge" not in M:
    M["gedge"] = mat("CP_GlassEdge", (0.30, 0.48, 0.42), 0.1, alpha=0.55)
M["mirror"] = mat("CP_Mirror", (0.9, 0.9, 0.9), 0.04, 1.0)
M["seal"] = mat("CP_Seal", (0.05, 0.05, 0.05), 0.85)
M["pad"] = mat("CP_Pad", (0.55, 0.58, 0.6), 0.5)
M["floormat"] = mat("CP_FloorMat", (0.05, 0.05, 0.05), 0.85)      # ribbed rubber floor matting
M["glare"] = mat("CP_Glare", (0.03, 0.03, 0.03), 0.7)             # glareshield: black grained vinyl over padding
M["frame"] = mat("CP_Frame", (0.2, 0.36, 0.4), 0.45, 0.3)      # canopy and windscreen frames (lighter, metallic paint)

SU27 = os.path.join(ROOT, "blender", "su27.blend")
HINGE = Vector((0.0, -3.35, 0.9))
CNP_ROOT = bpy.data.objects.new("CNP_Root", None); COL.objects.link(CNP_ROOT)
CNP_ROOT.matrix_world = Matrix.Translation(HINGE)

def to_canopy(ob):
    """Parent to the canopy root, keeping the world transform (moves with the canopy in game)."""
    mw = ob.matrix_world.copy()
    ob.parent = CNP_ROOT
    ob.matrix_parent_inverse = Matrix()
    ob.matrix_basis = CNP_ROOT.matrix_world.inverted() @ mw
    return ob

def _source_glass(objname):
    with bpy.data.libraries.load(SU27, link=False) as (src, dst):
        dst.objects = [objname]
    o = dst.objects[0]
    SCN.collection.objects.link(o)
    bpy.context.view_layer.update()
    mw = o.matrix_world.copy() if o.parent is None else (o.parent.matrix_world @ o.matrix_parent_inverse @ o.matrix_basis)
    bm = bmesh.new(); bm.from_mesh(o.data); bm.transform(mw)
    keep = [i for i, m in enumerate(o.data.materials) if m and m.name.split(".")[0] == "M_Su27_Glass"]
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.material_index not in keep], context="FACES")
    bmesh.ops.delete(bm, geom=[e for e in bm.edges if not e.link_faces], context="EDGES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_edges], context="VERTS")
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
    for f in bm.faces:
        f.material_index = 0
    # make normals point out of the cockpit
    bm.normal_update()
    score = sum((f.normal.dot(f.calc_center_median() - Vector((0, f.calc_center_median().y, 0.75)))) for f in bm.faces)
    if score < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
        bm.normal_update()
    par = o.parent
    bpy.data.objects.remove(o)
    if par and par.users == 0:
        bpy.data.objects.remove(par)
    return bm

def _boundary_chains(bm, pred):
    E = [e for e in bm.edges if e.is_boundary and pred(e.verts[0].co) and pred(e.verts[1].co)]
    adj = {}
    for e in E:
        a, b = e.verts
        adj.setdefault(a, []).append(b); adj.setdefault(b, []).append(a)
    seen, out = set(), []
    for s in [v for v in adj if len(adj[v]) == 1] + list(adj):
        if s in seen:
            continue
        ch = [s]; seen.add(s); cur = s
        while True:
            nx = [w for w in adj[cur] if w not in seen]
            if not nx:
                break
            cur = nx[0]; seen.add(cur); ch.append(cur)
        if len(ch) > 2:
            out.append([(v.co.copy(), (-v.normal).normalized()) for v in ch])
    return out

def _resample(chain, step):
    """Even spacing along a chain of (point, inward normal)."""
    pts = [p for p, _ in chain]; ns = [n for _, n in chain]
    out = [chain[0]]; acc = 0.0
    for i in range(1, len(pts)):
        seg = (pts[i] - pts[i - 1]).length
        while acc + seg >= step and seg > 1e-9:
            t = (step - acc) / seg
            p = pts[i - 1].lerp(pts[i], t); n = ns[i - 1].lerp(ns[i], t).normalized()
            out.append((p, n)); pts[i - 1] = p; ns[i - 1] = n
            seg = (pts[i] - p).length; acc = 0.0
        acc += seg
    if (out[-1][0] - chain[-1][0]).length > step * 0.3:
        out.append(chain[-1])
    return out

def sweep(name, chain, profile, material, bref, flat_axis=None):
    """Extrude a 2D profile (a along the inward normal, c along the binormal) along a chain."""
    bm = bmesh.new(); rings = []
    pts = [p for p, _ in chain]
    for i, (p, n) in enumerate(chain):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        if flat_axis is not None:
            n = (n - flat_axis * n.dot(flat_axis)).normalized()
        n = (n - t * n.dot(t)).normalized()
        b = t.cross(n).normalized()
        if b.dot(bref) < 0:
            b = -b
        rings.append([bm.verts.new(p + n * a + b * c) for a, c in profile])
    k = len(profile)
    for i in range(len(rings) - 1):
        for j in range(k):
            bm.faces.new((rings[i][j], rings[i][(j + 1) % k], rings[i + 1][(j + 1) % k], rings[i + 1][j]))
    bm.faces.new(rings[0]); bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm_to(name, bm, material, smooth=False)

def rivets(name, chain, a, c, step, material, r=0.0026, bref=Vector((0, 1, 0)), flat_axis=None):
    """Domed rivet heads on the inner face of a frame, every `step` metres."""
    bm = bmesh.new()
    rs = _resample(chain, step)
    pts = [p for p, _ in rs]
    for i, (p, n) in enumerate(rs):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        if flat_axis is not None:
            n = (n - flat_axis * n.dot(flat_axis)).normalized()
        b = t.cross(n).normalized()
        if b.dot(bref) < 0:
            b = -b
        base = p + n * a + b * c
        m = Matrix.Translation(base) @ n.to_track_quat("Z", "Y").to_matrix().to_4x4()
        ring0 = [bm.verts.new(m @ Vector((r * math.cos(2 * math.pi * k / 8), r * math.sin(2 * math.pi * k / 8), 0))) for k in range(8)]
        ring1 = [bm.verts.new(m @ Vector((r * 0.6 * math.cos(2 * math.pi * k / 8), r * 0.6 * math.sin(2 * math.pi * k / 8), r * 0.45))) for k in range(8)]
        top = bm.verts.new(m @ Vector((0, 0, r * 0.6)))
        for k in range(8):
            bm.faces.new((ring0[k], ring0[(k + 1) % 8], ring1[(k + 1) % 8], ring1[k]))
            bm.faces.new((ring1[k], ring1[(k + 1) % 8], top))
    return bm_to(name, bm, material, smooth=True)

def thick_glass(name, bm, thickness):
    """Solidify inward: two real surfaces plus a visible edge where the glass meets the frames."""
    me = bpy.data.meshes.new(name); bm.to_mesh(me)
    ob = link(name, me, M["cglass"], smooth=True)
    me.materials.append(M["gedge"])
    mod = ob.modifiers.new("Solid", "SOLIDIFY")
    mod.thickness = thickness; mod.offset = -1.0
    mod.use_even_offset = False; mod.use_quality_normals = True; mod.use_rim = True
    mod.material_offset_rim = 1
    dg = bpy.context.evaluated_depsgraph_get()
    baked = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
    ob.modifiers.clear(); old = ob.data; ob.data = baked; baked.name = name
    bpy.data.meshes.remove(old)
    return ob

def canopy():
    # --- glass: the canopy bubble about 18 mm thick, the front windscreen 45 mm (armoured block)
    cbm = _source_glass("Canopy")
    front = _boundary_chains(cbm, lambda co: co.y < -6.33)
    sides = _boundary_chains(cbm, lambda co: co.z < 0.62 and co.y < -4.10 and co.y > -6.36)
    to_canopy(thick_glass("CNP_Glass", cbm.copy(), 0.018))
    wbm = _source_glass("Airframe")
    wrear = _boundary_chains(wbm, lambda co: co.y > -6.37)
    wside = _boundary_chains(wbm, lambda co: co.y < -6.36 and (co.z < 0.62 or co.y < -7.55))
    thick_glass("WS_Glass", wbm.copy(), 0.045)
    cbm.free(); wbm.free()
    Y = Vector((0, 1, 0)); Z = Vector((0, 0, 1))
    # --- canopy front bow (moves with the canopy): deep, heavy section with a rubber seal on its face
    for ch in front:
        to_canopy(sweep("CNP_FrontBow", ch, [(-0.004, 0.0), (0.07, 0.0), (0.08, 0.01), (0.08, 0.07), (0.072, 0.08), (0.034, 0.08), (0.03, 0.092), (-0.004, 0.092)], M["frame"], Y, Y))
        to_canopy(sweep("CNP_FrontSeal", ch, [(-0.002, -0.006), (0.07, -0.006), (0.07, 0.0), (-0.002, 0.0)], M["seal"], Y, Y))
        to_canopy(rivets("CNP_BowRivets", ch, 0.08, 0.02, 0.038, M["metal"], flat_axis=Y))
        to_canopy(rivets("CNP_BowRivets", ch, 0.08, 0.06, 0.038, M["metal"], flat_axis=Y))
        # stiffening bosses across the inner face, like the frame's machined pockets
        for p, n in _resample(ch, 0.11)[1:-1]:
            nf = Vector((n.x, 0.0, n.z)).normalized()
            t = Vector((0, 1, 0)).cross(nf).normalized()
            m = frame(p + nf * 0.08 + Vector((0, 0.04, 0)), t, Vector((0, 1, 0)))
            to_canopy(box("CNP_BowBoss", m, (-0.012, -0.03, 0.0), (0.012, 0.03, 0.006), M["frame"], 0.002))
        # light hand-hold pads on the bow's upper corners
        for sgn in (-1, 1):
            cand = [(p, n) for p, n in ch if p.x * sgn > 0.1]
            if not cand:
                continue
            p, n = min(cand, key=lambda pn: abs(math.degrees(math.atan2(pn[0].z - 0.8, abs(pn[0].x))) - 48))
            nf = Vector((n.x, 0.0, n.z)).normalized()
            t = Vector((0, 1, 0)).cross(nf).normalized()
            m = frame(p + nf * 0.081 + Vector((0, 0.045, 0)), t, Vector((0, 1, 0)))
            to_canopy(box("CNP_HandHold", m, (-0.09, -0.032, 0.0), (0.09, 0.032, 0.012), M["pad"], 0.005))
    # --- windscreen arch (fixed): behind the armoured glass, with a fillet down to the glareshield
    for ch in wrear:
        sweep("WS_Arch", ch, [(-0.004, -0.085), (0.06, -0.085), (0.072, -0.07), (0.072, -0.006), (-0.004, -0.006)], M["frame"], Y, Y)
        rivets("WS_ArchRivets", ch, 0.072, -0.03, 0.038, M["metal"], flat_axis=Y)
        rivets("WS_ArchRivets", ch, 0.072, -0.062, 0.038, M["metal"], flat_axis=Y)
    for ch in wside:
        sweep("WS_SideFrame", ch, [(-0.004, -0.03), (0.03, -0.03), (0.034, 0.0), (-0.004, 0.0)], M["frame"], Z)
    # --- canopy side rails: the heavy longerons that latch into the sill
    for ch in sides:
        to_canopy(sweep("CNP_SideRail", ch, [(-0.006, -0.05), (0.045, -0.05), (0.052, -0.035), (0.052, 0.012), (0.03, 0.02), (-0.006, 0.02)], M["frame"], Z))
        to_canopy(rivets("CNP_RailRivets", ch, 0.052, -0.012, 0.05, M["metal"], bref=Z))
        # latch hooks along the rail
        rs = _resample(ch, 0.38)
        for p, n in rs[1:-1]:
            to_canopy(box("CNP_Latch", Matrix.Translation(p + n * 0.03 + Vector((0, 0, -0.06))), (-0.012, -0.02, -0.02), (0.012, 0.02, 0.0), M["steel_dark"], 0.003))
    # --- rear-view mirrors on L-brackets either side of the bow (off for now: the reference layout has none)
    for s, side in (() if "--mirrors" not in ARGS else ((1, "L"), (-1, "R"))):
        cand = [(p, n) for ch in front for p, n in ch if p.x * s > 0.2]
        if not cand:
            continue
        p, n = min(cand, key=lambda pn: abs(pn[0].z - 1.13))
        nf = Vector((n.x, 0.0, n.z)).normalized()
        root = p + nf * 0.08 + Vector((0, 0.05, 0))
        elbow = root + nf * 0.05
        centre = elbow + Vector((0, 0.05, 0.0)) + nf * 0.035
        to_canopy(lathe("CNP_MirrorArm" + side, between(root, elbow), [(0.0, 0.0), (0.008, 0.0), (0.008, -(elbow - root).length), (0.0, -(elbow - root).length)], 10, M["steel_dark"]))
        to_canopy(cylinder("CNP_MirrorPivot" + side, Matrix.Translation(elbow) @ Matrix.Rotation(math.radians(90), 4, "X"), 0.012, 0.03, 14, M["steel_dark"], z0=-0.015))
        look = ((EYE - centre).normalized() + Vector((0, 1.0, 0))).normalized()
        mm = Matrix.Translation(centre) @ look.to_track_quat("Z", "Y").to_matrix().to_4x4()
        w, h, r = 0.13, 0.075, 0.016
        pts = []
        for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
            for k in range(5):
                a = math.radians(a0 + 90 * k / 4)
                pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        rings = [[mm @ Vector((x * sc, y * sc, z)) for x, y in pts] for sc, z in ((0.92, -0.022), (1.0, -0.01), (1.0, 0.004), (0.96, 0.006))]
        to_canopy(bevel_smooth(loft("CNP_MirrorHousing" + side, rings, M["frame"], smooth=False), 0.002, 2))
        bm = bmesh.new()
        uvl = bm.loops.layers.uv.new("UVMap")
        vs = [bm.verts.new(mm @ Vector((x * 0.9, y * 0.88, 0.0045))) for x, y in pts]
        f = bm.faces.new(vs)
        for l, (x, y) in zip(f.loops, pts):
            l[uvl].uv = (0.5 + x * 0.9 / w, 0.5 + y * 0.88 / h)
        mo = bm_to("CNP_Mirror" + side, bm, M["mirror"], smooth=False)
        to_canopy(mo)
    # --- standby compass (KI-13): a ball housing hung from the windscreen arch, upper right
    cand = [(p, n) for ch in wrear for p, n in ch if p.x < -0.15]
    p, n = min(cand, key=lambda pn: abs(pn[0].z - 1.24))
    nf = Vector((n.x, 0.0, n.z)).normalized()
    hang = p + nf * 0.075 + Vector((0, -0.03, 0))
    ball = hang + nf * 0.07 + Vector((0, 0.02, 0))
    lathe("Compass_Bracket", between(hang, ball), [(0.0, 0.0), (0.007, 0.0), (0.007, -(ball - hang).length), (0.0, -(ball - hang).length)], 10, M["steel_dark"])
    ellipsoid("Compass_Ball", Matrix.Translation(ball), 0.036, 0.036, 0.034, M["paint_dark"])
    look = (EYE - ball).normalized()
    fm_ = Matrix.Translation(ball + look * 0.031) @ look.to_track_quat("Z", "Y").to_matrix().to_4x4()
    if "COMPASS_FACE" in CELLS:
        quad_uv("Compass_Face", fm_, 0.04, 0.024, [CELLS["COMPASS_FACE"][0] + 76, CELLS["COMPASS_FACE"][1] + 186, 360, 140], M["gauge"], z=0.0)
    lathe("Compass_Rim", fm_, [(0.024, -0.002), (0.028, 0.0), (0.028, 0.004), (0.022, 0.004)], 24, M["steel_dark"])
    # --- demist / ventilation hose curling from the coaming up the left of the HUD (as on the real jet)
    # kept outboard of the HUD frame uprights (x 0.122) so it never sits behind the combiner glass
    a = Vector((0.15, -6.48, 0.99)); b = Vector((0.205, -6.43, 1.13))
    pts = []
    for k in range(13):
        t = k / 12
        q = a.lerp(b, t) + Vector((0.035 * math.sin(math.pi * t), 0.02 * math.sin(math.pi * t), 0.03 * math.sin(math.pi * t)))
        pts.append(q)
    for k in range(12):
        L = (pts[k + 1] - pts[k]).length
        lathe("DemistHose", between(pts[k], pts[k + 1]), [(0.0, 0.0), (0.024, 0.0), (0.028, -L * 0.5), (0.024, -L), (0.0, -L)], 14, M["rubber"])

# ------------------------------------------------------------------ pilot (ZSh-7 helmet, KM-34 mask, suit, G-suit, gloves, boots)
M["suit"] = mat("CP_Suit", (0.16, 0.17, 0.11), 0.85)        # olive flight coverall
M["gsuit"] = mat("CP_GSuit", (0.10, 0.11, 0.07), 0.8)       # darker anti-G trousers
M["helmet"] = mat("CP_Helmet", (0.62, 0.63, 0.6), 0.35)     # white-grey shell
M["visor"] = mat("CP_Visor", (0.03, 0.025, 0.02), 0.05, alpha=0.6)
M["mask"] = mat("CP_Mask", (0.07, 0.08, 0.06), 0.7)
M["glove"] = mat("CP_Glove", (0.035, 0.03, 0.025), 0.6)
M["boot"] = mat("CP_Boot", (0.02, 0.02, 0.02), 0.55)

def adopt(objs, parent):
    """Parent loose objects to `parent`, keeping where they are."""
    bpy.context.view_layer.update()      # a freshly parented empty's matrix_world is stale until an update
    pinv = parent.matrix_world.inverted()
    for o in objs:
        if o.parent is None and o is not parent:
            mw = o.matrix_world.copy()
            o.parent = parent
            o.matrix_parent_inverse = Matrix()
            o.matrix_basis = pinv @ mw

def empty(name, mtx, parent=None):
    e = bpy.data.objects.new(name, None); COL.objects.link(e)
    e.empty_display_size = 0.03
    if parent:
        bpy.context.view_layer.update()
        e.parent = parent; e.matrix_parent_inverse = Matrix()
        e.matrix_basis = parent.matrix_world.inverted() @ mtx
    else:
        e.matrix_world = mtx
    return e

def soften(ob, levels=2):
    """Organic shapes (body, boots, gloves): bevelled blocks smoothed by subdivision."""
    m = ob.modifiers.new("Subsurf", "SUBSURF")
    m.levels = levels; m.render_levels = levels
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob

def capsule(name, L, r0, r1, material, segs=18):
    """Limb segment along local -Z from the origin (proximal joint) to -L (distal joint). The game aims it."""
    k = 0.7071
    prof = [(0.0, r0), (r0 * 0.5, r0 * 0.87), (r0 * k, r0 * k), (r0 * 0.87, r0 * 0.5), (r0, 0.0),
            (r1, -L), (r1 * 0.87, -L - r1 * 0.5), (r1 * k, -L - r1 * k), (r1 * 0.5, -L - r1 * 0.87), (0.0, -L - r1)]
    return lathe(name, Matrix(), prof, segs, material)

def ellipsoid(name, mtx, rx, ry, rz, material, parent=None, segs=(32, 16)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs[0], v_segments=segs[1], radius=1.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * rx, v.co.y * ry, v.co.z * rz))
    return bm_to(name, bm, material, mtx, parent, smooth=True)

def between(a, b):
    """Frame at a whose local -Z points at b."""
    d = (b - a).normalized()
    return Matrix.Translation(a) @ (-d).to_track_quat("Z", "Y").to_matrix().to_4x4()

def pilot(seat_root):
    hip = Vector((0.0, -5.26, 0.43))
    BK = Matrix.Translation(hip + Vector((0, 0.13, -0.02))) @ Matrix.Rotation(-SEAT_RAKE, 4, "X")
    root = empty("PLT_Root", Matrix.Translation(hip), seat_root)
    made = set(bpy.data.objects)
    # torso, collar, life vest panel, pelvis
    soften(frustum("PLT_Torso", BK, (-0.165, -0.25, 0.06), (0.165, -0.035, 0.06), (-0.21, -0.245, 0.55), (0.21, -0.045, 0.55), M["suit"], 0.06))
    soften(frustum("PLT_Vest", BK, (-0.15, -0.272, 0.2), (0.15, -0.235, 0.2), (-0.17, -0.268, 0.5), (0.17, -0.232, 0.5), M["fabric"], 0.012), 1)
    soften(box("PLT_Pelvis", BK, (-0.175, -0.33, -0.05), (0.175, -0.03, 0.15), M["gsuit"], 0.05))
    cylinder("PLT_Collar", BK @ Matrix.Translation((0, -0.13, 0.52)), 0.068, 0.06, 20, M["suit"])
    for s, sd in ((1, "L"), (-1, "R")):
        box("PLT_ShoulderStrap" + sd, BK, (s * 0.085 - 0.022, -0.275, 0.2), (s * 0.085 + 0.022, -0.262, 0.56), M["fabric"], 0.003)
        box("PLT_ShoulderStrapTop" + sd, BK, (s * 0.085 - 0.022, -0.262, 0.54), (s * 0.085 + 0.022, 0.0, 0.555), M["fabric"], 0.003)
        box("PLT_LapStrap" + sd, BK @ Matrix.Translation((s * 0.15, -0.2, 0.1)) @ Matrix.Rotation(math.radians(-25 * s), 4, "Y"), (-0.022, -0.14, -0.006), (0.022, 0.0, 0.006), M["fabric"], 0.003)
    box("PLT_ChestConnector", BK @ Matrix.Translation((0.07, -0.275, 0.38)), (-0.025, -0.012, -0.03), (0.025, 0.012, 0.03), M["steel_dark"], 0.004)
    torso_parts = [o for o in bpy.data.objects if o not in made]
    # head: helmet, visor (raised), mask and hose; pivots at the top of the neck
    neck = BK @ Matrix.Translation((0, -0.12, 0.6))
    head = empty("PLT_Head", neck, root)
    made = set(bpy.data.objects)
    hc = BK @ Matrix.Translation((0, -0.095, 0.765))
    cylinder("PLT_Neck", BK @ Matrix.Translation((0, -0.12, 0.56)), 0.052, 0.12, 16, M["suit"])
    ellipsoid("PLT_Helmet", hc, 0.122, 0.138, 0.13, M["helmet"])
    ellipsoid("PLT_HelmetRim", hc @ Matrix.Translation((0, -0.02, -0.03)), 0.124, 0.12, 0.09, M["paint_dark"])
    box("PLT_VisorHousing", hc @ Matrix.Translation((0, -0.11, 0.075)) @ Matrix.Rotation(math.radians(-35), 4, "X"), (-0.095, -0.012, -0.03), (0.095, 0.012, 0.03), M["helmet"], 0.01)
    ellipsoid("PLT_Visor", hc @ Matrix.Translation((0, -0.035, 0.065)), 0.128, 0.11, 0.075, M["visor"])
    mask_m = hc @ Matrix.Translation((0, -0.13, -0.055)) @ Matrix.Rotation(math.radians(90), 4, "X")
    lathe("PLT_Mask", mask_m, [(0.0, 0.055), (0.025, 0.05), (0.045, 0.03), (0.052, 0.0), (0.05, -0.012), (0.0, -0.012)], 24, M["mask"])
    cylinder("PLT_MaskValve", mask_m @ Matrix.Translation((0, 0, 0.05)), 0.016, 0.02, 14, M["steel_dark"])
    a = (hc @ Vector((0.0, -0.15, -0.09)))
    b = (BK @ Vector((0.07, -0.29, 0.40)))
    for i in range(9):
        t0, t1 = i / 9, (i + 1) / 9
        p0 = a.lerp(b, t0) + Vector((0, -0.04 * math.sin(math.pi * t0), 0))
        p1 = a.lerp(b, t1) + Vector((0, -0.04 * math.sin(math.pi * t1), 0))
        seg = between(p0, p1)
        lathe("PLT_Hose", seg, [(0.0, 0.0), (0.016, 0.0), (0.019, -(p1 - p0).length * 0.5), (0.016, -(p1 - p0).length), (0.0, -(p1 - p0).length)], 12, M["mask"])
    head_parts = [o for o in bpy.data.objects if o not in made]
    adopt(head_parts, head)
    # limbs: segments the game aims every frame by two-bone IK (shoulder -> wrist, hip -> ankle)
    for s, side in ((1, "L"), (-1, "R")):
        empty("PLT_Shoulder" + side, BK @ Matrix.Translation((0.2 * s, -0.14, 0.49)), root)
        empty("PLT_Hip" + side, Matrix.Translation((0.1 * s, -5.30, 0.48)), root)
        for nm, L, r0, r1, m in (("UpperArm", 0.29, 0.058, 0.047, "suit"), ("Forearm", 0.25, 0.047, 0.038, "suit"),
                                 ("Thigh", 0.45, 0.076, 0.058, "gsuit"), ("Shin", 0.43, 0.056, 0.044, "gsuit")):
            o = capsule("PLT_%s%s" % (nm, side), L, r0, r1, M[m])
            o.parent = root; o.matrix_parent_inverse = Matrix(); o.matrix_basis = Matrix()
            o["length"] = L
    adopt(torso_parts, root)

def hands_and_boots():
    stick = bpy.data.objects["ANIM_Stick"]
    thr = bpy.data.objects["ANIM_Throttle"]
    # right hand round the stick grip (grip frame as built in stick(): 0.375 up, leaning 14 degrees)
    gm = stick.matrix_world @ STICK_GM
    hr = empty("PLT_HandR", gm, stick)
    made = set(bpy.data.objects)
    soften(box("PLT_PalmR", gm @ Matrix.Translation((-0.03, 0.022, 0.064)) @ Matrix.Rotation(math.radians(-38), 4, "Z"), (-0.013, -0.036, -0.046), (0.013, 0.036, 0.046), M["glove"], 0.011), 1)
    lathe("PLT_FingersR", gm @ Matrix.Diagonal((0.95, 1.25, 1.0, 1.0)) @ Matrix.Rotation(math.radians(165), 4, "Z"),
          [(0.031, 0.024), (0.05, 0.03), (0.052, 0.1), (0.031, 0.106), (0.031, 0.024)], 14, M["glove"], angle=math.radians(215))
    th = between(gm @ Vector((-0.012, 0.03, 0.112)), gm @ Vector((0.016, -0.004, 0.128)))
    lathe("PLT_ThumbR", th, [(0.0, 0.012), (0.012, 0.0), (0.011, -0.04), (0.0, -0.05)], 10, M["glove"])
    cuff = between(gm @ Vector((-0.04, 0.05, 0.05)), gm @ Vector((-0.05, 0.09, 0.03)))
    lathe("PLT_CuffR", cuff, [(0.0, 0.0), (0.034, 0.0), (0.04, -0.045), (0.0, -0.045)], 14, M["glove"])
    adopt([o for o in bpy.data.objects if o not in made], hr)
    empty("PLT_WristR", gm @ Matrix.Translation((-0.05, 0.095, 0.03)), hr)
    # left hand over the throttle grip (grip frame as built in throttle())
    g = thr.matrix_world @ Matrix.Translation((0.004, 0.0, 0.125)) @ Matrix.Rotation(math.radians(-12), 4, "Y")
    hl = empty("PLT_HandL", g, thr)
    made = set(bpy.data.objects)
    soften(box("PLT_PalmL", g @ Matrix.Translation((-0.012, -0.004, 0.05)) @ Matrix.Rotation(math.radians(-18), 4, "Y"), (-0.04, -0.048, -0.012), (0.04, 0.048, 0.014), M["glove"], 0.011), 1)
    soften(box("PLT_FingersL", g @ Matrix.Translation((0.042, 0.0, 0.018)), (-0.012, -0.046, -0.03), (0.012, 0.046, 0.026), M["glove"], 0.01), 1)
    th = between(g @ Vector((-0.04, 0.02, 0.03)), g @ Vector((-0.036, 0.06, 0.01)))
    lathe("PLT_ThumbL", th, [(0.0, 0.012), (0.012, 0.0), (0.011, -0.035), (0.0, -0.045)], 10, M["glove"])
    cuff = between(g @ Vector((-0.04, -0.05, 0.045)), g @ Vector((-0.05, -0.09, 0.05)))
    lathe("PLT_CuffL", cuff, [(0.0, 0.0), (0.034, 0.0), (0.04, -0.045), (0.0, -0.045)], 14, M["glove"])
    adopt([o for o in bpy.data.objects if o not in made], hl)
    empty("PLT_WristL", g @ Matrix.Translation((-0.05, -0.095, 0.05)), hl)
    # boots on the rudder pedals (pad frame as built in pedals())
    for side in ("L", "R"):
        pv = bpy.data.objects["ANIM_Pedal" + side]
        P = pv.matrix_world @ Matrix.Translation((0, 0.02, -0.14)) @ Matrix.Rotation(math.radians(-20), 4, "X")
        bt = empty("PLT_Boot" + side, P, pv)
        made = set(bpy.data.objects)
        box("PLT_Sole" + side, P, (-0.045, 0.012, -0.11), (0.045, 0.03, 0.1), M["rubber"], 0.008)
        soften(frustum("PLT_BootUpper" + side, P, (-0.047, 0.03, -0.11), (0.047, 0.115, -0.11), (-0.042, 0.03, 0.09), (0.042, 0.06, 0.09), M["boot"], 0.018), 1)
        cylinder("PLT_BootShaft" + side, P @ Matrix.Translation((0, 0.075, -0.07)) @ Matrix.Rotation(math.radians(-70), 4, "X"), 0.052, 0.09, 16, M["boot"])
        adopt([o for o in bpy.data.objects if o not in made], bt)
        empty("PLT_Ankle" + side, P @ Matrix.Translation((0, 0.075, -0.07)), bt)

def _limb(upper, lower, a, t, l1, l2, pole):
    d = t - a
    dist = max(abs(l1 - l2) + 0.001, min(d.length, l1 + l2 - 0.001))
    di = d.normalized()
    x = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
    h = math.sqrt(max(l1 * l1 - x * x, 0.0))
    side = pole - a
    side = (side - di * side.dot(di)).normalized()
    e = a + di * x + side * h
    w = a + di * dist
    # segments run along local -Z in Blender (glTF: -Y), so aim with the Z column
    for ob, p, q in ((upper, a, e), (lower, e, w)):
        zc = (p - q).normalized()
        xc = side.cross(zc).normalized()
        yc = zc.cross(xc)
        ob.matrix_world = Matrix(((xc.x, yc.x, zc.x, p.x), (xc.y, yc.y, zc.y, p.y), (xc.z, yc.z, zc.z, p.z), (0, 0, 0, 1)))

def solve_limbs():
    bpy.context.view_layer.update()
    O = bpy.data.objects
    for s, side in ((1, "L"), (-1, "R")):
        sh = O["PLT_Shoulder" + side].matrix_world.translation
        wr = O["PLT_Wrist" + side].matrix_world.translation
        _limb(O["PLT_UpperArm" + side], O["PLT_Forearm" + side], sh, wr, 0.29, 0.25, sh + Vector((0.3 * s, 0.1, -0.35)))
        hp = O["PLT_Hip" + side].matrix_world.translation
        an = O["PLT_Ankle" + side].matrix_world.translation
        _limb(O["PLT_Thigh" + side], O["PLT_Shin" + side], hp, an, 0.45, 0.43, hp + Vector((0.12 * s, -0.4, 0.5)))

# ------------------------------------------------------------------ build and preview
_pre_tub = set(bpy.data.objects)
tub()
_tub_parts = set(bpy.data.objects) - _pre_tub
_pre_panel = set(bpy.data.objects)
front_panel()
coaming()
hud()
for o in set(bpy.data.objects) - _pre_panel:
    if o.parent is None:
        o.matrix_world = Matrix.Translation((0.0, 0.0, PANEL_DZ)) @ o.matrix_world
bpy.context.view_layer.update()
consoles()
throttle()
stick()
console_fill()
pedals()
_before_seat = set(bpy.data.objects)
seat()
SEAT_ROOT = bpy.data.objects.new("ANIM_Seat", None); COL.objects.link(SEAT_ROOT)
SEAT_ROOT.matrix_world = Matrix.Translation((0.0, -5.26, 0.43))   # moves up and down with the seat height setting
adopt([o for o in bpy.data.objects if o not in _before_seat], SEAT_ROOT)
# the pilot model is not built for now (the cockpit is shown empty); pilot() and hands_and_boots() stay available
# Move the interior forward so the pilot sits under the canopy's high point, the panel tucks under the
# windscreen arch and the arch frames the view as in the real jet (the airframe fixes the canopy opening).
DY = -0.40
for o in bpy.data.objects:
    if o.parent is None and o not in _tub_parts:
        o.matrix_world = Matrix.Translation((0.0, DY, 0.0)) @ o.matrix_world
EYE = EYE + Vector((0.0, DY, 0.0))
bpy.context.view_layer.update()
canopy()

def preview(path):
    cam = bpy.data.cameras.new("Eye")
    cam.lens_unit = "FOV"
    cam.angle = math.radians(80)
    co = bpy.data.objects.new("EyeCam", cam); SCN.collection.objects.link(co)
    look = (EYE + Vector((0, -0.8, -0.3)) - EYE).normalized()
    co.matrix_world = Matrix.Translation(EYE) @ look.to_track_quat("-Z", "Y").to_matrix().to_4x4()
    SCN.camera = co
    sun = bpy.data.lights.new("Sun", "SUN"); sun.energy = 2.2
    so = bpy.data.objects.new("Sun", sun); SCN.collection.objects.link(so)
    so.rotation_euler = (math.radians(50), 0, math.radians(160))
    fill = bpy.data.lights.new("Fill", "AREA"); fill.energy = 25; fill.size = 1.5
    fo = bpy.data.objects.new("Fill", fill); SCN.collection.objects.link(fo)
    fo.matrix_world = Matrix.Translation(EYE + Vector((0, 0.3, 0.6))) @ Vector((0, -0.6, -0.8)).to_track_quat("-Z", "Y").to_matrix().to_4x4()
    w = bpy.data.worlds.new("W"); w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.62, 0.7, 1); w.node_tree.nodes["Background"].inputs[1].default_value = 0.45
    SCN.world = w
    SCN.render.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] else "BLENDER_EEVEE_NEXT"
    SCN.render.resolution_x = 1600; SCN.render.resolution_y = 900
    SCN.view_settings.view_transform = "AgX"
    SCN.render.filepath = path
    bpy.ops.render.render(write_still=True)
    if "--render2" in ARGS:
        co.matrix_world = Matrix.Translation(Vector((0.55, -4.1, 1.75))) @ (Vector((-0.05, -5.8, 0.55)) - Vector((0.55, -4.1, 1.75))).to_track_quat("-Z", "Y").to_matrix().to_4x4()
        cam.angle = math.radians(70)
        SCN.render.filepath = ARGS[ARGS.index("--render2") + 1]
        bpy.ops.render.render(write_still=True)
    if "--render3" in ARGS:
        co.matrix_world = Matrix.Translation(EYE) @ (Vector((0.15, -6.35, 1.2)) - EYE).to_track_quat("-Z", "Y").to_matrix().to_4x4()
        cam.angle = math.radians(80)
        SCN.render.filepath = ARGS[ARGS.index("--render3") + 1]
        bpy.ops.render.render(write_still=True)

if "--render" in ARGS:
    preview(ARGS[ARGS.index("--render") + 1])
# extra preview cameras: --cam out.png:cx,cy,cz:tx,ty,tz:fov   (the pilot's body is hidden as in the game's cockpit view,
# legs stay; --pilot shows him whole)
_hidden = []
if "--pilot" not in ARGS:
    for o in bpy.data.objects:
        if o.name.startswith("PLT_") and not any(k in o.name for k in ("Thigh", "Shin", "Boot", "Sole")):
            if o.type == "MESH" and not o.hide_render:
                o.hide_render = True; _hidden.append(o)
for i, a in enumerate(ARGS):
    if a == "--cam" and i + 1 < len(ARGS):
        path, c, t, f = ARGS[i + 1].rsplit(":", 3)
        c = Vector([float(x) for x in c.split(",")]); t = Vector([float(x) for x in t.split(",")])
        if SCN.camera is None:
            preview(path)          # sets up camera, lights and world (renders the default view once)
        cam = SCN.camera
        cam.matrix_world = Matrix.Translation(c) @ (t - c).to_track_quat("-Z", "Y").to_matrix().to_4x4()
        cam.data.angle = math.radians(float(f))
        SCN.render.filepath = path
        bpy.ops.render.render(write_still=True)
for o in _hidden:
    o.hide_render = False
bpy.data.orphans_purge(do_recursive=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(ROOT, "blender", "su27_cockpit.blend"))

# ------------------------------------------------------------------ game export: bake, weather, merge per material, GLB
KEEP = ("NDL_", "LMP_", "SCR_", "ANIM_", "PLT_", "CNP_Mirror", "AP_", "OSB_")

def _mover(ob):
    p = ob.parent
    while p:
        if p.name.startswith("ANIM_") or p.name == "CNP_Root":
            return p
        p = p.parent
    return None

# Cockpit floodlights for the baked night lighting (final Blender coordinates): two lamps under the glareshield
# washing the panel, four along the canopy sills washing the consoles. [position, intensity]
def _hood_lamp(u):
    pos = pp(u, panel_top(u) - 0.008, 0.045) + Vector((0.0, DY, PANEL_DZ))
    aim = (-_pup(u) + _pnorm(u) * 0.35).normalized()
    return (tuple(pos), tuple(aim), 1.0)

CABIN_LAMPS = [_hood_lamp(0.24), _hood_lamp(-0.24),
               ((0.43, -5.6, 0.7), (-0.6, 0.0, -1.0), 0.8), ((-0.43, -5.6, 0.7), (0.6, 0.0, -1.0), 0.8),
               ((0.43, -4.9, 0.7), (-0.6, 0.0, -1.0), 0.7), ((-0.43, -4.9, 0.7), (0.6, 0.0, -1.0), 0.7)]
_LIGHT_BVH = None

def _cabin_light(p, n):
    """Baked floodlight at a point: each lamp is a soft spot (cone about its aim), with distance falloff,
    Lambert and a shadow ray (shadowed 0.12, so shadows stay soft but read), saturated softly. Returns 0..1."""
    if _LIGHT_BVH is None:
        return 1.0
    tot = 0.0
    for pos, aim, inten in CABIN_LAMPS:
        lp = Vector(pos)
        d = lp - p
        dist = d.length
        if dist > 0.95 or dist < 1e-4:
            continue
        l = d / dist
        cone = -l.dot(Vector(aim).normalized())
        t = min(1.0, max(0.0, (cone - 0.1) / 0.6))
        spot = t * t * (3.0 - 2.0 * t)
        lam = max(0.0, n.dot(l) * 0.9 + 0.1)
        fall = inten / (1.0 + (dist / 0.28) ** 2) * min(1.0, max(0.0, (0.95 - dist) / 0.35))
        c = lam * fall * spot
        if c < 0.01:
            continue
        hit = _LIGHT_BVH.ray_cast(p + n * 0.004, l, dist - 0.01)
        if hit[0] is not None:
            c *= 0.12
        tot += c
    return 1.0 - math.exp(-tot * 5.0)     # soft saturation: pools reach ~1, shadows stay well below

# baked ambient occlusion: cosine-weighted hemisphere rays, short range (contact shadows in corners, under lips,
# around bezels and switches). Gives the cockpit its depth under flat sky light.
AO_RANGE = 0.12
_AO_DIRS = []
for _k in range(14):
    _a = 2.399963 * _k                       # golden angle spiral, cosine weighted
    _r = math.sqrt((_k + 0.5) / 14)
    _AO_DIRS.append(Vector((_r * math.cos(_a), _r * math.sin(_a), math.sqrt(max(0.0, 1.0 - _r * _r)))))

_AO_BVH = None

def _ao(p, n):
    if _AO_BVH is None or n.length < 0.5:
        return 1.0
    rot = n.to_track_quat("Z", "Y").to_matrix()
    spin = Matrix.Rotation((p.x * 91.7 + p.y * 37.3 + p.z * 53.1) % 6.283, 3, "Z")
    o = p + n * 0.0015
    occ = 0.0
    for d in _AO_DIRS:
        w = rot @ (spin @ d)
        hit = _AO_BVH.ray_cast(o, w, AO_RANGE)
        if hit[0] is not None:
            occ += 1.0 - hit[3] / AO_RANGE * 0.6
    contact = max(0.0, 1.0 - occ / len(_AO_DIRS))
    # sky visibility: how much of the open canopy this point sees (long rays; the glass is not in the BVH), so
    # deep places (footwells, under the glareshield, the console walls) sit darker than the open sills
    vis = 0.0
    for d in _AO_DIRS:
        w = rot @ (spin @ d)
        if _AO_BVH.ray_cast(o, w, 1.4)[0] is None:
            vis += 1.0
    sky = vis / len(_AO_DIRS)
    return contact * (0.35 + 0.65 * sky)

def _wear(bm, seed, bevelled=True):
    """Per-corner mask for the paint shader. R = edge wear: only on the narrow bevel strips that round off
    convex edges (so whole plates never chip). G = grime: low in the tub and in tight concave corners.
    B = baked ambient occlusion (_ao): 1 open, 0 fully enclosed.
    A = baked cabin floodlight (CABIN_LAMPS, with soft shadows): the game's cockpit lights use it at night."""
    col = bm.loops.layers.float_color.new("Col")
    bm.normal_update()
    lit = {}
    # occlusion per vertex, then relaxed over the mesh so the few rays per vertex never read as blotches
    occl = {v.index: _ao(v.co.copy(), v.normal.copy()) for v in bm.verts}
    for _ in range(3):
        nxt = {}
        for v in bm.verts:
            nb = [e.other_vert(v) for e in v.link_edges]
            if nb:
                nxt[v.index] = 0.5 * occl[v.index] + 0.5 * sum(occl[o.index] for o in nb) / len(nb)
            else:
                nxt[v.index] = occl[v.index]
        occl = nxt
    for f in bm.faces:
        lens = [e.calc_length() for e in f.edges]
        narrow = min(lens) < 0.0075 and max(lens) > 2.5 * min(lens)
        convex = any(len(e.link_faces) == 2 and e.calc_face_angle_signed(0.0) > 0.15 for e in f.edges)
        for l in f.loops:
            v = l.vert
            n = mathutils.noise.noise(v.co * 18.0)
            edge = (0.6 + 0.4 * n) if (bevelled and narrow and convex) else 0.0
            concave = max([-e.calc_face_angle_signed(0.0) for e in v.link_edges if len(e.link_faces) == 2] + [0.0])
            grime = min(1.0, max(0.0, 0.6 - v.co.z) * 1.4 + min(1.0, concave / 1.2) * 0.35 + 0.15 * n)
            if v.index not in lit:
                lit[v.index] = _cabin_light(v.co.copy(), v.normal.copy())
            l[col] = (max(0.0, edge), max(0.0, grime), occl[v.index], lit[v.index])

def bake_and_merge():
    global _LIGHT_BVH, _AO_BVH
    dg = bpy.context.evaluated_depsgraph_get()
    # one BVH of the whole cockpit (world space) for the baked floodlight's shadow rays
    verts, polys = [], []
    av, ap = [], []
    for ob in COL.objects:
        if ob.type != "MESH" or ob.name.startswith(("CNP_Glass", "WS_Glass")) or "Glass" in ob.name:
            continue
        me = ob.evaluated_get(dg).to_mesh()
        mw = ob.matrix_world
        base = len(verts)
        wv = [mw @ v.co for v in me.vertices]
        verts += wv
        polys += [[base + i for i in p.vertices] for p in me.polygons]
        # ambient occlusion comes only from the large structure (panel, hood, consoles, walls, seat)
        if wv:
            lo = Vector((min(v.x for v in wv), min(v.y for v in wv), min(v.z for v in wv)))
            hi = Vector((max(v.x for v in wv), max(v.y for v in wv), max(v.z for v in wv)))
            if (hi - lo).length > 0.3:
                b2 = len(av)
                av += wv
                ap += [[b2 + i for i in p.vertices] for p in me.polygons]
        ob.evaluated_get(dg).to_mesh_clear()
    _AO_BVH = mathutils.bvhtree.BVHTree.FromPolygons(av, ap, all_triangles=False)
    _LIGHT_BVH = mathutils.bvhtree.BVHTree.FromPolygons(verts, polys, all_triangles=False)
    print("CABIN_BVH", len(verts), len(polys))
    # parts the game moves or lights stay separate objects: apply their modifiers and give them the wear mask too
    for ob in list(COL.objects):
        if ob.type != "MESH" or not ob.name.startswith(KEEP):
            continue
        bevelled = any(m.type == "BEVEL" for m in ob.modifiers)
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
        bm = bmesh.new(); bm.from_mesh(me)
        mw = ob.matrix_world.copy()
        bm.transform(mw); _wear(bm, ob.name, bevelled); bm.transform(mw.inverted())
        bm.to_mesh(me); bm.free()
        if me.color_attributes:
            me.color_attributes.active_color_index = 0
            me.color_attributes.render_color_index = 0
        ob.modifiers.clear(); ob.data = me
    groups = {}
    for ob in list(COL.objects):
        if ob.type != "MESH" or ob.name.startswith(KEEP):
            continue
        mats = [m for m in ob.data.materials]
        if len(mats) != 1 or ob.name.startswith(("CNP_Glass", "WS_Glass")):
            continue  # multi-material glass stays whole
        mv = _mover(ob)
        key = (mv.name if mv else "", mats[0].name)
        bevelled = any(m.type == "BEVEL" for m in ob.modifiers)
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
        bm = bmesh.new(); bm.from_mesh(me); bpy.data.meshes.remove(me)
        bm.transform(ob.matrix_world)
        _wear(bm, ob.name, bevelled)
        g = groups.setdefault(key, [])
        tmp = bpy.data.meshes.new("tmp"); bm.to_mesh(tmp); bm.free(); g.append(tmp)
        bpy.data.objects.remove(ob)
    for (mv, mname), meshes in groups.items():
        bm = bmesh.new()
        for me in meshes:
            bm.from_mesh(me); bpy.data.meshes.remove(me)
        root = bpy.data.objects.get(mv) if mv else None
        if root:
            bm.transform(root.matrix_world.inverted())
        name = ("%s_%s" % (mv, mname)) if mv else ("Static_%s" % mname)
        me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
        if me.color_attributes:
            me.color_attributes.active_color_index = 0
            me.color_attributes.render_color_index = 0
        ob = bpy.data.objects.new(name, me); COL.objects.link(ob)
        me.materials.append(bpy.data.materials[mname])
        if root:
            ob.parent = root; ob.matrix_parent_inverse = Matrix(); ob.matrix_basis = Matrix()
    # remaining kept meshes still carry bevel modifiers: the exporter applies them
    for ob in list(bpy.data.objects):
        if ob.name not in COL.objects:
            bpy.data.objects.remove(ob)

if "--export" in ARGS:
    bake_and_merge()
    out = os.path.join(TEX, "su27_cockpit.glb")
    kw = dict(filepath=out, export_format="GLB", export_apply=True, export_yup=True, export_extras=True)
    opts = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    if "export_image_format" in opts:
        kw["export_image_format"] = "NONE"
    if "export_vertex_color" in opts:
        kw["export_vertex_color"] = "ACTIVE"
    elif "export_colors" in opts:
        kw["export_colors"] = True
    if "export_active_vertex_color_when_no_material" in opts:
        kw["export_active_vertex_color_when_no_material"] = True
    print("GLTF_OPTS", sorted(k for k in kw if k != "filepath"))
    bpy.ops.export_scene.gltf(**kw)
    print("EXPORT_OK", out, len(COL.objects))
print("BUILD_OK", len(bpy.data.objects))
