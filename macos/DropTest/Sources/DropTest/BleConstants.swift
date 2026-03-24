import CoreBluetooth

/// Protocol UUIDs matching the Drop protocol spec
enum BleConstants {
    static let serviceUUID = CBUUID(string: "D7A00001-E28C-4B8E-8C3F-4A77C4D2F5B1")
    static let inboxWriteUUID = CBUUID(string: "D7A00002-E28C-4B8E-8C3F-4A77C4D2F5B1")
    static let outboxNotifyUUID = CBUUID(string: "D7A00003-E28C-4B8E-8C3F-4A77C4D2F5B1")
    static let handshakeUUID = CBUUID(string: "D7A00004-E28C-4B8E-8C3F-4A77C4D2F5B1")
    static let ackUUID = CBUUID(string: "D7A00005-E28C-4B8E-8C3F-4A77C4D2F5B1")
    static let targetMTU = 517
}
