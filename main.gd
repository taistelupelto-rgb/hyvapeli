extends Node2D
## Hyvapeli: Nekomimi Snake - Mmmmm coins. Eat golden coins to grow and score.
## Controls: WASD / arrows, swipe or drag to steer. R / Enter / Space / click / tap restarts.
## T toggles autoplay attract mode (ON at boot). Rainbow lighting, all cheap _draw.

const GRID_COLS := 24
const GRID_ROWS := 16
const CELL := 32.0
const ORIGIN := Vector2(192.0, 88.0)  # centers 768x512 field in 1152x648
const BASE_STEP := 0.14
const MIN_STEP := 0.07
const RAMP_PER_COIN := 0.003
const GLOW_DOT_COUNT := 24  # only extra-draw cost; zero extra nodes
const AUTOPLAY_RESTART_DELAY := 2.0
const YELL_STREAM := preload("res://assets/yell.ogg")
const YELL_COOLDOWN := 8.0

var snake: Array[Vector2i] = []
var dir := Vector2i.RIGHT
var queued_dir := Vector2i.RIGHT
var coin := Vector2i(-1, -1)
var score := 0
var best := 0
var alive := true
var step_timer := 0.0
var rng := RandomNumberGenerator.new()
var drag_start := Vector2.INF  # pointer swipe anchor, INF = none
var autoplay := true  # attract mode ON at boot; any steering input hands control to player
var rainbow_t := 0.0
var death_timer := 0.0
var glow_dots: Array[Vector2] = []
var glow_phase: Array[float] = []

var score_label: Label
var best_label: Label
var hint_label: Label
var autoplay_label: Label
var overlay: CanvasLayer
var overlay_title: Label
var overlay_sub: Label
var yell_player: AudioStreamPlayer
var yell_muted := false
var last_yell_msec := -100000


func _ready() -> void:
	rng.randomize()
	_seed_glow_dots()
	_build_hud()
	_build_overlay()
	_build_audio()
	start_game()


func start_game() -> void:
	restart_game()


func restart_game() -> void:
	score = 0
	var cx := GRID_COLS / 2
	var cy := GRID_ROWS / 2
	snake = [Vector2i(cx, cy), Vector2i(cx - 1, cy), Vector2i(cx - 2, cy), Vector2i(cx - 3, cy)]
	dir = Vector2i.RIGHT
	queued_dir = Vector2i.RIGHT
	alive = true
	step_timer = 0.0
	death_timer = 0.0
	drag_start = Vector2.INF
	# NOTE: autoplay flag preserved; manual restarts stay manual, autoplay stays autoplay.
	_place_coin()
	overlay.visible = false
	_update_hud()
	queue_redraw()
	if DisplayServer.get_name() == "headless":
		print("[autoplay] restart alive=true autoplay=%s" % str(autoplay))


func current_step() -> float:
	return maxf(MIN_STEP, BASE_STEP - float(score) * RAMP_PER_COIN)


func set_direction(d: Vector2i) -> void:
	# Reject zero and direct reversal of the committed direction.
	if d == Vector2i.ZERO:
		return
	if d + dir == Vector2i.ZERO and snake.size() > 1:
		return
	queued_dir = d


func _player_steer(d: Vector2i) -> void:
	# Any steering input hands control to the player.
	if d == Vector2i.ZERO:
		return
	if autoplay:
		autoplay = false
		_update_hud()
	set_direction(d)


func eat_coin() -> void:
	# Test/debug hook: force the eat path as if the head reached the coin.
	if not alive:
		return
	score += 1
	if score > best:
		best = score
	_place_coin()
	_update_hud()
	queue_redraw()
	if DisplayServer.get_name() == "headless":
		print("[autoplay] ate coin score=%d autoplay=%s" % [score, str(autoplay)])


func _physics_process(delta: float) -> void:
	_poll_keys()
	if not alive:
		return
	step_timer += delta
	var interval := current_step()
	while step_timer >= interval and alive:
		step_timer -= interval
		_step()
		interval = current_step()


func _autoplay_pick() -> Vector2i:
	# Greedy attract AI: minimize Manhattan distance to coin among safe moves.
	# Never reverses. Current direction wins ties (listed first).
	var ordered: Array[Vector2i] = [dir]
	for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if d != dir and d + dir != Vector2i.ZERO:
			ordered.append(d)
	var target := Vector2i(coin) if coin.x >= 0 else snake[0]
	var best_d := dir
	var best_dist := 1 << 30
	var found := false
	for d in ordered:
		var head: Vector2i = snake[0] + d
		if head.x < 0 or head.y < 0 or head.x >= GRID_COLS or head.y >= GRID_ROWS:
			continue
		var growing := head == coin
		var limit := snake.size()
		if not growing:
			limit -= 1
		var hits_self := false
		for i in limit:
			if snake[i] == head:
				hits_self = true
				break
		if hits_self:
			continue
		var dist := absi(head.x - target.x) + absi(head.y - target.y)
		if not found or dist < best_dist:
			found = true
			best_d = d
			best_dist = dist
	return best_d  # all moves lethal: keep heading, die, auto-restart


