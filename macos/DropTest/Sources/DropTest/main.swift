import Foundation

/// Simple terminal-based Drop messaging client for macOS.
/// Uses BLE to exchange messages with Android/iOS Drop apps.

let ui = TerminalUI()

// MARK: - Raw terminal input with history

/// Manages raw terminal input for the command prompt.
final class RawInput: @unchecked Sendable {
    private var history: [String] = []
    private var historyIndex: Int = 0
    private var currentLine: String = ""
    private var cursorPos: Int = 0
    private var originalTermios = termios()

    init() {
        enableRawMode()
    }

    private func enableRawMode() {
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        // Disable canonical mode (line buffering) and echo
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        // Read 1 byte at a time, no timeout
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    func restoreTerminal() {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    }

    /// Read a line of input with arrow key history support.
    /// Returns nil on EOF.
    func readLine() -> String? {
        currentLine = ""
        cursorPos = 0
        historyIndex = history.count

        while true {
            var c: UInt8 = 0
            let n = read(STDIN_FILENO, &c, 1)
            if n <= 0 { return nil }

            switch c {
            case 3:  // Ctrl+C
                return "\u{03}"  // signal to caller
            case 4:  // Ctrl+D (EOF)
                if currentLine.isEmpty { return nil }
            case 10, 13:  // Enter
                if !currentLine.isEmpty {
                    history.append(currentLine)
                    if history.count > 200 { history.removeFirst() }
                }
                return currentLine
            case 127, 8:  // Backspace / Delete
                if cursorPos > 0 {
                    let idx = currentLine.index(currentLine.startIndex, offsetBy: cursorPos - 1)
                    currentLine.remove(at: idx)
                    cursorPos -= 1
                    refreshLine()
                }
            case 27:  // Escape sequence (arrow keys)
                var seq1: UInt8 = 0, seq2: UInt8 = 0
                guard read(STDIN_FILENO, &seq1, 1) == 1 else { continue }
                guard read(STDIN_FILENO, &seq2, 1) == 1 else { continue }
                if seq1 == 91 {  // [
                    switch seq2 {
                    case 65:  // Up arrow
                        if historyIndex > 0 {
                            historyIndex -= 1
                            currentLine = history[historyIndex]
                            cursorPos = currentLine.count
                            refreshLine()
                        }
                    case 66:  // Down arrow
                        if historyIndex < history.count - 1 {
                            historyIndex += 1
                            currentLine = history[historyIndex]
                            cursorPos = currentLine.count
                            refreshLine()
                        } else if historyIndex == history.count - 1 {
                            historyIndex = history.count
                            currentLine = ""
                            cursorPos = 0
                            refreshLine()
                        }
                    case 67:  // Right arrow
                        if cursorPos < currentLine.count {
                            cursorPos += 1
                            refreshLine()
                        }
                    case 68:  // Left arrow
                        if cursorPos > 0 {
                            cursorPos -= 1
                            refreshLine()
                        }
                    default:
                        break
                    }
                }
            case 21:  // Ctrl+U — clear line
                currentLine = ""
                cursorPos = 0
                refreshLine()
            default:
                if c >= 32 && c < 127 {  // printable ASCII
                    let idx = currentLine.index(currentLine.startIndex, offsetBy: cursorPos)
                    currentLine.insert(Character(UnicodeScalar(c)), at: idx)
                    cursorPos += 1
                    refreshLine()
                }
            }
        }
    }

    private func refreshLine() {
        // Redraw the prompt line with current input
        ui.drawPromptWithText(currentLine, cursorOffset: cursorPos)
    }
}

// -- Ctrl+C state --
var ctrlCPending = false

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

ui.info("Commands: peers, add, send, identity, bloom, status, log, quit")
ui.redrawPrompt()

let input = RawInput()

// Run the command loop on a background thread so RunLoop stays alive for BLE
DispatchQueue.global().async {
    while true {
        guard let line = input.readLine() else {
            // EOF
            ui.cleanup()
            input.restoreTerminal()
            exit(0)
        }

        // Handle Ctrl+C
        if line == "\u{03}" {
            if ctrlCPending {
                ui.cleanup()
                input.restoreTerminal()
                Foundation.write(STDOUT_FILENO, "Bye!\n", 5)
                exit(0)
            }
            ctrlCPending = true
            ui.systemLog("Press Ctrl+C again to exit")
            ui.redrawPrompt()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                ctrlCPending = false
            }
            continue
        }

        ctrlCPending = false
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            ui.redrawPrompt()
            continue
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
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
            ui.cleanup()
            input.restoreTerminal()
            Foundation.write(STDOUT_FILENO, "Bye!\n", 5)
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
