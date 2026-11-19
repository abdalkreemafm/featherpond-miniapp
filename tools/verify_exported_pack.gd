extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_verify")


func _verify() -> void:
	_check(ProjectSettings.get_setting("application/config/name") == "بركة الريش", "exported identity")
	for path: String in [
		"assets/share/favicon.png",
		"assets/fonts/NotoSansArabic-Regular.ttf",
		"assets/pond/runtime_final/duck_sunny.png",
		"assets/pond/runtime_final/duck_aqua.png",
		"assets/pond/runtime_final/duck_lilac.png",
		"assets/pond/runtime_final/egg_speckled.png",
		"assets/pond/runtime/pond_background.png",
	]:
		_check(ResourceLoader.exists("res://" + path), "pack resource: " + path)
	_check(not ResourceLoader.exists("res://test/pond_smoke.gd"), "source smoke test excluded")
	_check(not ResourceLoader.exists("res://assets/template/characters/runner.png"), "generic template art excluded")
	_check(not ResourceLoader.exists("res://scripts/game/maze_world.gd"), "generic template gameplay excluded")
	_check(not ResourceLoader.exists("res://config/tuning.json"), "template config excluded")
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "exported main scene")
	if packed != null:
		var game := packed.instantiate() as Control
		root.add_child(game)
		await process_frame
		await process_frame
		_check(game.has_node("PondBackground"), "pack boots to custom pond")
		var state: Dictionary = game.get("_state")
		_check(state.get("ducks", []).size() == 1, "starter flock is available")
		_check(state.get("eggs", []).size() == 2, "starter incubator is available")
		_check(str(game.call("_apply_local_action", "feed", {})) == "", "exported game accepts feeding")
		_check(int(game.get("_state")["player"]["food"]) == 4, "feeding persists resource change")
		game.queue_free()
		await process_frame
	if _failures.is_empty():
		print("[pond-pack] PASS: identity, Telegram art, resources, boot and feeding")
		quit(0)
	else:
		for failure: String in _failures:
			push_error("[pond-pack] " + failure)
		quit(1)


func _check(condition: bool, context: String) -> void:
	if not condition and context not in _failures:
		_failures.append(context)
