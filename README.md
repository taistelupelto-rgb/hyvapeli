# Hyvapeli — Snake coins

Small snake game for Godot 4 web. Eat golden coins to grow and score. Walls and your own tail kill. Speed ramps up per coin.

Play live: https://uuh.uusbitch.party

## Controls

- Steer: WASD / arrow keys, or swipe / drag with mouse / touch.
- Restart: `R` / `Enter` / `Space`, or click / tap after game over.

## Run locally

Needs Godot 4.7:

```sh
$GODOT --path . --import
$GODOT --path .
```

Headless smoke test:

```sh
GODOT=/tmp/opencode/godot-standard/Godot_v4.7.2-stable_linux.arm64
$GODOT --headless --path . --import
$GODOT --headless --fixed-fps 60 --quit-after 900 --path .
```

Zero `SCRIPT ERROR` lines is the bar.

## Web export

Web preset exports to `build/web/index.html` (GL Compatibility renderer).
No audio, no autoloads, no addons — repo has zero binary assets.
