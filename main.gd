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
const GLOW_DOT_COUNT := 16  # only extra-draw cost; zero extra nodes
const AUTOPLAY_RESTART_DELAY := 2.0
const EAT_FLASH_TIME := 0.5
const DANGER_LOOKAHEAD := 2
const YELL_STREAM := preload("res://assets/yell.ogg")
const MUSIC_STREAM := preload("res://assets/music.mp3")
const YELL_COOLDOWN := 1.0
const MAX_HEARTS := 3
const MERCY_TIME := 2.0
const COINS_PER_HEART := 8
const HURT_FLASH_TIME := 0.6
const ROAMER_COUNT := 50
const ROAMER_MIN_SPEED := 120.0
const ROAMER_MAX_SPEED := 260.0
const ROAMER_TURN_CHANCE := 0.6

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
var eat_flash := 0.0

var score_label: Label
var best_label: Label
var hint_label: Label
var autoplay_label: Label
var overlay: CanvasLayer
var overlay_title: Label
var overlay_sub: Label
var yell_player: AudioStreamPlayer
var music_player: AudioStreamPlayer
var yell_muted := false
var last_yell_msec := -100000
var hearts := 3
var mercy_timer := 0.0
var hurt_flash := 0.0
var coins_since_heal := 0
var hp_label: Label
# Ambient crowd: parallel typed arrays (no per-frame Dict/Variant overhead).
var roamer_pos: Array[Vector2] = []
var roamer_vel: Array[Vector2] = []
var roamer_phase: Array[float] = []
var roamer_tunic: Array[Color] = []
var roamer_trim: Array[Color] = []
var roamer_skin: Array[Color] = []
var roamer_shade: Array[Color] = []
var oct_unit := PackedVector2Array()
# Reused polygon buffers: _draw fills then draws immediately, so sharing
# is safe and kills all per-frame PackedVector2Array allocations.
var poly8 := PackedVector2Array()
var tri3 := PackedVector2Array()


func _ready() -> void:
	rng.randomize()
	_seed_glow_dots()
	_seed_oct_unit()
	_seed_roamers()
	_build_hud()
	_build_overlay()
	_build_audio()
	start_game()


func start_game() -> void:
	restart_game()


func restart_game() -> void:
	score = 0
	hearts = MAX_HEARTS
	mercy_timer = 0.0
	hurt_flash = 0.0
	coins_since_heal = 0
	var cx := GRID_COLS / 2
	var cy := GRID_ROWS / 2
	snake = [Vector2i(cx, cy), Vector2i(cx - 1, cy), Vector2i(cx - 2, cy), Vector2i(cx - 3, cy)]
	dir = Vector2i.RIGHT
	queued_dir = Vector2i.RIGHT
	alive = true
	step_timer = 0.0
	death_timer = 0.0
	eat_flash = 0.0
	drag_start = Vector2.INF
	# NOTE: autoplay flag preserved; manual restarts stay manual, autoplay stays autoplay.
	_place_coin()
	_seed_roamers()
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
	coins_since_heal += 1
	if coins_since_heal >= COINS_PER_HEART:
		coins_since_heal = 0
		if hearts < MAX_HEARTS:
			hearts += 1
	eat_flash = 1.0
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
	# Hamilton-style survivor AI: BFS shortest path to coin (body is obstacle
	# except the vacating tail, mirroring _step), taken only if the new tail
	# stays reachable after the move (flood-fill guard against sealed traps).
	# Falls back to tail-chase stalling, then any non-suicidal move.
	if snake.is_empty():
		return dir
	var head: Vector2i = snake[0]
	var blocked := _ai_blocked()
	# 1. Shortest path to coin, guarded by tail-reachability.
	if coin.x >= 0:
		var first := _bfs_first(head, coin, blocked)
		if first != Vector2i.ZERO and (first + dir != Vector2i.ZERO or snake.size() <= 1):
			var nh := head + first
			if not _ai_cell_hits(nh):
				var sim: Array[Vector2i] = [nh]
				var keep := snake.size() if nh == coin else snake.size() - 1
				for i in keep:
					sim.append(snake[i])
				if _ai_tail_reachable(sim):
					return first
	# 2. Stall safely: chase own tail (same obstacle rules).
	var tail: Vector2i = snake[snake.size() - 1]
	var to_tail := _bfs_first(head, tail, blocked)
	if to_tail != Vector2i.ZERO and (to_tail + dir != Vector2i.ZERO or snake.size() <= 1):
		if not _ai_cell_hits(head + to_tail):
			return to_tail
	# 3. Any non-suicidal move, current heading first, never reverse.
	var ordered: Array[Vector2i] = [dir]
	for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if d != dir and d + dir != Vector2i.ZERO:
			ordered.append(d)
	for d in ordered:
		var nh2 := head + d
		if nh2.x < 0 or nh2.y < 0 or nh2.x >= GRID_COLS or nh2.y >= GRID_ROWS:
			continue
		if _ai_cell_hits(nh2):
			continue
		return d
	return dir  # all moves lethal: keep heading, die, auto-restart


