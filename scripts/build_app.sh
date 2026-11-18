#!/usr/bin/env bash
# Builds SpeechToPrompt.app and dictate-cli, signs them, and installs the app.
#
# Usage: scripts/build_app.sh [--no-install] [--open]
#
# Signing, in order of preference:
#   1. CODESIGN_IDENTITY="…" if you set it
#   2. an "Apple Development" certificate (needs full Xcode: Settings → Accounts)
#   3. "SpeechToPrompt Local Signing", made by scripts/make_signing_cert.sh (no Xcode needed)
#   4. ad hoc, which works but makes macOS forget the permissions after every rebuild
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INSTALL=1; OPEN=0
for a in "$@"; do
  case "$a" in
    --no-install) INSTALL=0 ;;
    --open) OPEN=1 ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
OUT="$ROOT/build"
APP="$OUT/SpeechToPrompt.app"

[[ -d Vendor/whisper.xcframework ]] || { echo "Vendor/whisper.xcframework missing: run scripts/setup.sh first"; exit 1; }

echo "==> swift build (release)"
swift build -c release --product SpeechToPrompt
swift build -c release --product dictate-cli
BIN="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SpeechToPrompt" "$APP/Contents/MacOS/SpeechToPrompt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/dictate-cli" "$OUT/dictate-cli"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"SpeechToPrompt Local Signing"'; then
  IDENTITY="SpeechToPrompt Local Signing"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "WARNING: no signing certificate found; signing ad hoc."
  echo "         macOS will forget the app's permissions after every rebuild."
  echo "         Fix once with: scripts/make_signing_cert.sh"
  IDENTITY="-"
fi
echo "==> Signing with: $IDENTITY"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/SpeechToPrompt.entitlements --sign "$IDENTITY" "$APP"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$OUT/dictate-cli"
codesign --verify --strict "$APP"

if (( INSTALL )); then
  if pgrep -x SpeechToPrompt >/dev/null; then
    echo "==> Quitting running SpeechToPrompt"
    osascript -e 'quit app "SpeechToPrompt"' >/dev/null 2>&1 || pkill -x SpeechToPrompt || true
    sleep 1
  fi
  echo "==> Installing to $INSTALL_DIR"
  rm -rf "$INSTALL_DIR/SpeechToPrompt.app"
  cp -R "$APP" "$INSTALL_DIR/"
  APP="$INSTALL_DIR/SpeechToPrompt.app"
fi

echo
echo "Built:  $APP"
echo "CLI:    $OUT/dictate-cli"
if (( OPEN )); then open "$APP"; else echo "Start:  open \"$APP\""; fi
