#!/usr/bin/env bash
# Build the Rust drop-ffi library for Android targets and copy to jniLibs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JNI_DIR="$PROJECT_ROOT/android/app/src/main/jniLibs"

cd "$PROJECT_ROOT"

echo "==> Building drop-ffi for Android targets..."

if ! command -v cargo-ndk &>/dev/null; then
    echo "Installing cargo-ndk..."
    cargo install cargo-ndk
fi

cargo ndk \
    --target aarch64-linux-android \
    --target armv7-linux-androideabi \
    --target x86_64-linux-android \
    --platform 26 \
    --output-dir "$JNI_DIR" \
    -- build --package drop-ffi --release

echo "==> Generating Kotlin bindings..."
cargo run --package uniffi-bindgen -- generate \
    --library target/aarch64-linux-android/release/libdrop_ffi.so \
    --language kotlin \
    --out-dir "$PROJECT_ROOT/android/app/src/main/java/uniffi/drop_ffi" \
    --no-format

echo ""
echo "✅ Android build complete!"
echo "   Libraries: $JNI_DIR/"
find "$JNI_DIR" -name "*.so" -exec ls -lh {} \;
echo "   Bindings:  android/app/src/main/java/uniffi/drop_ffi/drop_ffi.kt"
