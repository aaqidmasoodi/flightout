extends Node
## Game (autoload): session flow between the menu and the flight, and a cache for assets
## preloaded on the loading screen. Multiplayer session state will live here later.

const MENU_SCENE := "res://scenes/menu.tscn"
const GAME_SCENE := "res://scenes/main.tscn"
const VERSION := "0.1.0 Alpha"

var _cache := {}


func keep(path: String, res: Resource) -> void:
	_cache[path] = res


func release_cache() -> void:
	_cache.clear()


func goto_menu() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func quit() -> void:
	get_tree().quit()
