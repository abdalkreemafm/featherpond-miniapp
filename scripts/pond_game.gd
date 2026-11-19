extends Control

const LOCAL_SAVE_PATH := "user://featherpond-local.json"
const FONT_PATH := "res://assets/fonts/NotoSansArabic-Regular.ttf"
const BG_TEXTURE: Texture2D = preload("res://assets/pond/runtime/pond_background.png")
const DUCK_TEXTURES := {
	"sunny": preload("res://assets/pond/runtime_final/duck_sunny.png"),
	"aqua": preload("res://assets/pond/runtime_final/duck_aqua.png"),
	"lilac": preload("res://assets/pond/runtime_final/duck_lilac.png"),
}
const EGG_TEXTURE: Texture2D = preload("res://assets/pond/runtime_final/egg_speckled.png")

const INK := Color(0.035, 0.14, 0.15, 0.92)
const INK_SOFT := Color(0.035, 0.14, 0.15, 0.82)
const CREAM := Color(1.0, 0.96, 0.84, 1.0)
const MINT := Color(0.60, 0.88, 0.75, 1.0)
const CORAL := Color(0.97, 0.54, 0.38, 1.0)
const TEXT_MUTED := Color(0.84, 0.91, 0.83, 1.0)

var _state: Dictionary = {}
var _current_page := "pond"
var _selected_egg_ids: Array[String] = []
var _font: Font
var _api_base := ""
var _telegram_init_data := ""
var _online := false
var _busy := false
var _pending_action: Dictionary = {}
var _request_kind := ""
var _notice := ""

var _header_stats: Label
var _connection_label: Label
var _notice_label: Label
var _retry_button: Button
var _page_body: VBoxContainer
var _scroll: ScrollContainer
var _nav_buttons: Dictionary = {}
var _http: HTTPRequest


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout_direction = Control.LAYOUT_DIRECTION_RTL
	_font = load(FONT_PATH) as Font
	var ui_theme := Theme.new()
	if _font != null:
		ui_theme.default_font = _font
	ui_theme.default_font_size = 18
	theme = ui_theme
	_state = _default_state()
	_load_offline_save()
	_build_shell()
	_refresh_all()
	_setup_telegram_bridge()
	_setup_network()
	_load_online_state()


func _build_shell() -> void:
	var background := TextureRect.new()
	background.name = "PondBackground"
	background.texture = BG_TEXTURE
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var tint := ColorRect.new()
	tint.color = Color(0.015, 0.12, 0.13, 0.18)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tint)

	var safe := MarginContainer.new()
	safe.name = "SafeMargin"
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe.add_theme_constant_override("margin_left", 18)
	safe.add_theme_constant_override("margin_top", 18)
	safe.add_theme_constant_override("margin_right", 18)
	safe.add_theme_constant_override("margin_bottom", 18)
	add_child(safe)

	var column := VBoxContainer.new()
	column.name = "GameColumn"
	column.add_theme_constant_override("separation", 12)
	safe.add_child(column)

	column.add_child(_build_header())
	column.add_child(_build_page_panel())
	column.add_child(_build_navigation())

	_http = HTTPRequest.new()
	_http.name = "PondApiRequest"
	_http.timeout = 12.0
	_http.request_completed.connect(_on_http_completed)
	add_child(_http)


func _build_header() -> Control:
	var panel := _make_panel(INK)
	panel.name = "Header"
	panel.custom_minimum_size = Vector2(0, 142)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	panel.add_child(content)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	content.add_child(title_row)
	var title := _label("بركة الريش", 27, CREAM, true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_row.add_child(title)
	_connection_label = _label("وضع محلي", 14, MINT)
	_connection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title_row.add_child(_connection_label)

	_header_stats = _label("", 15, CREAM)
	_header_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_header_stats)

	_notice_label = _label("", 14, TEXT_MUTED)
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_notice_label)

	_retry_button = _button("إعادة المحاولة الآمنة", false, Vector2(0, 38))
	_retry_button.visible = false
	_retry_button.pressed.connect(_retry_pending_action)
	content.add_child(_retry_button)
	return panel


func _build_page_panel() -> Control:
	var panel := _make_panel(Color(0.035, 0.15, 0.16, 0.79))
	panel.name = "PagePanel"
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll = ScrollContainer.new()
	_scroll.name = "PageScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	_page_body = VBoxContainer.new()
	_page_body.name = "PageBody"
	_page_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_body.add_theme_constant_override("separation", 14)
	_scroll.add_child(_page_body)
	return panel


