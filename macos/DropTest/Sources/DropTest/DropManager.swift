import CoreBluetooth
import Foundation

/// Coordinates BLE central/peripheral with the Rust DropCore for message exchange.
final class DropManager: @unchecked Sendable {
    let core: DropCore
    let central: BleCentral
    let peripheral: BlePeripheral
    let ui: TerminalUI

    /// Maps CBPeripheral UUID → device_id bytes (learned during handshake)
    private var peerMap: [UUID: Data] = [:]
    /// Tracks whether we've initiated a handshake with a connected peer
    private var handshakeComplete: [UUID: Bool] = [:]

    // -- Deduplication state --
    /// Peripheral UUIDs we've already discovered (avoid repeat "Discovered" logs)
    private var knownPeripherals: Set<UUID> = []
    /// Peripheral UUIDs for which we already logged a bloom filter check
    private var bloomCheckedPeers: Set<UUID> = []
    /// Peers we've exchanged messages with (device-id hex → true)
    private var exchangedPeers: Set<String> = []
    /// Whether a reconnect timer is already pending
    private var reconnectScheduled: Bool = false

    init(dbPath: String, ui: TerminalUI) throws {
        self.ui = ui

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

        // Wire up UI references
        central.ui = ui
        peripheral.ui = ui

        setupCallbacks()
        refreshBloomFilter()

        let identity = core.getIdentity()
        ui.info("══════════════════════════════════════════")
        ui.info("  Drop Test — macOS BLE Messaging")
        ui.info("══════════════════════════════════════════")
        ui.info("  Device ID:  \(identity.deviceId.hex)")
        ui.info("  Public Key: \(identity.publicKey.hex)")
        ui.info("══════════════════════════════════════════")
    }

    func refreshBloomFilter() {
        do {
            let filter = try core.buildBloomFilter()
            peripheral.updateBloomFilter(filter)
        } catch {
            ui.error("Failed to build bloom filter: \(error)")
        }
    }

    // MARK: - Status

    func printStatus() {
        ui.commandOutput("BLE Status:")
        ui.commandOutput("  Scanning:    \(central.isScanning ? "yes" : "no")")
        ui.commandOutput("  Advertising: \(peripheral.isAdvertising ? "yes" : "no")")
        ui.commandOutput("  Known peers nearby: \(knownPeripherals.count)")
        ui.commandOutput("  Handshakes done:    \(handshakeComplete.values.filter { $0 }.count)")
        ui.commandOutput("  Verbose logging:    \(ui.verboseLogging ? "on" : "off")")
    }

    // MARK: - Peer Management

    func addPeer(publicKey: Data, name: String) {
        do {
            let peer = try core.addPeer(publicKey: publicKey, displayName: name)
            ui.success("✅ Added peer '\(name)' — device ID: \(peer.deviceId.hex)")
        } catch {
            ui.error("Failed to add peer: \(error)")
        }
    }

    func listPeers() {
        do {
            let peers = try core.getPeers()
            if peers.isEmpty {
                ui.commandOutput("No peers. Use 'add <hex-pubkey> <name>' to add one.")
                return
            }
            ui.commandOutput("Known peers:")
            for p in peers {
                ui.commandOutput("  • \(p.displayName) — \(p.deviceId.hex)")
            }
        } catch {
            ui.error("Error: \(error)")
        }
    }

    func sendMessage(to peerDeviceId: Data, text: String) {
        do {
            let msg = try core.composeMessage(
                recipientDeviceId: peerDeviceId,
                text: text
            )
            refreshBloomFilter()
            ui.chatMessage(from: "you", text: text, incoming: false)
            ui.systemLog("Message queued: \(msg.msgId) (\(msg.wireBytes.count) bytes)")
        } catch {
            ui.error("Send failed: \(error)")
        }
    }

    // MARK: - BLE Callbacks

