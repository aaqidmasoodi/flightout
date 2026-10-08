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
	"audio/engine": 0.9,
	"audio/effects": 0.9,
	"audio/warnings": 0.9,
	"audio/ui": 0.7,
	"weather/wind": 1,                # 0 calm, 1 light, 2 moderate, 3 strong
	"weather/wind_from": 0.0,         # degrees the wind blows from (0 = north, a headwind on runway 36)
	"weather/turbulence": 1,          # 0 off, 1 light, 2 moderate, 3 severe
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
	reset_bindings()


func save() -> void:
	var cfg := ConfigFile.new()
	for k in _values.keys():
		var parts: PackedStringArray = String(k).split("/")
		cfg.set_value(parts[0], parts[1], _values[k])
	for a in bindings:
		cfg.set_value("bindings", a, bindings[a])
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


# ---------------- input map: rebindable keys ----------------
## Every rebindable action with up to two keys (primary, secondary). Saved in the [bindings] section.
const DEFAULT_BINDINGS := {
	"pitch_down": [KEY_W, KEY_UP], "pitch_up": [KEY_S, KEY_DOWN],
	"roll_left": [KEY_A, KEY_LEFT], "roll_right": [KEY_D, KEY_RIGHT],
	"yaw_left": [KEY_Q], "yaw_right": [KEY_E],
	"throttle_up": [KEY_SHIFT], "throttle_down": [KEY_CTRL],
	"toggle_gear": [KEY_G], "toggle_flaps": [KEY_F], "toggle_airbrake": [KEY_B], "wheel_brake": [KEY_SPACE],
	"toggle_autothrottle": [KEY_Z], "toggle_limiter": [KEY_K], "toggle_canopy": [KEY_C], "toggle_lights": [KEY_L],
	"toggle_radar": [KEY_R], "toggle_radome": [KEY_T], "toggle_view": [KEY_V], "toggle_hud": [KEY_H],
	"practice_approach": [KEY_P], "reset": [KEY_BACKSPACE],
}
## Settings screen layout: [section] or [action, label].
const BINDABLE := [
	["FLIGHT CONTROLS"], ["pitch_down", "Pitch down (nose down)"], ["pitch_up", "Pitch up (nose up)"],
	["roll_left", "Roll left"], ["roll_right", "Roll right"], ["yaw_left", "Yaw left / steer left"], ["yaw_right", "Yaw right / steer right"],
	["throttle_up", "Throttle up"], ["throttle_down", "Throttle down"],
	["SYSTEMS"], ["toggle_gear", "Landing gear"], ["toggle_flaps", "Flaps"], ["toggle_airbrake", "Airbrake"], ["wheel_brake", "Wheel brakes (hold)"],
	["toggle_autothrottle", "Auto-throttle"], ["toggle_limiter", "AoA limiter override (Cobra)"], ["toggle_canopy", "Canopy"],
	["toggle_lights", "Exterior lights"], ["toggle_radar", "Radar scan"], ["toggle_radome", "Radome"],
	["CAMERA AND GAME"], ["toggle_view", "Camera view"], ["toggle_hud", "Flight data panel"], ["practice_approach", "Practice approach"],
	["reset", "Reset to runway"],
]
const FIXED_BINDINGS := [["Look around", "RIGHT MOUSE"], ["Zoom", "MOUSE WHEEL"], ["Pause menu", "ESC"]]
const SHORT_NAMES := {"Space": "SPACE", "Shift": "SHIFT", "Ctrl": "CTRL", "Alt": "ALT", "BackSpace": "BKSP", "Backspace": "BKSP",
	"Escape": "ESC", "Enter": "ENTER", "Tab": "TAB", "Up": "UP", "Down": "DOWN", "Left": "LEFT", "Right": "RIGHT",
	"CapsLock": "CAPS", "Delete": "DEL", "Insert": "INS", "PageUp": "PGUP", "PageDown": "PGDN", "Home": "HOME", "End": "END"}

var bindings := {}


func _register_input() -> void:
	bindings = {}
	for a in DEFAULT_BINDINGS:
		bindings[a] = (DEFAULT_BINDINGS[a] as Array).duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK and cfg.has_section("bindings"):
		for a in DEFAULT_BINDINGS:
			if cfg.has_section_key("bindings", a):
				bindings[a] = Array(cfg.get_value("bindings", a))
	if not InputMap.has_action("pause_menu"):
		InputMap.add_action("pause_menu")
		var esc := InputEventKey.new()
		esc.physical_keycode = KEY_ESCAPE
		InputMap.action_add_event("pause_menu", esc)
	_apply_bindings()


func _apply_bindings() -> void:
	for a in bindings:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
		InputMap.action_erase_events(a)
		for k in bindings[a]:
			if int(k) == 0:
				continue
			var ev := InputEventKey.new()
			ev.physical_keycode = int(k)
			InputMap.action_add_event(a, ev)


## Binds a key to an action slot (0 primary, 1 secondary). A key used elsewhere is moved, as games do.
## Returns the label of the action the key was taken from ("" if none).
func bind_key(action: String, slot: int, keycode: int) -> String:
	var taken_from := ""
	for a in bindings:
		var arr: Array = bindings[a]
		for i in arr.size():
			if int(arr[i]) == keycode and not (a == action and i == slot):
				arr[i] = 0
				taken_from = action_label(a)
	var mine: Array = bindings[action]
	while mine.size() <= slot:
		mine.append(0)
	mine[slot] = keycode
	_apply_bindings()
	save()
	changed.emit("bindings", action)
	return taken_from


func clear_key(action: String, slot: int) -> void:
	var mine: Array = bindings[action]
	if slot < mine.size():
		mine[slot] = 0
	_apply_bindings()
	save()
	changed.emit("bindings", action)


func reset_bindings() -> void:
	for a in DEFAULT_BINDINGS:
		bindings[a] = (DEFAULT_BINDINGS[a] as Array).duplicate()
	_apply_bindings()
	save()
	changed.emit("bindings", "")


func key_name(keycode: int) -> String:
	if keycode == 0:
		return ""
	# map to the user's keyboard layout where the display server supports it (not on headless servers)
	var k := keycode
	if DisplayServer.get_name() != "headless":
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(keycode)
		if mapped != KEY_NONE:
			k = mapped
	var s := OS.get_keycode_string(k)
	return SHORT_NAMES.get(s, s.to_upper())


## Label for an action's key(s): primary only by default, e.g. "G"; with both=true "W / UP".
func key_label(action: String, both: bool = false) -> String:
	var names := []
	for k in bindings.get(action, []):
		if int(k) != 0:
			names.append(key_name(int(k)))
	if names.is_empty():
		return "--"
	return " / ".join(names) if both else names[0]


func action_label(action: String) -> String:
	for b in BINDABLE:
		if b.size() == 2 and b[0] == action:
			return b[1]
	return action