func _ai_blocked() -> Dictionary:
	# Snake body as obstacle, minus the tail cell that vacates this step.
	var blocked := {}
	for i in range(maxi(snake.size() - 1, 0)):
		blocked[snake[i]] = true
	return blocked


func _ai_cell_hits(cell: Vector2i) -> bool:
	# Mirrors _step self-kill logic: tail cell is free unless growing.
	var growing := cell == coin
	var limit := snake.size()
	if not growing:
		limit -= 1
	for i in limit:
		if snake[i] == cell:
			return true
	return false


func _bfs_first(from: Vector2i, target: Vector2i, blocked: Dictionary) -> Vector2i:
	# First step of the shortest path from->target, or ZERO when unreachable.
	# Neighbor order prefers the current heading for stable, non-jittery play.
	if from == target:
		return Vector2i.ZERO
	var order: Array[Vector2i] = [dir]
	for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if d != dir:
			order.append(d)
	var parent := {from: from}
	var queue: Array[Vector2i] = [from]
	var head_idx := 0
	while head_idx < queue.size():
		var cur: Vector2i = queue[head_idx]
		head_idx += 1
		for d in order:
			var nxt: Vector2i = cur + d
			if nxt.x < 0 or nxt.y < 0 or nxt.x >= GRID_COLS or nxt.y >= GRID_ROWS:
				continue
			if parent.has(nxt):
				continue
			if nxt != target and blocked.has(nxt):
				continue
			parent[nxt] = cur
			if nxt == target:
				var c := nxt
				while parent[c] != from:
					c = parent[c]
				return c - from
			queue.append(nxt)
	return Vector2i.ZERO


func _ai_tail_reachable(body: Array[Vector2i]) -> bool:
	# Flood-fill from the new head: can it still reach the new tail?
	# Free cells include the future-vacating tail (excluded from obstacles).
	if body.is_empty():
		return false
	var blocked := {}
	for i in range(body.size() - 1):
		blocked[body[i]] = true
	var tail: Vector2i = body[body.size() - 1]
	var seen := {body[0]: true}
	var queue: Array[Vector2i] = [body[0]]
	var head_idx := 0
	while head_idx < queue.size():
		var cur: Vector2i = queue[head_idx]
		head_idx += 1
		if cur == tail:
			return true
		for d in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
			var nxt: Vector2i = cur + d
			if nxt.x < 0 or nxt.y < 0 or nxt.x >= GRID_COLS or nxt.y >= GRID_ROWS:
				continue
			if seen.has(nxt) or blocked.has(nxt):
				continue
			seen[nxt] = true
			queue.append(nxt)
	return seen.has(tail)


func _danger_ahead() -> bool:
	# True when a wall or body cell sits within DANGER_LOOKAHEAD steps ahead.
	# Uses the same tail-vacates rule as _step (tail cell counts as free).
	if snake.is_empty():
		return false
	var body := {}
	for i in range(maxi(snake.size() - 1, 0)):
		body[snake[i]] = true
	var p: Vector2i = snake[0]
	for i in DANGER_LOOKAHEAD:
		p += dir
		if p.x < 0 or p.y < 0 or p.x >= GRID_COLS or p.y >= GRID_ROWS:
			return true
		if body.has(p):
			return true
	return false


func _step() -> void:
	if autoplay:
		queued_dir = _autoplay_pick()
	if queued_dir + dir != Vector2i.ZERO or snake.size() <= 1:
		dir = queued_dir
	var head: Vector2i = snake[0] + dir
	# Walls kill (mercy invincibility: hold position, no death).
	if head.x < 0 or head.y < 0 or head.x >= GRID_COLS or head.y >= GRID_ROWS:
		if mercy_timer > 0.0:
			return
		_die()
		return
	var growing := head == coin
	# Self kill (tail cell is free unless growing; mercy: hold position).
	var limit := snake.size()
	if not growing:
		limit -= 1
	for i in limit:
		if snake[i] == head:
			if mercy_timer > 0.0:
				return
			_die()
			return
	snake.push_front(head)
	if growing:
		eat_coin()
	else:
		snake.pop_back()
	queue_redraw()


