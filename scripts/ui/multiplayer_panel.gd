extends Control
## Multiplayer: the official servers (live status, pilots, ping), join any server by address, or host one on this
## computer. Up to 16 pilots per server, each starting parked in their own hardened shelter.

signal closed
signal join_ready                     # connected and welcomed: the menu loads the flight
const T = preload("res://scripts/ui/ui_theme.gd")
const P = preload("res://scripts/net/protocol.gd")
const Probe = preload("res://scripts/net/probe.gd")
const REFRESH := 6.0

var _callsign: LineEdit
var _address: LineEdit
var _status: Label
var _host: Button
var _join_addr: Button
var _cards: Array = []                # [{"server", "probe", "dot", "detail", "join"}]
var _busy := false
var _refresh_t := 0.0


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
	col.add_theme_constant_override("separation", 12)
	m.add_child(col)
	col.add_child(T.label("MULTIPLAYER", 40, "Bold", T.TEXT, 6))
	col.add_child(T.label("Fly together: up to %d pilots a server, each starting in their own shelter." % P.MAX_PLAYERS, 21, "Medium", T.DIM))
	col.add_child(_gap(6))

	col.add_child(T.label("CALLSIGN", 16, "Bold", T.DIM, 4))
	_callsign = _field(String(Settings.get_value("net/callsign")), "Your name in the sky", 20)
	col.add_child(_callsign)
	col.add_child(_gap(8))

	col.add_child(T.label("OFFICIAL SERVERS", 16, "Bold", T.DIM, 4))
	for s in P.OFFICIAL_SERVERS:
		col.add_child(_server_card(s))
	col.add_child(_gap(8))

	col.add_child(T.label("JOIN BY ADDRESS", 16, "Bold", T.DIM, 4))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_address = _field(String(Settings.get_value("net/last_server")), "IP or host name, optional :port (default %d)" % P.DEFAULT_PORT, 80)
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_address.text_submitted.connect(func(_t): _on_join_address())
	row.add_child(_address)
	_join_addr = _action("JOIN", _on_join_address)
	_join_addr.custom_minimum_size = Vector2(150, 56)
	row.add_child(_join_addr)
	col.add_child(row)

	_status = T.label("", 20, "Medium", T.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)
	var sp := Control.new(); sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 16)
	_host = _action("HOST A SERVER", _on_host)
	_host.tooltip_text = "Runs a server on this computer in the background (UDP %d). Friends outside your network need that port forwarded." % P.DEFAULT_PORT
	foot.add_child(_host)
	var sp2 := Control.new(); sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp2)
	var back := _action("BACK", _on_back)
	back.flat = true
	foot.add_child(back)
	col.add_child(foot)

	Game.client.joined.connect(_on_joined)
	Game.client.failed.connect(_on_failed)
	var notice := String(Game.get_meta("menu_notice", ""))
	if notice != "":
		Game.remove_meta("menu_notice")
		_say(notice, T.WARN)
	_refresh()
	if not _cards.is_empty():
		(_cards[0].join as Button).call_deferred("grab_focus")


# ------------------------------------------------------------------ official server cards

func _server_card(s: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", T.flat(Color(1, 1, 1, 0.045), Color(1, 1, 1, 0.09), [1, 1, 1, 1], [22, 14, 16, 14]))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	card.add_child(row)
	var dot := T.label("●", 22, "Bold", T.DIM)
	dot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(dot)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(T.label(String(s.name).to_upper(), 26, "Bold", T.TEXT, 2))
	var detail := T.label(String(s.region) + "   ·   checking...", 18, "Medium", T.DIM)
	info.add_child(detail)
	row.add_child(info)
	var join := _action("JOIN", func(): _join_official(s))
	join.custom_minimum_size = Vector2(150, 56)
	join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(join)
	_cards.append({"server": s, "probe": Probe.new(), "dot": dot, "detail": detail, "join": join})
	return card


func _refresh() -> void:
	_refresh_t = 0.0
	for c in _cards:
		if (c.probe as Probe).state != "probing":
			(c.probe as Probe).start(c.server.address)


func _process(delta: float) -> void:
	_refresh_t += delta
	if _refresh_t > REFRESH and not _busy:
		_refresh()
	for c in _cards:
		var pr: Probe = c.probe
		pr.poll()
		var region := String(c.server.region)
		match pr.state:
			"online":
				var full := pr.players >= pr.capacity
				var wrong := pr.version != P.VERSION
				(c.dot as Label).add_theme_color_override("font_color", T.BAD if wrong else (T.WARN if full else T.GOOD))
				var text := "%s   ·   %d / %d pilots   ·   %d ms" % [region, pr.players, pr.capacity, pr.ping_ms]
				if wrong:
					text = "%s   ·   runs a different game version" % region
				(c.detail as Label).text = text
				(c.join as Button).disabled = _busy or full or wrong
			"offline":
				(c.dot as Label).add_theme_color_override("font_color", T.BAD)
				(c.detail as Label).text = region + "   ·   offline"
				(c.join as Button).disabled = true
			_:
				if (c.detail as Label).text.ends_with("checking..."):
					(c.join as Button).disabled = _busy


func _exit_tree() -> void:
	for c in _cards:
		(c.probe as Probe).stop()


# ------------------------------------------------------------------ helpers

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
	b.add_theme_font_size_override("font_size", 28)
	b.custom_minimum_size = Vector2(0, 56)
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


# ------------------------------------------------------------------ actions

func _join_official(s: Dictionary) -> void:
	if _busy:
		return
	_connect(String(s.address), String(s.name))


func _on_join_address() -> void:
	if _busy:
		return
	var addr := _address.text.strip_edges()
	if addr == "":
		_say("Enter a server address, or join an official server above.", T.WARN)
		_address.grab_focus()
		return
	Settings.set_value("net/last_server", addr)
	_connect(addr, addr)


func _on_host() -> void:
	if _busy:
		return
	var n := _name()
	if not Game.host_local_server("%s's server" % n):
		_say("Could not start the server on this computer.", T.BAD)
		return
	_set_busy(true)
	_say("Starting your server...")
	await get_tree().create_timer(1.5).timeout
	if not is_inside_tree():
		return
	_set_busy(false)
	_connect("127.0.0.1:%d" % P.DEFAULT_PORT, "your server")


func _connect(addr: String, label: String) -> void:
	_set_busy(true)
	_say("Connecting to %s..." % label)
	Game.client.connect_to(addr, _name())


func _set_busy(on: bool) -> void:
	_busy = on
	_join_addr.disabled = on
	_host.disabled = on
	for c in _cards:
		(c.join as Button).disabled = on


func _on_joined() -> void:
	_say("Joined %s. Taking you to shelter %02d." % [Game.client.server_name, Game.client.my_slot + 1], T.GOOD)
	join_ready.emit()


func _on_failed(reason: String) -> void:
	_set_busy(false)
	_say(reason, T.BAD)
	_refresh()


func _on_back() -> void:
	if Game.client.state == Game.client.CONNECTING:
		Game.client.disconnect_from_server("")
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		_on_back()
