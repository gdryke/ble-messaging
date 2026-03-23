#!/usr/bin/env bash
# Build the Rust drop-ffi library as an XCFramework for iOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORK_NAME="DropFfiFFI"
XCFRAMEWORK_DIR="$PROJECT_ROOT/ios/Drop/$FRAMEWORK_NAME.xcframework"
GENERATED_DIR="$PROJECT_ROOT/ios/Drop/Drop/Generated"

cd "$PROJECT_ROOT"

echo "==> Building drop-ffi for iOS targets..."

cargo build --package drop-ffi --target aarch64-apple-ios --release
cargo build --package drop-ffi --target aarch64-apple-ios-sim --release

echo "==> Generating Swift bindings..."
mkdir -p "$GENERATED_DIR"
cargo run --package uniffi-bindgen -- generate \
    --library target/aarch64-apple-ios/release/libdrop_ffi.a \
    --language swift \
    --out-dir "$GENERATED_DIR"

echo "==> Creating XCFramework..."
rm -rf "$XCFRAMEWORK_DIR"

DEVICE_DIR=$(mktemp -d)
SIM_DIR=$(mktemp -d)

mkdir -p "$DEVICE_DIR/Headers" "$DEVICE_DIR/Modules"
mkdir -p "$SIM_DIR/Headers" "$SIM_DIR/Modules"

cp "$GENERATED_DIR/drop_ffiFFI.h" "$DEVICE_DIR/Headers/"
cp "$GENERATED_DIR/drop_ffiFFI.h" "$SIM_DIR/Headers/"

cat > "$DEVICE_DIR/Modules/module.modulemap" <<EOF
framework module ${FRAMEWORK_NAME} {
    header "drop_ffiFFI.h"
    export *
}
EOF
cp "$DEVICE_DIR/Modules/module.modulemap" "$SIM_DIR/Modules/module.modulemap"

cp "target/aarch64-apple-ios/release/libdrop_ffi.a" "$DEVICE_DIR/${FRAMEWORK_NAME}"
cp "target/aarch64-apple-ios-sim/release/libdrop_ffi.a" "$SIM_DIR/${FRAMEWORK_NAME}"

xcodebuild -create-xcframework \
    -library "$DEVICE_DIR/${FRAMEWORK_NAME}" \
    -headers "$DEVICE_DIR/Headers" \
    -library "$SIM_DIR/${FRAMEWORK_NAME}" \
    -headers "$SIM_DIR/Headers" \
    -output "$XCFRAMEWORK_DIR"

rm -rf "$DEVICE_DIR" "$SIM_DIR"

echo ""
echo "✅ iOS build complete!"
echo "   XCFramework: $XCFRAMEWORK_DIR"
echo "   Bindings:    $GENERATED_DIR/drop_ffi.swift"
echo ""
echo "In Xcode: drag $FRAMEWORK_NAME.xcframework into your project,"
echo "then uncomment 'import DropFfiFFI' in the Swift source files."
