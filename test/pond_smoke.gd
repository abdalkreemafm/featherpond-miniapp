extends SceneTree

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "main scene loads")
	if packed == null:
		_finish()
		return
	var game := packed.instantiate() as Control
	root.add_child(game)
	await process_frame
	_check(game.has_node("PondBackground"), "custom pond background is present")
	_check(game.get("_state") is Dictionary, "playable starter state exists")
	game.set("_state", game.call("_default_state"))
	game.call("_refresh_local_tasks")
	for index in range(3):
		_check(str(game.call("_apply_local_action", "feed", {})) == "", "feed %d is accepted" % (index + 1))
	var state: Dictionary = game.get("_state")
	_check(int(state["player"]["readyEggs"]) == 1, "two feeds produce a ready egg")
	_check(int(state["player"]["feedProgress"]) == 1, "surplus feeding progress is retained")
	_check(str(game.call("_apply_local_action", "collect", {})) == "", "ready egg can be collected")
	state = game.get("_state")
	_check(state["eggs"].size() == 3, "collected egg enters the incubator")
	var ids: Array = [state["eggs"][0]["id"], state["eggs"][1]["id"]]
	_check(str(game.call("_apply_local_action", "merge", {"eggIds": ids})) == "", "two matching eggs merge")
	state = game.get("_state")
	var level_two_id := ""
	for egg in state["eggs"]:
		if int(egg["level"]) == 2:
			level_two_id = str(egg["id"])
	_check(not level_two_id.is_empty(), "merge creates a level-two egg")
	_check(str(game.call("_apply_local_action", "hatch", {"eggId": level_two_id})) == "", "selected egg hatches")
	state = game.get("_state")
	_check(state["ducks"].size() == 2, "hatched duck joins the flock")
	_check(state["ducks"].back()["species"] == "aqua", "level-two egg unlocks the aqua duck")
	_check(str(game.call("_apply_local_action", "claim_task", {"taskId": "feed3"})) == "", "completed daily task can be claimed")
	_check(int(game.get("_state")["player"]["coins"]) == 37, "task reward is added to local coins")
	game.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, context: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(context)


func _finish() -> void:
	if _failures.is_empty():
		print("[pond-smoke] PASS: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("[pond-smoke] " + failure)
	print("[pond-smoke] FAIL: %d failures across %d checks" % [_failures.size(), _checks])
	quit(1)
