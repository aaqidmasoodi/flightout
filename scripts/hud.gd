extends CanvasLayer
## Flight HUD.

var aircraft: Node3D
var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(20.0, 16.0)
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	add_child(_label)


func _process(_delta: float) -> void:
	if aircraft == null:
		return
	var a = aircraft
	var cam := get_viewport().get_camera_3d()
	var view_txt := ""
	if cam and "view_name" in cam:
		view_txt = cam.view_name
	var thr := "%d%%" % int(a.throttle * 100.0)
	if a.engine > 0.85:
		thr += "  AFTERBURNER"
	var lines := PackedStringArray()
	lines.append("SPEED    %d km/h    M %.2f" % [int(a.speed * 3.6), a.mach])
	lines.append("ALT      %d m       V/S %d m/s" % [int(a.global_position.y - 2.0), int(a.vertical_speed)])
	lines.append("G        %.1f       AoA %.1f deg" % [a.g_load, a.aoa_deg])
	lines.append("THROTTLE %s    THRUST %d kN" % [thr, int(a.thrust_now / 1000.0)])
	lines.append("GEAR %s    FLAPS %s    AIRBRAKE %s    BRAKES %s    RADAR %s    VIEW %s" % [
		"DOWN" if a.gear_down else "UP", "ON" if a.flaps else "OFF",
		"OUT" if a.airbrake else "IN", "ON" if a.wheel_brakes else "OFF",
		"ON" if a.radar_on else "OFF", view_txt])
	if a.aoa_deg > 22.0 and not a.on_ground:
		lines.append(">>> HIGH AoA / STALL WARNING <<<")
	if a.crashed:
		lines.append("*** CRASHED: %s. Press Backspace to reset ***" % a.crash_reason)
	lines.append("")
	lines.append("W/S pitch   A/D roll   Q/E yaw   Shift/Ctrl throttle (above 85% = afterburner)")
	lines.append("G gear   F flaps   B airbrake   Space wheel brakes   C canopy   R radar   T radome")
	lines.append("V view (close/far/cockpit)   Right-drag look   Wheel zoom   Backspace reset")
	_label.text = "\n".join(lines)
