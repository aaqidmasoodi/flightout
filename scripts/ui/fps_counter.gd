extends CanvasLayer
## Frame rate in the top right corner (Settings: Display > FPS counter). Available to players, unlike the
## developer overlay (scripts/hud.gd).

const T = preload("res://scripts/ui/ui_theme.gd")

var _label: Label


func _ready() -> void:
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = T.label("", 18, "Bold", T.DIM, 2)
	_label.anchor_left = 1.0
	_label.anchor_right = 1.0
	_label.offset_left = -160
	_label.offset_right = -24
	_label.offset_top = 18
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	Settings.changed.connect(func(_k, _v): _apply())
	_apply()


func _apply() -> void:
	_label.visible = bool(Settings.get_value("hud/fps"))


func _process(_delta: float) -> void:
	if _label.visible:
		_label.text = "%d FPS" % Engine.get_frames_per_second()
