#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
SERVER_ROOT="$REPO_ROOT/Server"
SPEECH_SWIFT_ROOT="$REPO_ROOT/Vendor/speech-swift"
APP_DIR="$ROOT/VibeTyping.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
HELPERS_DIR="$CONTENTS/Helpers"
RESOURCES_DIR="$CONTENTS/Resources"
HELPER_BUNDLES_DIR="$RESOURCES_DIR/HelperBundles"
EXPECTED_SPEECH_SWIFT_REV="79c3a25d8446f2b5afc8f8e14100363c6810e229"
BUILD_HOME="$ROOT/.build-home"
mkdir -p "$BUILD_HOME/.cache/clang" "$BUILD_HOME/.cache/swift"
export HOME="$BUILD_HOME"
export CLANG_MODULE_CACHE_PATH="$BUILD_HOME/.cache/clang"
export SWIFT_MODULECACHE_PATH="$BUILD_HOME/.cache/swift"

find_output_dir() {
  local build_dir="$1"
  local config="$2"
  if [[ -d "$build_dir/arm64-apple-macosx/$config" ]]; then
    printf '%s\n' "$build_dir/arm64-apple-macosx/$config"
  elif [[ -d "$build_dir/$config" ]]; then
    printf '%s\n' "$build_dir/$config"
  else
    echo "error: missing SwiftPM $config output under $build_dir" >&2
    exit 1
  fi
}

if [[ ! -f "$SPEECH_SWIFT_ROOT/Package.swift" ]]; then
  echo "error: speech-swift submodule is missing; run git submodule update --init --recursive" >&2
  exit 1
fi

echo "Building VibeTyping..."
cd "$ROOT"
swift build -c release --disable-sandbox
CLIENT_OUTPUT="$(find_output_dir "$ROOT/.build" release)"

ACTUAL_SPEECH_SWIFT_REV="$(git -C "$SPEECH_SWIFT_ROOT" rev-parse HEAD)"
if [[ "$ACTUAL_SPEECH_SWIFT_REV" != "$EXPECTED_SPEECH_SWIFT_REV" ]]; then
  echo "error: speech-swift is $ACTUAL_SPEECH_SWIFT_REV; expected $EXPECTED_SPEECH_SWIFT_REV" >&2
  exit 1
fi

echo "Building remote-asr-server..."
cd "$SERVER_ROOT"
swift build -c release --disable-sandbox --product remote-asr-server
LC_ALL=C LANG=C BUILD_DIR="$SERVER_ROOT/.build" \
  "$SPEECH_SWIFT_ROOT/scripts/build_mlx_metallib.sh" release
SERVER_OUTPUT="$(find_output_dir "$SERVER_ROOT/.build" release)"

cd "$ROOT"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$HELPER_BUNDLES_DIR" "$RESOURCES_DIR/Pets/default"
cp "$ROOT/AppBundle/Info.plist" "$CONTENTS/Info.plist"
cp "$CLIENT_OUTPUT/VibeTyping" "$MACOS_DIR/VibeTyping"
cp "$SERVER_OUTPUT/remote-asr-server" "$HELPERS_DIR/remote-asr-server"
cp "$SERVER_OUTPUT/mlx.metallib" "$HELPERS_DIR/mlx.metallib"

for bundle in "$SERVER_OUTPUT"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  name="$(basename "$bundle")"
  cp -R "$bundle" "$HELPER_BUNDLES_DIR/"
  ln -s "../Resources/HelperBundles/$name" "$HELPERS_DIR/$name"
done

cp "$ROOT/Sources/VibeTyping/Resources/Pets/default/pet.json" \
  "$RESOURCES_DIR/Pets/default/pet.json"
cp "$ROOT/Sources/VibeTyping/Resources/Pets/default/spritesheet.webp" \
  "$RESOURCES_DIR/Pets/default/spritesheet.webp"
printf 'speech-swift=%s\n' "$ACTUAL_SPEECH_SWIFT_REV" > "$RESOURCES_DIR/server-build.txt"

codesign --force --sign - "$HELPERS_DIR/mlx.metallib"
codesign --force --sign - "$HELPERS_DIR/remote-asr-server"
codesign --force --sign - "$MACOS_DIR/VibeTyping"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
codesign --verify --strict "$HELPERS_DIR/remote-asr-server"

"$HELPERS_DIR/remote-asr-server" --help >/dev/null
test -f "$HELPERS_DIR/RemoteASRServer_RemoteASRCore.bundle/smart-turn-v3.2-cpu.onnx"
test -f "$HELPERS_DIR/swift-transformers_Hub.bundle/gpt2_tokenizer_config.json"
test -f "$HELPERS_DIR/mlx.metallib"
test -f "$RESOURCES_DIR/Pets/default/pet.json"

echo "Built $APP_DIR"