    private func setupCallbacks() {
        // --- Central: discovered a peer advertising our service ---
        central.onBloomFilterDiscovered = { [weak self] peripheral, bloomData in
            guard let self else { return }

            let pId = peripheral.identifier
            let isNew = self.knownPeripherals.insert(pId).inserted
            if isNew {
                let name = peripheral.name ?? pId.uuidString.prefix(8).description
                self.ui.systemLog("Discovered peer: \(name)")
            }

            // Check bloom filter (only log once per peer)
            if let bloomData, bloomData.count >= 8 {
                if self.bloomCheckedPeers.insert(pId).inserted {
                    let hasMessages = self.core.checkBloomFilter(filterBytes: bloomData)
                    self.ui.systemLog("Bloom check for \(pId.uuidString.prefix(8)): \(hasMessages ? "match ✅" : "no match")")
                }
            }

            self.central.connect(to: peripheral)
        }

        // --- Central: connected to peripheral, chars discovered ---
        central.onCharacteristicDiscovered = { [weak self] peripheral, char in
            guard let self else { return }

            if char.uuid == BleConstants.handshakeUUID {
                self.central.read(from: BleConstants.handshakeUUID)
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
                self.ui.systemLog("Received ACK: \(data.hex)")

            default:
                break
            }
        }

        // --- Central: peer disconnected — delay before re-scanning ---
        central.onDisconnected = { [weak self] peripheral in
            guard let self else { return }
            self.peerMap.removeAll()
            self.handshakeComplete.removeAll()

            let name = peripheral.name ?? peripheral.identifier.uuidString.prefix(8).description
            self.ui.systemLog("Lost connection to \(name)")
            self.ui.statusBar("Drop — disconnected")

            // Avoid rapid reconnect loop: wait 3 seconds before resuming scan
            guard !self.reconnectScheduled else { return }
            self.reconnectScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                self.reconnectScheduled = false
                self.ui.systemLog("Resuming scan…")
                self.central.startScanning()
            }
        }

        // --- Peripheral: someone wrote to our GATT server ---
        peripheral.onWriteReceived = { [weak self] request in
            guard let self, let data = request.value else { return }

            switch request.characteristic.uuid {
            case BleConstants.handshakeUUID:
                self.handleIncomingHandshake(data, asCentral: false)
                self.respondWithHandshake(to: request)

            case BleConstants.inboxWriteUUID:
                self.handleIncomingChunk(data)

            case BleConstants.ackUUID:
                self.ui.systemLog("Received ACK via write: \(data.hex)")

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
            ui.systemLog("🤝 Handshake from \(peerDeviceId.hex.prefix(12))… (v\(info.version))")

            if info.pendingMsgIds.count > 0 {
                ui.systemLog("  Pending messages for us: \(info.pendingMsgIds.count)")
            }

            ui.statusBar("Drop — connected to \(peerDeviceId.hex.prefix(12))…")

            if asCentral {
                let ourHandshake = try core.buildHandshake(peerDeviceId: peerDeviceId)
                central.write(ourHandshake, to: BleConstants.handshakeUUID)
                sendPendingMessages(to: peerDeviceId)
            }
        } catch {
            ui.error("Handshake parse error: \(error)")
        }
    }

    private func respondWithHandshake(to request: CBATTRequest) {
        do {
            let zeroPeerId = Data(count: 16)
            let hs = try core.buildHandshake(peerDeviceId: zeroPeerId)
            request.value = hs
            peripheral.manager.respond(to: request, withResult: .success)
        } catch {
            ui.error("Failed to build handshake response: \(error)")
        }
    }

    private func sendPendingMessages(to peerDeviceId: Data) {
        do {
            let pending = try core.getPendingForPeer(deviceId: peerDeviceId)
            guard !pending.isEmpty else {
                ui.systemLog("No pending messages for this peer")
                return
            }
            ui.systemLog("Sending \(pending.count) message(s)…")

            for msg in pending {
                let chunks = core.splitIntoChunks(
                    msgWireBytes: msg.wireBytes,
                    mtu: UInt16(BleConstants.targetMTU)
                )
                for chunkBytes in chunks {
                    central.write(chunkBytes, to: BleConstants.inboxWriteUUID, type: .withResponse)
                }
                try core.markDelivered(msgId: msg.msgId)
                ui.success("✅ Sent message \(msg.msgId) (\(chunks.count) chunk(s))")
                exchangedPeers.insert(peerDeviceId.hex)
            }
            refreshBloomFilter()
        } catch {
            ui.error("Error sending messages: \(error)")
        }
    }

    private func handleIncomingChunk(_ data: Data) {
        do {
            let result = try core.processChunk(chunkBytes: data)
            ui.systemLog("Chunk \(result.chunkIndex + 1)/\(result.totalChunks) for msg \(result.msgId)")

            if result.isComplete, let assembled = result.assembledMessage {
                let decrypted = try core.receiveMessage(wireBytes: assembled)
                ui.chatMessage(from: decrypted.senderId.hex.prefix(12).description,
                               text: decrypted.body, incoming: true)
                exchangedPeers.insert(decrypted.senderId.hex)
            }
        } catch {
            ui.error("Chunk processing error: \(error)")
        }
    }
}

// MARK: - Data hex helper
extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