func _build_navigation() -> Control:
	var panel := _make_panel(INK)
	panel.name = "Navigation"
	panel.custom_minimum_size = Vector2(0, 72)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	panel.add_child(row)
	var pages := [
		{"id": "pond", "text": "البركة"},
		{"id": "eggs", "text": "الحاضنة"},
		{"id": "friends", "text": "الأصدقاء"},
		{"id": "tasks", "text": "المهام"},
	]
	for page in pages:
		var page_id := str(page["id"])
		var button := _button(str(page["text"]), page_id == _current_page, Vector2(0, 54))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 15)
		button.pressed.connect(_select_page.bind(page_id))
		row.add_child(button)
		_nav_buttons[page_id] = button
	return panel


func _refresh_all() -> void:
	_refresh_header()
	_refresh_page()
	_refresh_navigation()


func _refresh_header() -> void:
	if _state.is_empty():
		return
	var player: Dictionary = _state.get("player", {})
	var duck_count := int(player.get("duckCount", _state.get("ducks", []).size()))
	var egg_count := int(player.get("eggsCount", _state.get("eggs", []).size()))
	_header_stats.text = "العملات  %s     الطعام  %s     البط  %s     البيض  %s     النقاط  %s" % [
		str(player.get("coins", 0)), str(player.get("food", 0)), str(duck_count), str(egg_count), str(player.get("score", 0))
	]
	_connection_label.text = "متصل" if _online else "وضع محلي"
	_connection_label.add_theme_color_override("font_color", MINT if _online else CORAL)
	_notice_label.text = _notice
	_retry_button.visible = not _pending_action.is_empty() and not _busy


func _refresh_page() -> void:
	if _page_body == null:
		return
	for child in _page_body.get_children():
		child.queue_free()
	match _current_page:
		"pond":
			_build_pond_page()
		"eggs":
			_build_eggs_page()
		"friends":
			_build_friends_page()
		"tasks":
			_build_tasks_page()
		_:
			_build_pond_page()
	_refresh_navigation()


func _refresh_navigation() -> void:
	for page_id in _nav_buttons:
		var button: Button = _nav_buttons[page_id]
		_set_button_style(button, page_id == _current_page)


func _select_page(page_id: String) -> void:
	_current_page = page_id
	_selected_egg_ids.clear()
	_haptic("selection")
	_refresh_page()


func _build_pond_page() -> void:
	_page_body.add_child(_label("بركتك تنمو مع كل رعاية", 24, CREAM, true))
	var player: Dictionary = _state.get("player", {})
	var ducks: Array = _state.get("ducks", [])
	var species := "sunny"
	var duck_name := "شمسة"
	if not ducks.is_empty():
		var active: Dictionary = ducks[ducks.size() - 1]
		species = str(active.get("species", "sunny"))
		duck_name = str(active.get("name", _species_name(species)))
	var hero := CenterContainer.new()
	hero.custom_minimum_size = Vector2(0, 292)
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var portrait := TextureRect.new()
	portrait.texture = _duck_texture(species)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.custom_minimum_size = Vector2(260, 260)
	portrait.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(portrait)
	_page_body.add_child(hero)
	_page_body.add_child(_label("%s  ·  %s بطة في القطيع" % [duck_name, str(ducks.size())], 19, CREAM, true))
	var ready := int(player.get("readyEggs", 0))
	var feed_progress := int(player.get("feedProgress", 0))
	_page_body.add_child(_label("وجبتان تصنعان بيضة. البيض الجاهز للجمع: %s  ·  التقدم: %s/2" % [str(ready), str(feed_progress)], 15, TEXT_MUTED))
	_page_body.add_child(_label("أطعم البط، اجمع البيض، ثم ادمج بيضتين من المستوى نفسه أو فقّس واحدة.", 15, CREAM))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	_page_body.add_child(actions)
	var feed := _button("أطعم البط", true, Vector2(0, 58))
	feed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	feed.disabled = _busy
	feed.pressed.connect(_perform_action.bind("feed", {}))
	actions.add_child(feed)
	var collect := _button("اجمع البيض", false, Vector2(0, 58))
	collect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collect.disabled = _busy
	collect.pressed.connect(_perform_action.bind("collect", {}))
	actions.add_child(collect)

	var buy := _button("اشترِ 3 وجبات · 15 عملة", false, Vector2(0, 52))
	buy.disabled = _busy
	buy.pressed.connect(_perform_action.bind("buy_food", {}))
	_page_body.add_child(buy)
	_page_body.add_child(_label("قطيعك", 18, MINT, true))
	var flock := HFlowContainer.new()
	flock.alignment = FlowContainer.ALIGNMENT_CENTER
	flock.add_theme_constant_override("h_separation", 8)
	flock.add_theme_constant_override("v_separation", 8)
	_page_body.add_child(flock)
	for duck in ducks:
		var duck_info: Dictionary = duck
		var card := _make_panel(Color(0.05, 0.19, 0.19, 0.75))
		card.custom_minimum_size = Vector2(122, 120)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 1)
		card.add_child(stack)
		var icon := _texture_rect(_duck_texture(str(duck_info.get("species", "sunny"))), Vector2(78, 78))
		stack.add_child(icon)
		stack.add_child(_label(str(duck_info.get("name", _species_name(str(duck_info.get("species", "sunny"))))), 13, CREAM))
		flock.add_child(card)


