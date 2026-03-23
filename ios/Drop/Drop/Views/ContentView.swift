import SwiftUI

struct ContentView: View {
    @Environment(BleManager.self) private var bleManager
    @Environment(DropRepository.self) private var repository

    var body: some View {
        NavigationStack {
            ConversationListView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        BleStatusIndicator(phase: bleManager.phase)
                    }
                }
        }
        .onAppear {
            bleManager.start()
            repository.loadConversations()
        }
    }
}

// MARK: - BLE Status Indicator

private struct BleStatusIndicator: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(phase.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch phase {
        case .idle: .gray
        case .discovering: .blue
        case .connecting, .handshaking: .orange
        case .transferring: .green
        case .done: .green
        }
    }
}

#Preview {
    ContentView()
        .environment(BleManager(repository: DropRepository()))
        .environment(DropRepository())
}
