import Foundation

/// ANSI-based split-screen terminal UI.
/// Top region: scrolling system/BLE log.  Middle region: chat messages.
/// Bottom line: fixed command prompt that doesn't scroll away.
final class TerminalUI: @unchecked Sendable {

    // MARK: - ANSI helpers

    private let esc = "\u{1B}["
    private let reset = "\u{1B}[0m"
    private let cyan = "\u{1B}[36m"
    private let dim = "\u{1B}[2m"
    private let green = "\u{1B}[32m"
    private let yellow = "\u{1B}[33m"
    private let bold = "\u{1B}[1m"
    private let white = "\u{1B}[37m"
    private let red = "\u{1B}[31m"
    private let magenta = "\u{1B}[35m"

    // MARK: - Layout

    /// Terminal dimensions (updated on init and SIGWINCH)
    private var rows: Int = 24
    private var cols: Int = 80

    /// Row boundaries (1-based, inclusive)
    private var systemTop: Int { 1 }
    private var systemBottom: Int { statusRow - 1 }
    private var statusRow: Int { rows - 1 }
    private var promptRow: Int { rows }

    /// Whether verbose BLE logging is enabled
    var verboseLogging: Bool = true

    private let lock = NSLock()

    // Ring buffers so we can redraw on resize
    private var systemLines: [String] = []
    private var chatLines: [String] = []
    private let maxBuffer = 500

    // MARK: - Init / teardown

    init() {
        detectSize()
        setupScreen()
    }

    private func detectSize() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            rows = max(Int(ws.ws_row), 8)
            cols = max(Int(ws.ws_col), 40)
        }
    }

    private func setupScreen() {
        // Clear screen and draw initial layout
        write("\(esc)2J")          // clear entire screen
        write("\(esc)1;1H")        // cursor to top-left
        drawStatusBar("Drop — initializing…")
        redrawPrompt()
        // Set scroll region to system area only so prints don't touch prompt
        setScrollRegion(systemTop, systemBottom)
    }

    private func setScrollRegion(_ top: Int, _ bottom: Int) {
        write("\(esc)\(top);\(bottom)r")
    }

    // MARK: - Public API

    /// Log a BLE / system event in the top scrolling region (dim cyan).
    func systemLog(_ message: String) {
        guard verboseLogging else { return }
        let line = "\(dim)\(cyan)[sys] \(message)\(reset)"
        appendSystem(line)
    }

    /// Display a chat message (green=incoming, yellow=outgoing).
    func chatMessage(from sender: String, text: String, incoming: Bool) {
        let color = incoming ? green : yellow
        let arrow = incoming ? "◀" : "▶"
        let line = "\(bold)\(color)\(arrow) \(sender):\(reset) \(text)"
        appendChat(line)
    }

    /// Update the status bar.
    func statusBar(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        drawStatusBar(text)
        restorePromptCursor()
    }

    /// Redraw the prompt at the bottom row. Call after any output that might
    /// clobber it.
    func redrawPrompt() {
        write("\(esc)\(promptRow);1H\(esc)2K\(bold)\(white)> \(reset)")
        fflush(stdout)
    }

    /// Print an informational line in the system region (white, not dim).
    func info(_ message: String) {
        let line = "\(white)\(message)\(reset)"
        appendSystem(line)
    }

    /// Print an error in the system region (red).
    func error(_ message: String) {
        let line = "\(red)[err] \(message)\(reset)"
        appendSystem(line)
    }

    /// Print a success line in the system region.
    func success(_ message: String) {
        let line = "\(green)\(message)\(reset)"
        appendSystem(line)
    }

    /// Print command output that should appear right away (e.g. peer list).
    func commandOutput(_ message: String) {
        appendSystem("\(white)\(message)\(reset)")
    }

    // MARK: - Internal drawing

    private func appendSystem(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        systemLines.append(line)
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        printInSystemRegion(line)
    }

    private func appendChat(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        // Chat messages go to the system scroll region too (single scroll area).
        chatLines.append(line)
        if chatLines.count > maxBuffer { chatLines.removeFirst() }
        printInSystemRegion(line)
    }

    private func printInSystemRegion(_ line: String) {
        // Save cursor position, write in system region, restore cursor
        write("\(esc)s")  // save cursor
        setScrollRegion(systemTop, systemBottom)
        write("\(esc)\(systemBottom);1H\n\(esc)2K\(line)")
        write("\(esc)u")  // restore cursor
        fflush(stdout)
    }

    private func drawStatusBar(_ text: String) {
        write("\(esc)s")  // save cursor
        setScrollRegion(1, rows)
        let padded = String((text + String(repeating: " ", count: max(0, cols - text.count))).prefix(cols))
        write("\(esc)\(statusRow);1H\(esc)2K\(bold)\(magenta)── \(padded)\(reset)")
        setScrollRegion(systemTop, systemBottom)
        write("\(esc)u")  // restore cursor
    }

    private func restorePromptCursor() {
        // Put cursor back on the prompt line after the "> "
        write("\(esc)\(promptRow);3H")
        fflush(stdout)
    }

    private func write(_ s: String) {
        s.withCString { ptr in
            _ = Foundation.write(STDOUT_FILENO, ptr, strlen(ptr))
        }
    }
}
