import SwiftUI

@main
struct DropApp: App {
    @State private var repository = DropRepository()
    @State private var bleManager: BleManager

    init() {
        let repo = DropRepository()
        _repository = State(initialValue: repo)
        _bleManager = State(initialValue: BleManager(repository: repo))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(repository)
                .environment(bleManager)
        }
    }
}