func _die() -> void:
	if mercy_timer > 0.0:
		return
	# Damage system: hearts absorb lethal hits, yell EVERY time.
	if hearts > 1:
		hearts -= 1
		last_yell_msec = -100000  # force yell: every damage yells
		_play_yell()
		hurt_flash = 1.0
		mercy_timer = MERCY_TIME
		var cx := GRID_COLS / 2
		var cy := GRID_ROWS / 2
		snake = [Vector2i(cx, cy), Vector2i(cx - 1, cy), Vector2i(cx - 2, cy), Vector2i(cx - 3, cy)]
		dir = Vector2i.RIGHT
		queued_dir = Vector2i.RIGHT
		step_timer = 0.0
		if coin in snake:
			_place_coin()
		_update_hud()
		queue_redraw()
		if DisplayServer.get_name() == "headless":
			print("[damage] hit hearts=%d mercy=%.1f score=%d" % [hearts, mercy_timer, score])
		return
	hearts = 0
	alive = false
	death_timer = 0.0
	last_yell_msec = -100000  # force yell: death always yells
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


func _seed_oct_unit() -> void:
	# Unit octagon baked once; coin draw just scales/translates it.
	oct_unit.clear()
	for i in 8:
		var a := TAU * float(i) / 8.0 + PI / 8.0
		oct_unit.append(Vector2(cos(a), sin(a)))


func _field_rect() -> Rect2:
	return Rect2(ORIGIN, Vector2(GRID_COLS * CELL, GRID_ROWS * CELL))


func _seed_roamers() -> void:
	# Ambient background crowd: 50 fast wanderers, no gameplay effect.
	# Respectful pixel-art field workers with conical straw hats.
	# Derived shades are baked here so _draw does zero allocs/conversions.
	roamer_pos.clear()
	roamer_vel.clear()
	roamer_phase.clear()
	roamer_tunic.clear()
	roamer_trim.clear()
	roamer_skin.clear()
	roamer_shade.clear()
	var field := _field_rect()
	var tunics: Array[Color] = [
		Color(0.25, 0.45, 0.75), Color(0.35, 0.55, 0.65),
		Color(0.55, 0.45, 0.30), Color(0.45, 0.45, 0.50),
		Color(0.30, 0.60, 0.45),
	]
	var skins: Array[Color] = [
		Color(0.96, 0.80, 0.62), Color(0.90, 0.71, 0.53),
		Color(0.82, 0.62, 0.45),
	]
	for i in ROAMER_COUNT:
		roamer_pos.append(Vector2(
			rng.randf_range(field.position.x + 16.0, field.end.x - 16.0),
			rng.randf_range(field.position.y + 16.0, field.end.y - 16.0)
		))
		var ang := rng.randf_range(0.0, TAU)
		var speed := rng.randf_range(ROAMER_MIN_SPEED, ROAMER_MAX_SPEED)
		roamer_vel.append(Vector2(cos(ang), sin(ang)) * speed)
		roamer_phase.append(rng.randf_range(0.0, TAU))
		var tunic: Color = tunics[rng.randi_range(0, tunics.size() - 1)]
		var skin: Color = skins[rng.randi_range(0, skins.size() - 1)]
		roamer_tunic.append(tunic)
		roamer_trim.append(tunic.darkened(0.35))
		roamer_skin.append(skin)
		roamer_shade.append(skin.darkened(0.25))


func _update_roamers(delta: float) -> void:
	if roamer_pos.is_empty():
		return
	var field := _field_rect()
	var margin := 10.0
	for i in roamer_pos.size():
		var pos := roamer_pos[i]
		var vel := roamer_vel[i]
		# Random wander turns, keeps them roaming instead of straight lines.
		if rng.randf() < ROAMER_TURN_CHANCE * delta:
			vel = vel.rotated(rng.randf_range(-0.5, 0.5))
			# Keep speed in the fast band after rotation.
			var sp := clampf(vel.length(), ROAMER_MIN_SPEED, ROAMER_MAX_SPEED)
			vel = vel.normalized() * sp
		pos += vel * delta
		# Bounce off arena walls.
		if pos.x < field.position.x + margin:
			pos.x = field.position.x + margin
			vel.x = absf(vel.x)
		elif pos.x > field.end.x - margin:
			pos.x = field.end.x - margin
			vel.x = -absf(vel.x)
		if pos.y < field.position.y + margin:
			pos.y = field.position.y + margin
			vel.y = absf(vel.y)
		elif pos.y > field.end.y - margin:
			pos.y = field.end.y - margin
			vel.y = -absf(vel.y)
		roamer_pos[i] = pos
		roamer_vel[i] = vel
		roamer_phase[i] = roamer_phase[i] + delta * vel.length() * 0.06


