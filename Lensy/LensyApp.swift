import SwiftUI
import SwiftData

@main
struct LensyApp: App {
    let container: ModelContainer
    @State private var auth = AuthStore()
    @State private var sync: SyncService

    init() {
        let c = try! ModelContainer(for: WearSession.self)
        container = c
        _sync = State(initialValue: SyncService(container: c))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(sync)
        }
        .modelContainer(container)

        MenuBarExtra(isInserted: Binding(get: { sync.activeStartedAt != nil }, set: { _ in })) {
            MenuContent()
                .environment(sync)
        } label: {
            MenuLabel()
                .environment(sync)
        }
        .menuBarExtraStyle(.window)
    }
}