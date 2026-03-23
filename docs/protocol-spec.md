# Drop Protocol — Specification v0.1

> BLE-based asynchronous peer-to-peer messaging protocol

## 1. Overview

Drop is a protocol for exchanging short messages between mobile devices over Bluetooth Low Energy (BLE) without any internet connectivity. Devices continuously advertise and scan for peers. When two devices come into range and have pending messages, they establish a short-lived GATT connection, exchange messages, and disconnect.

### Design Goals

- **Async-first**: messages are queued locally and delivered opportunistically
- **Low power**: ≤10% daily battery impact with continuous background operation
- **Brief encounters**: complete a message exchange in a 3–10 second walk-by window
- **Resumable**: partial transfers pick up where they left off on the next encounter
- **End-to-end encrypted**: no trust required in the transport layer
- **Simple**: minimal state, minimal round-trips

### Non-Goals (v0.1)

- Group messaging (future version)
- Mesh relay / store-and-forward via third-party devices (future version)
- File/media transfer (future version — text messages only for now)

---

## 2. Identity

### 2.1 Key Pairs

Each device generates a long-term identity key pair on first launch:

| Parameter | Value |
|-----------|-------|
| Algorithm | X25519 |
| Public key size | 32 bytes |
| Private key storage | OS keychain (iOS Keychain / Android Keystore) |

The **public key** is the device's identity. A user-friendly **Device ID** is derived as:

```
device_id = SHA-256(public_key)[0..16]  // 16 bytes, 128 bits
```

### 2.2 Peer Exchange (Out-of-Band)

To message someone, you need their public key. Initial key exchange happens out-of-band:

- QR code scan (primary method — contains the 32-byte public key, base64-encoded)
- Manual entry of a base32-encoded short code (derived from public key)

Once exchanged, peers are stored locally. No central server or directory exists.

---

## 3. BLE Layer

### 3.1 Service Definition

| Parameter | Value |
|-----------|-------|
| Service UUID | `D7A0xxxx-E28C-4B8E-8C3F-4A77C4D2F5B1` (128-bit, custom) |
| Primary Service UUID | `D7A00001-E28C-4B8E-8C3F-4A77C4D2F5B1` |

**Characteristics:**

| Characteristic | UUID | Properties | Description |
|---------------|------|------------|-------------|
| Inbox Write | `D7A00002-E28C-4B8E-8C3F-4A77C4D2F5B1` | Write | Peer writes message chunks here |
| Outbox Notify | `D7A00003-E28C-4B8E-8C3F-4A77C4D2F5B1` | Notify | Device notifies peer of outbound chunks |
| Handshake | `D7A00004-E28C-4B8E-8C3F-4A77C4D2F5B1` | Read, Write | Exchange device IDs and pending message metadata |
| ACK | `D7A00005-E28C-4B8E-8C3F-4A77C4D2F5B1` | Notify, Write | Chunk-level acknowledgments |

### 3.2 Advertising

Each device advertises continuously in the background:

| Field | Size | Content |
|-------|------|---------|
| Flags | 3 bytes | Standard BLE flags |
| Service UUID | 18 bytes | Primary Service UUID (required for iOS background discovery) |
| Service Data | 10 bytes | Bloom filter (8 bytes) + protocol version (1 byte) + flags (1 byte) |
| **Total** | **31 bytes** | Fits in legacy advertising PDU |

**Advertising parameters:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Interval | 250 ms | Proven by Exposure Notification framework; good detection probability |
| TX Power | Platform default | Preserve range without excessive drain |
| Mode | Low-power | Advertising is cheap; no need to optimize further |

### 3.3 Bloom Filter

The 8-byte (64-bit) Bloom filter in the advertising payload encodes the `device_id`s of peers for whom this device has **pending outbound messages**.

| Parameter | Value |
|-----------|-------|
| Size | 64 bits (8 bytes) |
| Hash functions | 3 (using MurmurHash3 with 3 seeds) |
| Expected items | 1–10 peer IDs |
| False positive rate | ~7% at 5 items, ~18% at 10 items |

**How it's used:**

1. Scanner receives an advertisement with a Bloom filter
2. Scanner checks if its own `device_id` is in the filter
3. If **no match**: ignore — no messages for us (guaranteed, no false negatives)
4. If **match**: initiate a GATT connection to check for real (may be false positive)

An **all-zeros** Bloom filter means the advertiser has no pending messages. Scanners should not connect.

### 3.4 Scanning

| Platform | Mode | Parameters |
|----------|------|------------|
| Android (foreground service) | `SCAN_MODE_LOW_POWER` | 500 ms window / 5,000 ms interval (10% duty cycle) |
| iOS (background) | OS-managed | Must filter on Primary Service UUID |
| iOS (foreground) | OS-managed, aggressive | Near-continuous scanning |

### 3.5 Connection Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| MTU | 517 (negotiate immediately) | Maximize throughput per write |
| Connection interval | 7.5–15 ms | Fast transfers during brief encounters |
| Supervision timeout | 2,000 ms | Detect disconnection quickly for walk-by scenarios |
| Slave latency | 0 | Both sides are active during transfer |