func _draw_roamer(center: Vector2, facing_x: float, phase: float, tunic: Color, trim: Color, skin: Color, shade: Color) -> void:
	# Chunky pixel-art field worker, ~16x26 px. Rects only: no per-frame
	# allocs, no circle/polygon triangulation. Drawn feet-first.
	var hat := Color(0.85, 0.72, 0.42)
	var hat_dark := Color(0.62, 0.50, 0.28)
	var pants := Color(0.16, 0.16, 0.20)
	var step := sin(phase) * 3.0
	# Flat rect shadow: cheaper than a circle.
	draw_rect(Rect2(center + Vector2(-6, 11), Vector2(12, 2)), Color(0, 0, 0, 0.25))
	# Legs: 2-frame run, alternate offsets. Sandals folded into leg base.
	draw_rect(Rect2(center + Vector2(-5, 4 + step * 0.5), Vector2(4, 8)), pants)
	draw_rect(Rect2(center + Vector2(1, 4 - step * 0.5), Vector2(4, 8)), pants)
	# Tunic body + belt.
	draw_rect(Rect2(center + Vector2(-6, -4), Vector2(12, 9)), tunic)
	draw_rect(Rect2(center + Vector2(-6, 2), Vector2(12, 2)), trim)
	# Arms swinging opposite to legs.
	draw_rect(Rect2(center + Vector2(-9, -3 - step * 0.5), Vector2(3, 6)), shade)
	draw_rect(Rect2(center + Vector2(6, -3 + step * 0.5), Vector2(3, 6)), shade)
	# Head + hair fringe.
	draw_rect(Rect2(center + Vector2(-4, -10), Vector2(8, 6)), skin)
	draw_rect(Rect2(center + Vector2(-4, -10), Vector2(8, 2)), Color(0.10, 0.10, 0.12))
	# Eyes: plain single-pixel dots, shifted by facing.
	var look := clampf(facing_x, -1.0, 1.0) * 1.5
	draw_rect(Rect2(center + Vector2(-2 + look, -7), Vector2(1, 2)), Color(0.10, 0.10, 0.12))
	draw_rect(Rect2(center + Vector2(1 + look, -7), Vector2(1, 2)), Color(0.10, 0.10, 0.12))
	# Stepped-pyramid straw hat: 3 rects + dark brim, no polygon alloc.
	draw_rect(Rect2(center + Vector2(-2, -19), Vector2(4, 3)), hat)
	draw_rect(Rect2(center + Vector2(-5, -16), Vector2(10, 4)), hat)
	draw_rect(Rect2(center + Vector2(-8, -12), Vector2(16, 2)), hat)
	draw_rect(Rect2(center + Vector2(-8, -10), Vector2(16, 1)), hat_dark)


