import CoreBluetooth
import Foundation

/// Handles BLE central role: scanning + GATT client connections.
final class BleCentral: NSObject, @unchecked Sendable {
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var discoveredChars: [CBUUID: CBCharacteristic] = [:]

    var onBloomFilterDiscovered: ((CBPeripheral, Data?) -> Void)?
    var onConnected: ((CBPeripheral) -> Void)?
    var onCharacteristicDiscovered: ((CBPeripheral, CBCharacteristic) -> Void)?
    var onDataReceived: ((CBCharacteristic, Data) -> Void)?
    var onDisconnected: ((CBPeripheral) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        print("[Central] Scanning for Drop service...")
        centralManager.scanForPeripherals(
            withServices: [BleConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
    }

    func connect(to peripheral: CBPeripheral) {
        print("[Central] Connecting to \(peripheral.name ?? peripheral.identifier.uuidString)...")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }

    /// Write data to a characteristic on the connected peripheral.
    func write(_ data: Data, to charUUID: CBUUID, type: CBCharacteristicWriteType = .withResponse) {
        guard let peripheral = connectedPeripheral,
              let char = discoveredChars[charUUID] else {
            print("[Central] Cannot write — no connection or characteristic not found")
            return
        }
        peripheral.writeValue(data, for: char, type: type)
    }

    /// Read from a characteristic.
    func read(from charUUID: CBUUID) {
        guard let peripheral = connectedPeripheral,
              let char = discoveredChars[charUUID] else { return }
        peripheral.readValue(for: char)
    }

    /// Subscribe to notifications on a characteristic.
    func subscribe(to charUUID: CBUUID) {
        guard let peripheral = connectedPeripheral,
              let char = discoveredChars[charUUID] else { return }
        peripheral.setNotifyValue(true, for: char)
    }
}

extension BleCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("[Central] Bluetooth ON — ready to scan")
            startScanning()
        } else {
            print("[Central] Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "unknown"
        print("[Central] Discovered: \(name) (RSSI: \(RSSI))")

        // Extract service data (bloom filter)
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let bloomData = serviceData?[BleConstants.serviceUUID]

        onBloomFilterDiscovered?(peripheral, bloomData)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[Central] ✅ Connected to \(peripheral.name ?? "device")")
        // Request max MTU
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        print("[Central] MTU: \(mtu + 3) bytes")
        // Discover services
        peripheral.discoverServices([BleConstants.serviceUUID])
        onConnected?(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[Central] Disconnected from \(peripheral.name ?? "device")")
        discoveredChars.removeAll()
        connectedPeripheral = nil
        onDisconnected?(peripheral)
    }
}

extension BleCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            discoveredChars[char.uuid] = char
            print("[Central] Found characteristic: \(char.uuid)")
            onCharacteristicDiscovered?(peripheral, char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        onDataReceived?(characteristic, data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("[Central] Write error: \(error)")
        }
    }
}
