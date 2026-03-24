import Foundation

/// Simple terminal-based Drop messaging client for macOS.
/// Uses BLE to exchange messages with Android/iOS Drop apps.

let dbDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".drop")
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("drop.db").path

let manager: DropManager
do {
    manager = try DropManager(dbPath: dbPath)
} catch {
    print("❌ Failed to initialize: \(error)")
    exit(1)
}

print("")
print("Commands:")
print("  peers                       — List known peers")
print("  add <hex-pubkey> <name>     — Add a peer by public key")
print("  send <device-id-hex> <msg>  — Queue a message for a peer")
print("  identity                    — Show your identity (for sharing)")
print("  bloom                       — Show current bloom filter")
print("  quit                        — Exit")
print("")

// Run the command loop on a background thread so RunLoop stays alive for BLE
DispatchQueue.global().async {
    while true {
        print("> ", terminator: "")
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { continue }

        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let command = parts[0].lowercased()

        switch command {
        case "peers":
            manager.listPeers()

        case "add":
            guard parts.count >= 3 else {
                print("Usage: add <hex-pubkey-64chars> <name>")
                continue
            }
            guard let keyData = Data(hexString: parts[1]), keyData.count == 32 else {
                print("Invalid public key — must be 64 hex characters (32 bytes)")
                continue
            }
            manager.addPeer(publicKey: keyData, name: parts[2])

        case "send":
            guard parts.count >= 3 else {
                print("Usage: send <device-id-hex-32chars> <message>")
                continue
            }
            guard let idData = Data(hexString: parts[1]), idData.count == 16 else {
                print("Invalid device ID — must be 32 hex characters (16 bytes)")
                continue
            }
            manager.sendMessage(to: idData, text: parts[2])

        case "identity":
            let id = manager.core.getIdentity()
            print("Device ID:  \(id.deviceId.hex)")
            print("Public Key: \(id.publicKey.hex)")
            print("(Share the public key with peers so they can add you)")

        case "bloom":
            do {
                let filter = try manager.core.buildBloomFilter()
                print("Bloom filter: \(filter.hex)")
                let allZero = filter.allSatisfy { $0 == 0 }
                print(allZero ? "(empty — no pending messages)" : "(has pending messages)")
            } catch {
                print("Error: \(error)")
            }

        case "quit", "exit", "q":
            print("Bye!")
            exit(0)

        default:
            print("Unknown command: \(command)")
        }
    }
}

// Keep the main RunLoop alive for CoreBluetooth
RunLoop.main.run()

// MARK: - Hex string → Data

extension Data {
    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
