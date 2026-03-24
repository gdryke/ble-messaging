import CoreBluetooth
import Foundation

/// Handles BLE peripheral role: advertising + GATT server.
final class BlePeripheral: NSObject, @unchecked Sendable {
    private(set) var manager: CBPeripheralManager!
    private var service: CBMutableService?
    private var inboxChar: CBMutableCharacteristic?
    private var outboxChar: CBMutableCharacteristic?
    private var handshakeChar: CBMutableCharacteristic?
    private var ackChar: CBMutableCharacteristic?

    var bloomFilterData: Data = Data(count: 8)
    var onWriteReceived: ((CBATTRequest) -> Void)?
    var onReadReceived: ((CBATTRequest) -> Void)?
    var onSubscribed: ((CBCentral, CBCharacteristic) -> Void)?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func startAdvertising() {
        guard manager.state == .poweredOn else { return }

        let service = CBMutableService(type: BleConstants.serviceUUID, primary: true)

        inboxChar = CBMutableCharacteristic(
            type: BleConstants.inboxWriteUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        outboxChar = CBMutableCharacteristic(
            type: BleConstants.outboxNotifyUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        handshakeChar = CBMutableCharacteristic(
            type: BleConstants.handshakeUUID,
            properties: [.read, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )
        ackChar = CBMutableCharacteristic(
            type: BleConstants.ackUUID,
            properties: [.notify, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )

        service.characteristics = [inboxChar!, outboxChar!, handshakeChar!, ackChar!]
        self.service = service

        manager.add(service)
    }

    func updateBloomFilter(_ data: Data) {
        self.bloomFilterData = data
        // Re-advertise with new service data
        if manager.isAdvertising {
            manager.stopAdvertising()
            doAdvertise()
        }
    }

    /// Send data to a subscribed central via the outbox notify characteristic.
    func sendChunk(_ data: Data, to central: CBCentral) {
        guard let outboxChar else { return }
        manager.updateValue(data, for: outboxChar, onSubscribedCentrals: [central])
    }

    /// Send ACK notification.
    func sendAck(_ data: Data, to central: CBCentral) {
        guard let ackChar else { return }
        manager.updateValue(data, for: ackChar, onSubscribedCentrals: [central])
    }

    private func doAdvertise() {
        // Build service data: 8-byte bloom + 1-byte version + 1-byte flags
        var serviceData = bloomFilterData
        serviceData.append(0x01) // protocol version
        serviceData.append(0x00) // flags

        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Drop",
            CBAdvertisementDataServiceDataKey: [BleConstants.serviceUUID: serviceData],
        ])
    }
}

extension BlePeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            print("[Peripheral] Bluetooth ON — setting up GATT service")
            startAdvertising()
        } else {
            print("[Peripheral] Bluetooth state: \(peripheral.state.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            print("[Peripheral] Failed to add service: \(error)")
            return
        }
        print("[Peripheral] Service added — starting advertising")
        doAdvertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("[Peripheral] Advertising failed: \(error)")
        } else {
            print("[Peripheral] ✅ Advertising with service UUID")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            onWriteReceived?(request)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        onReadReceived?(request)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("[Peripheral] Central subscribed to \(characteristic.uuid)")
        onSubscribed?(central, characteristic)
    }
}
