#!/usr/bin/env bash
# Copy the web half of the Safari extension from Maurice's repo, where it is
# written once for Chrome, Firefox and Safari (maurice/clients/web-clipper).
# Carnet carries a copy because it is built on its own; run this after any
# change there, and commit what it brings.
#   scripts/sync-web-clipper.sh [path/to/maurice]
set -euo pipefail
cd "$(dirname "$0")/.."
maurice="${1:-../maurice}"
src="$maurice/clients/web-clipper"
[ -f "$src/manifest.json" ] || { echo "no web-clipper at $src" >&2; exit 1; }
# Safari lets the popup ask the app for its session only with this permission.
grep -q '"nativeMessaging"' "$src/manifest.json" || { echo "manifest.json does not list nativeMessaging: the extension could not read Carnet's session" >&2; exit 1; }
dst=CarnetSafariExtension/Resources
rm -rf "$dst"
mkdir -p "$dst"
cp "$src"/manifest.json "$src"/*.js "$src"/*.html "$src"/*.css "$dst"/
cp -R "$src"/_locales "$src"/icons "$dst"/
echo "copied $(cd "$src" && git rev-parse --short HEAD 2>/dev/null || echo '?') → $dst"