func _step() -> void:
	if autoplay:
		queued_dir = _autoplay_pick()
	if queued_dir + dir != Vector2i.ZERO or snake.size() <= 1:
		dir = queued_dir
	var head: Vector2i = snake[0] + dir
	# Walls kill.
	if head.x < 0 or head.y < 0 or head.x >= GRID_COLS or head.y >= GRID_ROWS:
		_die()
		return
	var growing := head == coin
	# Self kill (tail cell is free unless growing).
	var limit := snake.size()
	if not growing:
		limit -= 1
	for i in limit:
		if snake[i] == head:
			_die()
			return
	snake.push_front(head)
	if growing:
		eat_coin()
	else:
		snake.pop_back()
	queue_redraw()


func _die() -> void:
	alive = false
	death_timer = 0.0
	_play_yell()
	if score > best:
		best = score
	overlay_title.text = "GAME OVER"
	if autoplay:
		overlay_sub.text = "Score: %d   Best: %d   [AUTOPLAY]\nAuto-restarting... WASD / arrows / swipe to take over." % [score, best]
	else:
		overlay_sub.text = "Score: %d   Best: %d\nEat coins, dodge walls and tail.\nPress R / Enter / Space or click / tap  |  T for autoplay" % [score, best]
	overlay.visible = true
	_update_hud()
	queue_redraw()
	if DisplayServer.get_name() == "headless":
		print("[autoplay] died score=%d best=%d autoplay=%s" % [score, best, str(autoplay)])


func _place_coin() -> void:
	var free: Array[Vector2i] = []
	for y in GRID_ROWS:
		for x in GRID_COLS:
			var c := Vector2i(x, y)
			if not c in snake:
				free.append(c)
	if free.is_empty():
		coin = Vector2i(-1, -1)
		return
	coin = free[rng.randi_range(0, free.size() - 1)]


func _seed_glow_dots() -> void:
	glow_dots.clear()
	glow_phase.clear()
	for i in GLOW_DOT_COUNT:
		glow_dots.append(Vector2(rng.randf_range(0.0, 1152.0), rng.randf_range(0.0, 648.0)))
		glow_phase.append(rng.randf_range(0.0, TAU))


func _process(delta: float) -> void:
	rainbow_t += delta
	# Cheap modulate pulse on the existing badge node (no shaders).
	if autoplay_label != null:
		autoplay_label.modulate = Color.from_hsv(fmod(rainbow_t * 0.12, 1.0), 0.35, 1.0) if autoplay else Color.WHITE
	if not alive and autoplay:
		death_timer += delta
		if death_timer >= AUTOPLAY_RESTART_DELAY:
			restart_game()
	queue_redraw()


