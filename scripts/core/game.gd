extends Node
## Game (autoload): session flow between the menu and the flight, a cache for assets preloaded on the
## loading screen, and the multiplayer session (client, or a dedicated server when started with --server).

const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/main.tscn"
const VERSION := "0.2.0 Alpha"

var _cache := {}
var client: Node                     # net/client.gd, always present
var is_server := false               # this process is a dedicated server (FlightOut --headless -- --server)
var hosted_pid := -1                 # a local server this game started with HOST, stopped on quit


var online: bool:
	get: return client != null and client.online


func _ready() -> void:
	is_server = "--server" in OS.get_cmdline_user_args()
	client = preload("res://scripts/net/client.gd").new()
	add_child(client)
	if is_server:
		_become_server.call_deferred()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dev-quit="):   # development: quit after N seconds (automated tests)
			get_tree().create_timer(arg.trim_prefix("--dev-quit=").to_float()).timeout.connect(quit)


func _become_server() -> void:
	var srv: Node = preload("res://scripts/net/server.gd").new()
	get_tree().root.add_child(srv)
	var old := get_tree().current_scene
	get_tree().current_scene = srv
	if old:
		old.queue_free()


## Starts a dedicated server on this computer as its own process (same build, no window), for HOST.
func host_local_server(server_name: String) -> bool:
	stop_hosted_server()
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", "--", "--server", "--name=" + server_name])
	hosted_pid = OS.create_process(OS.get_executable_path(), args, false)
	return hosted_pid > 0


func stop_hosted_server() -> void:
	if hosted_pid > 0:
		OS.kill(hosted_pid)
		hosted_pid = -1


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if client:
			client.disconnect_from_server("")
		stop_hosted_server()


func keep(path: String, res: Resource) -> void:
	_cache[path] = res


func release_cache() -> void:
	_cache.clear()


func goto_menu() -> void:
	client.disconnect_from_server("")
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func quit() -> void:
	client.disconnect_from_server("")
	stop_hosted_server()
	get_tree().quit()