func _build_eggs_page() -> void:
	_page_body.add_child(_label("الحاضنة", 25, CREAM, true))
	_page_body.add_child(_label("اختر بيضة للتفقيس، أو اختر بيضتين متساويتين لدمجهما.", 15, TEXT_MUTED))
	var eggs: Array = _state.get("eggs", [])
	if eggs.is_empty():
		var empty := _make_panel(Color(0.05, 0.19, 0.19, 0.75))
		empty.add_child(_label("الحاضنة فارغة حالياً. أطعم البط واجمع ما ينتجه من بيض.", 16, CREAM))
		_page_body.add_child(empty)
	else:
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 8)
		_page_body.add_child(grid)
		for egg_value in eggs:
			var egg: Dictionary = egg_value
			var egg_id := str(egg.get("id", ""))
			var selected := _selected_egg_ids.has(egg_id)
			var card := Button.new()
			card.custom_minimum_size = Vector2(116, 128)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			card.text = ""
			card.pressed.connect(_toggle_egg.bind(egg_id))
			_set_button_style(card, selected)
			var stack := VBoxContainer.new()
			stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_theme_constant_override("separation", 1)
			card.add_child(stack)
			var pic := _texture_rect(EGG_TEXTURE, Vector2(70, 72))
			pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(pic)
			var level_label := _label("المستوى %s" % str(egg.get("level", 1)), 13, CREAM)
			level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(level_label)
			var marker := _label("محددة" if selected else "اختر", 12, MINT if selected else TEXT_MUTED)
			marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
			stack.add_child(marker)
			grid.add_child(card)

	var selected_count := _selected_egg_ids.size()
	_page_body.add_child(_label("البيض المحدد: %s" % str(selected_count), 15, MINT))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	_page_body.add_child(actions)
	var merge := _button("دمج البيضتين", true, Vector2(0, 54))
	merge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	merge.disabled = _busy or not _can_merge_selected()
	merge.pressed.connect(_merge_selected)
	actions.add_child(merge)
	var hatch := _button("فقس المحددة", false, Vector2(0, 54))
	hatch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hatch.disabled = _busy or selected_count != 1
	hatch.pressed.connect(_hatch_selected)
	actions.add_child(hatch)


