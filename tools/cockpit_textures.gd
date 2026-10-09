extends SceneTree
## Generates the Su-27S cockpit instrument faces (instruments.png, 4096 px, 8x8 cells of 512) and the label sheet
## (labels.png, 2048 px, 8x32 cells of 256x64), plus cells.json for the Blender build script.
## Run: Godot --path . --script res://tools/cockpit_textures.gd   (needs a window: it renders with the GPU)

const OUT := "res://assets/aircraft/su27_cockpit/"
const W := Color(0.93, 0.91, 0.84)
const DIM := Color(0.62, 0.62, 0.58)
const RED := Color(0.86, 0.2, 0.14)
const GREEN := Color(0.3, 0.72, 0.38)
const AMBER := Color(0.95, 0.68, 0.18)
const FACE := Color(0.05, 0.053, 0.058)

const LABELS := [
	"FIRE L", "FIRE R", "LOW FUEL", "GEN FAIL", "HYD 1", "HYD 2", "OIL PRESS", "SDU",
	"ACS FAIL", "STALL", "CANOPY", "O2 LOW", "BRAKE", "OVERSPEED", "G LIMIT", "EMERG",
	"GEAR", "FLAPS", "AIRBRAKE", "AB L", "AB R", "START", "AUTO", "NAV",
	"BVR", "WVR", "GND", "ACS", "READY", "LAUNCH", "LOCK", "LEVEL",
	"TRIM P", "TRIM R", "TRIM Y", "RETURN", "LANDING", "ALT HOLD", "ATT HOLD", "RESET",
	"R-27R", "R-27T", "R-27ER", "R-27ET", "R-73", "GUN", "CHAFF", "FLARE",
	"ENGINE START", "LEFT", "RIGHT", "FUEL", "PUMPS", "XFEED", "IGNITION", "ARM",
	"SAFE", "ON", "OFF", "MAN", "BATT", "GEN", "AC", "DC",
	"EXT PWR", "RADIO", "VOL", "SQL", "CHAN", "ILS", "RSBN", "LIGHTS",
	"PANEL", "FLOOD", "CONSOLE", "INSTR", "NAV LTS", "STROBE", "TAXI", "OXYGEN",
	"100%", "NORMAL", "PRESS", "DEFOG", "COMM", "IFF", "MODE", "CODE",
	"TEST", "BRT", "DIM", "DAY", "NIGHT", "GRID", "HUD", "SEAT",
	"OPEN", "CLOSE", "JETT", "EJECT", "PULL TO EJECT", "MASTER ARM", "CM", "PROGRAM",
	"DISP", "RADAR", "IRST", "LASER", "STBY", "EMIT", "SCAN", "COMPASS",
	"UP", "DOWN", "EMERG GEAR", "PARK BRAKE", "CHUTE", "TRIM", "AP", "DISENGAGE",
	"ALT", "ATT", "RTB", "LAND", "FUEL DUMP", "IDLE", "MIL", "MAX",
	"DIRECT", "AOA LIM", "MODES", "WEAPONS", "ENG MODE", "COMBAT", "TRAINING", "ANTI-ICE",
	"PITOT HEAT", "INTAKE", "AUTO", "HYDRAULICS", "ELECTRICAL", "EMERG HYD", "WING FLAP", "TAKEOFF",
	"CHAN 1", "CHAN 2", "CHAN 3", "CHAN 4", "1", "2", "3", "4",
	"5", "6", "7", "8", "9", "0", "ENT", "CLR",
	"WPT", "AIRFLD", "TGT", "MARK", "DATA", "MAP", "SCALE", "RECORD",
	"WARNING", "CAUTION", "MASTER", "INCR", "DECR", "CANOPY LOCK", "SEAT HEIGHT", "HARNESS",
	"BAILOUT", "SPO-15", "EKRAN", "HDD", "CRS", "DIST", "HDG", "ALT M",
]

var vp: SubViewport
var cells := {}


