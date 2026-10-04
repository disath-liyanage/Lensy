import SwiftUI
import SwiftData

@main
struct LensyApp: App {
    let container: ModelContainer
    @State private var auth = AuthStore()
    @State private var sync: SyncService
    @AppStorage("timerRunning") private var timerRunning = false

    init() {
        let c: ModelContainer
        do {
            c = try ModelContainer(for: WearSession.self)
        } catch {
            print("CONTAINER ERROR:", error)
            c = try! ModelContainer(
                for: WearSession.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        container = c
        let s = SyncService(container: c)
        s.refreshActive()
        _sync = State(initialValue: s)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(sync)
        }
        .modelContainer(container)
    }
}
