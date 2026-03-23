import CoreBluetooth
import os

/// Wraps CBCentralManager — handles scanning for peers and GATT client operations.
final class BleCentral: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.drop", category: "BleCentral")
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]

    weak var delegate: BleCentralDelegate?

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: DispatchQueue(label: "com.drop.central", qos: .userInitiated),
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: BleConstants.centralRestoreID
            ]
        )
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan — Bluetooth not powered on (state: \(self.centralManager.state.rawValue))")
            return
        }
        // Scanning for our service UUID is required for background scanning on iOS.
        centralManager.scanForPeripherals(
            withServices: [BleConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("Started scanning for Drop peers")
    }

    func stopScanning() {
        centralManager.stopScan()
        logger.info("Stopped scanning")
    }

    func connect(to peripheral: CBPeripheral) {
        centralManager.connect(peripheral, options: nil)
        logger.info("Connecting to \(peripheral.identifier)")
    }

    func disconnect(from peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func negotiatedMTU(for peripheral: CBPeripheral) -> Int {
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        return mtu > 0 ? mtu : 20 // fallback to default BLE MTU payload
    }
}

// MARK: - CBCentralManagerDelegate

extension BleCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central state: \(central.state.rawValue)")
        delegate?.bleCentral(self, didUpdateState: central.state)

        if central.state == .poweredOn {
            startScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // State restoration — recover peripherals that were connected before the app was killed.
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                peripheral.delegate = self
                connectedPeripherals[peripheral.identifier] = peripheral
                logger.info("Restored peripheral: \(peripheral.identifier)")
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        logger.info("Discovered \(peripheral.identifier) RSSI=\(RSSI)")
        discoveredPeripherals[peripheral.identifier] = peripheral

        // Extract service data (contains Bloom filter) if present.
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let bloomData = serviceData?[BleConstants.serviceUUID]

        delegate?.bleCentral(self, didDiscover: peripheral, serviceData: bloomData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.identifier)")
        connectedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self

        // Discover our GATT service.
        peripheral.discoverServices([BleConstants.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect to \(peripheral.identifier): \(error?.localizedDescription ?? "unknown")")
        discoveredPeripherals.removeValue(forKey: peripheral.identifier)
        delegate?.bleCentral(self, didDisconnect: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("Disconnected from \(peripheral.identifier)")
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        delegate?.bleCentral(self, didDisconnect: peripheral)
    }
}

// MARK: - CBPeripheralDelegate (GATT Client)

extension BleCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BleConstants.serviceUUID {
            peripheral.discoverCharacteristics([
                BleConstants.inboxWriteUUID,
                BleConstants.outboxNotifyUUID,
                BleConstants.handshakeUUID,
                BleConstants.ackUUID,
            ], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        logger.info("Discovered \(characteristics.count) characteristics for \(peripheral.identifier)")

        for char in characteristics {
            // Subscribe to notifications on the outbox characteristic.
            if char.uuid == BleConstants.outboxNotifyUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }

        delegate?.bleCentral(self, didDiscoverCharacteristics: characteristics, for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        delegate?.bleCentral(self, didReceiveData: data, on: characteristic.uuid, from: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("Write failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        logger.info("Notification state for \(characteristic.uuid): \(characteristic.isNotifying)")
    }
}

// MARK: - Delegate Protocol

protocol BleCentralDelegate: AnyObject {
    func bleCentral(_ central: BleCentral, didUpdateState state: CBManagerState)
    func bleCentral(_ central: BleCentral, didDiscover peripheral: CBPeripheral, serviceData: Data?, rssi: Int)
    func bleCentral(_ central: BleCentral, didDisconnect peripheral: CBPeripheral)
    func bleCentral(_ central: BleCentral, didDiscoverCharacteristics characteristics: [CBCharacteristic], for peripheral: CBPeripheral)
    func bleCentral(_ central: BleCentral, didReceiveData data: Data, on characteristicUUID: CBUUID, from peripheral: CBPeripheral)
}
