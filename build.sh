#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFI_DIR="$SCRIPT_DIR/packages/zcash_ffi/native/zcash-ffi"
DART_FFI_DIR="$SCRIPT_DIR/packages/zcash_ffi/lib/src/ffi/native"

echo "Building zcash-ffi (release)..."
(cd "$FFI_DIR" && cargo build --release)

OS="$(uname -s)"
case "$OS" in
  Linux*)
    ARTIFACT="$FFI_DIR/target/release/libzcash_ffi.so"
    PLATFORM="linux"
    ;;
  Darwin*)
    ARTIFACT="$FFI_DIR/target/release/libzcash_ffi.dylib"
    PLATFORM="macos"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    ARTIFACT="$FFI_DIR/target/release/zcash_ffi.dll"
    PLATFORM="windows"
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

DEST_DIR="$DART_FFI_DIR/$PLATFORM"
mkdir -p "$DEST_DIR"

echo "Copying $ARTIFACT -> $DEST_DIR/"
cp "$ARTIFACT" "$DEST_DIR/"

echo "Done. Native library available at $DEST_DIR/$(basename "$ARTIFACT")"