func _process(delta: float) -> void:
	rainbow_t += delta
	_update_roamers(delta)
	if eat_flash > 0.0:
		eat_flash = maxf(0.0, eat_flash - delta / EAT_FLASH_TIME)
	if hurt_flash > 0.0:
		hurt_flash = maxf(0.0, hurt_flash - delta / HURT_FLASH_TIME)
	if mercy_timer > 0.0:
		mercy_timer = maxf(0.0, mercy_timer - delta)
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
	# Background glow dots: hue-cycling, alpha shimmers with step rate.
	var speed_t := 0.0
	if BASE_STEP > MIN_STEP:
		speed_t = clampf((BASE_STEP - current_step()) / (BASE_STEP - MIN_STEP), 0.0, 1.0)
	for i in GLOW_DOT_COUNT:
		var pulse := 0.5 + 0.5 * sin(rainbow_t * 0.8 + glow_phase[i])
		var dot_hue := fmod(hue + float(i) / float(GLOW_DOT_COUNT), 1.0)
		var radius := 26.0 + 14.0 * (float(i % 5) / 4.0)
		draw_circle(glow_dots[i], radius, Color(Color.from_hsv(dot_hue, 0.6, 0.9), (0.05 + 0.04 * pulse) * (1.0 + speed_t)))
	# Arena frame cycles rainbow hues over time.
	draw_rect(field.grow(10.0), Color(Color.from_hsv(hue, 0.8, 0.55), 0.35))
	draw_rect(field.grow(6.0), Color.from_hsv(hue, 0.7, 0.85))
	if _danger_ahead() and alive:
		var dpulse := 0.5 + 0.5 * sin(rainbow_t * 10.0)
		draw_rect(field.grow(6.0), Color(1.0, 0.15, 0.15, 0.35 + 0.4 * dpulse), false, 4.0)
	draw_rect(field, Color(0.06, 0.14, 0.08))
	# Faint checkerboard for readability.
	for y in GRID_ROWS:
		for x in GRID_COLS:
			if (x + y) % 2 == 0:
				draw_rect(Rect2(ORIGIN + Vector2(x, y) * CELL, Vector2(CELL, CELL)), Color(1, 1, 1, 0.03))
	# Ambient roamers: background only, no collision, drawn under coin/snake.
	for i in roamer_pos.size():
		var rv := roamer_vel[i]
		var fx := 1.0 if rv.x >= 0.0 else -1.0
		_draw_roamer(roamer_pos[i], fx, roamer_phase[i], roamer_tunic[i], roamer_trim[i], roamer_skin[i], roamer_shade[i])
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
			# Mercy invincibility blink: skip head every other beat.
			if mercy_timer > 0.0 and fmod(rainbow_t * 12.0, 2.0) < 1.0:
				continue
			var hc := cell_rect.get_center()
			# White glow pulse behind the head.
			var hpulse := 0.5 + 0.5 * sin(rainbow_t * 4.0)
			draw_circle(hc, CELL * 0.75, Color(1.0, 1.0, 1.0, 0.14 + 0.12 * hpulse))
			# Nekomimi ears: two small triangles on top edge (outer pink, inner white).
			draw_rect(cell_rect, Color(1.0, 0.78, 0.86), true)
			_tri(hc + Vector2(-10, -8), hc + Vector2(-2, -8), hc + Vector2(-8, -20))
			draw_colored_polygon(tri3, Color(1.0, 0.62, 0.76))
			_tri(hc + Vector2(2, -8), hc + Vector2(10, -8), hc + Vector2(8, -20))
			draw_colored_polygon(tri3, Color(1.0, 0.62, 0.76))
			_tri(hc + Vector2(-8, -10), hc + Vector2(-4, -10), hc + Vector2(-7.2, -16))
			draw_colored_polygon(tri3, Color(1.0, 1.0, 1.0))
			_tri(hc + Vector2(4, -10), hc + Vector2(8, -10), hc + Vector2(7.2, -16))
			draw_colored_polygon(tri3, Color(1.0, 1.0, 1.0))
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
	# Eat flash: fullscreen white overlay decaying over EAT_FLASH_TIME.
	if eat_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(1152, 648)), Color(1.0, 1.0, 1.0, 0.35 * eat_flash))
	# Hurt flash: fullscreen red overlay decaying over HURT_FLASH_TIME.
	if hurt_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, Vector2(1152, 648)), Color(1.0, 0.1, 0.1, 0.45 * hurt_flash))


func _tri(a: Vector2, b: Vector2, c: Vector2) -> void:
	# Fill the shared triangle buffer. Draw must follow immediately.
	if tri3.size() != 3:
		tri3.resize(3)
	tri3[0] = a
	tri3[1] = b
	tri3[2] = c


func _octagon_points(center: Vector2, radius: float) -> PackedVector2Array:
	# Scale/translate the baked unit octagon: no sin/cos per frame.
	# Shared buffer, no allocation; draw must follow immediately.
	if poly8.size() != 8:
		poly8.resize(8)
	for i in 8:
		poly8[i] = center + oct_unit[i] * radius
	return poly8


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
	music_player = AudioStreamPlayer.new()
	music_player.name = "MusicPlayer"
	music_player.stream = MUSIC_STREAM
	(music_player.stream as AudioStreamMP3).loop = true
	music_player.volume_db = -8.0
	add_child(music_player)
	music_player.play()


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
	if music_player != null:
		if yell_muted:
			if music_player.playing:
				music_player.stop()
		elif not music_player.playing:
			music_player.play()
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
	hp_label = Label.new()
	hp_label.add_theme_font_size_override("font_size", 36)
	hp_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.25))
	hud.add_child(hp_label)
	hp_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hp_label.position = Vector2(260, 16)
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
	hint_label.text = "Nekomimi Snake - Mmmmm coins  |  WASD / arrows / swipe  |  R to restart  |  T autoplay  |  M mute music  |  click once for sound"
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
	if hp_label != null:
		hp_label.text = "HP: %d" % hearts
	best_label.text = "Best: %d" % best
	if hint_label != null:
		hint_label.text = "Nekomimi Snake - Mmmmm coins  |  WASD / arrows / swipe  |  R to restart  |  T autoplay  |  M mute music  |  click once for sound" + ("  [MUTED]" if yell_muted else "")
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