---

## 4. Protocol Flow

### 4.1 Discovery → Connection → Exchange → Disconnect

```
  Device A (scanner)                    Device B (advertiser)
  ─────────────────                    ──────────────────────
        │                                     │
        │  ◄── BLE Advertisement ────────────│  (includes Bloom filter)
        │                                     │
        │  [Check: is my device_id            │
        │   in the Bloom filter?]             │
        │                                     │
        │  ── GATT Connect ──────────────────►│
        │                                     │
        │  ── Negotiate MTU (517) ───────────►│
        │  ◄── MTU Accepted ─────────────────│
        │                                     │
        │  ── Read Handshake Char ───────────►│
        │  ◄── {device_id_B, pending[]} ─────│  (list of msg IDs pending for A)
        │                                     │
        │  ── Write Handshake Char ──────────►│  {device_id_A, pending[]}
        │                                     │
        │  ── [Bidirectional exchange] ──────►│
        │  ◄─────────────────────────────────│
        │                                     │
        │  ── GATT Disconnect ───────────────►│
        │                                     │
```

### 4.2 Handshake

After connecting and negotiating MTU, the **initiator** (scanner/central) reads the Handshake characteristic to get the advertiser's identity and pending message list.

**Handshake payload** (read from / written to Handshake characteristic):

```
┌──────────────┬───────────┬──────────┬─────────────────────┐
│ device_id    │ msg_count │ version  │ msg_ids[]           │
│ (16 bytes)   │ (1 byte)  │ (1 byte) │ (16 bytes × count)  │
└──────────────┴───────────┴──────────┴─────────────────────┘
```

- `device_id`: sender's 16-byte identity
- `msg_count`: number of pending messages for this peer (0–255)
- `version`: protocol version (0x01)
- `msg_ids[]`: list of message UUIDs the sender has queued for this peer

Both sides exchange handshakes. Each side then knows which messages to send and which to expect.

### 4.3 Message Transfer

After the handshake, both devices transfer messages **bidirectionally**:

- **Central → Peripheral**: writes chunks to the **Inbox Write** characteristic
- **Peripheral → Central**: sends chunks via **Outbox Notify** characteristic

This allows simultaneous bidirectional transfer without role reversal.

### 4.4 Role Selection

When two devices discover each other, **the device that discovers first becomes Central** (initiator). To prevent both devices from connecting simultaneously:

1. When device A discovers device B's advertisement, A initiates a GATT connection
2. When B receives the connection, B stops attempting to connect to A (if it was about to)
3. If both connect simultaneously (race condition), the device with the **lexicographically lower `device_id`** keeps its Central role; the other disconnects and waits

---

## 5. Message Format

### 5.1 Message Envelope

Each message is serialized as:

```
┌──────────────────────────────────────────────────────┐
│                    Message Envelope                   │
├──────────────┬───────────────────────────────────────┤
│ msg_id       │ 16 bytes (UUID v4)                    │
│ sender_id    │ 16 bytes (device_id)                  │
│ recipient_id │ 16 bytes (device_id)                  │
│ timestamp    │ 8 bytes (Unix millis, u64 big-endian) │
│ nonce        │ 24 bytes (XChaCha20-Poly1305 nonce)   │
│ ciphertext   │ variable (encrypted payload + 16-byte │
│              │          Poly1305 auth tag)            │
└──────────────┴───────────────────────────────────────┘
```

**Header size**: 80 bytes fixed + variable ciphertext

### 5.2 Plaintext Payload (before encryption)

```
┌──────────────┬───────────────────────────────────────┐
│ type         │ 1 byte (0x01 = text, 0x02 = ack,     │
│              │         0x03 = read receipt)           │
│ body_len     │ 2 bytes (u16 big-endian)              │
│ body         │ variable (UTF-8 text)                 │
└──────────────┴───────────────────────────────────────┘
```

**Max body size**: 4,096 bytes (v0.1 limit — text messages only)

### 5.3 Encryption

| Parameter | Value |
|-----------|-------|
| Key agreement | X25519 ECDH |
| Symmetric cipher | XChaCha20-Poly1305 |
| Nonce size | 24 bytes (random per message) |
| Auth tag | 16 bytes (included in ciphertext) |

**Key derivation:**

```
shared_secret = X25519(my_private_key, peer_public_key)
encryption_key = HKDF-SHA256(
    ikm = shared_secret,
    salt = sorted(sender_id, recipient_id),  // lexicographic sort
    info = "drop-v1-message",
    len = 32
)
```

Both peers derive the **same symmetric key** (since X25519 is commutative). The salt is deterministic by sorting the two device IDs, ensuring both sides compute the same value regardless of who is sender vs. recipient.

> **Note**: v0.1 uses a static shared secret per peer pair. A future version should implement the Double Ratchet algorithm (Signal Protocol) for forward secrecy.

---

## 6. Chunking

Messages larger than a single GATT write are split into chunks.

### 6.1 Chunk Format

