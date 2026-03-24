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

    var ui: TerminalUI?

    var bloomFilterData: Data = Data(count: 8)
    var onWriteReceived: ((CBATTRequest) -> Void)?
    var onReadReceived: ((CBATTRequest) -> Void)?
    var onSubscribed: ((CBCentral, CBCharacteristic) -> Void)?

    /// Whether currently advertising
    private(set) var isAdvertising: Bool = false

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
        // Note: CBAdvertisementDataServiceDataKey is not supported for peripheral
        // advertising on macOS. The Bloom filter is instead served via the
        // handshake characteristic. Only advertise service UUID and local name.
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleConstants.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Drop",
        ])
    }
}

extension BlePeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            ui?.systemLog("Peripheral: Bluetooth ON — setting up GATT")
            startAdvertising()
        } else {
            ui?.systemLog("Peripheral: Bluetooth state \(peripheral.state.rawValue)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            ui?.error("Peripheral: failed to add service: \(error)")
            return
        }
        ui?.systemLog("Peripheral: service added — advertising")
        doAdvertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            ui?.error("Peripheral: advertising failed: \(error)")
        } else {
            isAdvertising = true
            ui?.systemLog("Peripheral: advertising ✓")
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
        ui?.systemLog("Peripheral: central subscribed to \(characteristic.uuid)")
        onSubscribed?(central, characteristic)
    }
}
