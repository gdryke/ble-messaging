import Foundation

/// ANSI-based two-column terminal UI.
///
/// Layout:
/// ┌──────────────────┬──────────────────┐
/// │ System / BLE Log │   Chat Messages  │
/// │                  │                  │
/// ├──────────────────┴──────────────────┤
/// │ ── status bar ──────────────────    │
/// │ > command prompt                    │
/// └─────────────────────────────────────┘
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
    private let blue = "\u{1B}[34m"

    // MARK: - Layout

    private var rows: Int = 24
    private var cols: Int = 80

    // Derived layout (1-based rows)
    private var contentTop: Int { 1 }
    private var contentBottom: Int { statusRow - 1 }
    private var statusRow: Int { rows - 1 }
    private var promptRow: Int { rows }

    // Column split: left = system, right = chat
    private var dividerCol: Int { cols / 2 }
    private var leftWidth: Int { dividerCol - 1 }
    private var rightWidth: Int { cols - dividerCol - 1 }

    /// Whether verbose BLE logging is enabled
    var verboseLogging: Bool = true

    private let lock = NSLock()

    // Ring buffers for each column
    private var systemLines: [String] = []
    private var chatLines: [String] = []
    private let maxBuffer = 500

    // Track line counts for independent scrolling
    private var systemVisibleCount: Int { contentBottom - contentTop + 1 }
    private var chatVisibleCount: Int { contentBottom - contentTop + 1 }

    // Saved terminal state for clean exit
    private var originalTermios: termios?

    // MARK: - Init / teardown

    init() {
        detectSize()
        setupScreen()
        installSigwinch()
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        // Reset scroll region, clear, cursor home
        rawWrite("\(esc)r\(esc)2J\(esc)1;1H\(esc)?25h")
        fflush(stdout)
    }

    private func detectSize() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            rows = max(Int(ws.ws_row), 10)
            cols = max(Int(ws.ws_col), 40)
        }
    }

    private func installSigwinch() {
        signal(SIGWINCH) { _ in
            // Handled next time we draw — just flag a resize
        }
    }

    private func setupScreen() {
        rawWrite("\(esc)?25l")  // hide cursor during setup
        rawWrite("\(esc)2J")    // clear screen
        drawChrome()
        rawWrite("\(esc)?25h")  // show cursor
        redrawPrompt()
    }

    // MARK: - Chrome (divider, headers, status bar)

    private func drawChrome() {
        // Column headers
        let sysHeader = " System Log"
        let chatHeader = " Chat"

        rawWrite("\(esc)1;1H\(bold)\(cyan)\(pad(sysHeader, leftWidth))\(reset)")
        rawWrite("\(esc)1;\(dividerCol + 1)H\(bold)\(green)\(pad(chatHeader, rightWidth))\(reset)")

        // Vertical divider
        for row in contentTop...contentBottom {
            rawWrite("\(esc)\(row);\(dividerCol)H\(dim)│\(reset)")
        }

        drawStatusBar("Drop — starting…")
    }

    // MARK: - Public API

    /// Log a BLE / system event in the left column (dim cyan).
    func systemLog(_ message: String) {
        guard verboseLogging else { return }
        let line = "\(dim)\(cyan)\(message)\(reset)"
        lock.lock(); defer { lock.unlock() }
        systemLines.append(message)
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        redrawLeftColumn()
    }

    /// Print an informational line in the left column (white).
    func info(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        systemLines.append(message)
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        redrawLeftColumn()
    }

    /// Print an error in the left column (red).
    func error(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        systemLines.append("❌ \(message)")
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        redrawLeftColumn()
    }

    /// Print a success line in the left column (green).
    func success(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        systemLines.append("✅ \(message)")
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        redrawLeftColumn()
    }

    /// Print command output in the left column.
    func commandOutput(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        systemLines.append(message)
        if systemLines.count > maxBuffer { systemLines.removeFirst() }
        redrawLeftColumn()
    }

    /// Display a chat message in the right column.
    func chatMessage(from sender: String, text: String, incoming: Bool) {
        let arrow = incoming ? "◀" : "▶"
        let formatted = "\(arrow) \(sender): \(text)"
        lock.lock(); defer { lock.unlock() }
        chatLines.append(formatted)
        if chatLines.count > maxBuffer { chatLines.removeFirst() }
        redrawRightColumn(lastMessageIncoming: incoming)
    }

    /// Update the status bar.
    func statusBar(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        drawStatusBar(text)
        restoreCursor()
    }

    /// Redraw the prompt at the bottom row.
    func redrawPrompt() {
        rawWrite("\(esc)\(promptRow);1H\(esc)2K\(bold)\(white)> \(reset)")
        fflush(stdout)
    }

    /// Clear just the prompt text (for Ctrl+C).
    func clearPrompt() {
        rawWrite("\(esc)\(promptRow);1H\(esc)2K\(bold)\(white)> \(reset)")
        fflush(stdout)
    }

    // MARK: - Column drawing

    private func redrawLeftColumn() {
        rawWrite("\(esc)s")  // save cursor
        let visibleRows = contentBottom - contentTop  // reserve row 1 for header
        let startRow = contentTop + 1  // skip header row
        let startIdx = max(0, systemLines.count - visibleRows)
        let visible = Array(systemLines.suffix(visibleRows))

        for i in 0..<visibleRows {
            let row = startRow + i
            rawWrite("\(esc)\(row);1H\(esc)2K")  // move + clear full line first is wrong, need to clear only left side
            // Clear left column area only
            rawWrite("\(esc)\(row);1H")
            let blank = String(repeating: " ", count: leftWidth)
            rawWrite(blank)
            // Draw divider
            rawWrite("\(esc)\(row);\(dividerCol)H\(dim)│\(reset)")

            if i < visible.count {
                let trimmed = trimToWidth(visible[i], leftWidth - 1)
                let isError = visible[i].hasPrefix("❌")
                let isSuccess = visible[i].hasPrefix("✅")
                let color = isError ? red : (isSuccess ? green : "\(dim)\(cyan)")
                rawWrite("\(esc)\(row);1H\(color) \(trimmed)\(reset)")
            }
        }
        rawWrite("\(esc)u")  // restore cursor
        fflush(stdout)
    }

    private func redrawRightColumn(lastMessageIncoming: Bool? = nil) {
        rawWrite("\(esc)s")  // save cursor
        let visibleRows = contentBottom - contentTop  // reserve row 1 for header
        let startRow = contentTop + 1
        let visible = Array(chatLines.suffix(visibleRows))

        for i in 0..<visibleRows {
            let row = startRow + i
            // Clear right column area only
            rawWrite("\(esc)\(row);\(dividerCol + 1)H")
            let blank = String(repeating: " ", count: rightWidth)
            rawWrite(blank)

            if i < visible.count {
                let line = visible[i]
                let trimmed = trimToWidth(line, rightWidth - 1)
                let isIncoming = line.hasPrefix("◀")
                let color = isIncoming ? green : yellow
                rawWrite("\(esc)\(row);\(dividerCol + 1)H\(color) \(trimmed)\(reset)")
            }
        }
        rawWrite("\(esc)u")  // restore cursor
        fflush(stdout)
    }

    private func drawStatusBar(_ text: String) {
        rawWrite("\(esc)s")  // save cursor
        let padded = String((" ── " + text + " " + String(repeating: "─", count: max(0, cols))).prefix(cols))
        rawWrite("\(esc)\(statusRow);1H\(esc)2K\(bold)\(magenta)\(padded)\(reset)")
        rawWrite("\(esc)u")  // restore cursor
    }

    private func restoreCursor() {
        rawWrite("\(esc)\(promptRow);3H")
        fflush(stdout)
    }

    // MARK: - Helpers

    private func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    private func trimToWidth(_ s: String, _ width: Int) -> String {
        guard s.count > width else { return s }
        return String(s.prefix(max(0, width - 1))) + "…"
    }

    private func rawWrite(_ s: String) {
        s.withCString { ptr in
            _ = Foundation.write(STDOUT_FILENO, ptr, strlen(ptr))
        }
    }
}
