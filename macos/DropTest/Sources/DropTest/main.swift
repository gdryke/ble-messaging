import Foundation

/// Simple terminal-based Drop messaging client for macOS.
/// Uses BLE to exchange messages with Android/iOS Drop apps.

let ui = TerminalUI()

let dbDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".drop")
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("drop.db").path

let manager: DropManager
do {
    manager = try DropManager(dbPath: dbPath, ui: ui)
} catch {
    ui.error("Failed to initialize: \(error)")
    exit(1)
}

ui.info("")
ui.info("Commands:")
ui.info("  peers                       — List known peers")
ui.info("  add <hex-pubkey> <name>     — Add a peer by public key")
ui.info("  send <device-id-hex> <msg>  — Queue a message for a peer")
ui.info("  identity                    — Show your identity (for sharing)")
ui.info("  bloom                       — Show current bloom filter")
ui.info("  status                      — Show BLE connection state")
ui.info("  log                         — Toggle verbose BLE logging")
ui.info("  quit                        — Exit")
ui.info("")
ui.redrawPrompt()

// Run the command loop on a background thread so RunLoop stays alive for BLE
DispatchQueue.global().async {
    while true {
        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else {
            ui.redrawPrompt()
            continue
        }

        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        let command = parts[0].lowercased()

        switch command {
        case "peers":
            manager.listPeers()

        case "add":
            guard parts.count >= 3 else {
                ui.commandOutput("Usage: add <hex-pubkey-64chars> <name>")
                continue
            }
            guard let keyData = Data(hexString: parts[1]), keyData.count == 32 else {
                ui.error("Invalid public key — must be 64 hex characters (32 bytes)")
                continue
            }
            manager.addPeer(publicKey: keyData, name: parts[2])

        case "send":
            guard parts.count >= 3 else {
                ui.commandOutput("Usage: send <device-id-hex-32chars> <message>")
                continue
            }
            guard let idData = Data(hexString: parts[1]), idData.count == 16 else {
                ui.error("Invalid device ID — must be 32 hex characters (16 bytes)")
                continue
            }
            manager.sendMessage(to: idData, text: parts[2])

        case "identity":
            let id = manager.core.getIdentity()
            ui.commandOutput("Device ID:  \(id.deviceId.hex)")
            ui.commandOutput("Public Key: \(id.publicKey.hex)")
            ui.commandOutput("(Share the public key with peers so they can add you)")

        case "bloom":
            do {
                let filter = try manager.core.buildBloomFilter()
                ui.commandOutput("Bloom filter: \(filter.hex)")
                let allZero = filter.allSatisfy { $0 == 0 }
                ui.commandOutput(allZero ? "(empty — no pending messages)" : "(has pending messages)")
            } catch {
                ui.error("Error: \(error)")
            }

        case "status":
            manager.printStatus()

        case "log":
            ui.verboseLogging.toggle()
            ui.commandOutput("Verbose BLE logging: \(ui.verboseLogging ? "ON" : "OFF")")

        case "quit", "exit", "q":
            // Reset terminal before exiting
            print("\u{1B}[1;\(999)r", terminator: "") // restore full scroll region
            print("\u{1B}[2J", terminator: "")         // clear screen
            print("\u{1B}[1;1H", terminator: "")       // cursor home
            print("Bye!")
            exit(0)

        default:
            ui.commandOutput("Unknown command: \(command)")
        }

        ui.redrawPrompt()
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
