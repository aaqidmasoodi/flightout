extends RefCounted
## Shared materials for water and the menu cloud deck, built from seamless, mipmapped noise textures.
## Texture filtering (mipmaps + anisotropy) is what keeps them smooth at any distance.

const OCEAN_SHADER := preload("res://shaders/ocean.gdshader")
const CLOUD_SHADER := preload("res://shaders/menu_clouds.gdshader")

## Every ocean material created, so the sky system can update their distance haze.
static var ocean_materials: Array = []
static var _normal_large: NoiseTexture2D
static var _normal_small: NoiseTexture2D
static var _clouds: NoiseTexture2D
static var _sky_clouds: NoiseTexture2D
static var _puffs: ImageTexture


static func _noise(size: int, freq: float, octaves: int, seed: int, normal_map: bool, bump: float = 6.0) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	var t := NoiseTexture2D.new()
	t.width = size
	t.height = size
	t.seamless = true
	t.seamless_blend_skirt = 0.2
	t.generate_mipmaps = true
	t.as_normal_map = normal_map
	t.bump_strength = bump
	t.noise = n
	return t


static func ocean() -> ShaderMaterial:
	if _normal_large == null:
		_normal_large = _noise(512, 0.012, 4, 101, true, 5.0)
		_normal_small = _noise(512, 0.02, 3, 202, true, 4.0)
	var m := ShaderMaterial.new()
	m.shader = OCEAN_SHADER
	m.set_shader_parameter("normal_large", _normal_large)
	m.set_shader_parameter("normal_small", _normal_small)
	ocean_materials.append(m)
	return m


static func clouds() -> ShaderMaterial:
	if _clouds == null:
		_clouds = _noise(1024, 0.004, 5, 303, false)
	var m := ShaderMaterial.new()
	m.shader = CLOUD_SHADER
	m.set_shader_parameter("cloud_tex", _clouds)
	return m


static func sky_clouds() -> NoiseTexture2D:
	if _sky_clouds == null:
		_sky_clouds = _noise(1024, 0.005, 5, 404, false)
	return _sky_clouds


## 2x2 atlas of soft cumulus puff shapes. Alpha is the shape; red stores internal shading (lit top, darker base).
static func puff_atlas() -> ImageTexture:
	if _puffs:
		return _puffs
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.035
	n.fractal_octaves = 4
	var size := 256
	var img := Image.create(size * 2, size * 2, false, Image.FORMAT_RGBA8)
	for cell in 4:
		n.seed = 500 + cell
		var ox := (cell % 2) * size
		var oy := (cell / 2) * size
		for y in size:
			for x in size:
				var u := (x + 0.5) / size * 2.0 - 1.0
				var v := (y + 0.5) / size * 2.0 - 1.0
				var r := sqrt(u * u + v * v)
				var shape := 1.0 - smoothstep(0.35, 1.0, r + n.get_noise_2d(x, y) * 0.35)
				var a := clampf(shape * 1.25, 0.0, 1.0)
				a = a * a * (3.0 - 2.0 * a)
				var shade := clampf(0.55 - v * 0.45 + n.get_noise_2d(x * 2.0 + 50.0, y * 2.0) * 0.25, 0.0, 1.0)
				img.set_pixel(ox + x, oy + y, Color(shade, shade, shade, a))
	img.generate_mipmaps()
	_puffs = ImageTexture.create_from_image(img)
	return _puffs


static var _terrain_tex := {}


## Large-scale variation, fine detail and a detail normal map for the terrain shader.
static func terrain_textures() -> Dictionary:
	if _terrain_tex.is_empty():
		_terrain_tex = {
			"macro": _noise(1024, 0.006, 5, 611, false),
			"detail": _noise(512, 0.03, 4, 612, false),
			"normal": _noise(512, 0.03, 4, 613, true, 6.0),
		}
	return _terrain_tex


static var _volumes := {}


## 3D noise volumes for the raymarched clouds (Perlin, Worley, fine Worley detail) and a 2D weather map.
## Generated on worker threads; returns textures that may still be generating.
static func cloud_volumes() -> Dictionary:
	if not _volumes.is_empty():
		return _volumes
	var perlin := FastNoiseLite.new()
	perlin.noise_type = FastNoiseLite.TYPE_PERLIN
	perlin.frequency = 0.045
	perlin.fractal_type = FastNoiseLite.FRACTAL_FBM
	perlin.fractal_octaves = 4
	var worley := FastNoiseLite.new()
	worley.noise_type = FastNoiseLite.TYPE_CELLULAR
	worley.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	worley.frequency = 0.06
	worley.fractal_type = FastNoiseLite.FRACTAL_FBM
	worley.fractal_octaves = 3
	var detail := FastNoiseLite.new()
	detail.noise_type = FastNoiseLite.TYPE_CELLULAR
	detail.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
	detail.frequency = 0.14
	detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail.fractal_octaves = 2
	_volumes = {
		"perlin": _volume(96, perlin, false),
		"worley": _volume(96, worley, true),
		"detail": _volume(32, detail, true),
		"weather": _noise(512, 0.009, 4, 808, false),
		"blue": load("res://assets/clouds/blue_noise_64.png"),
	}
	return _volumes


static func _volume(size: int, n: FastNoiseLite, invert: bool) -> NoiseTexture3D:
	var t := NoiseTexture3D.new()
	t.width = size
	t.height = size
	t.depth = size
	t.seamless = true
	t.invert = invert
	t.normalize = true
	t.noise = n
	return t