func _draw() -> void:
	var field := Rect2(ORIGIN, Vector2(GRID_COLS * CELL, GRID_ROWS * CELL))
	var hue := fmod(rainbow_t * 0.06, 1.0)
	draw_rect(Rect2(Vector2.ZERO, Vector2(1152, 648)), Color(0.04, 0.08, 0.05))
	# Background glow dots: slow hue-cycling, low alpha, zero extra nodes.
	for i in GLOW_DOT_COUNT:
		var pulse := 0.5 + 0.5 * sin(rainbow_t * 0.8 + glow_phase[i])
		var dot_hue := fmod(hue + float(i) / float(GLOW_DOT_COUNT), 1.0)
		var radius := 26.0 + 14.0 * (float(i % 5) / 4.0)
		draw_circle(glow_dots[i], radius, Color(Color.from_hsv(dot_hue, 0.6, 0.9), 0.05 + 0.04 * pulse))
	# Arena frame cycles rainbow hues over time.
	draw_rect(field.grow(10.0), Color(Color.from_hsv(hue, 0.8, 0.55), 0.35))
	draw_rect(field.grow(6.0), Color.from_hsv(hue, 0.7, 0.85))
	draw_rect(field, Color(0.06, 0.14, 0.08))
	# Faint checkerboard for readability.
	for y in GRID_ROWS:
		for x in GRID_COLS:
			if (x + y) % 2 == 0:
				draw_rect(Rect2(ORIGIN + Vector2(x, y) * CELL, Vector2(CELL, CELL)), Color(1, 1, 1, 0.03))
	# Coin: golden octagon with sparkle pulse (scale/alpha oscillation).
	if coin.x >= 0:
		var sparkle := 0.5 + 0.5 * sin(rainbow_t * 6.0)
		var cc := ORIGIN + (Vector2(coin) + Vector2(0.5, 0.5)) * CELL
		var r := CELL * 0.36 * (1.0 + 0.12 * sin(rainbow_t * 6.0))
		draw_circle(cc, r * 1.7, Color(1.0, 0.9, 0.4, 0.14 + 0.12 * sparkle))
		draw_colored_polygon(_octagon_points(cc, r), Color(0.78, 0.55, 0.05))
		draw_colored_polygon(_octagon_points(cc, r * 0.7), Color(1.0, 0.85, 0.3))
		draw_circle(cc + Vector2(-r * 0.22, -r * 0.28), r * 0.18, Color(1.0, 0.96, 0.7, 0.6 + 0.4 * sparkle))
	# Snake: pastel nekomimi head (pink/white, cat ears, cute eyes),
	# pastel mint/lavender body, golden coin. Grid logic untouched.
	for i in range(snake.size() - 1, -1, -1):
		var cell_rect := Rect2(ORIGIN + Vector2(snake[i]) * CELL + Vector2(2, 2), Vector2(CELL - 4, CELL - 4))
		if i == 0:
			var hc := cell_rect.get_center()
			# White glow pulse behind the head.
			var hpulse := 0.5 + 0.5 * sin(rainbow_t * 4.0)
			draw_circle(hc, CELL * 0.75, Color(1.0, 1.0, 1.0, 0.14 + 0.12 * hpulse))
			# Nekomimi ears: two small triangles on top edge (outer pink, inner white).
			draw_rect(cell_rect, Color(1.0, 0.78, 0.86), true)
			var ear_l := PackedVector2Array([hc + Vector2(-10, -8), hc + Vector2(-2, -8), hc + Vector2(-8, -20)])
			var ear_r := PackedVector2Array([hc + Vector2(2, -8), hc + Vector2(10, -8), hc + Vector2(8, -20)])
			draw_colored_polygon(ear_l, Color(1.0, 0.62, 0.76))
			draw_colored_polygon(ear_r, Color(1.0, 0.62, 0.76))
			var in_l := PackedVector2Array([hc + Vector2(-8, -10), hc + Vector2(-4, -10), hc + Vector2(-7.2, -16)])
			var in_r := PackedVector2Array([hc + Vector2(4, -10), hc + Vector2(8, -10), hc + Vector2(7.2, -16)])
			draw_colored_polygon(in_l, Color(1.0, 1.0, 1.0))
			draw_colored_polygon(in_r, Color(1.0, 1.0, 1.0))
			var eye_off := Vector2(dir) * 6.0
			var perp := Vector2(-dir.y, dir.x) * 7.0
			draw_circle(hc + eye_off + perp, 4.5, Color.WHITE)
			draw_circle(hc + eye_off - perp, 4.5, Color.WHITE)
			draw_circle(hc + eye_off + perp, 2.2, Color(0.15, 0.12, 0.18))
			draw_circle(hc + eye_off - perp, 2.2, Color(0.15, 0.12, 0.18))
			draw_circle(hc + eye_off + perp + Vector2(-1, -1), 0.9, Color.WHITE)
			draw_circle(hc + eye_off - perp + Vector2(-1, -1), 0.9, Color.WHITE)
		else:
			var t := float(i) / float(maxi(snake.size() - 1, 1))
			var base := Color(0.62, 0.93, 0.79) if i % 2 == 0 else Color(0.79, 0.79, 0.98)
			var col := base.lerp(base.darkened(0.18), t)
			draw_rect(cell_rect, col, true)


