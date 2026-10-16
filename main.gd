extends Node2D
## Hyvapeli: Mmmmm coins. Grab GOAL coins before the timer runs out.
## Controls: WASD / arrows, or mouse / touch drag. R / Enter / tap restarts.

const ARENA := Rect2(40, 90, 1072, 500)
const PLAYER_SPEED := 420.0
const PLAYER_RADIUS := 24.0
const COIN_RADIUS := 18.0
const PICKUP_DIST := 44.0
const COINS_ON_FIELD := 6
const GOAL := 12
const TIME_LIMIT := 60.0

var score := 0
var time_left := TIME_LIMIT
var playing := false
var won := false
var elapsed := 0.0
var rng := RandomNumberGenerator.new()

var player: CharacterBody2D
var player_body: Polygon2D
var player_pop := 0.0
var drag_target := Vector2.INF  # active pointer destination, INF = none
var coins: Array[Node2D] = []

var score_label: Label
var timer_label: Label
var hint_label: Label
var overlay: CanvasLayer
var overlay_title: Label
var overlay_sub: Label

var sfx_pickup: AudioStreamPlayer
var sfx_win: AudioStreamPlayer
var sfx_lose: AudioStreamPlayer
var pickup_pitch := 1.0


func _ready() -> void:
	rng.seed = 1234567
	_build_background()
	_build_player()
	_build_hud()
	_build_overlay()
	_build_audio()
	start_game()


func start_game() -> void:
	score = 0
	time_left = TIME_LIMIT
	playing = true
	won = false
	elapsed = 0.0
	pickup_pitch = 1.0
	player.position = ARENA.get_center()
	player.velocity = Vector2.ZERO
	drag_target = Vector2.INF
	for c in coins:
		c.queue_free()
	coins.clear()
	for i in COINS_ON_FIELD:
		spawn_coin()
	overlay.visible = false
	_update_hud()


func _physics_process(delta: float) -> void:
	if not playing:
		return
	elapsed += delta
	time_left -= delta
	if time_left <= 0.0:
		time_left = 0.0
		end_game(false)
		return

	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	dir += _wasd_vector()
	if dir.length() > 1.0:
		dir = dir.normalized()
	if dir != Vector2.ZERO:
		drag_target = Vector2.INF  # keys win over pointer
		player.velocity = dir * PLAYER_SPEED
	elif drag_target != Vector2.INF:
		var to := drag_target - player.position
		if to.length() < 8.0:
			player.velocity = Vector2.ZERO
			drag_target = Vector2.INF
		else:
			player.velocity = to.normalized() * PLAYER_SPEED
	else:
		player.velocity = Vector2.ZERO
	player.move_and_slide()
	player.position.x = clampf(player.position.x, ARENA.position.x, ARENA.position.x + ARENA.size.x)
	player.position.y = clampf(player.position.y, ARENA.position.y, ARENA.position.y + ARENA.size.y)

	# Juicy wobble.
	if player_pop > 0.0:
		player_pop = maxf(0.0, player_pop - delta * 6.0)
	var s := 1.0 + 0.25 * player_pop
	player_body.scale = Vector2(s, s)
	player_body.rotation += delta * (2.0 + player.velocity.length() / 150.0)

	# Coin pickup by distance (no signals, no misses).
	for i in range(coins.size() - 1, -1, -1):
		var c := coins[i]
		if not is_instance_valid(c):
			coins.remove_at(i)
			continue
		if player.position.distance_to(c.position) <= PICKUP_DIST:
			coins.remove_at(i)
			c.queue_free()
			_collect_coin()

	# Coin bob and spin.
	for c in coins:
		if is_instance_valid(c):
			c.scale = Vector2.ONE * (1.0 + 0.08 * sin(elapsed * 5.0 + c.position.x * 0.05))
			c.rotation += delta * 1.5

	_update_hud()


func _collect_coin() -> void:
	score += 1
	player_pop = 1.0
	pickup_pitch = minf(pickup_pitch + 0.06, 1.6)  # rising pitch = more fun
	sfx_pickup.pitch_scale = pickup_pitch
	sfx_pickup.play()
	if score >= GOAL:
		end_game(true)
	else:
		spawn_coin()
		_update_hud()


