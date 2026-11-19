#!/usr/bin/env bash
# One-time setup on your Mac:
#   1. checks macOS / Xcode / cmake
#   2. builds Vendor/whisper.xcframework (whisper.cpp + Metal, static) from source
#   3. downloads the Whisper and Silero VAD models
#   4. (with --eval) creates eval/.venv with the Python eval dependencies
#   5. (with --llm) installs Ollama, starts it, and pulls the clean-mode model
#
# Usage: scripts/setup.sh [--eval] [--llm] [--llm-candidates] [--rebuild-whisper] [--small-model]
#   --small-model     use ggml-large-v3-turbo-q5_0.bin (547 MB) instead of the full 1.6 GB model
#   --llm             Ollama + gemma4:e4b (the default clean-mode model)
#   --llm-candidates  also pull qwen3.5:9b and qwen3:8b to compare with eval/rewrite_test.py
#
# Network use: github.com (whisper.cpp source), huggingface.co (model files), PyPI (eval deps),
# Homebrew and ollama.com (Ollama and model downloads).
# Nothing here or in the app uploads audio or text.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_VERSION="${WHISPER_VERSION:-1.9.5}"
SUPPORT="$HOME/Library/Application Support/SpeechToPrompt"
MODELS="$SUPPORT/models"
WITH_EVAL=0; REBUILD=0; WHISPER_MODEL="ggml-large-v3-turbo.bin"; WITH_LLM=0
LLM_MODELS=("gemma4:e4b")
for a in "$@"; do
  case "$a" in
    --eval) WITH_EVAL=1 ;;
    --rebuild-whisper) REBUILD=1 ;;
    --small-model) WHISPER_MODEL="ggml-large-v3-turbo-q5_0.bin" ;;
    --llm) WITH_LLM=1 ;;
    --llm-candidates) WITH_LLM=1; LLM_MODELS=("gemma4:e4b" "qwen3.5:9b" "qwen3:8b") ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Prerequisites ---------------------------------------------------------
say "Checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || die "this script runs on macOS"
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon required"
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 26 )) || die "macOS 26 or later required (found $(sw_vers -productVersion))"
xcrun --find swift >/dev/null 2>&1 || die "Swift not found: install the Command Line Tools (xcode-select --install) or Xcode"
echo "Swift: $(xcrun swift --version 2>&1 | head -1)"
if ! command -v cmake >/dev/null; then
  command -v brew >/dev/null || die "cmake is missing; install Homebrew (https://brew.sh) or cmake"
  echo "Installing cmake with Homebrew…"
  brew install cmake
fi

# 2. whisper.cpp -----------------------------------------------------------
# Builds static libraries with CMake and packages them as an XCFramework folder by hand
# (the same layout `xcodebuild -create-xcframework` produces), so full Xcode is not needed:
# the Command Line Tools are enough.
XCF="$ROOT/Vendor/whisper.xcframework"
if [[ -f "$XCF/Info.plist" && $REBUILD -eq 0 ]]; then
  say "whisper.xcframework already built (use --rebuild-whisper to rebuild)"
