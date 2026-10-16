extends Node2D
## Hyvapeli: Snake with coins. Eat golden coins to grow and score.
## Controls: WASD / arrows, swipe or drag to steer. R / Enter / Space / click / tap restarts.

const GRID_COLS := 24
const GRID_ROWS := 16
const CELL := 32.0
const ORIGIN := Vector2(192.0, 88.0)  # centers 768x512 field in 1152x648
const BASE_STEP := 0.14
const MIN_STEP := 0.07
const RAMP_PER_COIN := 0.003

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

var score_label: Label
var best_label: Label
var hint_label: Label
var overlay: CanvasLayer
var overlay_title: Label
var overlay_sub: Label


func _ready() -> void:
	rng.randomize()
	_build_hud()
	_build_overlay()
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
	drag_start = Vector2.INF
	_place_coin()
	overlay.visible = false
	_update_hud()
	queue_redraw()


func current_step() -> float:
	return maxf(MIN_STEP, BASE_STEP - float(score) * RAMP_PER_COIN)


func set_direction(d: Vector2i) -> void:
	# Reject zero and direct reversal of the committed direction.
	if d == Vector2i.ZERO:
		return
	if d + dir == Vector2i.ZERO and snake.size() > 1:
		return
	queued_dir = d


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


func _step() -> void:
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
	if score > best:
		best = score
	overlay_title.text = "GAME OVER"
	overlay_sub.text = "Score: %d   Best: %d\nEat coins, dodge walls and tail.\nPress R / Enter / Space or click / tap" % [score, best]
	overlay.visible = true
	_update_hud()
	queue_redraw()


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


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var field := Rect2(ORIGIN, Vector2(GRID_COLS * CELL, GRID_ROWS * CELL))
	draw_rect(Rect2(Vector2.ZERO, Vector2(1152, 648)), Color(0.04, 0.08, 0.05))
	draw_rect(field.grow(6.0), Color(0.12, 0.32, 0.18))
	draw_rect(field, Color(0.06, 0.14, 0.08))
	# Faint checkerboard for readability.
	for y in GRID_ROWS:
		for x in GRID_COLS:
			if (x + y) % 2 == 0:
				draw_rect(Rect2(ORIGIN + Vector2(x, y) * CELL, Vector2(CELL, CELL)), Color(1, 1, 1, 0.03))
	# Coin: golden octagon with shine.
	if coin.x >= 0:
		var cc := ORIGIN + (Vector2(coin) + Vector2(0.5, 0.5)) * CELL
		var r := CELL * 0.36
		draw_colored_polygon(_octagon_points(cc, r), Color(0.78, 0.55, 0.05))
		draw_colored_polygon(_octagon_points(cc, r * 0.7), Color(1.0, 0.85, 0.3))
		draw_circle(cc + Vector2(-r * 0.22, -r * 0.28), r * 0.18, Color(1.0, 0.96, 0.7))
	# Snake: green rounded body, lighter head, white eyes.
	for i in range(snake.size() - 1, -1, -1):
		var cell_rect := Rect2(ORIGIN + Vector2(snake[i]) * CELL + Vector2(2, 2), Vector2(CELL - 4, CELL - 4))
		if i == 0:
			draw_rect(cell_rect, Color(0.35, 0.85, 0.42), true)
			var hc := cell_rect.get_center()
			var eye_off := Vector2(dir) * 6.0
			var perp := Vector2(-dir.y, dir.x) * 7.0
			draw_circle(hc + eye_off + perp, 4.0, Color.WHITE)
			draw_circle(hc + eye_off - perp, 4.0, Color.WHITE)
			draw_circle(hc + eye_off + perp, 2.0, Color(0.02, 0.05, 0.03))
			draw_circle(hc + eye_off - perp, 2.0, Color(0.02, 0.05, 0.03))
		else:
			var t := float(i) / float(maxi(snake.size() - 1, 1))
			var col := Color(0.18, 0.75, 0.35).lerp(Color(0.10, 0.45, 0.20), t)
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
		set_direction(d)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		match k.physical_keycode:
			KEY_W, KEY_UP:
				set_direction(Vector2i.UP)
			KEY_S, KEY_DOWN:
				set_direction(Vector2i.DOWN)
			KEY_A, KEY_LEFT:
				set_direction(Vector2i.LEFT)
			KEY_D, KEY_RIGHT:
				set_direction(Vector2i.RIGHT)
			KEY_R, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				restart_game()
		# Fallback for layouts where physical keycode is unset (web quirk).
		if k.keycode != KEY_NONE:
			match k.keycode:
				KEY_W, KEY_UP:
					set_direction(Vector2i.UP)
				KEY_S, KEY_DOWN:
					set_direction(Vector2i.DOWN)
				KEY_A, KEY_LEFT:
					set_direction(Vector2i.LEFT)
				KEY_D, KEY_RIGHT:
					set_direction(Vector2i.RIGHT)
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


func _apply_swipe(pos: Vector2) -> void:
	var delta := pos - drag_start
	if delta.length() < 24.0:
		return
	if absf(delta.x) >= absf(delta.y):
		set_direction(Vector2i.RIGHT if delta.x > 0.0 else Vector2i.LEFT)
	else:
		set_direction(Vector2i.DOWN if delta.y > 0.0 else Vector2i.UP)
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
	hint_label = Label.new()
	hint_label.text = "WASD / arrows / swipe to steer  |  R to restart"
	hint_label.add_theme_font_size_override("font_size", 18)
	hint_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.72))
	hud.add_child(hint_label)
	hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.position = Vector2(-250, -36)
	hint_label.size = Vector2(500, 28)
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