func _build_friends_page() -> void:
	_page_body.add_child(_label("الأصدقاء والبركة المشتركة", 24, CREAM, true))
	if _online:
		_page_body.add_child(_label("اعرض بطة من قطيعك؛ عندما يقبل لاعب آخر، يحصل كلاكما على بيضة تعاون من المستوى 2.", 15, TEXT_MUTED))
		var invite := _button("ادعُ صديقاً إلى اللعبة", false, Vector2(0, 52))
		invite.pressed.connect(_share_game)
		_page_body.add_child(invite)
		var offer := _button("انشر عرض تعاون", true, Vector2(0, 56))
		offer.disabled = _busy or _state.get("ducks", []).is_empty()
		offer.pressed.connect(_create_offer)
		_page_body.add_child(offer)
		_page_body.add_child(_label("عروض اللاعبين", 18, MINT, true))
		var offers: Array = _state.get("offers", [])
		if offers.is_empty():
			_page_body.add_child(_label("لا توجد عروض نشطة الآن. أعد الزيارة لاحقاً أو انشر عرضك.", 15, TEXT_MUTED))
		for offer_value in offers:
			var item: Dictionary = offer_value
			var card := _make_panel(Color(0.05, 0.19, 0.19, 0.82))
			var stack := VBoxContainer.new()
			stack.add_theme_constant_override("separation", 6)
			card.add_child(stack)
			var name := str(item.get("nickname", "صديق البركة"))
			var species := str(item.get("species", "sunny"))
			stack.add_child(_label("%s يشارك %s" % [name, _species_name(species)], 16, CREAM))
			var accept := _button("اقبل التعاون · 5 عملات", true, Vector2(0, 46))
			accept.disabled = _busy
			accept.pressed.connect(_perform_action.bind("accept_offer", {"offerId": str(item.get("id", ""))}))
			stack.add_child(accept)
			_page_body.add_child(card)
	else:
		var offline_card := _make_panel(Color(0.05, 0.19, 0.19, 0.82))
		offline_card.add_child(_label("الميزات الاجتماعية تحتاج فتح اللعبة من زر Telegram الرسمي واتصال الخادم الذي ستثبّته على استضافتك. تقدمك المحلي يبقى محفوظاً على هذا الجهاز.", 16, CREAM))
		_page_body.add_child(offline_card)
		var invite_offline := _button("مشاركة رابط اللعبة", false, Vector2(0, 52))
		invite_offline.pressed.connect(_share_game)
		_page_body.add_child(invite_offline)

	_page_body.add_child(_label("لوحة الصدارة", 19, MINT, true))
	var leaderboard: Array = _state.get("leaderboard", [])
	if leaderboard.is_empty():
		_page_body.add_child(_label("ستظهر النتائج بعد اتصال اللاعبين بالخادم.", 14, TEXT_MUTED))
	else:
		for entry_value in leaderboard:
			var entry: Dictionary = entry_value
			_page_body.add_child(_label("%s.  %s  ·  %s نقطة" % [str(entry.get("rank", "")), str(entry.get("nickname", "صديق البركة")), str(entry.get("score", 0))], 15, CREAM))


func _build_tasks_page() -> void:
	_page_body.add_child(_label("مهام اليوم", 24, CREAM, true))
	_page_body.add_child(_label("أنجز المهام لتحصل على عملات تساعدك في توسيع رعايتك للقطيع.", 15, TEXT_MUTED))
	var tasks: Array = _state.get("tasks", [])
	if tasks.is_empty():
		_page_body.add_child(_label("ستظهر مهامك هنا بعد الاتصال أو بدء اللعب المحلي.", 15, TEXT_MUTED))
	for task_value in tasks:
		var task: Dictionary = task_value
		var card := _make_panel(Color(0.05, 0.19, 0.19, 0.82))
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 6)
		card.add_child(stack)
		stack.add_child(_label(str(task.get("title", "مهمة")), 16, CREAM, true))
		stack.add_child(_label("التقدم %s/%s  ·  المكافأة %s عملة" % [str(task.get("progress", 0)), str(task.get("target", 1)), str(task.get("reward", 0))], 14, TEXT_MUTED))
		var claim := _button("تم الاستلام" if task.get("claimed", false) else "استلام المكافأة", bool(task.get("ready", false)), Vector2(0, 46))
		claim.disabled = _busy or task.get("claimed", false) or not task.get("ready", false)
		claim.pressed.connect(_perform_action.bind("claim_task", {"taskId": str(task.get("id", ""))}))
		stack.add_child(claim)
		_page_body.add_child(card)


func _toggle_egg(egg_id: String) -> void:
	if _selected_egg_ids.has(egg_id):
		_selected_egg_ids.erase(egg_id)
	elif _selected_egg_ids.size() < 2:
		_selected_egg_ids.append(egg_id)
	else:
		_selected_egg_ids.pop_front()
		_selected_egg_ids.append(egg_id)
	_haptic("selection")
	_refresh_page()