```
┌──────────────┬───────────────────────────────────────┐
│ msg_id       │ 16 bytes (which message this belongs  │
│              │          to)                           │
│ chunk_index  │ 2 bytes (u16 big-endian, 0-based)     │
│ total_chunks │ 2 bytes (u16 big-endian)              │
│ payload      │ up to (MTU - 23) bytes                │
└──────────────┴───────────────────────────────────────┘
```

**Chunk header**: 20 bytes fixed. With MTU 517, each chunk carries up to **494 bytes** of message data.

A 4,096-byte message (max size) requires ~9 chunks at MTU 517.

### 6.2 Acknowledgment

Each chunk is individually acknowledged via the **ACK characteristic**:

```
┌──────────────┬───────────────────────────────────────┐
│ msg_id       │ 16 bytes                              │
│ chunk_index  │ 2 bytes (last successfully received   │
│              │          chunk index)                  │
└──────────────┴───────────────────────────────────────┘
```

ACKs are **cumulative**: ACK for chunk index N means all chunks 0..N were received.

### 6.3 Resumption

Both devices persist transfer state:

```
TransferState {
    peer_id:          DeviceId,
    msg_id:           UUID,
    direction:        Inbound | Outbound,
    last_acked_chunk: u16,
    total_chunks:     u16,
    chunks_received:  BitSet,  // for out-of-order reception
}
```

On reconnection, the handshake includes `last_acked_chunk` per message, and transfer resumes from `last_acked_chunk + 1`.

### 6.4 Deduplication

Messages are deduplicated by `msg_id` (UUID v4). If a message with the same `msg_id` is received again (e.g., due to a retry after a failed ACK), it is silently dropped. Completed `msg_id`s are retained for 30 days to prevent replays.

---

## 7. Message Lifecycle

```
  Sender                              Receiver
  ──────                              ────────

  compose()
     │
     ▼
  [Queued]  ─── stored locally ──►  (not yet aware)
     │
     ▼
  [Advertising]  ── Bloom filter     
     │               includes
     │               recipient_id
     ▼
  ── encounter ──────────────────►  [Discovered]
     │                                   │
     ▼                                   ▼
  [Transferring] ◄── chunks + ACKs ── [Receiving]
     │                                   │
     ▼                                   ▼
  [Delivered]                        [Received]
     │                                   │
     ▼                                   ▼
  (retain 30 days                   display to user
   for dedup, then                       │
   delete)                               ▼
                                    [Read] ── read receipt ──► sender
```

**Message states** (sender side): `Queued → Transferring → Delivered`  
**Message states** (receiver side): `Receiving → Received → Read`

---

## 8. Timing Budget

Worst-case walk-by encounter (3 m/s relative speed, 10m range ≈ 6.6s window):

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Discovery (Android scanner) | 0–5,000 ms | 5,000 ms |
| GATT connection setup | 50–200 ms | 5,200 ms |
| MTU negotiation | 50–100 ms | 5,300 ms |
| Handshake exchange | 50–100 ms | 5,400 ms |
| **Available for transfer** | **~1,200 ms** | 6,600 ms |

At MTU 517 with 7.5 ms connection interval: ~65 kB/s throughput → **~80 kB** in the transfer window.

That's enough for ~18 max-size text messages (4 KB each) or ~80 typical messages (~1 KB) in a single walk-by.

**Best case** (15m range, 1.5 m/s walking speed = 10s window, instant discovery): **~500 kB** transferable.

---

## 9. Storage

### 9.1 Local Message Store

Each device maintains a SQLite database:

| Table | Purpose |
|-------|---------|
| `peers` | Known peers (public key, device_id, display name, last seen) |
| `messages` | All messages (inbound + outbound) |
| `outbox` | Queue of messages pending delivery |
| `transfer_state` | Chunk-level progress per peer per message |
| `seen_msg_ids` | Deduplication set (msg_id + expiry timestamp) |

### 9.2 Retention

| Data | Retention |
|------|-----------|
| Messages | Until user deletes |
| Outbox (undelivered) | 30 days, then expire |
| Transfer state | Until transfer completes or message expires |
| Seen message IDs | 30 days |

---

## 10. Security Considerations

| Threat | Mitigation |
|--------|------------|
| Eavesdropping on BLE | All message content encrypted E2E (XChaCha20-Poly1305) |
| Replay attacks | msg_id deduplication; random nonces per message |
| Tracking via advertising | Bloom filter rotates with message queue; OS handles address rotation |
| Man-in-the-middle | Key exchange is out-of-band (QR code); public keys verified by users |
| Spam / unsolicited messages | Only messages from known peers (in local peer list) are accepted |
| Forward secrecy | ⚠️ NOT in v0.1 — static key pairs. Future: Double Ratchet |

---

## 11. Future Extensions

- **v0.2**: Double Ratchet (Signal Protocol) for forward secrecy
- **v0.2**: Group messaging (fan-out to multiple peers)
- **v0.3**: Media attachments (images, compressed, chunked over multiple encounters)
- **v0.3**: Store-and-forward relay (trusted intermediary devices carry messages between peers who are never co-located)
- **v0.4**: Mesh routing (multi-hop message delivery via untrusted relays)