func end_game(victory: bool) -> void:
	playing = false
	won = victory
	if victory:
		sfx_win.play()
		overlay_title.text = "MMMMM COINS! YOU WIN!"
		overlay_sub.text = "You grabbed %d coins with %.1fs left.\nMmmmm. Tasty.\n\nPress R / Enter or tap to play again" % [score, time_left]
	else:
		sfx_lose.play()
		overlay_title.text = "TIME UP! SO HUNGRY!"
		overlay_sub.text = "You grabbed %d / %d coins.\nMmmmm... almost.\n\nPress R / Enter or tap to try again" % [score, GOAL]
	overlay.visible = true
	_update_hud()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not playing:
			start_game()
		else:
			drag_target = get_global_mouse_position()
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if playing:
			drag_target = get_global_mouse_position()
	elif event is InputEventScreenTouch:
		if not playing:
			if event.pressed:
				start_game()
		elif event.pressed:
			drag_target = event.position
		else:
			drag_target = Vector2.INF
	elif event is InputEventScreenDrag:
		if playing:
			drag_target = event.position
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_R or k.physical_keycode == KEY_ENTER or k.physical_keycode == KEY_KP_ENTER:
			start_game()
		elif not playing and k.physical_keycode == KEY_SPACE:
			start_game()


func _wasd_vector() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		v.y += 1.0
	return v


func spawn_coin() -> void:
	var pos := _random_arena_point()
	# Keep some distance from the player so it never spawns on top.
	for attempt in 12:
		if pos.distance_to(player.position) >= 140.0:
			break
		pos = _random_arena_point()
	var coin := Node2D.new()
	coin.position = pos
	var rim := Polygon2D.new()
	rim.polygon = _octagon(COIN_RADIUS)
	rim.color = Color(0.78, 0.55, 0.05)
	var face := Polygon2D.new()
	face.polygon = _octagon(COIN_RADIUS * 0.72)
	face.color = Color(1.0, 0.85, 0.3)
	var shine := Polygon2D.new()
	shine.polygon = _octagon(COIN_RADIUS * 0.34)
	shine.position = Vector2(-4, -5)
	shine.color = Color(1.0, 0.96, 0.7)
	coin.add_child(rim)
	coin.add_child(face)
	coin.add_child(shine)
	add_child(coin)
	coins.append(coin)


func _random_arena_point() -> Vector2:
	return Vector2(
		rng.randf_range(ARENA.position.x + 30.0, ARENA.position.x + ARENA.size.x - 30.0),
		rng.randf_range(ARENA.position.y + 30.0, ARENA.position.y + ARENA.size.y - 30.0)
	)


func _octagon(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 8:
		var a := TAU * float(i) / 8.0 + PI / 8.0
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


func _circle_poly(r: float, n := 24) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


func _build_background() -> void:
	var layer := CanvasLayer.new()
	layer.layer = -10
	add_child(layer)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.07, 0.14)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	# Arena frame drawn in world space.
	var frame := Line2D.new()
	frame.width = 4.0
	frame.default_color = Color(0.3, 0.5, 0.9, 0.8)
	frame.points = PackedVector2Array([
		ARENA.position,
		ARENA.position + Vector2(ARENA.size.x, 0),
		ARENA.position + ARENA.size,
		ARENA.position + Vector2(0, ARENA.size.y),
		ARENA.position,
	])
	add_child(frame)
	# Decorative floor dots.
	for i in 40:
		var dot := Polygon2D.new()
		dot.polygon = _octagon(rng.randf_range(2.0, 5.0))
		dot.color = Color(0.16, 0.2, 0.34, 0.9)
		dot.position = _random_arena_point()
		add_child(dot)