func _can_merge_selected() -> bool:
	if _selected_egg_ids.size() != 2:
		return false
	var first := _find_egg(_selected_egg_ids[0])
	var second := _find_egg(_selected_egg_ids[1])
	return not first.is_empty() and not second.is_empty() and int(first.get("level", 0)) == int(second.get("level", -1)) and int(first.get("level", 0)) < 4


func _merge_selected() -> void:
	if _can_merge_selected():
		_perform_action("merge", {"eggIds": _selected_egg_ids.duplicate()})


func _hatch_selected() -> void:
	if _selected_egg_ids.size() == 1:
		_perform_action("hatch", {"eggId": _selected_egg_ids[0]})


func _create_offer() -> void:
	var ducks: Array = _state.get("ducks", [])
	if not ducks.is_empty():
		var duck: Dictionary = ducks[0]
		_perform_action("create_offer", {"duckId": str(duck.get("id", ""))})


func _share_game() -> void:
	var player: Dictionary = _state.get("player", {})
	var invite_url := str(_state.get("inviteUrl", ""))
	if invite_url.is_empty():
		invite_url = _current_game_url()
	if invite_url.is_empty():
		_set_notice("رابط الدعوة غير مُعدّ بعد. أضف اسم البوت في إعداد الخادم.")
		return
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.PondBridge && window.PondBridge.share(%s)" % JSON.stringify(invite_url), true)
		_haptic("light")
	else:
		DisplayServer.clipboard_set(invite_url)
		_set_notice("تم نسخ رابط اللعبة. شاركه مع أصدقائك.")
	if player.has("nickname"):
		_set_notice("أرسل الدعوة إلى أصدقائك ليلتقوا بك في البركة.")


func _current_game_url() -> String:
	if OS.has_feature("web"):
		var result: Variant = JavaScriptBridge.eval("window.location.href", true)
		return str(result) if result != null else ""
	return ""


func _setup_telegram_bridge() -> void:
	if not OS.has_feature("web"):
		return
	var raw: Variant = JavaScriptBridge.eval("window.PondBridge ? window.PondBridge.getInitData() : ''", true)
	_telegram_init_data = str(raw) if raw != null else ""
	var base: Variant = JavaScriptBridge.eval("window.PondBridge ? window.PondBridge.apiBase : window.location.origin", true)
	_api_base = str(base).strip_edges().trim_suffix("/") if base != null else ""
	JavaScriptBridge.eval("window.PondBridge && window.PondBridge.ready()", true)


func _setup_network() -> void:
	if not OS.has_feature("web") or _telegram_init_data.is_empty() or _api_base.is_empty():
		_online = false
		return
	_online = true


func _load_online_state() -> void:
	if not _online:
		return
	_busy = true
	_request_kind = "state"
	var headers := ["X-Telegram-Init-Data: " + _telegram_init_data]
	var err := _http.request(_api_base + "/api/state", headers, HTTPClient.METHOD_GET)
	if err != OK:
		_busy = false
		_online = false
		_set_notice("تعذّر الاتصال بالخادم؛ يمكنك اللعب محلياً حتى استعادة الاتصال.")
		_refresh_all()


func _perform_action(action_type: String, payload: Dictionary = {}) -> void:
	if _busy:
		return
	if not _online:
		var local_error := _apply_local_action(action_type, payload)
		if local_error != "":
			_set_notice(local_error)
		else:
			_set_notice(_success_message(action_type))
			_save_offline_state()
		_refresh_all()
		_haptic("light")
		return
	_pending_action = payload.duplicate(true)
	_pending_action["type"] = action_type
	_pending_action["requestId"] = _new_request_id()
	_submit_pending_action()


