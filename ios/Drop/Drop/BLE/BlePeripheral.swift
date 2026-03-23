import CoreBluetooth
import os

/// Wraps CBPeripheralManager — handles advertising our GATT service and serving characteristics.
final class BlePeripheral: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.drop", category: "BlePeripheral")
    private var peripheralManager: CBPeripheralManager!
    private var gattService: CBMutableService?
    private var subscribedCentrals: [CBCentral] = []

    // Characteristic references for sending data.
    private var outboxCharacteristic: CBMutableCharacteristic?
    private var handshakeCharacteristic: CBMutableCharacteristic?
    private var ackCharacteristic: CBMutableCharacteristic?

    weak var delegate: BlePeripheralDelegate?

    /// Bloom filter bytes to include in advertisement service data.
    var bloomFilterData: Data = Data()

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: DispatchQueue(label: "com.drop.peripheral", qos: .userInitiated),
            options: [
                CBPeripheralManagerOptionRestoreIdentifierKey: BleConstants.peripheralRestoreID
            ]
        )
    }

    // MARK: - Public API

    func startAdvertising() {
        guard peripheralManager.state == .poweredOn else {
            logger.warning("Cannot advertise — Bluetooth not powered on")
            return
        }

        if gattService == nil {
            setupGATTService()
        }

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Drop",
            // Service data is included when advertising in foreground.
            // iOS strips it in background but peers can still discover via service UUID.
        ])
        logger.info("Started advertising")
    }

    func stopAdvertising() {
        peripheralManager.stopAdvertising()
        logger.info("Stopped advertising")
    }

    /// Send data to all subscribed centrals via the outbox (notify) characteristic.
    func sendOutboxData(_ data: Data) -> Bool {
        guard let char = outboxCharacteristic else { return false }
        return peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
    }

    // MARK: - GATT Service Setup

    private func setupGATTService() {
        let inboxChar = CBMutableCharacteristic(
            type: BleConstants.inboxWriteUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let outboxChar = CBMutableCharacteristic(
            type: BleConstants.outboxNotifyUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )

        let handshakeChar = CBMutableCharacteristic(
            type: BleConstants.handshakeUUID,
            properties: [.write, .writeWithoutResponse, .read],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let ackChar = CBMutableCharacteristic(
            type: BleConstants.ackUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let service = CBMutableService(type: BleConstants.serviceUUID, primary: true)
        service.characteristics = [inboxChar, outboxChar, handshakeChar, ackChar]

        outboxCharacteristic = outboxChar
        handshakeCharacteristic = handshakeChar
        ackCharacteristic = ackChar
        gattService = service

        peripheralManager.add(service)
        logger.info("GATT service added")
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BlePeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("Peripheral state: \(peripheral.state.rawValue)")
        delegate?.blePeripheral(self, didUpdateState: peripheral.state)

        if peripheral.state == .poweredOn {
            startAdvertising()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Restore services published before termination.
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services where service.uuid == BleConstants.serviceUUID {
                gattService = service
                for char in service.characteristics ?? [] {
                    if let mutableChar = char as? CBMutableCharacteristic {
                        switch mutableChar.uuid {
                        case BleConstants.outboxNotifyUUID:
                            outboxCharacteristic = mutableChar
                        case BleConstants.handshakeUUID:
                            handshakeCharacteristic = mutableChar
                        case BleConstants.ackUUID:
                            ackCharacteristic = mutableChar
                        default:
                            break
                        }
                    }
                }
                logger.info("Restored GATT service")
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            logger.error("Failed to add service: \(error.localizedDescription)")
        } else {
            logger.info("Service registered: \(service.uuid)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            logger.error("Advertising failed: \(error.localizedDescription)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            logger.info("Write on \(request.characteristic.uuid) (\(data.count) bytes)")
            delegate?.blePeripheral(self, didReceiveWrite: data, on: request.characteristic.uuid, from: request.central)

            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        logger.info("Read on \(request.characteristic.uuid)")
        delegate?.blePeripheral(self, didReceiveRead: request)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        logger.info("Central \(central.identifier) subscribed to \(characteristic.uuid)")
        subscribedCentrals.append(central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        logger.info("Central \(central.identifier) unsubscribed from \(characteristic.uuid)")
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Called when the transmit queue has space again after a failed updateValue.
        delegate?.blePeripheralIsReadyToSend(self)
    }
}

// MARK: - Delegate Protocol

protocol BlePeripheralDelegate: AnyObject {
    func blePeripheral(_ peripheral: BlePeripheral, didUpdateState state: CBManagerState)
    func blePeripheral(_ peripheral: BlePeripheral, didReceiveWrite data: Data, on characteristicUUID: CBUUID, from central: CBCentral)
    func blePeripheral(_ peripheral: BlePeripheral, didReceiveRead request: CBATTRequest)
    func blePeripheralIsReadyToSend(_ peripheral: BlePeripheral)
}
