#!/usr/bin/env bash
# Local publish: export the Godot web build on this machine and copy it
# straight into the Caddy webroot. No GitHub Actions involved.
set -e
GODOT="${GODOT:-/tmp/opencode/godot-standard/Godot_v4.7.2-stable_linux.arm64}"
WEBROOT="/var/www/uuh.uusbitch.party"
cd "$(dirname "$0")"
"$GODOT" --headless --path . --import
rm -rf build/web && mkdir -p build/web
"$GODOT" --headless --path . --export-release Web build/web/index.html
ls build/web/index.html build/web/index.js build/web/index.wasm build/web/index.pck
rm -f "$WEBROOT"/* && cp -f build/web/* "$WEBROOT"/
VER="$(git describe --tags --always --dirty 2>/dev/null || echo manual)"
echo "$VER" > "$WEBROOT/.version"
echo "LIVE: $(cat "$WEBROOT/.version")"
