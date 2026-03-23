# Drop — iOS App

BLE peer-to-peer messaging app powered by a Rust core library (`drop-core`) via UniFFI.

## Prerequisites

- Xcode 16+ (Swift 6 toolchain)
- iOS 17+ deployment target
- A physical iOS device (BLE is not available in the Simulator)

## Project Setup

1. **Open Xcode** → *File → New → Project → iOS → App*
2. Product Name: **Drop**, Organization Identifier: your reverse-DNS id
3. Interface: **SwiftUI**, Language: **Swift**
4. Save the project inside `ios/Drop/` (Xcode will create `Drop.xcodeproj`)
5. Delete the auto-generated `ContentView.swift` and `DropApp.swift`
6. Drag the existing `Drop/` source folder into the Xcode project navigator
   - Make sure **"Create groups"** is selected
   - Ensure target membership is checked for all `.swift` files
7. Replace the auto-generated `Info.plist` with the one in `Drop/Info.plist`,
   or merge the keys into the build settings (see below)
8. Add `Drop.entitlements` to the target's *Signing & Capabilities*

## Info.plist Keys

The provided `Info.plist` includes:

| Key | Purpose |
|-----|---------|
| `NSBluetoothAlwaysUsageDescription` | BLE permission prompt |
| `UIBackgroundModes` | `bluetooth-central`, `bluetooth-peripheral` |

## Rust Core Integration (UniFFI)

The protocol logic lives in `crates/drop-core`. To wire it up:

1. Build the Rust library for iOS targets:
   ```bash
   cargo build --target aarch64-apple-ios --release
   ```
2. Generate Swift bindings with `uniffi-bindgen`:
   ```bash
   cargo run -p uniffi-bindgen generate \
     --library target/aarch64-apple-ios/release/libdrop_core.a \
     --language swift --out-dir ios/Drop/Drop/Generated
   ```
3. Add the generated `.swift` file and the `libdrop_core.a` static library
   to the Xcode project.
4. Replace the `// TODO: Wire UniFFI bindings` placeholders in
   `DropRepository.swift` with real calls.

## Architecture

```
DropApp (entry point)
  └─ ContentView
       ├─ ConversationListView  ← list of peers
       └─ ChatView              ← per-peer message thread

BleManager (ObservableObject, coordinates BLE)
  ├─ BleCentral   — CBCentralManager wrapper (scanning, GATT client)
  └─ BlePeripheral — CBPeripheralManager wrapper (advertising, GATT server)

DropRepository (bridges Rust core ↔ iOS)
```

## Testing on Device

BLE requires a physical device. Pair two phones running Drop to test
peer discovery and message exchange.