func _submit_pending_action() -> void:
	if _busy or _pending_action.is_empty() or not _online:
		return
	_busy = true
	_request_kind = "action"
	var headers := ["Content-Type: application/json", "X-Telegram-Init-Data: " + _telegram_init_data]
	var body := JSON.stringify(_pending_action)
	var err := _http.request(_api_base + "/api/action", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_busy = false
		_set_notice("تعذّر إرسال الإجراء. أعد المحاولة بالمعرّف نفسه لتجنّب تكراره.")
		_refresh_all()


func _retry_pending_action() -> void:
	if not _pending_action.is_empty():
		_submit_pending_action()


func _on_http_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var previous_kind := _request_kind
	_request_kind = ""
	_busy = false
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
	if previous_kind == "state":
		if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and parsed is Dictionary and parsed.get("state") is Dictionary:
			_state = parsed["state"]
			_online = true
			_set_notice("")
			_refresh_all()
		else:
			_online = false
			_state = _default_state()
			_load_offline_save()
			_set_notice("اللعب المحلي متاح؛ فعّل الخادم واتصل عبر Telegram للمزامنة الاجتماعية.")
			_refresh_all()
		return

	if previous_kind == "action":
		if result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300 and parsed is Dictionary and parsed.get("state") is Dictionary:
			var completed_action := str(_pending_action.get("type", ""))
			_state = parsed["state"]
			_pending_action.clear()
			_set_notice(_success_message(completed_action))
			_refresh_all()
			_haptic("success")
			return
		if response_code == 401 or response_code == 403:
			_pending_action.clear()
			_online = false
			_state = _default_state()
			_load_offline_save()
			_set_notice("تعذّر التحقق من جلسة Telegram؛ عاد اللعب إلى الحفظ المحلي على هذا الجهاز.")
			_refresh_all()
			return
		if response_code >= 400 and response_code < 500:
			_pending_action.clear()
			var message := "تعذّر تنفيذ الإجراء. حدّث الحالة وحاول مجدداً."
			if parsed is Dictionary:
				message = str(parsed.get("message", message))
			_set_notice(message)
			_refresh_all()
			return
		_set_notice("لم يصل تأكيد الحفظ. أعد المحاولة؛ يستخدم الطلب المعرّف نفسه فلا يتكرر.")
		_refresh_all()


func _apply_local_action(action_type: String, payload: Dictionary) -> String:
	var player: Dictionary = _state.get("player", {})
	var daily: Dictionary = _state.get("daily", {})
	match action_type:
		"feed":
			if int(player.get("food", 0)) < 1:
				return "نفد الطعام. يمكنك شراء 3 وجبات مقابل 15 عملة."
			player["food"] = int(player.get("food", 0)) - 1
			player["feedProgress"] = int(player.get("feedProgress", 0)) + 1
			player["score"] = int(player.get("score", 0)) + 1
			daily["feeds"] = int(daily.get("feeds", 0)) + 1
			if int(player["feedProgress"]) >= 2 and int(player.get("readyEggs", 0)) < 9:
				player["feedProgress"] = int(player["feedProgress"]) - 2
				player["readyEggs"] = int(player.get("readyEggs", 0)) + 1
		"collect":
			var ready := int(player.get("readyEggs", 0))
			if ready < 1:
				return "لا يوجد بيض جاهز للجمع بعد. أطعِم البط أولاً."
			if _state.get("eggs", []).size() + ready > 40:
				return "الحاضنة ممتلئة. ادمج البيض أو فقّسه أولاً."
			for i in range(ready):
				_state["eggs"].append({"id": _local_id(), "level": 1})
			player["readyEggs"] = 0
			player["score"] = int(player.get("score", 0)) + ready * 5
			daily["collects"] = int(daily.get("collects", 0)) + ready
		"merge":
			var egg_ids: Array = payload.get("eggIds", [])
			if egg_ids.size() != 2:
				return "اختر بيضتين لدمجهما."
			var egg_a := _find_egg(str(egg_ids[0]))
			var egg_b := _find_egg(str(egg_ids[1]))
			if egg_a.is_empty() or egg_b.is_empty() or int(egg_a.get("level", 0)) != int(egg_b.get("level", -1)):
				return "يجب اختيار بيضتين من المستوى نفسه."
			var next_level := int(egg_a.get("level", 1)) + 1
			if next_level > 4:
				return "وصلت البيضة إلى أعلى مستوى في هذه النسخة."
			_remove_local_egg(str(egg_ids[0]))
			_remove_local_egg(str(egg_ids[1]))
			_state["eggs"].append({"id": _local_id(), "level": next_level})
			player["score"] = int(player.get("score", 0)) + 10 * next_level
			daily["merges"] = int(daily.get("merges", 0)) + 1
		"hatch":
			var egg_id := str(payload.get("eggId", ""))
			var egg := _find_egg(egg_id)
			if egg.is_empty():
				return "اختر بيضة موجودة في الحاضنة."
			_remove_local_egg(egg_id)
			var species := _species_for_level(int(egg.get("level", 1)))
			_state["ducks"].append({"id": _local_id(), "species": species, "name": _species_name(species)})
			player["score"] = int(player.get("score", 0)) + 10 * int(egg.get("level", 1))
			daily["hatches"] = int(daily.get("hatches", 0)) + 1
		"buy_food":
			if int(player.get("coins", 0)) < 15:
				return "تحتاج إلى 15 عملة لشراء الطعام. أكمل المهام لكسب المزيد."
			if int(player.get("food", 0)) >= 12:
				return "مخزون الطعام ممتلئ حالياً."
			player["coins"] = int(player.get("coins", 0)) - 15
			player["food"] = min(12, int(player.get("food", 0)) + 3)
		"claim_task":
			var task_id := str(payload.get("taskId", ""))
			var task := _find_task(task_id)
			if task.is_empty() or task.get("claimed", false) or not task.get("ready", false):
				return "لم تُنجز المهمة أو سبق استلام مكافأتها."
			for idx in range(_state["tasks"].size()):
				if str(_state["tasks"][idx].get("id", "")) == task_id:
					_state["tasks"][idx]["claimed"] = true
			player["coins"] = int(player.get("coins", 0)) + int(task.get("reward", 0))
		"create_offer", "accept_offer":
			return "التعاون بين اللاعبين يتطلب الاتصال بالخادم."
		_:
			return "هذا الإجراء غير معروف."
	_state["player"] = player
	_state["daily"] = daily
	_refresh_local_tasks()
	_update_local_counts()
	return ""


func _refresh_local_tasks() -> void:
	var daily: Dictionary = _state.get("daily", {})
	var existing: Dictionary = {}
	for task_value in _state.get("tasks", []):
		var task: Dictionary = task_value
		existing[str(task.get("id", ""))] = bool(task.get("claimed", false))
	var definitions := [
		{"id": "feed3", "title": "أطعم البط 3 مرات", "progress": int(daily.get("feeds", 0)), "target": 3, "reward": 12},
		{"id": "collect1", "title": "اجمع بيضة واحدة", "progress": int(daily.get("collects", 0)), "target": 1, "reward": 8},
		{"id": "merge1", "title": "ادمج بيضتين", "progress": int(daily.get("merges", 0)), "target": 1, "reward": 12},
		{"id": "hatch1", "title": "فقّس بطة جديدة", "progress": int(daily.get("hatches", 0)), "target": 1, "reward": 15},
	]
	var tasks: Array = []
	for definition in definitions:
		var id := str(definition["id"])
		var target := int(definition["target"])
		var progress := int(definition["progress"])
		var claimed := bool(existing.get(id, false))
		tasks.append({
			"id": id,
			"title": str(definition["title"]),
			"progress": progress,
			"target": target,
			"reward": int(definition["reward"]),
			"claimed": claimed,
			"ready": progress >= target and not claimed,
		})
	_state["tasks"] = tasks


func _update_local_counts() -> void:
	var player: Dictionary = _state.get("player", {})
	player["duckCount"] = _state.get("ducks", []).size()
	player["eggsCount"] = _state.get("eggs", []).size()
	_state["player"] = player


func _default_state() -> Dictionary:
	return {
		"player": {"nickname": "صديق البركة", "coins": 25, "food": 5, "readyEggs": 0, "feedProgress": 0, "score": 0, "duckCount": 1, "eggsCount": 2},
		"ducks": [{"id": "local-duck-1", "species": "sunny", "name": "شمسة"}],
		"eggs": [{"id": "local-egg-1", "level": 1}, {"id": "local-egg-2", "level": 1}],
		"tasks": [],
		"offers": [],
		"leaderboard": [],
		"inviteUrl": "",
		"daily": {"feeds": 0, "collects": 0, "merges": 0, "hatches": 0},
	}


func _load_offline_save() -> void:
	if not FileAccess.file_exists(LOCAL_SAVE_PATH):
		_refresh_local_tasks()
		_update_local_counts()
		return
	var file := FileAccess.open(LOCAL_SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary and parsed.has("player") and parsed.has("eggs") and parsed.has("ducks"):
		_state = parsed
		_state["offers"] = []
		_state["leaderboard"] = []
		_state["inviteUrl"] = ""
		if not _state.has("daily"):
			_state["daily"] = {"feeds": 0, "collects": 0, "merges": 0, "hatches": 0}
		_refresh_local_tasks()
		_update_local_counts()


func _save_offline_state() -> void:
	var to_save := _state.duplicate(true)
	to_save["offers"] = []
	to_save["leaderboard"] = []
	to_save["inviteUrl"] = ""
	var file := FileAccess.open(LOCAL_SAVE_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(to_save))
		file.close()


func _find_egg(egg_id: String) -> Dictionary:
	for egg_value in _state.get("eggs", []):
		var egg: Dictionary = egg_value
		if str(egg.get("id", "")) == egg_id:
			return egg
	return {}


func _remove_local_egg(egg_id: String) -> void:
	var eggs: Array = _state.get("eggs", [])
	for i in range(eggs.size() - 1, -1, -1):
		if str(eggs[i].get("id", "")) == egg_id:
			eggs.remove_at(i)
		_state["eggs"] = eggs


func _find_task(task_id: String) -> Dictionary:
	for task_value in _state.get("tasks", []):
		var task: Dictionary = task_value
		if str(task.get("id", "")) == task_id:
			return task
	return {}


func _species_for_level(level: int) -> String:
	if level <= 1:
		return "sunny"
	if level == 2:
		return "aqua"
	return "lilac"


func _species_name(species: String) -> String:
	match species:
		"aqua":
			return "موجة"
		"lilac":
			return "ليلك"
		_:
			return "شمسة"


func _duck_texture(species: String) -> Texture2D:
	return DUCK_TEXTURES.get(species, DUCK_TEXTURES["sunny"])


func _texture_rect(texture: Texture2D, dimensions: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = dimensions
	rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _make_panel(fill: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = Color(0.72, 0.88, 0.75, 0.42)
	style.set_border_width_all(1)
	style.set_corner_radius_all(18)
	style.content_margin_left = 14
	style.content_margin_top = 10
	style.content_margin_right = 14
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _button(text: String, primary: bool, minimum: Vector2 = Vector2(0, 52)) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = minimum
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 18)
	_set_button_style(button, primary)
	return button


func _set_button_style(button: Button, primary: bool) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = MINT if primary else Color(0.07, 0.25, 0.24, 0.96)
	normal.border_color = Color(0.94, 0.97, 0.82, 0.65)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(14)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 5
	normal.content_margin_bottom = 5
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.74, 0.94, 0.80, 1.0) if primary else Color(0.11, 0.34, 0.31, 1.0)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.44, 0.73, 0.61, 1.0) if primary else Color(0.04, 0.19, 0.20, 1.0)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.28, 0.41, 0.37, 0.80)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", INK if primary else CREAM)
	button.add_theme_color_override("font_hover_color", INK if primary else CREAM)
	button.add_theme_color_override("font_pressed_color", INK if primary else CREAM)
	button.add_theme_color_override("font_disabled_color", Color(0.88, 0.91, 0.82, 0.75))
	button.text_direction = Control.TEXT_DIRECTION_RTL


