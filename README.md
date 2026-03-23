# Low Energy BT Messaging

A Bluetooth Low Energy (BLE) based asynchronous messaging protocol and mobile apps. Phones drop messages to each other when in BLE range — no internet required.

## How It Works

1. Both phones continuously **advertise** a custom BLE service UUID and **scan** for it (dual-role BLE)
2. When two phones discover each other, a **Bloom filter** in the advertising data lets them quickly check if there are pending messages — avoiding unnecessary connections
3. If messages are pending, one phone initiates a **GATT connection** and messages are exchanged bidirectionally
4. Messages are **chunked with sequence numbers** so partial transfers (e.g., brief walk-by encounters) can resume later
5. All messages are **end-to-end encrypted** (X25519 key exchange + AES-GCM)

## Architecture

```
┌─────────────────────────────────────────────┐
│              Rust Core (UniFFI)              │
│  Protocol · Crypto · State Machine · Store  │
├──────────────────┬──────────────────────────┤
│   iOS (Swift)    │    Android (Kotlin)       │
│  CoreBluetooth   │    Android BLE API        │
│  State Restore   │    Foreground Service     │
│  SwiftUI         │    Jetpack Compose        │
└──────────────────┴──────────────────────────┘
```

- **Rust core** (~60-70% of logic): protocol encoding, cryptography, message store (SQLite), state machines — shared via [UniFFI](https://mozilla.github.io/uniffi-rs/)
- **Native iOS**: Swift + CoreBluetooth for BLE, background state restoration, SwiftUI
- **Native Android**: Kotlin + Android BLE API, foreground service for reliable background operation, Jetpack Compose

## Research Findings

### Feasibility — ✅ Proven viable
- Both iOS and Android support dual-role BLE (Central + Peripheral simultaneously)
- Proven at scale by COVID-19 Exposure Notifications, Bridgefy, Berty
- Realistic range: 10–30m indoor, 20–100m outdoor
- A 5-second walk-by encounter can transfer 150+ kB (dozens of text messages)

### Battery — ~7.5% daily drain
- Achievable with 5% scan duty cycle + 250ms advertising interval
- Comparable to a fitness tracker's background drain
- Scanning dominates power cost; advertising is cheap

### Key Challenges
| Challenge | Mitigation |
|-----------|------------|
| iOS background throttling (1–15 min discovery latency) | CoreBluetooth state restoration; accept async nature |
| Android OEM battery killers | Foreground service + user education ([dontkillmyapp.com](https://dontkillmyapp.com)) |
| No cross-platform BLE Peripheral library | Native BLE on each platform; share everything else via Rust |

### Why Rust + Native (not pure cross-platform)?
No cross-platform framework (Flutter, React Native, KMP) has a BLE library supporting the **Peripheral role** — they're all Central-only. Since background BLE is deeply OS-specific, native BLE layers give us the control we need. Rust core via UniFFI lets us share all the non-BLE logic.

## Status

- [x] Research: BLE feasibility
- [x] Research: Battery / polling trade-offs
- [x] Research: Cross-platform options
- [ ] Protocol specification
- [ ] Rust core scaffold
- [ ] Android app scaffold
- [ ] iOS app scaffold
- [ ] End-to-end BLE message exchange