else
  say "Building whisper.cpp v$WHISPER_VERSION (Metal, static) — takes a few minutes the first time"
  SRC="$ROOT/Vendor/src/whisper.cpp"
  BUILD="$ROOT/Vendor/src/build-macos"
  MARKER="$SRC/.speechtoprompt-version"
  if [[ ! -f "$MARKER" ]] || [[ "$(cat "$MARKER")" != "$WHISPER_VERSION" ]]; then
    rm -rf "$SRC" "$BUILD"
    git -c advice.detachedHead=false clone --depth 1 --branch "v$WHISPER_VERSION" \
      https://github.com/ggml-org/whisper.cpp.git "$SRC"
    echo "$WHISPER_VERSION" > "$MARKER"
  fi
  (( REBUILD )) && rm -rf "$BUILD"
  # Incremental: re-running after a failure doesn't recompile what's already built.
  cmake -S "$SRC" -B "$BUILD" -Wno-dev \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_COREML=OFF -DGGML_CCACHE=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
  cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)"

  rm -rf "$XCF"
  SLICE="$XCF/macos-arm64"
  mkdir -p "$SLICE/Headers"
  # Combine whisper + all ggml static libraries into one.
  LIBS=()
  while IFS= read -r lib; do LIBS+=("$lib"); done < <(find "$BUILD" -name '*.a' -type f)
  (( ${#LIBS[@]} > 0 )) || die "no static libraries were built"
  echo "Combining: ${LIBS[*]##*/}"
  libtool -static -no_warning_for_no_symbols -o "$SLICE/libwhisper.a" "${LIBS[@]}"
  cp "$SRC/include/whisper.h" "$SLICE/Headers/"
  cp "$SRC"/ggml/include/*.h "$SLICE/Headers/"
  cat > "$SLICE/Headers/module.modulemap" <<'MAP'
module whisper {
    header "whisper.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    export *
}
MAP
  cat > "$XCF/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libwhisper.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libwhisper.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
  plutil -lint "$XCF/Info.plist" >/dev/null || die "generated Info.plist is invalid"
  echo "Built $XCF"
fi

# 3. Models ----------------------------------------------------------------
download() { # url dest min_bytes
  local url="$1" dest="$2" min="$3"
  if [[ -f "$dest" ]] && (( $(stat -f%z "$dest") >= min )); then
    echo "✓ $(basename "$dest") already present"
    return
  fi
  echo "Downloading $(basename "$dest")…"
  curl -L --fail --retry 3 -C - -o "$dest.part" "$url"
  (( $(stat -f%z "$dest.part") >= min )) || die "$(basename "$dest") looks truncated"
  mv "$dest.part" "$dest"
}
say "Models → $MODELS"
mkdir -p "$MODELS"
if [[ "$WHISPER_MODEL" == "ggml-large-v3-turbo.bin" ]]; then MIN=1500000000; else MIN=500000000; fi
download "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL" "$MODELS/$WHISPER_MODEL" "$MIN"
download "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin" "$MODELS/ggml-silero-v6.2.0.bin" 500000
if [[ "$WHISPER_MODEL" != "ggml-large-v3-turbo.bin" ]]; then
  echo "NOTE: set \"engine\": {\"whisperModel\": \"$WHISPER_MODEL\"} in $SUPPORT/config.json"
fi

# 4. Eval environment ------------------------------------------------------
if (( WITH_EVAL )); then
  say "Python eval environment (eval/.venv)"
  PY="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
  [[ -n "$PY" ]] || die "python3 not found (brew install python@3.12)"
  "$PY" -m venv "$ROOT/eval/.venv"
  "$ROOT/eval/.venv/bin/pip" install --upgrade pip >/dev/null
  "$ROOT/eval/.venv/bin/pip" install -r "$ROOT/eval/requirements.txt"
fi

# 5. Local LLM -------------------------------------------------------------
if (( WITH_LLM )); then
  say "Local LLM (Ollama)"
  # Privacy: Ollama must only listen on this Mac.
  for h in "${OLLAMA_HOST:-}" "$(launchctl getenv OLLAMA_HOST 2>/dev/null || true)"; do
    if [[ -n "$h" && "$h" != 127.0.0.1* && "$h" != localhost* && "$h" != "http://127.0.0.1"* && "$h" != "http://localhost"* ]]; then
      die "OLLAMA_HOST=$h makes Ollama reachable from other machines. Unset it (launchctl unsetenv OLLAMA_HOST) and rerun."
    fi
  done
  if ! command -v ollama >/dev/null; then
    command -v brew >/dev/null || die "install Ollama from https://ollama.com/download or install Homebrew"
    brew install ollama
  fi
  if ! curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null; then
    if brew list ollama >/dev/null 2>&1; then
      echo "Starting Ollama as a background service (starts at login too)…"
      brew services start ollama
    else
      open -a Ollama || die "start the Ollama app, then rerun"
    fi
    for _ in $(seq 1 30); do curl -s --max-time 1 http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
    curl -s --max-time 2 http://127.0.0.1:11434/api/version >/dev/null || die "Ollama didn't start"
  fi
  echo "Ollama $(curl -s http://127.0.0.1:11434/api/version | sed 's/.*"version":"\([^"]*\)".*/\1/') is running on 127.0.0.1:11434"
  for m in "${LLM_MODELS[@]}"; do
    echo "Pulling ${m}…"
    ollama pull "$m"
  done
fi

say "Done. Next: scripts/build_app.sh"
