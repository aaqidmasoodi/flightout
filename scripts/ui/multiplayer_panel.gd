extends Control
## Multiplayer: join a server by address, or host one on this computer. Up to 16 pilots per server, each
## starting parked in their own hardened shelter. (The official FlightOut server list arrives with the
## official servers; until then, join by address.)

signal closed
signal join_ready                     # connected and welcomed: the menu loads the flight
const T = preload("res://scripts/ui/ui_theme.gd")
const P = preload("res://scripts/net/protocol.gd")

var _callsign: LineEdit
var _address: LineEdit
var _status: Label
var _join: Button
var _host: Button
var _busy := false


func _ready() -> void:
	theme = T.get_theme()
	var glass := T.glass(0.70)
	glass.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(glass)
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 48)
	m.add_theme_constant_override("margin_top", 40)
	m.add_theme_constant_override("margin_bottom", 30)
	glass.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	m.add_child(col)
	col.add_child(T.label("MULTIPLAYER", 40, "Bold", T.TEXT, 6))
	col.add_child(T.label("Fly together on a server: up to %d pilots, each starting in their own shelter." % P.MAX_PLAYERS, 21, "Medium", T.DIM))
	col.add_child(_gap(10))
	col.add_child(T.label("CALLSIGN", 17, "Bold", T.DIM, 4))
	_callsign = _field(String(Settings.get_value("net/callsign")), "Your name in the sky", 20)
	col.add_child(_callsign)
	col.add_child(T.label("SERVER ADDRESS", 17, "Bold", T.DIM, 4))
	_address = _field(String(Settings.get_value("net/last_server")), "IP or host name, optional :port (default %d)" % P.DEFAULT_PORT, 80)
	col.add_child(_address)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_join = _action("JOIN", _on_join)
	row.add_child(_join)
	_host = _action("HOST A SERVER", _on_host)
	row.add_child(_host)
	col.add_child(row)
	_status = T.label("", 20, "Medium", T.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	var sp := Control.new(); sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)
	var note := T.label("Hosting runs a dedicated server in the background on UDP port %d. Friends outside your network need that port forwarded to this computer. Official FlightOut servers and a server browser are coming." % P.DEFAULT_PORT, 17, "Medium", Color(1, 1, 1, 0.38))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)
	var foot := HBoxContainer.new()
	var sp2 := Control.new(); sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp2)
	var back := Button.new(); back.text = "BACK"
	back.add_theme_font_override("font", T.spaced("Bold", 3))
	back.add_theme_font_size_override("font_size", 30)
	back.pressed.connect(_on_back)
	foot.add_child(back)
	col.add_child(foot)
	Game.client.joined.connect(_on_joined)
	Game.client.failed.connect(_on_failed)
	var notice := String(Game.get_meta("menu_notice", ""))
	if notice != "":
		Game.remove_meta("menu_notice")
		_say(notice, T.WARN)
	_join.call_deferred("grab_focus")


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _field(text: String, hint: String, max_len: int) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = hint
	e.max_length = max_len
	e.custom_minimum_size = Vector2(0, 56)
	e.add_theme_font_override("font", T.font("SemiBold"))
	e.add_theme_font_size_override("font_size", 24)
	return e


func _action(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", T.spaced("Bold", 3))
	b.add_theme_font_size_override("font_size", 30)
	b.custom_minimum_size = Vector2(0, 60)
	b.pressed.connect(cb)
	return b


func _say(text: String, col: Color = T.DIM) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", col)


func _name() -> String:
	var n := _callsign.text.strip_edges()
	if n == "":
		n = "Pilot %d" % (randi() % 900 + 100)
		_callsign.text = n
	Settings.set_value("net/callsign", n)
	return n


func _on_join() -> void:
	if _busy:
		return
	var addr := _address.text.strip_edges()
	if addr == "":
		_say("Enter the server's address.", T.WARN)
		return
	Settings.set_value("net/last_server", addr)
	_connect(addr)


func _on_host() -> void:
	if _busy:
		return
	var n := _name()
	if not Game.host_local_server("%s's server" % n):
		_say("Could not start the server.", T.BAD)
		return
	_say("Starting your server...")
	_busy = true
	await get_tree().create_timer(1.2).timeout
	_busy = false
	_connect("127.0.0.1:%d" % P.DEFAULT_PORT)


func _connect(addr: String) -> void:
	_busy = true
	_join.disabled = true
	_host.disabled = true
	_say("Connecting to %s..." % addr)
	Game.client.connect_to(addr, _name())


func _on_joined() -> void:
	_say("Joined %s. Taking you to shelter %02d." % [Game.client.server_name, Game.client.my_slot + 1], T.GOOD)
	join_ready.emit()


func _on_failed(reason: String) -> void:
	_busy = false
	_join.disabled = false
	_host.disabled = false
	_say(reason, T.BAD)


func _on_back() -> void:
	if Game.client.state == Game.client.CONNECTING:
		Game.client.disconnect_from_server("")
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		_on_back()
