extends RefCounted
## Shared materials for water and the menu cloud deck, built from seamless, mipmapped noise textures.
## Texture filtering (mipmaps + anisotropy) is what keeps them smooth at any distance.

const OCEAN_SHADER := preload("res://shaders/ocean.gdshader")
const CLOUD_SHADER := preload("res://shaders/menu_clouds.gdshader")

static var _normal_large: NoiseTexture2D
static var _normal_small: NoiseTexture2D
static var _clouds: NoiseTexture2D


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
	return m


static func clouds() -> ShaderMaterial:
	if _clouds == null:
		_clouds = _noise(1024, 0.004, 5, 303, false)
	var m := ShaderMaterial.new()
	m.shader = CLOUD_SHADER
	m.set_shader_parameter("cloud_tex", _clouds)
	return m
