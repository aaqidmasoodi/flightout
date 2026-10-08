extends RefCounted
## Image adjustments (brightness, contrast, gamma, saturation) from Settings, applied to any Environment.
## Gamma is a 1D colour-correction curve; the others are Godot's built-in adjustments.

static var _curve_gamma := -1.0
static var _curve: GradientTexture1D


static func apply(env: Environment, base_contrast: float = 1.0, base_saturation: float = 1.0) -> void:
	env.adjustment_enabled = true
	env.adjustment_brightness = float(Settings.get_value("display/brightness"))
	env.adjustment_contrast = float(Settings.get_value("display/contrast")) * base_contrast
	env.adjustment_saturation = float(Settings.get_value("display/saturation")) * base_saturation
	var g := float(Settings.get_value("display/gamma"))
	if absf(g - 1.0) < 0.001:
		env.adjustment_color_correction = null
	else:
		env.adjustment_color_correction = _gamma_curve(g)


static func _gamma_curve(g: float) -> GradientTexture1D:
	if _curve and absf(_curve_gamma - g) < 0.0001:
		return _curve
	var grad := Gradient.new()
	grad.remove_point(1)
	grad.set_offset(0, 0.0)
	grad.set_color(0, Color.BLACK)
	for i in range(1, 33):
		var x := i / 32.0
		var y := pow(x, 1.0 / g)
		grad.add_point(x, Color(y, y, y))
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	tex.width = 256
	_curve = tex
	_curve_gamma = g
	return tex
