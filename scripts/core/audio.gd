extends Node
## Audio (autoload): mix buses, volume settings, and interface sounds for every button in the game.
## Bus layout:  Engine ─┐
##              Effects ┴─ World (muffled in the cockpit) ─┐
##              Warnings ──────────────────────────────────┼─ Master
##              UI ────────────────────────────────────────┘

const DIR := "res://assets/audio/"
var _ui_player: AudioStreamPlayer
var _ui_streams := {}
var _world_lp: AudioEffectLowPassFilter
var _muffle := 0.0
var _muffle_target := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bus("World", "Master")
	_bus("Engine", "World")
	_bus("Effects", "World")
	_bus("Warnings", "Master")
	_bus("UI", "Master")
	_bus("Pilot", "Master")          # the pilot's own breathing, in his mask: never muffled by the canopy
	_world_lp = AudioEffectLowPassFilter.new()
	_world_lp.cutoff_hz = 20000.0
	_world_lp.resonance = 0.4
	AudioServer.add_bus_effect(AudioServer.get_bus_index("World"), _world_lp)
	var lim := AudioEffectHardLimiter.new()
	lim.ceiling_db = -0.5
	AudioServer.add_bus_effect(0, lim)
	_ui_player = AudioStreamPlayer.new()
	_ui_player.bus = "UI"
	add_child(_ui_player)
	for n in ["ui_hover", "ui_click", "ui_back", "ui_start"]:
		_ui_streams[n] = load(DIR + n + ".wav")
	Settings.changed.connect(func(k, _v):
		if String(k).begins_with("audio/"):
			_apply_volumes())
	_apply_volumes()
	get_tree().node_added.connect(_on_node_added)


func _bus(bus_name: String, send: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, send)


func _apply_volumes() -> void:
	for pair in [["Engine", "audio/engine"], ["Effects", "audio/effects"], ["Pilot", "audio/effects"], ["Warnings", "audio/warnings"], ["UI", "audio/ui"]]:
		var v := float(Settings.get_value(pair[1]))
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index(pair[0]), linear_to_db(maxf(v, 0.0001)))


## 0 = outside, 1 = inside a closed cockpit (muffles engines and effects, as a canopy and helmet do).
func set_cockpit_muffle(amount: float) -> void:
	_muffle_target = clampf(amount, 0.0, 1.0)


func _process(delta: float) -> void:
	_muffle = move_toward(_muffle, _muffle_target, delta * 2.5)
	_world_lp.cutoff_hz = lerpf(20000.0, 2300.0, pow(_muffle, 0.6))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("World"), lerpf(0.0, -5.0, _muffle))


func play_ui(n: String, vol_db: float = 0.0) -> void:
	if _ui_streams.has(n):
		_ui_player.stream = _ui_streams[n]
		_ui_player.volume_db = vol_db
		_ui_player.play()


func _on_node_added(node: Node) -> void:
	if node is TabBar:
		var tb := node as TabBar
		tb.tab_hovered.connect(func(_i): play_ui("ui_hover", -6.0))
		tb.tab_clicked.connect(func(_i): play_ui("ui_click"))
		return
	if node is Slider:
		var sl := node as Slider
		sl.mouse_entered.connect(func(): play_ui("ui_hover", -8.0))
		sl.drag_ended.connect(func(_c): play_ui("ui_click", -4.0))
		return
	if node is PopupMenu:
		(node as PopupMenu).id_focused.connect(func(_i): play_ui("ui_hover", -8.0))
		return
	if node is BaseButton:
		var b := node as BaseButton
		b.mouse_entered.connect(func():
			if not b.disabled:
				play_ui("ui_hover", -6.0))
		b.focus_entered.connect(func():
			if not b.disabled and not b.is_hovered():
				play_ui("ui_hover", -8.0))
		b.pressed.connect(func():
			var txt := (b as Button).text if b is Button else ""
			if txt == "PLAY":
				play_ui("ui_start")
			elif txt == "BACK" or txt == "RESUME":
				play_ui("ui_back")
			else:
				play_ui("ui_click"))


static var _looped := {}               # path -> looping stream, shared by every player (every jet's engines)


## Loads a WAV and makes it loop seamlessly. One shared copy per file: a second jet joining reuses it instead of
## copying the sound data again.
static func looped(path: String) -> AudioStream:
	if _looped.has(path):
		return _looped[path]
	var out := _make_looped(path)
	_looped[path] = out
	return out


static func _make_looped(path: String) -> AudioStream:
	var s: AudioStream = load(path)
	if s is AudioStreamWAV:
		var w := (s as AudioStreamWAV).duplicate() as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
		return w
	if s is AudioStreamOggVorbis:
		var o := (s as AudioStreamOggVorbis).duplicate() as AudioStreamOggVorbis
		o.loop = true
		return o
	return s