class Painter extends Control:
	var jobs: Array = []
	func _draw() -> void:
		for j in jobs:
			j.call(self)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var f_bold: Font = load("res://assets/fonts/Rajdhani-Bold.ttf")
	var f_semi: Font = load("res://assets/fonts/Rajdhani-SemiBold.ttf")
	# ---------------------------------------------------------------- instruments
	var img := await _render(4096, 4096, func(p: Painter): _instruments(p, f_bold, f_semi))
	img.save_png(OUT + "instruments.png")
	# ---------------------------------------------------------------- labels
	var lab := await _render(2048, 2048, func(p: Painter): _labels(p, f_bold))
	lab.save_png(OUT + "labels.png")
	var f := FileAccess.open(OUT + "cells.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(cells, "  "))
	f.close()
	quit()


func _render(w: int, h: int, fill: Callable) -> Image:
	vp = SubViewport.new()
	vp.size = Vector2i(w, h)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	root.add_child(vp)
	var p := Painter.new()
	p.size = Vector2(w, h)
	vp.add_child(p)
	fill.call(p)
	p.queue_redraw()
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


# ======================================================================= helpers
static func pt(c: Vector2, r: float, a: float) -> Vector2:
	return c + Vector2(sin(deg_to_rad(a)), -cos(deg_to_rad(a))) * r


static func text(p: Painter, f: Font, pos: Vector2, s: String, size: int, col: Color) -> void:
	var sz := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	p.draw_string(f, pos + Vector2(-sz.x * 0.5, f.get_ascent(size) * 0.5 - f.get_descent(size) * 0.35), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func arc_band(p: Painter, c: Vector2, r: float, a0: float, a1: float, w: float, col: Color) -> void:
	var pts := PackedVector2Array()
	var n := maxi(int(absf(a1 - a0) / 2.0), 2)
	for i in n + 1:
		pts.append(pt(c, r, lerpf(a0, a1, float(i) / n)))
	p.draw_polyline(pts, col, w, true)


## Ticks and numbers along an arc. map: value -> angle (degrees clockwise from 12 o'clock).
static func scale(p: Painter, f: Font, c: Vector2, r: float, v0: float, v1: float, minor: float, major: float, labels: Array,
		map: Callable, label_r: float, size: int, col: Color = W, fmt: Callable = Callable()) -> void:
	var v := v0
	var guard := 0
	while v <= v1 + 1e-4 and guard < 2000:
		var a: float = map.call(v)
		var is_major := absf(fmod(absf(v - v0) + 1e-4, major)) < 2e-3 or absf(fmod(absf(v - v0) + 1e-4, major) - major) < 2e-3
		var len := 26.0 if is_major else 13.0
		p.draw_line(pt(c, r, a), pt(c, r - len, a), col, 5.0 if is_major else 2.5, true)
		v += minor
		guard += 1
	for lv in labels:
		var s: String = fmt.call(lv) if fmt.is_valid() else str(lv)
		text(p, f, pt(c, label_r, map.call(float(lv))), s, size, col)


static func face(p: Painter, c: Vector2, r: float, noise: Texture2D, center_clear := 0.0) -> void:
	# deep matte face with a little falloff to the rim, worn by dust
	for i in 8:
		var k := float(i) / 7.0
		p.draw_circle(c, r * (1.0 - k * 0.35), FACE.lerp(Color(0.085, 0.088, 0.092), k * 0.6))
	if noise:
		p.draw_texture_rect(noise, Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0), false, Color(1, 0.95, 0.85, 0.07))
	p.draw_arc(c, r - 2.0, 0.0, TAU, 128, Color(0, 0, 0, 0.9), 6.0, true)


static func cell_c(col: int, row: int) -> Vector2:
	return Vector2(col * 512 + 256, row * 512 + 256)


# ======================================================================= instruments
func _instruments(p: Painter, fb: Font, fs: Font) -> void:
	var nz := FastNoiseLite.new()
	nz.frequency = 0.03
	nz.fractal_octaves = 5
	var nimg := nz.get_image(512, 512)
	var noise := ImageTexture.create_from_image(nimg)
	var R := 236.0
	var reg := func(name: String, col: int, row: int, w := 1, h := 1):
		cells[name] = [col * 512, row * 512, w * 512, h * 512]

	# ---- AOA / G (УУА-1): AoA on the left arc, G on the right
	reg.call("AOA_G", 0, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(0, 0)
		face(pp, c, R, noise)
		var am := func(v): return lerpf(205.0, 335.0, (v + 10.0) / 45.0)
		var gm := func(v): return lerpf(155.0, 25.0, (v + 2.0) / 12.0)
		arc_band(pp, c, R - 14, am.call(25.0), am.call(35.0), 12.0, RED)
		arc_band(pp, c, R - 14, gm.call(9.0), gm.call(10.0), 12.0, RED)
		scale(pp, fb, c, R - 8, -10, 35, 1, 5, [-10, 0, 10, 20, 30], am, 165, 40)
		scale(pp, fb, c, R - 8, -2, 10, 0.5, 1, [-2, 0, 2, 4, 6, 8, 10], gm, 165, 40)
		text(pp, fb, c + Vector2(-70, -70), "AOA°", 30, DIM)
		text(pp, fb, c + Vector2(72, -70), "G", 34, DIM)
		text(pp, fs, c + Vector2(0, 120), "AOA · G", 24, DIM))

	# ---- IAS / Mach (КУС-2500)
	reg.call("IAS", 1, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(1, 0)
		face(pp, c, R, noise)
		var m := func(v): return -150.0 + v / 1600.0 * 300.0
		scale(pp, fb, c, R - 8, 0, 1600, 50, 100, [0, 200, 400, 600, 800, 1000, 1200, 1400, 1600], m, 172, 32, W, func(v): return str(int(v / 100)))
		var mm := func(v): return -135.0 + (v - 0.6) / 2.4 * 270.0
		pp.draw_arc(c, 118, 0, TAU, 96, Color(1, 1, 1, 0.08), 2.0, true)
		scale(pp, fb, c, 116, 0.6, 3.0, 0.1, 0.2, [0.6, 1.0, 1.4, 2.0, 2.6, 3.0], mm, 86, 22, W, func(v): return ("%.1f" % v))
		text(pp, fb, c + Vector2(0, 30), "KM/H ×100", 20, DIM)
		text(pp, fb, c + Vector2(0, 160), "IAS · M", 24, DIM))

	# ---- Radar altimeter
	reg.call("RADALT", 2, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(2, 0)
		face(pp, c, R, noise)
		var m := func(v):
			if v <= 100.0:
				return -150.0 + v / 100.0 * 180.0
			return 30.0 + log(v / 100.0) / log(10.0) * 120.0
		arc_band(pp, c, R - 14, m.call(0.0), m.call(50.0), 10.0, Color(RED, 0.8))
		scale(pp, fb, c, R - 8, 0, 100, 5, 10, [0, 20, 40, 60, 80, 100], m, 172, 34)
		for v in [150, 200, 300, 400, 500, 600, 700, 800, 900, 1000]:
			var a: float = m.call(float(v))
			pp.draw_line(pt(c, R - 8, a), pt(c, R - 30, a), W, 5.0, true)
		for v in [200, 300, 500, 1000]:
			text(pp, fb, pt(c, 168, m.call(float(v))), str(v), 30, W)
		pp.draw_rect(Rect2(c + Vector2(-40, -110), Vector2(80, 40)), Color(0.02, 0.02, 0.02))
		text(pp, fb, c + Vector2(0, -90), "OFF", 26, RED)
		text(pp, fb, c + Vector2(0, 70), "RAD ALT", 26, DIM)
		text(pp, fs, c + Vector2(0, 100), "M", 24, DIM))

	# ---- Barometric altimeter (ВМ-15): long needle 1000 m a turn, short needle 10 km a turn
	reg.call("BARO", 3, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(3, 0)
		face(pp, c, R, noise)
		var m := func(v): return v / 1000.0 * 360.0
		scale(pp, fb, c, R - 8, 0, 980, 20, 100, [], m, 0, 0)
		for d in 10:
			text(pp, fb, pt(c, 170, d * 36.0), str(d), 48, W)
		pp.draw_rect(Rect2(c + Vector2(-56, 64), Vector2(112, 44)), Color(0.02, 0.02, 0.02))
		pp.draw_rect(Rect2(c + Vector2(-56, 64), Vector2(112, 44)), Color(1, 1, 1, 0.25), false, 2.0)
		text(pp, fb, c + Vector2(0, 86), "760", 32, W)
		text(pp, fb, c + Vector2(0, -78), "ALT", 26, DIM)
		text(pp, fs, c + Vector2(0, -50), "M ×100 · KM", 20, DIM)
		text(pp, fs, c + Vector2(0, 130), "MM HG", 18, DIM))

	# ---- Vertical speed (ВАР-150) with slip ball tube
	reg.call("VVI", 4, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(4, 0)
		face(pp, c, R, noise)
		var m := func(v):
			var av := absf(v)
			var d := 0.0
			if av <= 10.0:
				d = av / 10.0 * 60.0
			elif av <= 50.0:
				d = 60.0 + (av - 10.0) / 40.0 * 60.0
			else:
				d = 120.0 + (av - 50.0) / 100.0 * 40.0
			return 270.0 + d * signf(v) if v != 0.0 else 270.0
		for s in [-1.0, 1.0]:
			for v in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30, 35, 40, 45, 50, 75, 100, 125, 150]:
				var a: float = m.call(s * v)
				var big: bool = v in [5, 10, 20, 50, 100, 150]
				pp.draw_line(pt(c, R - 8, a), pt(c, R - (32 if big else 16), a), W, 5.0 if big else 2.5, true)
			for v in [5, 10, 20, 50, 100, 150]:
				text(pp, fb, pt(c, 172, m.call(s * v)), str(v), 30, W)
		pp.draw_line(pt(c, R - 8, 270), pt(c, R - 40, 270), W, 7.0, true)
		text(pp, fb, pt(c, 172, 270), "0", 34, W)
		text(pp, fb, c + Vector2(-20, -60), "UP", 24, DIM)
		text(pp, fb, c + Vector2(-20, 40), "DN", 24, DIM)
		text(pp, fs, c + Vector2(40, -10), "V/S  M/S", 20, DIM)
		# slip indicator tube
		var tube := PackedVector2Array()
		for i in 21:
			var t := lerpf(-1, 1, i / 20.0)
			tube.append(c + Vector2(-20 + t * 70, 92 + (1.0 - t * t) * 12.0))
		pp.draw_polyline(tube, Color(0.6, 0.6, 0.55, 0.7), 30.0, true)
		pp.draw_polyline(tube, Color(0.12, 0.12, 0.11), 24.0, true)
		pp.draw_line(c + Vector2(-34, 88), c + Vector2(-34, 120), Color(0, 0, 0), 3.0)
		pp.draw_line(c + Vector2(-6, 88), c + Vector2(-6, 120), Color(0, 0, 0), 3.0))

	# ---- Engine RPM, two needles
	reg.call("RPM", 5, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(5, 0)
		face(pp, c, R, noise)
		var m := func(v): return -135.0 + v / 110.0 * 270.0
		arc_band(pp, c, R - 14, m.call(70.0), m.call(100.0), 10.0, Color(GREEN, 0.8))
		arc_band(pp, c, R - 14, m.call(103.0), m.call(110.0), 10.0, RED)
		scale(pp, fb, c, R - 8, 0, 110, 2, 10, [0, 20, 40, 60, 80, 100], m, 168, 36)
		text(pp, fb, c + Vector2(0, 72), "RPM %", 28, DIM)
		text(pp, fs, c + Vector2(0, 104), "ENG  1 · 2", 20, DIM))

	# ---- EGT, two needles
	reg.call("EGT", 6, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(6, 0)
		face(pp, c, R, noise)
		var m := func(v): return -135.0 + (v - 300.0) / 800.0 * 270.0
		arc_band(pp, c, R - 14, m.call(1000.0), m.call(1100.0), 10.0, RED)
		scale(pp, fb, c, R - 8, 300, 1100, 20, 100, [300, 500, 700, 900, 1100], m, 166, 32)
		text(pp, fb, c + Vector2(0, 72), "EGT °C", 28, DIM)
		text(pp, fs, c + Vector2(0, 104), "L · R", 20, DIM))

	# ---- Clock
	reg.call("CLOCK", 7, 0)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(7, 0)
		face(pp, c, R, noise)
		var m := func(v): return v / 60.0 * 360.0
		scale(pp, fb, c, R - 8, 0, 59, 1, 5, [], m, 0, 0)
		for h in range(1, 13):
			text(pp, fb, pt(c, 168, h * 30.0), str(h), 46, W)
		pp.draw_arc(c + Vector2(0, 70), 44, 0, TAU, 48, Color(1, 1, 1, 0.35), 2.0, true)
		text(pp, fs, c + Vector2(0, -80), "CLOCK", 20, DIM))

	# ---- Small gauges: flaps, cabin, oxygen, brakes, hydraulics
	reg.call("FLAPS", 0, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(0, 1)
		face(pp, c, R, noise)
		var m := func(v): return -90.0 + v / 30.0 * 180.0
		scale(pp, fb, c, R - 8, 0, 30, 1, 5, [0, 10, 20, 30], m, 166, 40)
		text(pp, fb, c + Vector2(0, 80), "FLAPS °", 30, DIM))
	reg.call("CABIN", 1, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(1, 1)
		face(pp, c, R, noise)
		var m1 := func(v): return -80.0 + v / 20.0 * 160.0
		scale(pp, fb, c, R - 8, 0, 20, 1, 5, [0, 5, 10, 15, 20], m1, 172, 32)
		var m2 := func(v): return 260.0 - (v + 0.1) / 0.7 * 160.0
		scale(pp, fb, c, R - 8, -0.1, 0.6, 0.05, 0.1, [0.0, 0.2, 0.4, 0.6], m2, 172, 28, W, func(v): return ("%.1f" % v))
		text(pp, fb, c + Vector2(0, -60), "CABIN KM", 22, DIM)
		text(pp, fb, c + Vector2(0, 60), "ΔP KG/CM²", 20, DIM))
	reg.call("OXY", 2, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(2, 1)
		face(pp, c, R, noise)
		var m := func(v): return -135.0 + v / 150.0 * 270.0
		arc_band(pp, c, R - 14, m.call(0.0), m.call(20.0), 10.0, RED)
		scale(pp, fb, c, R - 8, 0, 150, 5, 25, [0, 50, 100, 150], m, 168, 36)
		text(pp, fb, c + Vector2(0, 76), "O₂", 34, DIM)
		text(pp, fs, c + Vector2(0, 108), "KG/CM²", 20, DIM))
	reg.call("BRAKE", 3, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(3, 1)
		face(pp, c, R, noise)
		var m := func(v): return -135.0 + v / 16.0 * 270.0
		scale(pp, fb, c, R - 8, 0, 16, 0.5, 2, [0, 4, 8, 12, 16], m, 168, 36)
		text(pp, fb, c + Vector2(0, 76), "BRAKE", 28, DIM)
		text(pp, fs, c + Vector2(0, 106), "L · R  KG/CM²", 18, DIM))
	reg.call("HYD", 4, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(4, 1)
		face(pp, c, R, noise)
		var m := func(v): return -135.0 + v / 300.0 * 270.0
		arc_band(pp, c, R - 14, m.call(200.0), m.call(240.0), 10.0, Color(GREEN, 0.8))
		scale(pp, fb, c, R - 8, 0, 300, 10, 50, [0, 100, 200, 300], m, 168, 36)
		text(pp, fb, c + Vector2(0, 76), "HYD", 30, DIM)
		text(pp, fs, c + Vector2(0, 106), "1 · 2  KG/CM²", 18, DIM))

	# ---- ADI bezel (transparent centre over the ball), bank scale on top
	reg.call("ADI_BEZEL", 5, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(5, 1)
		pp.draw_arc(c, 218, 0, TAU, 128, Color(0.06, 0.062, 0.066), 40.0, true)
		for b in [-90, -60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60, 90]:
			var big: bool = absi(b) in [0, 30, 60, 90]
			pp.draw_line(pt(c, 236, b), pt(c, 236 - (34 if big else 20), b), W, 6.0 if big else 3.5, true)
		var tri := PackedVector2Array([pt(c, 196, 0), pt(c, 236, -4), pt(c, 236, 4)])
		pp.draw_colored_polygon(tri, W))

	# ---- HSI compass card (rotates) and fixed overlay
	reg.call("HSI_CARD", 6, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(6, 1)
		pp.draw_circle(c, 236, FACE)
		pp.draw_texture_rect(noise, Rect2(c - Vector2(236, 236), Vector2(472, 472)), false, Color(1, 0.95, 0.85, 0.06))
		for d in range(0, 360, 5):
			var big := d % 10 == 0
			pp.draw_line(pt(c, 232, d), pt(c, 232 - (28 if big else 15), d), W, 4.5 if big else 2.5, true)
		for d in range(0, 360, 30):
			var s := str(d / 10)
			match d:
				0: s = "N"
				90: s = "E"
				180: s = "S"
				270: s = "W"
			text(pp, fb, pt(c, 176, d), s, 44 if s.length() == 1 else 38, W if s.length() > 1 or not s in ["N", "E", "S", "W"] else AMBER))
	reg.call("HSI_FACE", 7, 1)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(7, 1)
		for a in range(0, 360, 45):
			pp.draw_line(pt(c, 250, a), pt(c, 238, a), W, 5.0, true)
		pp.draw_colored_polygon(PackedVector2Array([pt(c, 236, 0), pt(c, 252, -3), pt(c, 252, 3)]), AMBER)
		for corner in [[Vector2(-250, -250), "CRS", "000"], [Vector2(150, -250), "DIST", "000"]]:
			var o: Vector2 = c + corner[0]
			pp.draw_rect(Rect2(o, Vector2(100, 70)), Color(0.04, 0.04, 0.045))
			text(pp, fb, o + Vector2(50, 18), corner[1], 18, DIM)
			text(pp, fb, o + Vector2(50, 48), corner[2], 28, W))

	# ---- ADI ball (equirectangular, 1024 x 512): sky above, earth below, pitch ladder
	reg.call("ADI_BALL", 0, 2, 2, 1)
	p.jobs.append(func(pp: Painter):
		var o := Vector2(0, 1024)
		var sky := Color(0.42, 0.52, 0.6)
		var earth := Color(0.19, 0.12, 0.07)
		pp.draw_rect(Rect2(o, Vector2(1024, 256)), sky)
		pp.draw_rect(Rect2(o + Vector2(0, 256), Vector2(1024, 256)), earth)
		pp.draw_texture_rect(noise, Rect2(o, Vector2(1024, 512)), true, Color(1, 1, 1, 0.06))
		pp.draw_line(o + Vector2(0, 256), o + Vector2(1024, 256), W, 5.0)
		for pitch in range(-80, 90, 10):
			if pitch == 0:
				continue
			var y := 256.0 - pitch / 90.0 * 256.0
			var col := Color(0.08, 0.08, 0.08) if pitch > 0 else W
			for cx in [256.0, 768.0]:
				pp.draw_line(o + Vector2(cx - 34, y), o + Vector2(cx + 34, y), col, 3.0)
				text(pp, fb, o + Vector2(cx - 58, y), str(absi(pitch)), 18, col)
				text(pp, fb, o + Vector2(cx + 58, y), str(absi(pitch)), 18, col)
			for cx in [256.0, 768.0]:
				pp.draw_line(o + Vector2(cx - 14, y - 128.0 / 9.0), o + Vector2(cx + 14, y - 128.0 / 9.0), col, 2.0))

	# ---- SPO-15 RWR face
	reg.call("RWR", 2, 2)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(2, 2)
		pp.draw_rect(Rect2(c - Vector2(250, 250), Vector2(500, 500)), Color(0.07, 0.072, 0.076))
		pp.draw_texture_rect(noise, Rect2(c - Vector2(250, 250), Vector2(500, 500)), false, Color(1, 1, 1, 0.05))
		var ac := c + Vector2(0, -20)
		for a in [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330]:
			pp.draw_circle(pt(ac, 150, a), 13, Color(0.02, 0.02, 0.02))
			pp.draw_arc(pt(ac, 150, a), 13, 0, TAU, 24, Color(1, 1, 1, 0.3), 2.0, true)
		pp.draw_arc(ac, 110, 0, TAU, 96, Color(1, 1, 1, 0.18), 2.0, true)
		var plane := PackedVector2Array([ac + Vector2(0, -60), ac + Vector2(10, -20), ac + Vector2(60, 10), ac + Vector2(60, 20), ac + Vector2(10, 10), ac + Vector2(8, 40), ac + Vector2(24, 52), ac + Vector2(24, 58), ac + Vector2(0, 52), ac + Vector2(-24, 58), ac + Vector2(-24, 52), ac + Vector2(-8, 40), ac + Vector2(-10, 10), ac + Vector2(-60, 20), ac + Vector2(-60, 10), ac + Vector2(-10, -20)])
		pp.draw_colored_polygon(plane, Color(W, 0.55))
		var types := ["AIR", "LR", "MR", "SR", "EWR", "AWACS"]
		for i in types.size():
			var x := c.x - 200 + i * 80
			pp.draw_rect(Rect2(Vector2(x - 30, c.y + 168), Vector2(60, 40)), Color(0.02, 0.02, 0.02))
			text(pp, fb, Vector2(x, c.y + 222), types[i], 18, DIM)
		text(pp, fb, c + Vector2(0, -226), "SPO-15", 22, DIM))

	# ---- Mechanical devices indicator: gear, flaps, airbrake, intake screens
	reg.call("MECH", 3, 2)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(3, 2)
		pp.draw_rect(Rect2(c - Vector2(250, 250), Vector2(500, 500)), Color(0.07, 0.072, 0.076))
		var body := PackedVector2Array([c + Vector2(0, -200), c + Vector2(26, -120), c + Vector2(30, -20), c + Vector2(200, 60), c + Vector2(200, 90), c + Vector2(40, 80), c + Vector2(40, 150), c + Vector2(110, 200), c + Vector2(110, 215), c + Vector2(0, 200), c + Vector2(-110, 215), c + Vector2(-110, 200), c + Vector2(-40, 150), c + Vector2(-40, 80), c + Vector2(-200, 90), c + Vector2(-200, 60), c + Vector2(-30, -20), c + Vector2(-26, -120)])
		pp.draw_polyline(body + PackedVector2Array([body[0]]), Color(W, 0.6), 4.0, true)
		for w in [[Vector2(0, -110), "N"], [Vector2(-80, 40), "L"], [Vector2(80, 40), "R"]]:
			pp.draw_circle(c + w[0], 26, Color(0.02, 0.02, 0.02))
			pp.draw_arc(c + w[0], 26, 0, TAU, 32, Color(1, 1, 1, 0.3), 2.0, true)
			text(pp, fb, c + w[0] + Vector2(0, 46), w[1], 20, DIM)
		pp.draw_circle(c + Vector2(0, 30), 20, Color(0.02, 0.02, 0.02))
		text(pp, fb, c + Vector2(0, -236), "GEAR · FLAPS · AIRBRAKE", 18, DIM))

	# ---- Fuel quantity: two vertical scales with moving pointers
	reg.call("FUEL", 4, 2)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(4, 2)
		pp.draw_rect(Rect2(c - Vector2(250, 250), Vector2(500, 500)), Color(0.06, 0.062, 0.066))
		for col in [[-90.0, "TOTAL", 9.0], [90.0, "FEED", 1.5]]:
			var x := c.x + float(col[0])
			pp.draw_rect(Rect2(Vector2(x - 34, c.y - 200), Vector2(68, 380)), FACE)
			var top: float = col[2]
			var steps := 18 if top > 2.0 else 15
			for i in steps + 1:
				var y := c.y + 180 - i * (380.0 / steps)
				var big := i % 2 == 0
				pp.draw_line(Vector2(x - 34, y), Vector2(x - (12 if big else 22), y), W, 3.0)
				if big:
					text(pp, fb, Vector2(x + 14, y), ("%d" % (i / 2)) if top > 2.0 else ("%.1f" % (i * 0.1)), 22, W)
			text(pp, fb, Vector2(x, c.y + 214), col[1], 20, DIM)
		text(pp, fb, c + Vector2(0, -226), "FUEL ×1000 KG", 20, DIM))

	# ---- EKRAN message window and HDD screen surround
	reg.call("EKRAN", 5, 2)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(5, 2)
		pp.draw_rect(Rect2(c - Vector2(250, 150), Vector2(500, 300)), Color(0.07, 0.072, 0.076))
		pp.draw_rect(Rect2(c - Vector2(210, 90), Vector2(420, 180)), Color(0.02, 0.035, 0.03))
		text(pp, fb, c + Vector2(0, -122), "EKRAN", 22, DIM))
	reg.call("COMPASS_FACE", 6, 2)
	p.jobs.append(func(pp: Painter):
		var c := cell_c(6, 2)
		pp.draw_rect(Rect2(c - Vector2(250, 150), Vector2(500, 300)), Color(0.08, 0.08, 0.082))
		pp.draw_rect(Rect2(c - Vector2(180, 70), Vector2(360, 140)), Color(0, 0, 0, 0))
		pp.draw_line(c + Vector2(0, -90), c + Vector2(0, 90), AMBER, 5.0))

	# ---- Standby compass drum strip (2 cells wide)
	reg.call("COMPASS_DRUM", 0, 3, 2, 1)
	p.jobs.append(func(pp: Painter):
		var o := Vector2(0, 1536)
		pp.draw_rect(Rect2(o, Vector2(1024, 512)), Color(0.06, 0.06, 0.06))
		for d in range(0, 360, 5):
			var x := d / 360.0 * 1024.0
			var big := d % 10 == 0
			pp.draw_line(o + Vector2(x, 330), o + Vector2(x, 330 - (60 if big else 34)), W, 3.0)
		for d in range(0, 360, 30):
			var s := str(d / 10)
			match d:
				0: s = "N"
				90: s = "E"
				180: s = "S"
				270: s = "W"
			text(pp, fb, o + Vector2(d / 360.0 * 1024.0, 220), s, 56, W)
		text(pp, fb, o + Vector2(1024.0, 220), "N", 56, W))


# ======================================================================= labels (white on transparent)
func _labels(p: Painter, fb: Font) -> void:
	var lab := {}
	for i in LABELS.size():
		var col := i % 8
		var row := i / 8
		var s: String = LABELS[i]
		lab[s] = [col * 256, row * 64, 256, 64]
		p.jobs.append(func(pp: Painter):
			var size := 40
			while size > 14 and fb.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > 236:
				size -= 2
			text(pp, fb, Vector2(col * 256 + 128, row * 64 + 32), s, size, Color(1, 1, 1)))
	cells["_labels"] = lab