func _octagon_points(center: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 8:
		var a := TAU * float(i) / 8.0 + PI / 8.0
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts


func _poll_keys() -> void:
	var d := Vector2i.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		d = Vector2i.LEFT
	elif Input.is_physical_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		d = Vector2i.RIGHT
	elif Input.is_physical_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		d = Vector2i.UP
	elif Input.is_physical_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		d = Vector2i.DOWN
	if d != Vector2i.ZERO:
		_player_steer(d)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.physical_keycode:
			KEY_W, KEY_UP:
				_player_steer(Vector2i.UP)
			KEY_S, KEY_DOWN:
				_player_steer(Vector2i.DOWN)
			KEY_A, KEY_LEFT:
				_player_steer(Vector2i.LEFT)
			KEY_D, KEY_RIGHT:
				_player_steer(Vector2i.RIGHT)
			KEY_T:
				_toggle_autoplay()
			KEY_M:
				_toggle_mute()
			KEY_R, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				restart_game()
		# Fallback for layouts where physical keycode is unset (web quirk).
		if k.keycode != KEY_NONE:
			match k.keycode:
				KEY_W, KEY_UP:
					_player_steer(Vector2i.UP)
				KEY_S, KEY_DOWN:
					_player_steer(Vector2i.DOWN)
				KEY_A, KEY_LEFT:
					_player_steer(Vector2i.LEFT)
				KEY_D, KEY_RIGHT:
					_player_steer(Vector2i.RIGHT)
				KEY_T:
					_toggle_autoplay()
				KEY_M:
					_toggle_mute()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if not alive:
					restart_game()
				else:
					drag_start = mb.position
			else:
				drag_start = Vector2.INF
	elif event is InputEventMouseMotion:
		if alive and drag_start != Vector2.INF:
			_apply_swipe((event as InputEventMouseMotion).position)
	elif event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			if not alive:
				restart_game()
			else:
				drag_start = st.position
		else:
			drag_start = Vector2.INF
	elif event is InputEventScreenDrag:
		if alive and drag_start != Vector2.INF:
			_apply_swipe((event as InputEventScreenDrag).position)


func _toggle_autoplay() -> void:
	autoplay = not autoplay
	if autoplay and not alive:
		restart_game()
	else:
		_update_hud()
		queue_redraw()


func _build_audio() -> void:
	yell_player = AudioStreamPlayer.new()
	yell_player.name = "YellPlayer"
	yell_player.stream = YELL_STREAM
	add_child(yell_player)


func _play_yell() -> void:
	if yell_muted or yell_player == null:
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec - last_yell_msec < YELL_COOLDOWN * 1000.0:
		return
	last_yell_msec = now_msec
	yell_player.play()


func _toggle_mute() -> void:
	yell_muted = not yell_muted
	if yell_muted and yell_player != null and yell_player.playing:
		yell_player.stop()
	_update_hud()


func _apply_swipe(pos: Vector2) -> void:
	var delta := pos - drag_start
	if delta.length() < 24.0:
		return
	if absf(delta.x) >= absf(delta.y):
		_player_steer(Vector2i.RIGHT if delta.x > 0.0 else Vector2i.LEFT)
	else:
		_player_steer(Vector2i.DOWN if delta.y > 0.0 else Vector2i.UP)
	drag_start = pos  # re-anchor so one swipe can chain turns


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 36)
	score_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	hud.add_child(score_label)
	score_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	score_label.position = Vector2(48, 16)
	best_label = Label.new()
	best_label.add_theme_font_size_override("font_size", 36)
	best_label.add_theme_color_override("font_color", Color.WHITE)
	hud.add_child(best_label)
	best_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	best_label.position = Vector2(-248, 16)
	best_label.size = Vector2(200, 48)
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	autoplay_label = Label.new()
	autoplay_label.add_theme_font_size_override("font_size", 24)
	autoplay_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	autoplay_label.position = Vector2(-150, 22)
	autoplay_label.size = Vector2(300, 36)
	autoplay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(autoplay_label)
	hint_label = Label.new()
	hint_label.text = "Nekomimi Snake - Mmmmm coins  |  WASD / arrows / swipe  |  R to restart  |  T autoplay  |  M mute"
	hint_label.add_theme_font_size_override("font_size", 18)
	hint_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.72))
	hud.add_child(hint_label)
	hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.position = Vector2(-350, -36)
	hint_label.size = Vector2(700, 28)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_overlay() -> void:
	overlay = CanvasLayer.new()
	overlay.layer = 10
	add_child(overlay)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.65)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)
	overlay_title = Label.new()
	overlay_title.text = "Nekomimi Snake - Mmmmm coins"
	overlay_title.add_theme_font_size_override("font_size", 56)
	overlay_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_title.set_anchors_preset(Control.PRESET_CENTER)
	overlay_title.position = Vector2(-500, -120)
	overlay_title.size = Vector2(1000, 80)
	overlay.add_child(overlay_title)
	overlay_sub = Label.new()
	overlay_sub.add_theme_font_size_override("font_size", 26)
	overlay_sub.add_theme_color_override("font_color", Color.WHITE)
	overlay_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	overlay_sub.set_anchors_preset(Control.PRESET_CENTER)
	overlay_sub.position = Vector2(-500, -30)
	overlay_sub.size = Vector2(1000, 200)
	overlay.add_child(overlay_sub)
	overlay.visible = false


func _update_hud() -> void:
	score_label.text = "Coins: %d" % score
	best_label.text = "Best: %d" % best
	if hint_label != null:
		hint_label.text = "Nekomimi Snake - Mmmmm coins  |  WASD / arrows / swipe  |  R to restart  |  T autoplay  |  M mute" + ("  [MUTED]" if yell_muted else "")
	_update_autoplay_badge()


func _update_autoplay_badge() -> void:
	if autoplay_label == null:
		return
	if autoplay:
		autoplay_label.text = "AUTOPLAY"
		autoplay_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	else:
		autoplay_label.text = "MANUAL (T)"
		autoplay_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
