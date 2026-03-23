import CoreBluetooth
import Observation
import os

/// Connection lifecycle states.
enum ConnectionPhase: String, Sendable {
    case idle
    case discovering
    case connecting
    case handshaking
    case transferring
    case done
}

/// Coordinates BleCentral and BlePeripheral.
/// Acts as the single entry-point for all BLE operations from the UI layer.
@Observable
final class BleManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.drop", category: "BleManager")
    private let central: BleCentral
    private let peripheral: BlePeripheral
    private let repository: DropRepository

    // MARK: - Observable State

    var centralState: CBManagerState = .unknown
    var peripheralState: CBManagerState = .unknown
    var phase: ConnectionPhase = .idle
    var discoveredPeerCount: Int = 0

    /// Peer IDs we are currently connected to (prevents duplicate connections).
    private var activePeers: Set<UUID> = []

    init(repository: DropRepository) {
        self.repository = repository
        self.central = BleCentral()
        self.peripheral = BlePeripheral()

        self.central.delegate = self
        self.peripheral.delegate = self

        // TODO: Wire UniFFI bindings — load Bloom filter from Rust core
        // peripheral.bloomFilterData = repository.buildBloomFilter()
    }

    // MARK: - Public API

    func start() {
        central.startScanning()
        peripheral.startAdvertising()
        phase = .discovering
    }

    func stop() {
        central.stopScanning()
        peripheral.stopAdvertising()
        phase = .idle
    }

    // MARK: - Role Selection

    /// When two Drop peers discover each other simultaneously, both sides may
    /// try to connect as Central. To break the tie, the device with the
    /// lexicographically lower device-id keeps the Central role; the other
    /// side backs off and waits to be connected to as Peripheral.
    private func shouldActAsCentral(localID: Data, remoteID: Data) -> Bool {
        localID.lexicographicallyPrecedes(remoteID)
    }

    // MARK: - Peer Handling

    private func handleDiscoveredPeer(_ peerPeripheral: CBPeripheral, serviceData: Data?) {
        guard !activePeers.contains(peerPeripheral.identifier) else {
            logger.debug("Already connected to \(peerPeripheral.identifier), skipping")
            return
        }

        // TODO: Wire UniFFI bindings — check Bloom filter intersection
        // let hasMessages = repository.checkBloomFilter(remoteFilter: serviceData)
        let hasMessages = true // placeholder

        if hasMessages {
            activePeers.insert(peerPeripheral.identifier)
            central.connect(to: peerPeripheral)
            phase = .connecting
        }
    }

    private func handleCharacteristicsReady(_ characteristics: [CBCharacteristic], for peerPeripheral: CBPeripheral) {
        phase = .handshaking

        // TODO: Wire UniFFI bindings — perform handshake via Rust core
        // let handshakePayload = repository.buildHandshake(peerId: peerPeripheral.identifier)
        // write handshakePayload to the handshake characteristic

        logger.info("Characteristics ready for \(peerPeripheral.identifier), starting handshake")
    }

    private func handleReceivedData(_ data: Data, on uuid: CBUUID, from peerPeripheral: CBPeripheral) {
        switch uuid {
        case BleConstants.handshakeUUID:
            logger.info("Received handshake from \(peerPeripheral.identifier)")
            // TODO: Wire UniFFI bindings — process handshake via Rust core
            phase = .transferring

        case BleConstants.outboxNotifyUUID:
            logger.info("Received message data (\(data.count) bytes) from \(peerPeripheral.identifier)")
            // TODO: Wire UniFFI bindings — deliver message payload to Rust core
            // repository.storeIncomingMessage(data, from: peerPeripheral.identifier)

        case BleConstants.ackUUID:
            logger.info("Received ACK from \(peerPeripheral.identifier)")
            // TODO: Wire UniFFI bindings — mark messages as delivered

        default:
            logger.warning("Unexpected characteristic: \(uuid)")
        }
    }

    private func handlePeerDisconnected(_ peerPeripheral: CBPeripheral) {
        activePeers.remove(peerPeripheral.identifier)
        if activePeers.isEmpty {
            phase = .discovering
        }
    }
}

// MARK: - BleCentralDelegate

extension BleManager: BleCentralDelegate {
    func bleCentral(_ central: BleCentral, didUpdateState state: CBManagerState) {
        centralState = state
    }

    func bleCentral(_ central: BleCentral, didDiscover peerPeripheral: CBPeripheral, serviceData: Data?, rssi: Int) {
        discoveredPeerCount += 1
        handleDiscoveredPeer(peerPeripheral, serviceData: serviceData)
    }

    func bleCentral(_ central: BleCentral, didDisconnect peerPeripheral: CBPeripheral) {
        handlePeerDisconnected(peerPeripheral)
    }

    func bleCentral(_ central: BleCentral, didDiscoverCharacteristics characteristics: [CBCharacteristic], for peerPeripheral: CBPeripheral) {
        handleCharacteristicsReady(characteristics, for: peerPeripheral)
    }

    func bleCentral(_ central: BleCentral, didReceiveData data: Data, on characteristicUUID: CBUUID, from peerPeripheral: CBPeripheral) {
        handleReceivedData(data, on: characteristicUUID, from: peerPeripheral)
    }
}

// MARK: - BlePeripheralDelegate

extension BleManager: BlePeripheralDelegate {
    func blePeripheral(_ peripheral: BlePeripheral, didUpdateState state: CBManagerState) {
        peripheralState = state
    }

    func blePeripheral(_ peripheral: BlePeripheral, didReceiveWrite data: Data, on characteristicUUID: CBUUID, from central: CBCentral) {
        switch characteristicUUID {
        case BleConstants.inboxWriteUUID:
            logger.info("Inbox write from \(central.identifier) (\(data.count) bytes)")
            // TODO: Wire UniFFI bindings — deliver incoming message to Rust core

        case BleConstants.handshakeUUID:
            logger.info("Handshake write from \(central.identifier)")
            // TODO: Wire UniFFI bindings — process handshake via Rust core

        case BleConstants.ackUUID:
            logger.info("ACK write from \(central.identifier)")
            // TODO: Wire UniFFI bindings — mark messages as delivered

        default:
            logger.warning("Write on unexpected characteristic: \(characteristicUUID)")
        }
    }

    func blePeripheral(_ peripheral: BlePeripheral, didReceiveRead request: CBATTRequest) {
        // TODO: Wire UniFFI bindings — serve read requests from Rust core
    }

    func blePeripheralIsReadyToSend(_ peripheral: BlePeripheral) {
        // Resume sending queued outbox data.
        // TODO: Wire UniFFI bindings — get next chunk from Rust core
    }
}
