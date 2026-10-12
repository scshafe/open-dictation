#!/bin/sh
# Build OpenDictation and wrap the binary in a launchable .app bundle.
# Required for real microphone / Accessibility testing: those OS permissions
# need a bundle identifier + Info.plist (usage description) and stable signing.
#
# Usage: ./scripts/package-app.sh [debug|release]   (default: release)
set -eu

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/OpenDictation.app"

echo "==> swift build -c $CONFIG"
(cd "$ROOT" && swift build -c "$CONFIG")

BIN="$ROOT/.build/$CONFIG/OpenDictation"
if [ ! -f "$BIN" ]; then
  # swift build layout may be .build/arm64-apple-macosx/... ; locate binary
  BIN="$(find "$ROOT/.build" -name OpenDictation -type f -path "*$CONFIG*" | head -n 1)"
fi
echo "==> binary: $BIN"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/OpenDictation"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing. Default: ad-hoc ("-"). An ad-hoc signature changes with EVERY build,
# and macOS keys Accessibility / Microphone grants to the signature, so each
# rebuild silently invalidates them (toggle the app off/on in System Settings
# → Privacy & Security → Accessibility to re-grant). Set CODESIGN_IDENTITY to
# the name of a stable identity — e.g. a self-signed "Code Signing" certificate
# created in Keychain Access — and grants survive rebuilds. See README.
# Resolution order: $CODESIGN_IDENTITY, then scripts/codesign-identity.local
# (one line, git-ignored, machine-specific), then ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -f "$ROOT/scripts/codesign-identity.local" ]; then
  IDENTITY="$(head -n 1 "$ROOT/scripts/codesign-identity.local" | tr -d '\r\n')"
fi
IDENTITY="${IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
  if [ "$IDENTITY" = "-" ]; then
    echo "==> codesign: ad-hoc (set CODESIGN_IDENTITY for a stable identity; rebuilds invalidate TCC grants)"
  else
    echo "==> codesign: configured identity"
  fi
  codesign --force --deep -s "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi

echo "==> app: $APP"
echo "Launch with: open \"$APP\""
