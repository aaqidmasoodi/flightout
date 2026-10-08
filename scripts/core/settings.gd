extends Node
## Settings (autoload): defaults, persistence in user://settings.cfg and live application.
## Menus write through set_value(); scenes that care read get_value() and listen to `changed`.

signal changed(key: String, value)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"display/window_mode": 0,        # 0 windowed, 1 borderless fullscreen, 2 exclusive fullscreen
	"display/vsync": true,
	"display/max_fps": 0,            # 0 = unlimited
	"display/render_scale": 1.0,
	"display/fov": 70.0,
	"graphics/msaa": 1,              # 0 off, 1 2x, 2 4x
	"graphics/shadows": true,
	"graphics/trees": true,
	"graphics/draw_distance": 1,     # 0 near, 1 medium, 2 far
	"hud/telemetry": true,
	"hud/key_hints": false,
	"hud/fps": false,
	"hud/unit_system": 1,            # 1 aviation (kt, ft, ft/min, NM), 0 metric (km/h, m, m/s, km)
	"controls/invert_pitch": false,
	"controls/mouse_sensitivity": 1.0,
	"audio/master": 0.8,
}

var _values := {}


func _enter_tree() -> void:
	_register_input()
	_values = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k in DEFAULTS.keys():
			var parts: PackedStringArray = String(k).split("/")
			if cfg.has_section_key(parts[0], parts[1]):
				_values[k] = cfg.get_value(parts[0], parts[1])


func _ready() -> void:
	DisplayServer.window_set_title("Yembera FlightOut")
	for k in _values.keys():
		_apply(k)


func get_value(key: String) -> Variant:
	return _values.get(key, DEFAULTS.get(key))


func set_value(key: String, value) -> void:
	if _values.get(key) == value:
		return
	_values[key] = value
	_apply(key)
	save()
	changed.emit(key, value)


func reset_defaults() -> void:
	for k in DEFAULTS.keys():
		set_value(k, DEFAULTS[k])


func save() -> void:
	var cfg := ConfigFile.new()
	for k in _values.keys():
		var parts: PackedStringArray = String(k).split("/")
		cfg.set_value(parts[0], parts[1], _values[k])
	cfg.save(PATH)


# ---------------- units ----------------
func speed_text(mps: float) -> Array:
	if int(get_value("hud/unit_system")) == 1:
		return ["%d" % int(mps * 1.94384), "KT"]
	return ["%d" % int(mps * 3.6), "KM/H"]


func alt_text(m: float) -> Array:
	if int(get_value("hud/unit_system")) == 1:
		return ["%d" % int(m * 3.28084), "FT"]
	return ["%d" % int(m), "M"]


func dist_text(m: float) -> Array:
	if int(get_value("hud/unit_system")) == 1:
		return ["%.1f" % (m / 1852.0), "NM"]
	return ["%.1f" % (m / 1000.0), "KM"]


func vs_text(mps: float) -> Array:
	if int(get_value("hud/unit_system")) == 1:
		return ["%+d" % int(mps * 196.85), "FT/MIN"]
	return ["%+.0f" % mps, "M/S"]


# ---------------- application ----------------
func _apply(key: String) -> void:
	var v = get_value(key)
	match key:
		"display/window_mode":
			var modes := [DisplayServer.WINDOW_MODE_WINDOWED, DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
			DisplayServer.window_set_mode(modes[clampi(int(v), 0, 2)])
		"display/vsync":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(v) else DisplayServer.VSYNC_DISABLED)
		"display/max_fps":
			Engine.max_fps = int(v)
		"display/render_scale":
			get_viewport().scaling_3d_scale = clampf(float(v), 0.5, 1.0)
		"graphics/msaa":
			var aa := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]
			get_viewport().msaa_3d = aa[clampi(int(v), 0, 2)]
		"audio/master":
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(float(v), 0.0001)))


# ---------------- input map (one place for every binding) ----------------
func _add_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)


func _register_input() -> void:
	_add_keys("pitch_up", [KEY_S, KEY_DOWN])
	_add_keys("pitch_down", [KEY_W, KEY_UP])
	_add_keys("roll_left", [KEY_A, KEY_LEFT])
	_add_keys("roll_right", [KEY_D, KEY_RIGHT])
	_add_keys("yaw_left", [KEY_Q])
	_add_keys("yaw_right", [KEY_E])
	_add_keys("throttle_up", [KEY_SHIFT])
	_add_keys("throttle_down", [KEY_CTRL])
	_add_keys("toggle_gear", [KEY_G])
	_add_keys("toggle_canopy", [KEY_C])
	_add_keys("toggle_airbrake", [KEY_B])
	_add_keys("toggle_flaps", [KEY_F])
	_add_keys("toggle_radar", [KEY_R])
	_add_keys("toggle_radome", [KEY_T])
	_add_keys("toggle_view", [KEY_V])
	_add_keys("reset", [KEY_BACKSPACE])
	_add_keys("wheel_brake", [KEY_SPACE])
	_add_keys("toggle_lights", [KEY_L])
	_add_keys("toggle_autothrottle", [KEY_Z])
	_add_keys("practice_approach", [KEY_P])
	_add_keys("toggle_hud", [KEY_H])
	_add_keys("pause_menu", [KEY_ESCAPE])


## Human-readable bindings for the settings screen.
const BINDINGS := [
	["Pitch down / up", "W / S"], ["Roll", "A / D"], ["Yaw / nose-wheel steering", "Q / E"],
	["Throttle up / down", "Shift / Ctrl"], ["Landing gear", "G"], ["Flaps", "F"], ["Airbrake", "B"],
	["Wheel brakes", "Space"], ["Auto-throttle", "Z"], ["Canopy", "C"], ["Exterior lights", "L"],
	["Radar scan", "R"], ["Radome", "T"], ["Camera view", "V"], ["Look around", "Right mouse drag"],
	["Zoom", "Mouse wheel"], ["Flight data panel", "H"], ["Practice approach", "P"],
	["Reset to runway", "Backspace"], ["Pause menu", "Esc"],
]