func _label(text: String, size: int, color: Color, strong: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text_direction = Control.TEXT_DIRECTION_RTL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size + (1 if strong else 0))
	label.add_theme_color_override("font_color", color)
	return label


func _set_notice(message: String) -> void:
	_notice = message
	if is_instance_valid(_notice_label):
		_notice_label.text = message


func _success_message(action_type: String) -> String:
	match action_type:
		"feed":
			return "أحسنت! اعتنى البط بالطعام."
		"collect":
			return "تم جمع البيض إلى الحاضنة."
		"merge":
			return "اندُمجت البيضتان وارتفع المستوى."
		"hatch":
			return "فقست بيضة وانضمت بطة جديدة إلى القطيع."
		"buy_food":
			return "وصل الطعام إلى مخزونك."
		"claim_task":
			return "استلمت مكافأة المهمة."
		"create_offer":
			return "نُشر عرض التعاون للّاعبين."
		"accept_offer":
			return "نجح التعاون؛ أضيفت بيضة إلى حاضنتكما."
		_:
			return "تم حفظ التغيير."


func _new_request_id() -> String:
	return "%s-%s" % [str(Time.get_unix_time_from_system()), str(randi())]


func _local_id() -> String:
	return "local-%s-%s" % [str(Time.get_ticks_msec()), str(randi())]


func _haptic(kind: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.PondBridge && window.PondBridge.haptic(%s)" % JSON.stringify(kind), true)
