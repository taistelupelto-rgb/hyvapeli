# Hyvapeli — Mmmmm coins

Insanely fun but small coin-collector for Godot 4 web.

## Play

- Grab coins before timer runs out. Collect `GOAL` coins to win.
- Move: WASD / arrow keys, or drag with mouse / touch.
- Restart: `R` / `Enter` / tap or click.

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
$GODOT --headless --fixed-fps 60 --quit-after 600 --path .
```

Zero `SCRIPT ERROR` lines is the bar.

## Web export

Web preset exports to `build/web/index.html` (GL Compatibility renderer).
Sounds are generated in code (`AudioStreamWav`), so repo has zero binary assets.
