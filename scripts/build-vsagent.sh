#!/usr/bin/env bash
#
# build-vsagent.sh — Compile and (optionally) install the standalone "VS Agent" app.
#
# VS Agent is the Agents Window shipped as its own product (see product.json:
# nameLong "VS Agent", applicationName "vsagent", defaultWindowKind "agents").
# This script wraps the gulp darwin packaging task, trims debug-only artifacts,
# and installs the result to /Applications.
#
# Usage:
#   scripts/build-vsagent.sh [--arch arm64|x64] [--fast] [--no-slim] [--no-install] [--dmg]
#
# Flags:
#   --arch <a>     Target arch. Defaults to the host arch (arm64 on Apple Silicon).
#   --fast         Skip minify + private-mangling (non-min build). Much faster to
#                  build; the app is functionally identical but larger on disk.
#                  Tip: stick to one mode (fast or not) so the incremental
#                  compile-build cache stays warm between runs.
#   --no-slim      Keep sourcemaps (*.js.map). Default strips them (~400M smaller).
#   --no-install   Don't copy to /Applications; leave the .app in the build output dir.
#   --dmg          Also build a compressed .dmg from the app (via hdiutil).
#
# Requirements: Node.js matching .nvmrc (currently 24.x). The script will use nvm
# to select it if nvm is installed; otherwise it relies on the active `node`.

set -euo pipefail

# --- locate repo root (mirrors scripts/code.sh) ---
if [[ "$OSTYPE" == "darwin"* ]]; then
	realpath() { [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"; }
	ROOT=$(dirname "$(dirname "$(realpath "$0")")")
else
	ROOT=$(dirname "$(dirname "$(readlink -f "$0")")")
fi
cd "$ROOT"

if [[ "$OSTYPE" != "darwin"* ]]; then
	echo "This script targets macOS. For Windows/Linux use: npm run gulp vscode-<platform>-<arch>-min" >&2
	exit 1
fi

# --- defaults ---
ARCH="$(uname -m)"          # arm64 or x86_64
[[ "$ARCH" == "x86_64" ]] && ARCH="x64"
SLIM=1
INSTALL=1
DMG=0
FAST=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--arch) ARCH="$2"; shift 2;;
		--fast) FAST=1; shift;;
		--no-slim) SLIM=0; shift;;
		--no-install) INSTALL=0; shift;;
		--dmg) DMG=1; shift;;
		-h|--help) sed -n '2,33p' "$0"; exit 0;;
		*) echo "Unknown option: $1" >&2; exit 1;;
	esac
done

if [[ "$ARCH" != "arm64" && "$ARCH" != "x64" ]]; then
	echo "Invalid --arch '$ARCH' (expected arm64 or x64)" >&2
	exit 1
fi

# --- select Node via nvm if available, then sanity-check the major version ---
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
	# shellcheck disable=SC1091
	source "$HOME/.nvm/nvm.sh"
	nvm use >/dev/null 2>&1 || nvm install >/dev/null 2>&1 || true
fi
WANT_MAJOR="$(tr -dc '0-9.' < .nvmrc | cut -d. -f1)"
HAVE_MAJOR="$(node -v | tr -dc '0-9.' | cut -d. -f1)"
if [[ -n "$WANT_MAJOR" && "$HAVE_MAJOR" != "$WANT_MAJOR" ]]; then
	echo "WARNING: Node major $HAVE_MAJOR != required $WANT_MAJOR (.nvmrc). Build may fail." >&2
fi
echo "==> Node $(node -v), target darwin-$ARCH"

# --- ensure deps ---
if [[ ! -d node_modules ]]; then
	echo "==> Installing dependencies (npm install)..."
	npm install
fi

# --- build ---
if [[ "$FAST" == "1" ]]; then
	TASK="vscode-darwin-${ARCH}"        # non-min: skips minify + mangle
else
	TASK="vscode-darwin-${ARCH}-min"
fi

# The built-in copilot extension materializes its CLI SDK during
# compile-copilot-extension-build while vsce.listFiles walks the same tree.
# Those two steps interleave non-deterministically and the build occasionally
# fails with "Copilot SDK directory not found" or "ENOENT ... shims.txt".
# It is a transient race, not a real error — retry a couple of times.
ATTEMPTS=3
for ((i = 1; i <= ATTEMPTS; i++)); do
	echo "==> Building (attempt $i/$ATTEMPTS): npm run gulp $TASK"
	if npm run gulp "$TASK"; then
		break
	fi
	if [[ $i -eq $ATTEMPTS ]]; then
		echo "Build failed after $ATTEMPTS attempts." >&2
		exit 1
	fi
	echo "==> Build failed (likely the transient copilot-SDK race); retrying..." >&2
done

OUT_DIR="$ROOT/../VSCode-darwin-${ARCH}"
APP="$OUT_DIR/VS Agent.app"
if [[ ! -d "$APP" ]]; then
	echo "Build did not produce '$APP'." >&2
	exit 1
fi

# --- slim: strip debug-only sourcemaps (safe; not used at runtime) ---
if [[ "$SLIM" == "1" ]]; then
	echo "==> Slimming: removing *.js.map"
	find "$APP/Contents/Resources/app/out" -name "*.js.map" -delete 2>/dev/null || true
	find "$APP/Contents/Resources/app/extensions" -name "*.js.map" -delete 2>/dev/null || true
fi

echo "==> Built: $APP ($(du -sh "$APP" | cut -f1))"

# --- optional dmg (self-contained via hdiutil; the gulp build has no dmg task) ---
if [[ "$DMG" == "1" ]]; then
	DMG_PATH="$OUT_DIR/VS Agent-${ARCH}.dmg"
	echo "==> Building dmg: $DMG_PATH"
	rm -f "$DMG_PATH"
	hdiutil create -volname "VS Agent" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH"
	echo "==> Created: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
fi

# --- install to /Applications ---
if [[ "$INSTALL" == "1" ]]; then
	DEST="/Applications/VS Agent.app"
	echo "==> Installing to $DEST"
	rm -rf "$DEST"
	ditto "$APP" "$DEST"
	echo "==> Installed: $DEST ($(du -sh "$DEST" | cut -f1))"
	echo "    Launch with:  open -a 'VS Agent'"
fi

echo "Done."
