extends RefCounted
## The ground the cloud layers are measured from (scripts/world/volumetric_clouds.gd, shaders/clouds_march.glsl).
##
## Weather in FlightOut gives each cloud layer a base and top in metres above the ground beneath it, not above sea
## level: Kashmir's valleys lie at 1,600 m and its plains at 200 m, so fixed heights put the overcast and the fog
## underground. But a cloud deck does not follow every ridge either: it is flat over a region, the mountains rise
## into and through it, and fog pools in the valleys. So the reference is the terrain smoothed over a region, in two
## versions:
##   r  "floor": the low ground of the area (valley floors and plains), from a minimum over a few kilometres, then
##      smoothed. Fog and low cloud sit on it and fill the valleys, the slopes rise out of it.
##   g  "mean": the average ground over about 25 km. Decks (overcast, rain) sit on a mix of the two, so in a valley
##      ringed by mountains the deck is a ceiling over the valley and the high ridges reach up through it.
## Built once per flight from the terrain's 256 m overview (on a worker thread: about half a second), at a 2 km grid.

const CELL := 2000.0                  # metres per cell of the reference grid
const FLOOR_R := 2                    # cells: minimum over this radius (a 10 km square) for the floor
const FLOOR_BLUR := 2                 # cells: then smoothed over this radius
const MEAN_BLUR := 6                  # cells: the mean is the average over this radius (about 25 km across)

static var texture: Texture2D         # RG: floor, mean (metres above sea level); a 1x1 zero until built
static var rect := Vector4(0.0, 0.0, 1.0, 1.0)   # x0, z0 (map metres of the image's corner), 1 / width, 1 / depth
static var lo := 0.0                  # lowest and highest reference anywhere (for the ray bounds)
static var hi := 0.0
static var ready := false
static var _img: Image
static var _w := 0
static var _h := 0
static var _floor := PackedFloat32Array()
static var _mean := PackedFloat32Array()
static var _task := -1
static var _gen := 0


static func _static_init() -> void:
	var img := Image.create(1, 1, false, Image.FORMAT_RGH)
	img.set_pixel(0, 0, Color(0.0, 0.0, 0.0))
	texture = ImageTexture.create_from_image(img)


## The terrain overview (R16: metres = value * 0.25 - 500, the encoding the terrain uses), its first sample's map
## position and spacing.
static func build(overview: Image, x0: float, z0: float, spacing: float) -> void:
	_gen += 1
	var gen := _gen
	var data := overview.get_data()
	var w := overview.get_width()
	var h := overview.get_height()
	_task = WorkerThreadPool.add_task(func(): _work(gen, data, w, h, x0, z0, spacing), false, "Cloud ground")


static func _work(gen: int, data: PackedByteArray, w: int, h: int, x0: float, z0: float, spacing: float) -> void:
	var f := maxi(int(round(CELL / spacing)), 1)
	var cw := maxi(w / f, 1)
	var ch := maxi(h / f, 1)
	# average and minimum of each cell
	var avg := PackedFloat32Array()
	var mn := PackedFloat32Array()
	avg.resize(cw * ch)
	mn.resize(cw * ch)
	for cj in ch:
		for ci in cw:
			var s := 0.0
			var m := 1e9
			for j in f:
				var row := (cj * f + j) * w
				for i in f:
					var v := data.decode_u16((row + ci * f + i) * 2) * 0.25 - 500.0
					s += v
					m = minf(m, v)
			avg[cj * cw + ci] = s / float(f * f)
			mn[cj * cw + ci] = m
	# floor: the minimum around (valley floors), smoothed; never above the cell's own average
	var fl := _blur(_min_filter(mn, cw, ch, FLOOR_R), cw, ch, FLOOR_BLUR)
	var me := _blur(avg, cw, ch, MEAN_BLUR)
	for k in fl.size():
		fl[k] = minf(fl[k], me[k])
	var img := Image.create(cw, ch, false, Image.FORMAT_RGH)
	var l := 1e9
	var hgh := -1e9
	for cj in ch:
		for ci in cw:
			var k := cj * cw + ci
			img.set_pixel(ci, cj, Color(fl[k], me[k], 0.0))
			l = minf(l, fl[k])
			hgh = maxf(hgh, me[k])
	# texel centres on the cells' centres
	var cell := spacing * f
	var r := Vector4(x0 - spacing * 0.5, z0 - spacing * 0.5, 1.0 / (cw * cell), 1.0 / (ch * cell))
	_finish.call_deferred(gen, img, r, l, hgh, fl, me, cw, ch)


static func _finish(gen: int, img: Image, r: Vector4, l: float, hgh: float, fl: PackedFloat32Array, me: PackedFloat32Array, cw: int, ch: int) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if gen != _gen:
		return
	_img = img
	_floor = fl
	_mean = me
	_w = cw
	_h = ch
	rect = r
	lo = l
	hi = hgh
	texture = ImageTexture.create_from_image(img)
	ready = true
	print("CLOUDS ground reference %d x %d (floor %.0f .. mean %.0f m)" % [cw, ch, l, hgh])


## The reference at a map position: x floor, y mean (metres above sea level), interpolated as the GPU does.
static func at(x: float, z: float) -> Vector2:
	if not ready:
		return Vector2.ZERO
	var u := (x - rect.x) * rect.z * _w - 0.5
	var v := (z - rect.y) * rect.w * _h - 0.5
	var i := clampi(int(floor(u)), 0, _w - 1)
	var j := clampi(int(floor(v)), 0, _h - 1)
	var i1 := mini(i + 1, _w - 1)
	var j1 := mini(j + 1, _h - 1)
	var fu := clampf(u - floor(u), 0.0, 1.0)
	var fv := clampf(v - floor(v), 0.0, 1.0)
	var out := Vector2.ZERO
	for c in 2:
		var a: PackedFloat32Array = _floor if c == 0 else _mean
		var top := lerpf(a[j * _w + i], a[j * _w + i1], fu)
		var bot := lerpf(a[j1 * _w + i], a[j1 * _w + i1], fu)
		out[c] = lerpf(top, bot, fv)
	return out


static func _min_filter(a: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	# separable: rows, then columns
	var tmp := PackedFloat32Array()
	tmp.resize(a.size())
	for j in h:
		for i in w:
			var m := 1e9
			for d in range(-r, r + 1):
				m = minf(m, a[j * w + clampi(i + d, 0, w - 1)])
			tmp[j * w + i] = m
	var out := PackedFloat32Array()
	out.resize(a.size())
	for j in h:
		for i in w:
			var m := 1e9
			for d in range(-r, r + 1):
				m = minf(m, tmp[clampi(j + d, 0, h - 1) * w + i])
			out[j * w + i] = m
	return out


static func _blur(a: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(a.size())
	var n := float(2 * r + 1)
	for j in h:
		for i in w:
			var s := 0.0
			for d in range(-r, r + 1):
				s += a[j * w + clampi(i + d, 0, w - 1)]
			tmp[j * w + i] = s / n
	var out := PackedFloat32Array()
	out.resize(a.size())
	for j in h:
		for i in w:
			var s := 0.0
			for d in range(-r, r + 1):
				s += tmp[clampi(j + d, 0, h - 1) * w + i]
			out[j * w + i] = s / n
	return out
