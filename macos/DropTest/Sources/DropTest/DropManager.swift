import CoreBluetooth
import Foundation

/// Coordinates BLE central/peripheral with the Rust DropCore for message exchange.
final class DropManager: @unchecked Sendable {
    let core: DropCore
    let central: BleCentral
    let peripheral: BlePeripheral

    /// Maps CBPeripheral UUID → device_id bytes (learned during handshake)
    private var peerMap: [UUID: Data] = [:]
    /// Tracks whether we've initiated a handshake with a connected peer
    private var handshakeComplete: [UUID: Bool] = [:]

    init(dbPath: String) throws {
        // Try to load existing secret key
        let keyURL = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
            .appendingPathComponent("identity.key")
        var secretKey: Data? = nil
        if FileManager.default.fileExists(atPath: keyURL.path) {
            secretKey = try? Data(contentsOf: keyURL)
        }

        core = try DropCore(
            dbPath: dbPath,
            secretKey: secretKey
        )

        // Persist secret key if newly generated
        if secretKey == nil {
            let identity = core.getIdentity()
            try? identity.secretKey.write(to: keyURL)
        }

        central = BleCentral()
        peripheral = BlePeripheral()

        setupCallbacks()
        refreshBloomFilter()

        let identity = core.getIdentity()
        print("══════════════════════════════════════════")
        print("  Drop Test — macOS BLE Messaging")
        print("══════════════════════════════════════════")
        print("  Device ID: \(identity.deviceId.hex)")
        print("  Public Key: \(identity.publicKey.hex)")
        print("══════════════════════════════════════════")
    }

    func refreshBloomFilter() {
        do {
            let filter = try core.buildBloomFilter()
            peripheral.updateBloomFilter(filter)
        } catch {
            print("[Drop] Failed to build bloom filter: \(error)")
        }
    }

    // MARK: - Peer Management

    func addPeer(publicKey: Data, name: String) {
        do {
            let peer = try core.addPeer(publicKey: publicKey, displayName: name)
            print("[Drop] ✅ Added peer '\(name)' — device ID: \(peer.deviceId.hex)")
        } catch {
            print("[Drop] Failed to add peer: \(error)")
        }
    }

    func listPeers() {
        do {
            let peers = try core.getPeers()
            if peers.isEmpty {
                print("[Drop] No peers. Use 'add <hex-pubkey> <name>' to add one.")
                return
            }
            print("[Drop] Known peers:")
            for p in peers {
                print("  • \(p.displayName) — \(p.deviceId.hex)")
            }
        } catch {
            print("[Drop] Error: \(error)")
        }
    }

    func sendMessage(to peerDeviceId: Data, text: String) {
        do {
            let msg = try core.composeMessage(
                recipientDeviceId: peerDeviceId,
                text: text
            )
            refreshBloomFilter()
            print("[Drop] ✉️  Message queued: \(msg.msgId) (\(msg.wireBytes.count) bytes)")
        } catch {
            print("[Drop] Send failed: \(error)")
        }
    }

    // MARK: - BLE Callbacks