func _build_player() -> void:
	player = CharacterBody2D.new()
	player.position = ARENA.get_center()
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = PLAYER_RADIUS
	shape.shape = circle
	player.add_child(shape)
	player_body = Polygon2D.new()
	player_body.polygon = _circle_poly(PLAYER_RADIUS)
	player_body.color = Color(0.25, 0.6, 1.0)
	player.add_child(player_body)
	var belly := Polygon2D.new()
	belly.polygon = _circle_poly(PLAYER_RADIUS * 0.55)
	belly.position = Vector2(0, 4)
	belly.color = Color(0.7, 0.88, 1.0)
	player.add_child(belly)
	var eye_l := Polygon2D.new()
	eye_l.polygon = _circle_poly(5.0, 10)
	eye_l.position = Vector2(-8, -6)
	eye_l.color = Color.WHITE
	player.add_child(eye_l)
	var eye_r := Polygon2D.new()
	eye_r.polygon = _circle_poly(5.0, 10)
	eye_r.position = Vector2(8, -6)
	eye_r.color = Color.WHITE
	player.add_child(eye_r)
	var pup_l := Polygon2D.new()
	pup_l.polygon = _circle_poly(2.4, 8)
	pup_l.position = Vector2(-8, -6)
	pup_l.color = Color(0.02, 0.03, 0.08)
	player.add_child(pup_l)
	var pup_r := Polygon2D.new()
	pup_r.polygon = _circle_poly(2.4, 8)
	pup_r.position = Vector2(8, -6)
	pup_r.color = Color(0.02, 0.03, 0.08)
	player.add_child(pup_r)
	add_child(player)


func _build_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	score_label = Label.new()
	score_label.position = Vector2(48, 16)
	score_label.add_theme_font_size_override("font_size", 36)
	score_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	add_child(score_label)
	score_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	# Labels need the CanvasLayer as parent to draw in screen space.
	remove_child(score_label)
	hud.add_child(score_label)
	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 36)
	timer_label.add_theme_color_override("font_color", Color.WHITE)
	hud.add_child(timer_label)
	timer_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	timer_label.position = Vector2(-60, 16)
	hint_label = Label.new()
	hint_label.text = "WASD / arrows / drag to move  |  R to restart"
	hint_label.add_theme_font_size_override("font_size", 18)
	hint_label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.9))
	hud.add_child(hint_label)
	hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.position = Vector2(-230, -40)


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
	overlay_sub.autowrap_mode = TextServer.AUTOWRAP_OFF
	overlay_sub.set_anchors_preset(Control.PRESET_CENTER)
	overlay_sub.position = Vector2(-500, -30)
	overlay_sub.size = Vector2(1000, 200)
	overlay.add_child(overlay_sub)
	overlay.visible = false


func _build_audio() -> void:
	sfx_pickup = AudioStreamPlayer.new()
	sfx_pickup.stream = _make_tone(880.0, 0.12, 0.25)
	add_child(sfx_pickup)
	sfx_win = AudioStreamPlayer.new()
	sfx_win.stream = _make_arpeggio([523.25, 659.25, 783.99, 1046.5], 0.14)
	add_child(sfx_win)
	sfx_lose = AudioStreamPlayer.new()
	sfx_lose.stream = _make_tone(160.0, 0.5, 0.3)
	add_child(sfx_lose)


func _make_tone(freq: float, duration: float, volume: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(duration * float(rate))
	var data := PackedByteArray()
	data.resize(n)
	for i in n:
		var t := float(i) / float(rate)
		var env := 1.0 - float(i) / float(n)  # linear decay, no clicks
		var v := sin(TAU * freq * t) * env * volume
		data[i] = int(clampf(v * 127.0 + 128.0, 0.0, 255.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


func _make_arpeggio(freqs: Array, note_len: float) -> AudioStreamWAV:
	var rate := 22050
	var per := int(note_len * float(rate))
	var data := PackedByteArray()
	data.resize(per * freqs.size())
	for j in freqs.size():
		var freq := float(freqs[j])
		for i in per:
			var t := float(i) / float(rate)
			var env := 1.0 - float(i) / float(per)
			var v := sin(TAU * freq * t) * env * 0.3
			data[j * per + i] = int(clampf(v * 127.0 + 128.0, 0.0, 255.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	return wav


func _update_hud() -> void:
	score_label.text = "Coins: %d / %d  Mmmmm!" % [score, GOAL]
	timer_label.text = "%.1fs" % time_left
	if time_left < 10.0 and playing:
		timer_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	else:
		timer_label.add_theme_color_override("font_color", Color.WHITE)