    private func setupCallbacks() {
        // --- Central: discovered a peer advertising our service ---
        central.onBloomFilterDiscovered = { [weak self] peripheral, bloomData in
            guard let self else { return }

            // Check if their bloom filter indicates messages for us
            let shouldConnect = true
            if let bloomData, bloomData.count >= 8 {
                let hasMessages = self.core.checkBloomFilter(filterBytes: bloomData)
                print("[Drop] Bloom filter check: \(hasMessages ? "match ✅" : "no match")")
                // Connect anyway for handshake — we might have messages for them
            }

            if shouldConnect {
                self.central.connect(to: peripheral)
            }
        }

        // --- Central: connected to peripheral, chars discovered ---
        central.onCharacteristicDiscovered = { [weak self] peripheral, char in
            guard let self else { return }

            // Once we have all chars, initiate handshake
            if char.uuid == BleConstants.handshakeUUID {
                // Read their handshake first
                self.central.read(from: BleConstants.handshakeUUID)
                // Subscribe to outbox notifications (for receiving their messages)
                self.central.subscribe(to: BleConstants.outboxNotifyUUID)
                self.central.subscribe(to: BleConstants.ackUUID)
            }
        }

        // --- Central: received data from a characteristic ---
        central.onDataReceived = { [weak self] char, data in
            guard let self else { return }

            switch char.uuid {
            case BleConstants.handshakeUUID:
                self.handleIncomingHandshake(data, asCentral: true)

            case BleConstants.outboxNotifyUUID:
                self.handleIncomingChunk(data)

            case BleConstants.ackUUID:
                print("[Drop] Received ACK: \(data.hex)")

            default:
                break
            }
        }

        central.onDisconnected = { [weak self] _ in
            self?.peerMap.removeAll()
            self?.handshakeComplete.removeAll()
            print("[Drop] Peer disconnected — resuming scan")
            self?.central.startScanning()
        }

        // --- Peripheral: someone wrote to our GATT server ---
        peripheral.onWriteReceived = { [weak self] request in
            guard let self, let data = request.value else { return }

            switch request.characteristic.uuid {
            case BleConstants.handshakeUUID:
                self.handleIncomingHandshake(data, asCentral: false)
                // Respond with our handshake — we need to figure out who they are first
                // For now, build a generic handshake
                self.respondWithHandshake(to: request)

            case BleConstants.inboxWriteUUID:
                self.handleIncomingChunk(data)

            case BleConstants.ackUUID:
                print("[Drop] Received ACK via write: \(data.hex)")

            default:
                break
            }
        }

        peripheral.onReadReceived = { [weak self] request in
            guard let self else { return }
            if request.characteristic.uuid == BleConstants.handshakeUUID {
                self.respondWithHandshake(to: request)
            }
        }
    }

    private func handleIncomingHandshake(_ data: Data, asCentral: Bool) {
        do {
            let info = try core.parseHandshake(data: data)
            let peerDeviceId = info.deviceId
            print("[Drop] 🤝 Handshake from peer: \(peerDeviceId.hex) (v\(info.version))")
            print("[Drop]    Pending messages for us: \(info.pendingMsgIds.count)")

            // If we're the central, write our handshake back
            if asCentral {
                let ourHandshake = try core.buildHandshake(peerDeviceId: peerDeviceId)
                central.write(ourHandshake, to: BleConstants.handshakeUUID)

                // Now send any pending messages for this peer
                sendPendingMessages(to: peerDeviceId)
            }
        } catch {
            print("[Drop] Handshake parse error: \(error)")
        }
    }

    private func respondWithHandshake(to request: CBATTRequest) {
        do {
            let zeroPeerId = Data(count: 16)
            let hs = try core.buildHandshake(peerDeviceId: zeroPeerId)
            request.value = hs
            peripheral.manager.respond(to: request, withResult: .success)
        } catch {
            print("[Drop] Failed to build handshake response: \(error)")
        }
    }

    private func sendPendingMessages(to peerDeviceId: Data) {
        do {
            let pending = try core.getPendingForPeer(deviceId: peerDeviceId)
            guard !pending.isEmpty else {
                print("[Drop] No pending messages for this peer")
                return
            }
            print("[Drop] Sending \(pending.count) message(s)...")

            for msg in pending {
                let chunks = core.splitIntoChunks(
                    msgWireBytes: msg.wireBytes,
                    mtu: UInt16(BleConstants.targetMTU)
                )
                for chunkBytes in chunks {
                    central.write(chunkBytes, to: BleConstants.inboxWriteUUID, type: .withResponse)
                }
                try core.markDelivered(msgId: msg.msgId)
                print("[Drop] ✅ Sent message \(msg.msgId) (\(chunks.count) chunk(s))")
            }
            refreshBloomFilter()
        } catch {
            print("[Drop] Error sending messages: \(error)")
        }
    }

    private func handleIncomingChunk(_ data: Data) {
        do {
            let result = try core.processChunk(chunkBytes: data)
            print("[Drop] Chunk \(result.chunkIndex + 1)/\(result.totalChunks) for msg \(result.msgId)")

            if result.isComplete, let assembled = result.assembledMessage {
                let decrypted = try core.receiveMessage(wireBytes: assembled)
                print("[Drop] 💬 Message from \(decrypted.senderId.hex):")
                print("[Drop]    \(decrypted.body)")
            }
        } catch {
            print("[Drop] Chunk processing error: \(error)")
        }
    }
}

// MARK: - Data hex helper
extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
